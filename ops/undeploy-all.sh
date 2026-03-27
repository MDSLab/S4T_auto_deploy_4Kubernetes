#!/bin/bash

################################################################################
# Stack4Things Complete Automated Teardown Script
# 
# Questo script disinstalla l'intero ambiente Stack4Things:
# 1. Rimuove i file locali generati (Certificati TLS, Realm Keycloak)
# 2. Rimuove le risorse Kubernetes (Namespaces, ConfigMaps) o l'intero cluster
# 3. Disinstalla K3s e Helm (se non viene passata la flag --keep-k3s)
#
# Usage: ./undeploy-all.sh [--keep-k3s] [--help]
################################################################################

set -euo pipefail

### Colors ###
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

### Utility functions ###
section() {
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

step() {
  echo ""
  echo -e "${YELLOW}▶ STEP $1: $2${NC}"
}

ok() {
  echo -e "${GREEN}✔${NC} $1"
}

warn() {
  echo -e "${YELLOW}⚠️${NC} $1"
}

fail() {
  echo -e "${RED}✖ ERROR: $1${NC}"
  exit 1
}

### Parse command line arguments ###
KEEP_K3S=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-k3s)
      KEEP_K3S=true
      shift
      ;;
    --help)
      echo "Usage: ./undeploy-all.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --keep-k3s    Pulisce i deployment ma NON disinstalla K3s/Helm"
      echo "  --help        Mostra questo messaggio di aiuto"
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

### Warning Prompt ###
echo -e "${RED}⚠️ ATTENZIONE: Stai per cancellare l'intero ambiente Stack4Things!${NC}"
if [ "$KEEP_K3S" = false ]; then
  echo -e "${RED}Questo comando DISINSTALLERÀ completamente anche il cluster K3s e Helm.${NC}"
else
  echo -e "${YELLOW}Il cluster K3s verrà mantenuto, ma tutte le risorse verranno eliminate.${NC}"
fi
echo ""
read -p "Sei sicuro di voler procedere? [y/N]: " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Operazione annullata."
  exit 0
fi

### Determine script directories ###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK4THINGS_DIR="${SCRIPT_DIR}/../stack4things-improved"
KEYCLOAK_KEYSTONE_DIR="${STACK4THINGS_DIR}/keycloak-keystone-integration"
KEYCLOAK_CONFIG_DIR="${KEYCLOAK_KEYSTONE_DIR}/keycloak-config"
CERTS_DIR="${KEYCLOAK_CONFIG_DIR}/certs"
REALM_FILE="${KEYCLOAK_CONFIG_DIR}/stack4things-realm.json"

### Step 1: Clean Local Files ###
section "Pulizia dei File Locali (Certificati e Configurazioni)"

step "1" "Rimozione certificati TLS e file Realm..."
if [ -d "$CERTS_DIR" ]; then
  rm -rf "$CERTS_DIR"
  ok "Cartella certificati eliminata: $CERTS_DIR"
else
  ok "Cartella certificati non trovata, skippo."
fi

if [ -f "$REALM_FILE" ]; then
  rm -f "$REALM_FILE"
  ok "File di configurazione Realm eliminato: $REALM_FILE"
else
  ok "File Realm non trovato, skippo."
fi

### Step 2: Clean Kubernetes Resources ###
section "Pulizia dell'Ambiente Kubernetes"

if [ "$KEEP_K3S" = true ]; then
  step "2" "Eliminazione mirata delle risorse K8s (Questo può richiedere alcuni minuti)..."
  
  export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  
  # Delete ConfigMaps
  kubectl delete configmap keycloak-certs keycloak-realm-config keystone-config keystone-mapping keystone-sso keystone-wsgi iotronic-ssl-certs -n default --ignore-not-found || true
  kubectl delete configmap keycloak-certs keycloak-realm-config -n keycloak --ignore-not-found || true
  kubectl delete configmap keystone-config keystone-mapping keystone-sso keystone-wsgi -n keystone --ignore-not-found || true
  ok "ConfigMaps eliminate"

  # Delete PVCs
  kubectl delete pvc iotronic-ssl -n default --ignore-not-found || true
  
  # Delete Namespaces (these might take time due to finalizers)
  echo "Cancellazione Namespaces in corso..."
  kubectl delete namespace keycloak keystone crossplane-system metallb-system istio-system istio-ingress --ignore-not-found || warn "Alcuni namespace potrebbero richiedere pulizia manuale"
  ok "Namespace eliminati"
  
else
  step "2" "Disinstallazione profonda di K3s (Tabula Rasa)..."
  
  if command -v k3s-uninstall.sh &>/dev/null || [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh || warn "K3s uninstall script ha restituito un errore"
    ok "K3s disinstallato completamente"
  else
    warn "Script di disinstallazione K3s non trovato. K3s era già stato rimosso?"
  fi
fi

### Step 3: Remove Helm (Optional) ###
if [ "$KEEP_K3S" = false ]; then
  section "Pulizia di Helm"
  step "3" "Rimozione binario di Helm..."
  if command -v helm &>/dev/null; then
    sudo rm -f $(which helm)
    ok "Helm rimosso dal sistema"
  else
    ok "Helm non trovato nel sistema"
  fi
fi

section "Teardown Completato"
echo -e "${GREEN}✅ TUTTO CANCELLATO CON SUCCESSO! L'ambiente è pulito.${NC}"
echo ""

exit 0
