#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/run-crd-suite-${TS}.log"

mkdir -p "${LOG_DIR}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

usage() {
  cat <<EOF
Usage: ./run-crd-suite.sh [OPTIONS]

Wrapper per lanciare in sequenza gli script CRD presenti in scripts/.

Options:
  --board-code CODE   Codice board per injection (override auto-discovery)
  --plugin-name NAME  Nome plugin (default: test-plugin-crd)
  --skip-cleanup      Non eseguire cleanup iniziale board
  --help              Mostra help
EOF
}

BOARD_CODE=""
PLUGIN_NAME="test-plugin-crd"
SKIP_CLEANUP=false
USE_LIVE_BOARD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board-code)
      BOARD_CODE="$2"
      USE_LIVE_BOARD=false
      shift 2
      ;;
    --plugin-name)
      PLUGIN_NAME="$2"
      shift 2
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      err "Argomento sconosciuto: $1"
      usage
      exit 1
      ;;
  esac
done

exec > >(tee -a "${LOG_FILE}") 2>&1

info "Log file: ${LOG_FILE}"
info "Plugin name: ${PLUGIN_NAME}"

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl non trovato"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq non trovato"
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  err "Cluster Kubernetes non raggiungibile"
  exit 1
fi

if ! kubectl get provider -n crossplane-system >/dev/null 2>&1; then
  warn "Provider Crossplane non trovato in crossplane-system (continuo comunque)"
fi

run_step() {
  local title="$1"
  shift
  echo ""
  info "=== ${title} ==="
  "$@"
  ok "${title} completato"
}

# Capture existing board codes to pick one created live in this run.
BOARD_CODES_BEFORE_FILE=""
if [[ "${USE_LIVE_BOARD}" == true ]]; then
  BOARD_CODES_BEFORE_FILE="$(mktemp)"
  kubectl get device -n default -o json 2>/dev/null \
    | jq -r '.items[]?.spec.forProvider.code // empty' \
    | sort -u > "${BOARD_CODES_BEFORE_FILE}" || true
fi

if [[ "${SKIP_CLEANUP}" == false ]] && [[ -x "${SCRIPT_DIR}/cleanup-all-boards.sh" ]]; then
  run_step "Cleanup board esistenti" "${SCRIPT_DIR}/cleanup-all-boards.sh"
else
  warn "Cleanup iniziale saltato"
fi

if [[ -x "${SCRIPT_DIR}/create-all-boards.sh" ]]; then
  run_step "Creazione board CRD" "${SCRIPT_DIR}/create-all-boards.sh"
else
  err "Script mancante o non eseguibile: ${SCRIPT_DIR}/create-all-boards.sh"
  exit 1
fi

if [[ "${USE_LIVE_BOARD}" == true ]]; then
  BOARD_CODES_AFTER_FILE="$(mktemp)"
  kubectl get device -n default -o json \
    | jq -r '.items[]?.spec.forProvider.code // empty' \
    | sort -u > "${BOARD_CODES_AFTER_FILE}"

  BOARD_CODE=$(comm -13 "${BOARD_CODES_BEFORE_FILE}" "${BOARD_CODES_AFTER_FILE}" \
    | grep '^TEST-BOARD-' \
    | tail -n1 || true)

  # Fallback to newest TEST-BOARD device if no set-difference was found.
  if [[ -z "${BOARD_CODE}" ]]; then
    BOARD_CODE=$(kubectl get device -n default --sort-by=.metadata.creationTimestamp -o json \
      | jq -r '.items[]?.spec.forProvider.code // empty' \
      | grep '^TEST-BOARD-' \
      | tail -n1 || true)
  fi

  rm -f "${BOARD_CODES_BEFORE_FILE}" "${BOARD_CODES_AFTER_FILE}"

  if [[ -z "${BOARD_CODE}" ]]; then
    err "Impossibile trovare una board TEST-BOARD creata live per l'injection"
    exit 1
  fi

  info "Board live selezionata per injection: ${BOARD_CODE}"
else
  info "Board code forzato da parametro: ${BOARD_CODE}"
fi

if [[ -x "${SCRIPT_DIR}/compile-settings-for-all-boards.sh" ]]; then
  run_step "Compilazione settings board" "${SCRIPT_DIR}/compile-settings-for-all-boards.sh"
else
  warn "Script non trovato: compile-settings-for-all-boards.sh"
fi

if [[ -x "${SCRIPT_DIR}/sync-boards-online.sh" ]]; then
  run_step "Allineamento board online" "${SCRIPT_DIR}/sync-boards-online.sh"
else
  warn "Script non trovato: sync-boards-online.sh"
fi

if [[ -x "${SCRIPT_DIR}/test-plugin-creation.sh" ]]; then
  run_step "Test creazione plugin" "${SCRIPT_DIR}/test-plugin-creation.sh"
else
  err "Script mancante o non eseguibile: ${SCRIPT_DIR}/test-plugin-creation.sh"
  exit 1
fi

if [[ -x "${SCRIPT_DIR}/inject-plugin-using-crd.sh" ]]; then
  run_step "Injection plugin via CRD" "${SCRIPT_DIR}/inject-plugin-using-crd.sh" "${BOARD_CODE}" "${PLUGIN_NAME}"
else
  warn "Script non trovato: inject-plugin-using-crd.sh"
fi

if [[ -x "${SCRIPT_DIR}/verify-plugins.sh" ]]; then
  run_step "Verifica plugin e injection" "${SCRIPT_DIR}/verify-plugins.sh"
else
  warn "Script non trovato: verify-plugins.sh"
fi

echo ""
ok "Suite CRD completata"
info "Report completo: ${LOG_FILE}"
