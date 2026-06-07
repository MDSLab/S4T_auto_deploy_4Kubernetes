import time
import json
import threading
import requests
from flask import Flask, request, jsonify
from common.utils import setup_logging, get_env
from confluent_kafka import Producer

log = setup_logging("EPREM")

KAFKA_BOOTSTRAP = get_env("KAFKA_BOOTSTRAP", "kafka:9092")
KAFKA_TOPIC = "production-forecasts"
PORT = int(get_env("PORT", 5000))

INFLUX_QUERY_URL = get_env("INFLUX_QUERY_URL", "http://<DATABASE_IP>:30086/query")
INFLUX_DB = get_env("INFLUX_DB", "airwatch")
INFLUX_USER = get_env("INFLUX_USER", "admin")
INFLUX_PASS = get_env("INFLUX_PASS", "admin")
ENABLE_PULL_EDGE = get_env("ENABLE_PULL_EDGE", "true").lower() == "true"

app = Flask(__name__)

kafka_conf = {
    'bootstrap.servers': KAFKA_BOOTSTRAP,
    'message.timeout.ms': 5000,
    'socket.timeout.ms': 5000,
    'request.timeout.ms': 5000,
}
producer = Producer(kafka_conf)
_pending = []
_pending_lock = threading.Lock()


def _enqueue(payload, reason):
    with _pending_lock:
        _pending.append(payload)
    log.warning(
        "Forecast queued for retry: producer=%s sequence=%s reason=%s pending=%d",
        payload.get("producer_id"),
        payload.get("sequence", "na"),
        reason,
        len(_pending),
    )


def _delivery_status():
    return {"delivered": False, "error": None}


def _publish(payload):
    status = _delivery_status()

    def delivery_report(err, msg):
        if err is not None:
            status["error"] = str(err)
            log.error("Kafka delivery failed: %s", err)
        else:
            status["delivered"] = True

    try:
        producer.produce(
            KAFKA_TOPIC,
            key=payload["producer_id"],
            value=json.dumps(payload),
            callback=delivery_report
        )
        producer.flush(5.0)
    except BufferError as exc:
        status["error"] = str(exc)
    except Exception as exc:
        status["error"] = str(exc)

    return status


def _flush_pending():
    with _pending_lock:
        if not _pending:
            return
        pending = list(_pending)
        _pending[:] = []

    still_pending = []
    for payload in pending:
        status = _publish(payload)
        if status["delivered"]:
            log.info(
                "Retry delivered to Kafka for %s sequence=%s",
                payload["producer_id"],
                payload.get("sequence", "na"),
            )
        else:
            still_pending.append(payload)

    if still_pending:
        with _pending_lock:
            _pending[0:0] = still_pending
        log.warning("Retry flush incomplete: pending=%d", len(_pending))


def send_to_kafka(producer_id, production_val, edge_ts=None, sequence=None, mode="push", start_proc_ts=None, influx_query_ms=None):
    now = time.time()
    produce_ts = time.time()
    
    # Internal EPREM processing time
    eprem_processing_ms = 0.0
    if start_proc_ts:
        eprem_processing_ms = (produce_ts - start_proc_ts) * 1000.0

    estimation = {
        "producer_id": producer_id,
        "estimated_production": round(float(production_val) * 1.05, 2),
        "confidence": 0.85,
        "timestamp": now,
        "type": "EPREM_FORECAST",
        "sequence": sequence,
        "mode": mode,
        "produce_ts": produce_ts, # Kafka produce start time
        "eprem_processing_ms": round(eprem_processing_ms, 3),
        "influx_query_ms": round(influx_query_ms, 3) if influx_query_ms is not None else 0.0
    }

    latency_ms = None
    if edge_ts is not None:
        latency_ms = round((now - float(edge_ts)) * 1000.0, 2)
        log.info("[LATENCY] Edge-to-Fog latency for %s: %.2f ms", producer_id, latency_ms)
        estimation["edge_to_fog_latency_ms"] = latency_ms
        estimation["generated_at"] = edge_ts

    _flush_pending()
    status = _publish(estimation)

    if status["delivered"]:
        log.info("Estimation sent to Kafka for %s: %s kW", producer_id, estimation["estimated_production"])
        log.info(
            "[TRACE] FORECAST_EMIT producer_id=%s sequence=%s mode=%s edge_to_fog_ms=%s influx_query_ms=%s eprem_processing_ms=%s forecast_ts=%.6f estimated_production=%.2f",
            producer_id,
            sequence if sequence is not None else "na",
            mode,
            latency_ms if latency_ms is not None else "na",
            estimation["influx_query_ms"],
            estimation["eprem_processing_ms"],
            now,
            estimation["estimated_production"],
        )
    else:
        _enqueue(estimation, status["error"] or "delivery_timeout")


@app.route('/data', methods=['POST'])
def receive_data():
    start_proc_ts = time.time()
    data = request.json
    source = data.get("producer_id", data.get("household_id", "unknown"))
    prod = data.get("production", 0.0)
    edge_ts = data.get("generated_at", data.get("timestamp"))
    sequence = data.get("sequence")
    log.info("Received push data from %s: %s kW", source, prod)

    send_to_kafka(source, prod, edge_ts=edge_ts, sequence=sequence, mode="push", start_proc_ts=start_proc_ts)
    return jsonify({"status": "processed", "mode": "push"})


def poll_influx_worker():
    log.info("Starting InfluxDB polling worker for Edge data...")
    last_timestamp_ns = int(time.time() * 1e9)

    while True:
        try:
            start_query_ts = time.time()
            query = (
                "SELECT production, generated_at, sequence FROM environmental_data "
                "WHERE source='edge-energy' AND time > %s" % last_timestamp_ns
            )
            params = {
                "db": INFLUX_DB,
                "q": query,
                "u": INFLUX_USER,
                "p": INFLUX_PASS,
                "epoch": "ns"
            }

            resp = requests.get(INFLUX_QUERY_URL, params=params, timeout=5)
            query_latency_ms = (time.time() - start_query_ts) * 1000.0
            
            start_proc_ts = time.time()
            if resp.status_code == 200:
                results = resp.json().get("results", [])
                if results and "series" in results[0]:
                    series = results[0]["series"][0]
                    for row in series["values"]:
                        ts_ns = row[0]
                        val = row[1]
                        gen_at = row[2]
                        sequence = row[3] if len(row) > 3 else None

                        if ts_ns > last_timestamp_ns:
                            log.info("Edge data retrieved from DB: %s kW (ts: %s, Query latency: %.2f ms)", val, ts_ns, query_latency_ms)
                            send_to_kafka(
                                "edge-house-01",
                                val,
                                edge_ts=gen_at,
                                sequence=sequence,
                                mode="pull",
                                start_proc_ts=start_proc_ts,
                                influx_query_ms=query_latency_ms
                            )
                            last_timestamp_ns = ts_ns
            elif resp.status_code != 200:
                log.warning("InfluxDB query error: %s %s", resp.status_code, resp.text)

        except Exception as exc:
            log.error("Error in polling worker: %s", exc)

        time.sleep(1) # Reduced from 10s to 1s to match AirWatch and improve E2E latency


if __name__ == "__main__":
    if ENABLE_PULL_EDGE:
        t = threading.Thread(target=poll_influx_worker, daemon=True)
        t.start()

    log.info("EPREM listening on port %s...", PORT)
    app.run(host='0.0.0.0', port=PORT)
