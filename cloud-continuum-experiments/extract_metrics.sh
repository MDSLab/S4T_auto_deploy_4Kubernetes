#!/usr/bin/env bash
# =============================================================================
# extract_metrics.sh - Automated Metrics Extraction for FGCS Artifact
# =============================================================================

set -u -o pipefail

MINUTES=10
APP="all"
SCIENTIFIC=false
OUT_DIR="./experiment-results"
INFLUX_DB="airwatch"
INFLUX_USER="admin"
INFLUX_PASSWORD="admin"
INFLUX_NS="default"
RUN_ID=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCFG_DIR="${SCRIPT_DIR}/kubeconfigs"

LOCAL_KCFG="${KCFG_DIR}/edge.yaml"
CLOUD_KCFG="${KCFG_DIR}/cloud.yaml"
FOG_KCFG="${KCFG_DIR}/fog.yaml"

# Support local execution if kubeconfigs are not provided
FALLBACK_LOCAL="/etc/rancher/k3s/k3s.yaml"
if [[ -f "$FALLBACK_LOCAL" && ! -f "$LOCAL_KCFG" ]]; then LOCAL_KCFG="$FALLBACK_LOCAL"; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes)    MINUTES="$2"; shift 2 ;;
    --hours)      MINUTES=$(($2 * 60)); shift 2 ;;
    --app)        APP="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --scientific) SCIENTIFIC=true; shift ;;
    --run-id)     RUN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$OUT_DIR/logs"

add_run_id_column() {
    local file="$1"
    [[ -z "$RUN_ID" ]] && return
    local tmp=$(mktemp)
    awk -v run="$RUN_ID" 'NR==1 {print "run_id," $0} NR>1 {print run "," $0}' "$file" > "$tmp" && mv "$tmp" "$file"
}

query_influx_to_csv() {
    local query="$1"
    local file="$2"
    local pod=$(kubectl --kubeconfig "$LOCAL_KCFG" --insecure-skip-tls-verify get pods -n "$INFLUX_NS" -l app=influxdb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -z "$pod" ]] && pod=$(kubectl --kubeconfig "$LOCAL_KCFG" --insecure-skip-tls-verify get pods -n "$INFLUX_NS" -l app.kubernetes.io/instance=influxdb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
        kubectl --kubeconfig "$LOCAL_KCFG" --insecure-skip-tls-verify exec -n "$INFLUX_NS" "$pod" -- \
            influx -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -database "$INFLUX_DB" \
            -execute "$query" -format csv > "$file" 2>/dev/null
        add_run_id_column "$file"
    fi
}

kv_extract() {
    local line="$1"
    local key="$2"
    # Supports both key=val and key:val for flexibility
    echo "$line" | sed -n "s/.*[ ,]${key}[=:]\([^, ]*\).*/\1/p"
}

