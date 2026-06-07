#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - Infrastructure Cleanup for Simulation Use Case
# =============================================================================

log() { echo -e "\033[0;34m[CLEANUP]\033[0m $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EDGE_CONF="${EDGE_CONF:-${ARTIFACT_ROOT}/kubeconfigs/edge.yaml}"
FOG_CONF="${FOG_CONF:-${ARTIFACT_ROOT}/kubeconfigs/fog.yaml}"
CLOUD_CONF="${CLOUD_CONF:-${ARTIFACT_ROOT}/kubeconfigs/cloud.yaml}"
NAMESPACE="simulation"

# Validation
[[ ! -f "$EDGE_CONF" || ! -f "$FOG_CONF" || ! -f "$CLOUD_CONF" ]] && echo "Error: Missing kubeconfig files." && exit 1

clean_cluster() {
  local conf=$1
  local name=$2
  log "Cleaning ${name} cluster..."
  kubectl --insecure-skip-tls-verify --kubeconfig "$conf" delete namespace "$NAMESPACE" --ignore-not-found=true --wait=false || log "Could not clean ${name} (connection or auth error)"
}

clean_cluster "$CLOUD_CONF" "Cloud"
clean_cluster "$FOG_CONF" "Fog"
clean_cluster "$EDGE_CONF" "Edge"

log "Cleanup initiated. Namespaces are being deleted in the background."
