#!/usr/bin/env bash
# =============================================================================
# deploy-continuum.sh — Cloud Continuum Deployment Orchestrator
#
# Automates the deployment of both use cases described in the paper:
# 1. Renewable Energy Community (REC) - Control-oriented
# 2. AirWatch Urban Monitoring - Monitoring-oriented
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Directories ───────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load Environment ──────────────────────────────────────────────────────
if [ -f "${ROOT_DIR}/.env" ]; then
    log "Loading environment from ${ROOT_DIR}/.env"
    set -a; source "${ROOT_DIR}/.env"; set +a
fi

# ── Configuration Defaults ────────────────────────────────────────────────
REGISTRY="${REGISTRY:-user-registry}"
VERSION="${VERSION:-v1.0.0}"
CLOUD_IP="${CLOUD_IP:-}"
FOG_IP="${FOG_IP:-}"
BUILD_IMAGE=false

# ── Kubeconfigs (Standardized naming) ─────────────────────────────────────
CLOUD_CONF="${ROOT_DIR}/kubeconfigs/cloud.yaml"
FOG_CONF="${ROOT_DIR}/kubeconfigs/fog.yaml"
EDGE_CONF="${ROOT_DIR}/kubeconfigs/edge.yaml"

# ── Prerequisites Check ───────────────────────────────────────────────────
log "Verifying cluster credentials in ${ROOT_DIR}/kubeconfigs/..."
MISSING=0
for f in "$CLOUD_CONF" "$FOG_CONF" "$EDGE_CONF"; do
    if [ ! -f "$f" ]; then
        warn "Kubeconfig not found: $(basename "$f")"
        MISSING=$((MISSING + 1))
    fi
done

if [ "$MISSING" -gt 0 ]; then
    err "Some kubeconfigs are missing. Please follow kubeconfigs/README.md"
fi

if [ -z "$CLOUD_IP" ] || [ -z "$FOG_IP" ]; then
    err "CLOUD_IP and FOG_IP must be defined in .env or as environment variables."
fi

# ── 1. Deploy REC (Simulation) ───────────────────────────────────────────
echo ""
log "═══ 1/2: Deploy REC (Control Use Case) ═══"
REC_ARGS=(
    --cloud-conf "$CLOUD_CONF"
    --fog-conf "$FOG_CONF"
    --edge-conf "$EDGE_CONF"
    --cloud-ip "$CLOUD_IP"
    --fog-ip "$FOG_IP"
    --registry "$REGISTRY"
)
[ "$BUILD_IMAGE" = true ] && REC_ARGS+=(--build)

bash "${ROOT_DIR}/experiments/simulation/deploy_all.sh" "${REC_ARGS[@]}"

# ── 2. Deploy AirWatch ────────────────────────────────────────────────────
echo ""
log "═══ 2/2: Deploy AirWatch (Monitoring Use Case) ═══"
AW_ARGS=(
    --cloud-kubeconfig "$CLOUD_CONF"
    --fog-kubeconfig "$FOG_CONF"
    --registry "$REGISTRY"
    --cloud-insecure-skip-tls-verify
    --fog-insecure-skip-tls-verify
)
[ "$BUILD_IMAGE" = false ] && AW_ARGS+=(--skip-build)

bash "${ROOT_DIR}/experiments/airwatch/deploy.sh" "${AW_ARGS[@]}"

echo ""
ok "Cloud Continuum deployment completed successfully!"