extract_infrastructure() {
    echo "[INFO] Extracting Edge logs (Remote: <PHYSICAL_EDGE_IP>)..."
    if command -v sshpass &>/dev/null; then
        # SSH timeout to avoid hanging if the board is offline
        if timeout 10s sshpass -p "arancino" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@<PHYSICAL_EDGE_IP> "tail -n 2000 /var/log/iotronic/lightning-rod.log" > "${OUT_DIR}/logs/edge_rasp_remote.log" 2>/dev/null; then
            if [[ -s "${OUT_DIR}/logs/edge_rasp_remote.log" ]]; then
                echo "[OK] Raspberry Pi logs extracted via SSH."
            fi
        else
            echo "[WARN] Could not connect to board (timeout or SSH error). Skipping SSH extraction..."
        fi
    fi

    LR_PODS=$(kubectl --kubeconfig "$LOCAL_KCFG" --insecure-skip-tls-verify get pods -l service.istio.io/canonical-name=lightning-rod -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    [[ -z "$LR_PODS" ]] && LR_PODS=$(kubectl --kubeconfig "$LOCAL_KCFG" --insecure-skip-tls-verify get pods -l io.kompose.service=lightning-rod -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for pod in $LR_PODS; do
        kubectl --kubeconfig "$LOCAL_KCFG" --insecure-skip-tls-verify logs "$pod" --since="${MINUTES}m" > "${OUT_DIR}/logs/edge_lr_${pod}.log" 2>/dev/null
    done
}

extract_airwatch() {
    echo "[INFO] Extracting AirWatch metrics..."
    query_influx_to_csv "SELECT * FROM \"environmental_data\" WHERE \"source\"='edge-node' AND time > now() - ${MINUTES}m" "${OUT_DIR}/airwatch_raw.csv"
    query_influx_to_csv "SELECT * FROM \"env_aggregated_spark\" WHERE time > now() - ${MINUTES}m" "${OUT_DIR}/airwatch_aggregated.csv"
    for srv in s1 s2 s3 s4 s5; do
        POD=$(kubectl --kubeconfig "$FOG_KCFG" --insecure-skip-tls-verify get pods -n airwatch -l "app=${srv}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [[ -n "$POD" ]] && kubectl --kubeconfig "$FOG_KCFG" --insecure-skip-tls-verify logs -n airwatch "$POD" --since="${MINUTES}m" > "${OUT_DIR}/logs/fog_${srv}.log" 2>/dev/null
    done
    
    # R2 Remote Sink
    R2_POD=$(kubectl --kubeconfig "$FOG_KCFG" --insecure-skip-tls-verify get pods -n airwatch-remote -l "app=r2" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$R2_POD" ]] && kubectl --kubeconfig "$FOG_KCFG" --insecure-skip-tls-verify logs -n airwatch-remote "$R2_POD" --since="${MINUTES}m" > "${OUT_DIR}/logs/fog_r2.log" 2>/dev/null

    SPARK_POD=$(kubectl --kubeconfig "$CLOUD_KCFG" --insecure-skip-tls-verify get pods -n airwatch-cloud -l "spark-role=driver" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -z "$SPARK_POD" ]] && SPARK_POD=$(kubectl --kubeconfig "$CLOUD_KCFG" --insecure-skip-tls-verify get pods -n airwatch-cloud -l "sparkoperator.k8s.io/app-name=s4-aggregator" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$SPARK_POD" ]]; then
        kubectl --kubeconfig "$CLOUD_KCFG" --insecure-skip-tls-verify logs -n airwatch-cloud "$SPARK_POD" --since="${MINUTES}m" > "${OUT_DIR}/logs/cloud_spark_driver_airwatch.log" 2>/dev/null
    fi
}

extract_airwatch_latency_csv() {
    local out="${OUT_DIR}/scientific_latency_airwatch.csv"
    echo "run_id,agent,edge_to_fog_ms,fog_to_kafka_ms" > "$out"

    local file_s1="${OUT_DIR}/logs/fog_s1.log"
    if [[ -f "$file_s1" ]]; then
        grep "\[TEST-3\]" "$file_s1" | while read -r line; do
            local lat=$(echo "$line" | sed -n 's/.*latency: \([0-9.]*\) ms.*/\1/p')
            echo "${RUN_ID},s1,$lat," >> "$out"
        done
    fi

    local file_s2="${OUT_DIR}/logs/fog_s2.log"
    if [[ -f "$file_s2" ]]; then
        grep -E "\[TEST-4\]|Normalization latency" "$file_s2" | while read -r line; do
            local lat=$(echo "$line" | sed -n 's/.*latency (Kafka): \([0-9.]*\) ms.*/\1/p')
            [[ -z "$lat" ]] && lat=$(echo "$line" | sed -n 's/.*latency for [^:]*: \([0-9.]*\) ms.*/\1/p')
            [[ -z "$lat" ]] && lat=$(echo "$line" | sed -n 's/.*latency: \([0-9.]*\) ms.*/\1/p')
            if [[ -n "$lat" ]]; then
                echo "${RUN_ID},s2,,$lat" >> "$out"
            fi
        done
    fi

    local file_s5="${OUT_DIR}/logs/fog_s5.log"
    if [[ -f "$file_s5" ]]; then
        grep "Alert routing latency" "$file_s5" | while read -r line; do
            local lat=$(echo "$line" | sed -n 's/.*latency for [^:]*: \([0-9.]*\) ms.*/\1/p')
            echo "${RUN_ID},s5_alert,$lat," >> "$out"
        done
    fi
    
    local spark_out="${OUT_DIR}/scientific_spark_processing.csv"
    echo "run_id,window,wall_clock_ts,processing_latency_ms" > "$spark_out"
    local file_spark="${OUT_DIR}/logs/cloud_spark_driver_airwatch.log"
    if [[ -f "$file_spark" ]]; then
        grep "\[SPARK\]" "$file_spark" | grep -v "aggregate=0" | while read -r line; do
            local win=$(echo "$line" | sed -n 's/.*Window \[\(.*\)\] written.*/\1/p')
            local ts=$(echo "$line" | sed -n 's/.*written at \([0-9]*\).*/\1/p')
            local lat=$(echo "$line" | sed -n 's/.*processing_latency_ms: \([0-9]*\).*/\1/p')
            if [[ -n "$lat" ]] && [ "$lat" -lt 10000 ]; then
                echo "${RUN_ID},\"$win\",$ts,$lat" >> "$spark_out"
            fi
        done
    fi
}

extract_rec() {
    echo "[INFO] Extracting REC metrics..."
    query_influx_to_csv "SELECT * FROM \"environmental_data\" WHERE \"source\"='edge-energy' AND time > now() - ${MINUTES}m" "${OUT_DIR}/rec_raw_energy.csv"
    query_influx_to_csv "SELECT * FROM \"energy_balance\" WHERE time > now() - ${MINUTES}m" "${OUT_DIR}/rec_balance.csv"

    POD_EPREM=$(kubectl --kubeconfig "$FOG_KCFG" --insecure-skip-tls-verify get pods -n simulation -l "app=eprem" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$POD_EPREM" ]] && kubectl --kubeconfig "$FOG_KCFG" --insecure-skip-tls-verify logs -n simulation "$POD_EPREM" --since="${MINUTES}m" > "${OUT_DIR}/logs/fog_eprem_rec.log" 2>/dev/null

    for srv in teans ecrem; do
        POD=$(kubectl --kubeconfig "$CLOUD_KCFG" --insecure-skip-tls-verify get pods -n simulation -l "app=${srv}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [[ -n "$POD" ]] && kubectl --kubeconfig "$CLOUD_KCFG" --insecure-skip-tls-verify logs -n simulation "$POD" --since="${MINUTES}m" > "${OUT_DIR}/logs/cloud_${srv}.log" 2>/dev/null
    done
}

extract_edge_records_csv() {
    local out="${OUT_DIR}/scientific_edge_records.csv"
    echo "run_id,record_id,sequence,runtime,generated_at,production,consumption,source_log" > "$out"
    local file line
    for file in "${OUT_DIR}"/logs/*.log; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            [[ "$line" == *"[TRACE] EDGE_RECORD"* ]] || continue
            echo "${RUN_ID},$(kv_extract "$line" "record_id"),$(kv_extract "$line" "sequence"),$(kv_extract "$line" "runtime"),$(kv_extract "$line" "generated_at"),$(kv_extract "$line" "production"),$(kv_extract "$line" "consumption"),$(basename "$file")" >> "$out"
        done < "$file"
    done
}

extract_latency_csv() {
    local out="${OUT_DIR}/scientific_latency_rec.csv"
    echo "run_id,producer_id,sequence,mode,edge_to_fog_ms,influx_query_ms,eprem_processing_ms,forecast_ts,estimated_production,source_log" > "$out"
    local file="${OUT_DIR}/logs/fog_eprem_rec.log"
    local line
    [[ -f "$file" ]] || return
    while IFS= read -r line; do
        [[ "$line" == *"[TRACE] FORECAST_EMIT"* ]] || continue
        echo "${RUN_ID},$(kv_extract "$line" "producer_id"),$(kv_extract "$line" "sequence"),$(kv_extract "$line" "mode"),$(kv_extract "$line" "edge_to_fog_ms"),$(kv_extract "$line" "influx_query_ms"),$(kv_extract "$line" "eprem_processing_ms"),$(kv_extract "$line" "forecast_ts"),$(kv_extract "$line" "estimated_production"),$(basename "$file")" >> "$out"
    done < "$file"
}

extract_decision_csv() {
    local out="${OUT_DIR}/scientific_decisions_rec.csv"
    echo "run_id,type,producer,household,task_id,sequence,provenance,action,balance,edge_to_fog_ms,influx_query_ms,eprem_processing_ms,fog_to_cloud_ms,edge_to_cloud_ms,kafka_transit_ms,teans_processing_ms,source_log" > "$out"
    local file="${OUT_DIR}/logs/cloud_teans.log"
    local line
    [[ -f "$file" ]] || return
    while IFS= read -r line; do
        [[ "$line" == *"[DECISION_TRACE]"* ]] || continue
        echo "${RUN_ID},$(kv_extract "$line" "type"),$(kv_extract "$line" "producer"),$(kv_extract "$line" "household"),$(kv_extract "$line" "task_id"),$(kv_extract "$line" "sequence"),$(kv_extract "$line" "provenance"),$(kv_extract "$line" "action"),$(kv_extract "$line" "balance"),$(kv_extract "$line" "edge_to_fog_ms"),$(kv_extract "$line" "influx_query_ms"),$(kv_extract "$line" "eprem_processing_ms"),$(kv_extract "$line" "fog_to_cloud_ms"),$(kv_extract "$line" "edge_to_cloud_ms"),$(kv_extract "$line" "kafka_transit_ms"),$(kv_extract "$line" "teans_processing_ms"),$(basename "$file")" >> "$out"
    done < "$file"
}

extract_scientific() {
    echo "[INFO] Extracting Scientific Metrics..."
    local SCI_FILE="${OUT_DIR}/scientific_metrics_report.txt"
    {
        echo "=== FGCS SCIENTIFIC METRICS REPORT ==="
        echo "Run ID: ${RUN_ID}"
        echo "Timestamp: $(date)"
        echo ""
        echo "--- PROVENANCE TAGS ---"
        echo "Edge:"
        cat "${OUT_DIR}"/logs/edge_*.log 2>/dev/null | grep "\[TEST-3\]" | tail -n 5 || echo "No Edge provenance detected"
        echo "Cloud Decision (TEANS):"
        kubectl --kubeconfig "$CLOUD_KCFG" --insecure-skip-tls-verify logs -n simulation -l app=teans --since="${MINUTES}m" 2>/dev/null | grep -E "\[TEST-3\]|\[DECISION_TRACE\]" | tail -n 5 || echo "No Cloud provenance detected"
    } > "$SCI_FILE"

    extract_edge_records_csv
    extract_latency_csv
    extract_decision_csv
    extract_airwatch_latency_csv
}

extract_infrastructure
case "$APP" in
    airwatch) extract_airwatch ;;
    rec)      extract_rec ;;
    all)      extract_airwatch; extract_rec ;;
esac
[[ "$SCIENTIFIC" == "true" ]] && extract_scientific
echo "[SUCCESS] Extraction completed in: ${OUT_DIR}"
