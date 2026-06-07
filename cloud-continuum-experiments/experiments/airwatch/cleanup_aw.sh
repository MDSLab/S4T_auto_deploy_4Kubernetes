#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - Infrastructure Cleanup for AirWatch
# =============================================================================

set -euo pipefail

log()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FOG_KUBECONFIG="${FOG_KUBECONFIG:-${ARTIFACT_ROOT}/kubeconfigs/fog.yaml}"
CLOUD_KUBECONFIG="${CLOUD_KUBECONFIG:-${ARTIFACT_ROOT}/kubeconfigs/cloud.yaml}"

log "Cleaning up AirWatch namespaces..."

# Fog Tier
if [[ -f "$FOG_KUBECONFIG" ]]; then
    kubectl --kubeconfig "$FOG_KUBECONFIG" delete namespace airwatch --ignore-not-found=true --wait=false || true
    kubectl --kubeconfig "$FOG_KUBECONFIG" delete namespace airwatch-remote --ignore-not-found=true --wait=false || true
    ok "Fog cleanup initiated."
else
    warn "Fog kubeconfig not found, skipping."
fi

# Cloud Tier
if [[ -f "$CLOUD_KUBECONFIG" ]]; then
    kubectl --kubeconfig "$CLOUD_KUBECONFIG" delete sparkapplication s4-aggregator -n airwatch-cloud --ignore-not-found=true || warn "Spark application not found"
    kubectl --kubeconfig "$CLOUD_KUBECONFIG" delete namespace airwatch-cloud --ignore-not-found=true --wait=false || true
    ok "Cloud cleanup initiated."
else
    warn "Cloud kubeconfig not found, skipping."
fi

ok "Cleanup completed."
