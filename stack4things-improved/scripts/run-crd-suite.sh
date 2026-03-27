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
  --plugin-name NAME  Nome plugin per injection (override auto-discovery)
  --skip-cleanup      Non eseguire cleanup iniziale board
  --help              Mostra help
EOF
}

BOARD_CODE=""
PLUGIN_NAME=""
SKIP_CLEANUP=false
USE_LIVE_BOARD=true
USE_LIVE_PLUGIN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board-code)
      BOARD_CODE="$2"
      USE_LIVE_BOARD=false
      shift 2
      ;;
    --plugin-name)
      PLUGIN_NAME="$2"
      USE_LIVE_PLUGIN=false
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
if [[ "${USE_LIVE_PLUGIN}" == true ]]; then
  info "Plugin name: auto-discovery da creazione live"
else
  info "Plugin name forzato da parametro: ${PLUGIN_NAME}"
fi

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

# Capture existing plugin names to pick one created live in this run.
PLUGIN_NAMES_BEFORE_FILE=""
if [[ "${USE_LIVE_PLUGIN}" == true ]]; then
  PLUGIN_NAMES_BEFORE_FILE="$(mktemp)"
  kubectl get plugin -n default -o json 2>/dev/null \
    | jq -r '.items[]?.metadata.name // empty' \
    | sort -u > "${PLUGIN_NAMES_BEFORE_FILE}" || true
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

if [[ "${USE_LIVE_PLUGIN}" == true ]]; then
  PLUGIN_NAMES_AFTER_FILE="$(mktemp)"
  kubectl get plugin -n default -o json \
    | jq -r '.items[]?.metadata.name // empty' \
    | sort -u > "${PLUGIN_NAMES_AFTER_FILE}"

  PLUGIN_NAME=$(comm -13 "${PLUGIN_NAMES_BEFORE_FILE}" "${PLUGIN_NAMES_AFTER_FILE}" \
    | grep '^test-plugin-' \
    | tail -n1 || true)

  # Fallback to newest test-plugin resource if no set-difference was found.
  if [[ -z "${PLUGIN_NAME}" ]]; then
    PLUGIN_NAME=$(kubectl get plugin -n default --sort-by=.metadata.creationTimestamp -o json \
      | jq -r '.items[]?.metadata.name // empty' \
      | grep '^test-plugin-' \
      | tail -n1 || true)
  fi

  rm -f "${PLUGIN_NAMES_BEFORE_FILE}" "${PLUGIN_NAMES_AFTER_FILE}"

  if [[ -z "${PLUGIN_NAME}" ]]; then
    err "Impossibile trovare un plugin test-plugin creato live per l'injection"
    exit 1
  fi

  info "Plugin live selezionato per injection: ${PLUGIN_NAME}"
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
