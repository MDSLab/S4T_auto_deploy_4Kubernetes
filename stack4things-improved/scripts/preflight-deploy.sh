#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

BLOCKERS=0
WARNINGS=0

ok() {
  echo -e "${GREEN}✔${NC} $1"
}

warn() {
  echo -e "${YELLOW}⚠${NC} $1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  echo -e "${RED}✖${NC} $1"
  BLOCKERS=$((BLOCKERS + 1))
}

step() {
  echo ""
  echo "================================================================="
  echo " PRE-FLIGHT: $1"
  echo "================================================================="
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

step "Checking required commands"

for cmd in kubectl ip curl make awk grep cut head; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Command available: $cmd"
  else
    fail "Missing required command: $cmd"
  fi
done

if command -v helm >/dev/null 2>&1; then
  ok "Optional command available: helm"
else
  warn "helm is not installed; deploy script will try to install it automatically"
fi

step "Checking kubeconfig accessibility"

if [ -r /etc/rancher/k3s/k3s.yaml ]; then
  export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  ok "Using kubeconfig: $KUBECONFIG"
elif [ -r /etc/rancher/k3s/k3s.yaml_backup ]; then
  export KUBECONFIG="/etc/rancher/k3s/k3s.yaml_backup"
  ok "Using backup kubeconfig: $KUBECONFIG"
else
  fail "No readable kubeconfig found at /etc/rancher/k3s/k3s.yaml or _backup"
fi

step "Checking Kubernetes cluster reachability"

if command -v kubectl >/dev/null 2>&1 && [ -n "${KUBECONFIG:-}" ]; then
  if kubectl cluster-info --request-timeout=8s >/dev/null 2>&1; then
    ok "Kubernetes API reachable"
  else
    fail "Cannot reach Kubernetes API with current kubeconfig"
  fi
else
  warn "Skipping cluster check because kubectl or kubeconfig is unavailable"
fi

step "Checking repository paths used by deploy script"

required_paths=(
  "${ROOT_DIR}/yaml_file"
  "${ROOT_DIR}/istioconf"
  "${ROOT_DIR}/scripts"
  "${ROOT_DIR}/scripts/compile-settings-for-all-boards.sh"
  "${ROOT_DIR}/scripts/deploy-keycloak-keystone.sh"
  "${ROOT_DIR}/scripts/deploy-rbac-operator.sh"
)

for path in "${required_paths[@]}"; do
  if [ -e "$path" ]; then
    ok "Found: $path"
  else
    fail "Missing required path: $path"
  fi
done

step "Checking Crossplane provider path discovery"

provider_found=""
for path in "${ROOT_DIR}/../crossplane-provider" "${ROOT_DIR}/../../crossplane-provider" "$(dirname "${ROOT_DIR}")/crossplane-provider"; do
  if [ -d "$path" ]; then
    provider_found="$path"
    break
  fi
done

if [ -n "$provider_found" ]; then
  ok "Crossplane provider directory found: $provider_found"
else
  warn "Crossplane provider directory not found in expected locations (deploy will skip provider installation)"
fi

echo ""
echo "================================================================="
echo " PRE-FLIGHT SUMMARY"
echo "================================================================="
echo "Blockers: $BLOCKERS"
echo "Warnings: $WARNINGS"

if [ "$BLOCKERS" -gt 0 ]; then
  echo -e "${RED}Pre-flight FAILED. Fix blockers before running deploy.${NC}"
  exit 1
fi

echo -e "${GREEN}Pre-flight PASSED. You can run deploy-complete-improved.sh.${NC}"
