#!/usr/bin/env bash
# =============================================================================
# deploy_all.sh — Simulation Deployment Orchestrator (REC Use Case)
#
# Usage:
#   ./deploy_all.sh --edge-conf <path> --fog-conf <path> --cloud-conf <path> \
#                   --cloud-ip <ip> --fog-ip <ip> \
#                   [--registry <reg>] [--build]
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── Load Environment Variables ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────
REGISTRY="${REGISTRY:-user-registry}"
BUILD_IMAGE="${BUILD_IMAGE:-false}"
EDGE_CONF="${EDGE_CONF:-${ARTIFACT_ROOT}/kubeconfigs/edge.yaml}"
FOG_CONF="${FOG_CONF:-${ARTIFACT_ROOT}/kubeconfigs/fog.yaml}"
CLOUD_CONF="${CLOUD_CONF:-${ARTIFACT_ROOT}/kubeconfigs/cloud.yaml}"
CLOUD_IP="${CLOUD_IP:-}"
FOG_IP="${FOG_IP:-}"

# ── Parsing Arguments ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --edge-conf)    EDGE_CONF="$2";    shift 2 ;;
    --fog-conf)     FOG_CONF="$2";     shift 2 ;;
    --cloud-conf)   CLOUD_CONF="$2";   shift 2 ;;
    --cloud-ip)     CLOUD_IP="$2";     shift 2 ;;
    --fog-ip)       FOG_IP="$2";       shift 2 ;;
    --registry)     REGISTRY="$2";     shift 2 ;;
    --build)        BUILD_IMAGE=true;  shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validation
[[ ! -f "$EDGE_CONF" || ! -f "$FOG_CONF" || ! -f "$CLOUD_CONF" ]] && echo "Error: Missing kubeconfig files." && exit 1
[[ -z "$CLOUD_IP" || -z "$FOG_IP" ]] && echo "Error: Missing IP addresses for Cloud and Fog." && exit 1

IMAGE_NAME="${REGISTRY}/rec-microservices:v1.0.0"
SPARK_IMAGE_NAME="${REGISTRY}/rec-spark:v1.0.0"

# ── 1. Build & Push (Optional) ───────────────────────────────────────────
if [ "$BUILD_IMAGE" = true ]; then
  log "Building REC images..."
  docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/src"
  docker push "${IMAGE_NAME}"
  docker build -f "${SCRIPT_DIR}/src/Dockerfile.spark" -t "${SPARK_IMAGE_NAME}" "${SCRIPT_DIR}/src"
  docker push "${SPARK_IMAGE_NAME}"
  ok "Images ready."
fi

# ── Deploy Helper ─────────────────────────────────────────────────────────
deploy_to() {
  local conf=$1; local file=$2; local target=$3
  log "Deploying to ${target}..."
  kubectl --kubeconfig "$conf" create namespace simulation --dry-run=client -o yaml | kubectl --kubeconfig "$conf" apply -f -
  sed -e "s/<CLOUD_IP>/${CLOUD_IP}/g" \
      -e "s/<FOG_IP>/${FOG_IP}/g" \
      -e "s|__MICROSERVICES_IMAGE__|${IMAGE_NAME}|g" \
      -e "s|__SPARK_IMAGE__|${SPARK_IMAGE_NAME}|g" \
      "$file" | kubectl --kubeconfig "$conf" apply -f -
}

# ── 2. Cloud Tier ─────────────────────────────────────────────────────────
log "═══ 1/3: Deploying Cloud Tier (REC Analytics) ═══"
# Note: In a production artifact, operators would be pre-installed or handled via Helm
kubectl --kubeconfig "$CLOUD_CONF" apply -f "${SCRIPT_DIR}/k3s/cloud/00-infrastructure-policy.yaml"
deploy_to "$CLOUD_CONF" "${SCRIPT_DIR}/k3s/cloud/01-spark-rbac.yaml" "Cloud (RBAC)"
deploy_to "$CLOUD_CONF" "${SCRIPT_DIR}/k3s/cloud/cloud-deploy.yaml" "Cloud (Kafka/TEANS)"
deploy_to "$CLOUD_CONF" "${SCRIPT_DIR}/k3s/cloud/spark-deploy.yaml" "Cloud (Spark Aggregator)"

# ── 3. Fog Tier ──────────────────────────────────────────────────────────
log "═══ 2/3: Deploying Fog Tier (REC Mediation) ═══"
deploy_to "$FOG_CONF" "${SCRIPT_DIR}/k3s/fog/fog-mediator-deploy.yaml" "Fog (Mediator)"
deploy_to "$FOG_CONF" "${SCRIPT_DIR}/k3s/fog/fog-source-deploy.yaml" "Fog (Source)"

# ── 4. Edge Tier ──────────────────────────────────────────────────────────
log "═══ 3/3: Deploying Edge Tier (Gateway) ═══"
deploy_to "$EDGE_CONF" "${SCRIPT_DIR}/k3s/edge/edge-gateway-deploy.yaml" "Edge (Gateway)"

echo ""
ok "REC Simulation successfully deployed across the continuum!"
