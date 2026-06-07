#!/usr/bin/env bash
# =============================================================================
# deploy.sh — AirWatch Monitoring Deployment Orchestrator
#
# Usage:
#   ./deploy.sh [--registry <registry>] [--skip-build] [--skip-cloud] \
#               [--fog-kubeconfig <path>] [--cloud-kubeconfig <path>] \
#               [--fog-insecure-skip-tls-verify] [--cloud-insecure-skip-tls-verify]
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────
REGISTRY="user-registry"
VERSION="v1.0.0"
SKIP_BUILD=false
SKIP_CLOUD=false
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FOG_KUBECONFIG="${ARTIFACT_ROOT}/kubeconfigs/fog.yaml"
CLOUD_KUBECONFIG="${ARTIFACT_ROOT}/kubeconfigs/cloud.yaml"
FOG_INSECURE_SKIP_TLS=false
CLOUD_INSECURE_SKIP_TLS=false

# ── Parsing arguments ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --registry) REGISTRY="$2"; shift 2 ;;
    --skip-build)  SKIP_BUILD=true; shift ;;
    --skip-cloud)  SKIP_CLOUD=true; shift ;;
    --fog-kubeconfig) FOG_KUBECONFIG="$2"; shift 2 ;;
    --cloud-kubeconfig) CLOUD_KUBECONFIG="$2"; shift 2 ;;
    --fog-insecure-skip-tls-verify) FOG_INSECURE_SKIP_TLS=true; shift ;;
    --cloud-insecure-skip-tls-verify) CLOUD_INSECURE_SKIP_TLS=true; shift ;;
    *) err "Unknown argument: $1" ;;
  esac
done

PIPELINE_IMAGE="${REGISTRY}/airwatch-pipeline:${VERSION}"
REMOTE_IMAGE="${REGISTRY}/airwatch-remote:${VERSION}"
SPARK_IMAGE="${REGISTRY}/airwatch-spark-analytics:${VERSION}"

echo ""
log "═══ Deploying AirWatch Monitoring Use Case ═══"
log "Fog kubeconfig:   ${FOG_KUBECONFIG}"
log "Cloud kubeconfig: ${CLOUD_KUBECONFIG}"
echo ""

KCTL_FOG=(kubectl --kubeconfig "$FOG_KUBECONFIG")
[ "$FOG_INSECURE_SKIP_TLS" = true ] && KCTL_FOG+=(--insecure-skip-tls-verify)

KCTL_CLOUD=(kubectl --kubeconfig "$CLOUD_KUBECONFIG")
[ "$CLOUD_INSECURE_SKIP_TLS" = true ] && KCTL_CLOUD+=(--insecure-skip-tls-verify)

kf() { "${KCTL_FOG[@]}" "$@"; }
kc() { "${KCTL_CLOUD[@]}" "$@"; }

# ── 1. Build and Push ─────────────────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
  log "Building AirWatch images..."
  docker build -t "${PIPELINE_IMAGE}" "${SCRIPT_DIR}/pipeline/"
  docker push "${PIPELINE_IMAGE}"
  docker build -t "${REMOTE_IMAGE}" "${SCRIPT_DIR}/remote/"
  docker push "${REMOTE_IMAGE}"
  if [ "$SKIP_CLOUD" = false ]; then
    docker build -t "${SPARK_IMAGE}" "${SCRIPT_DIR}/cloud/spark/"
    docker push "${SPARK_IMAGE}"
  fi
  ok "Images ready."
fi

# ── 2. Fog Tier Deployment ────────────────────────────────────────────────
log "Deploying Fog Tier components..."
kf apply -f "${SCRIPT_DIR}/k3s/shared/namespaces.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog/configmap-secret.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog/influxdb-external.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog/s1.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog/s2-s5.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog-remote/configmap-secret.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog-remote/r2.yaml"
kf apply -f "${SCRIPT_DIR}/k3s/fog-remote/grafana.yaml"
ok "Fog Tier online."

# ── 3. Cloud Tier Deployment ──────────────────────────────────────────────
if [ "$SKIP_CLOUD" = false ]; then
  log "Deploying Cloud Tier analytics..."
  # Standardized Kafka/Spark deployment logic (simplified for artifact)
  kc apply -f "${SCRIPT_DIR}/cloud/k3s/airwatch-cloud/spark-operator.yaml"
  kc apply -f "${SCRIPT_DIR}/cloud/k3s/airwatch-cloud/s4-spark-application.yaml"
  ok "Cloud Tier online."
fi

echo ""
ok "AirWatch successfully deployed!"
