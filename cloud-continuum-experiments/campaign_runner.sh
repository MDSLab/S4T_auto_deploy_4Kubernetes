#!/usr/bin/env bash
# =============================================================================
# campaign_runner.sh — Experimental Campaign Orchestrator
#
# Automates the execution of multiple experimental runs across the continuum.
# Ensures state isolation and consistent measurement.
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────
BOARDS=("pod-cluster" "rasp")
PLUGINS=("airwatch-mqtt")
RUNS=10
DURATION_MIN=10
WAIT_BUFFER_SEC=30 # Buffer for startup/shutdown

# Root directory
JAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$JAR_DIR"

# Standardized Kubeconfigs
CLOUD_CONF="./kubeconfigs/cloud.yaml"
FOG_CONF="./kubeconfigs/fog.yaml"
EDGE_CONF="./kubeconfigs/edge.yaml"

# ── Colors and Logging ──────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${BLUE}[CAMPAIGN]${NC} $*"; }
ok()  { echo -e "${GREEN}[SUCCESS]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}     $*"; }

# ── Utility: Environment Reset ───────────────────────────────────────────
set_ingestion_mode() {
    local mode=$1    # polling or streaming
    local app=$2     # airwatch or rec
    
    log "Switching Fog ingestion mode for $app to $mode..."
    
    if [[ "$app" == "airwatch" ]]; then
        # Patch ConfigMap on Fog cluster
        kubectl --kubeconfig "$FOG_CONF" --insecure-skip-tls-verify patch configmap airwatch-config -n airwatch --type merge -p "{\"data\":{\"INGESTION_MODE\":\"$mode\"}}"
        # Restart ingestion service (s1)
        kubectl --kubeconfig "$FOG_CONF" --insecure-skip-tls-verify rollout restart deployment s1 -n airwatch
        kubectl --kubeconfig "$FOG_CONF" --insecure-skip-tls-verify rollout status deployment s1 -n airwatch --timeout=60s || true
    else
        # Patch Deployment for REC on Fog cluster
        kubectl --kubeconfig "$FOG_CONF" --insecure-skip-tls-verify set env deployment/eprem INGESTION_MODE="$mode" -n simulation
        kubectl --kubeconfig "$FOG_CONF" --insecure-skip-tls-verify rollout status deployment eprem -n simulation --timeout=60s || true
    fi
}

reset_state() {
    log "Resetting stateful components (InfluxDB and Kafka) for isolation..."
    
    # Reset InfluxDB on Fog cluster
    INFLUX_POD=$(kubectl --kubeconfig "$FOG_CONF" get pods -n simulation -l app=influxdb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$INFLUX_POD" ]]; then
        kubectl --kubeconfig "$FOG_CONF" exec -n simulation "$INFLUX_POD" -- influx -username admin -password admin -execute "DROP DATABASE airwatch; CREATE DATABASE airwatch" || true
    fi

    # Reset Kafka topics on Cloud cluster
    KAFKA_POD=$(kubectl --kubeconfig "$CLOUD_CONF" get pods -n simulation -l app=kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$KAFKA_POD" ]]; then
        kubectl --kubeconfig "$CLOUD_CONF" exec -n simulation "$KAFKA_POD" -- kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic airwatch-normalized --if-exists || true
        kubectl --kubeconfig "$CLOUD_CONF" exec -n simulation "$KAFKA_POD" -- kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic production-forecasts --if-exists || true
    fi
}

# ── Execution Loop ───────────────────────────────────────────────────────
for BOARD in "${BOARDS[@]}"; do
    for PLUGIN in "${PLUGINS[@]}"; do
        for ((RUN=1; RUN<=RUNS; RUN++)); do
            
            RUN_TAG="${PLUGIN}-${BOARD}-run${RUN}"
            OUT_DIR="results-campaign/${RUN_TAG}"
            
            echo -e "\n${YELLOW}=======================================================${NC}"
            log "STARTING RUN: $RUN_TAG"
            echo -e "${YELLOW}=======================================================${NC}"

            # 1. Reset
            reset_state

            # 1b. Configure Ingestion Mode
            MODE="polling"
            [[ "$PLUGIN" == *"-mqtt"* || "$PLUGIN" == *"_mqtt"* ]] && MODE="streaming"
            
            APP_TYPE="airwatch"
            [[ "$PLUGIN" == "REC"* ]] && APP_TYPE="rec"
            
            set_ingestion_mode "$MODE" "$APP_TYPE"

            # 2. Start Plugin via IoTronic
            log "Starting plugin $PLUGIN on board $BOARD..."
            bash manage_plugins.sh start "$BOARD" "$PLUGIN"
            
            # 3. Execution Duration
            log "Executing for $DURATION_MIN minutes..."
            sleep "$WAIT_BUFFER_SEC" # Warmup
            
            # Background resource sampling
            python3 resource_sampler.py "${BOARD}-${PLUGIN}-run${RUN}" 5 &
            SAMPLER_PID=$!
            
            # Experiment wait
            sleep $((DURATION_MIN * 60))
            
            # 4. Stop Plugin
            log "Stopping plugin..."
            bash manage_plugins.sh stop "$BOARD" "$PLUGIN"
            kill "$SAMPLER_PID" || true
            sleep "$WAIT_BUFFER_SEC" # Cooldown

            # 5. Data Extraction
            log "Extracting scientific metrics..."
            mkdir -p "$OUT_DIR"
            
            APP_FLAG="all"
            [[ "$PLUGIN" == "airwatch"* ]] && APP_FLAG="airwatch"
            [[ "$PLUGIN" == "REC"* ]] && APP_FLAG="rec"

            bash extract_metrics.sh \
                --app "$APP_FLAG" \
                --minutes $((DURATION_MIN + 5)) \
                --scientific \
                --run-id "$RUN_TAG" \
                --output-dir "$OUT_DIR"
            
            # 6. Metadata and Resource logs
            python3 generate_metadata.py "$RUN_TAG"
            cp experiment_metadata.json "$OUT_DIR/"
            mv "resource_utilization_${BOARD}-${PLUGIN}-run${RUN}.csv" "$OUT_DIR/" 2>/dev/null || true
            
            ok "Completed: $RUN_TAG"
            log "Cooling down for 30s..."
            sleep 30
        done
    done
done

echo -e "\n${GREEN}=======================================================${NC}"
ok "EXPERIMENTAL CAMPAIGN COMPLETED SUCCESSFULLY!"
echo -e "${GREEN}=======================================================${NC}"
