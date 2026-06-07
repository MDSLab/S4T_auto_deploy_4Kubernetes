"""
s2_normalize.py - Normalization and validation (Pod: s2, namespace: airwatch).

Exposes POST /normalize.
Parallel fan-out:
  - HTTP towards s3 (anomaly detection, real-time)
  - Kafka topic airwatch-normalized (Spark aggregation, cloud cluster)
"""

import json
import logging
import math
import os
import csv
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import config
import http_client

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [s2] %(levelname)s %(message)s",
)
LOG = logging.getLogger("s2")

# -- Kafka producer (optional - if not configured, HTTP only) --
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "")
KAFKA_TOPIC     = os.getenv("KAFKA_TOPIC", "airwatch-normalized")
_producer = None
_seq_counter = 0

def _get_producer():
    global _producer
    if _producer is not None:
        return _producer
    if not KAFKA_BOOTSTRAP:
        return None
    try:
        from kafka import KafkaProducer
        _producer = KafkaProducer(
            bootstrap_servers=KAFKA_BOOTSTRAP,
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            acks="all",
            retries=3,
            linger_ms=50,
            batch_size=32768,
        )
        LOG.info("Kafka producer connected to %s", KAFKA_BOOTSTRAP)
    except Exception as exc:
        LOG.warning("Kafka not available: %s - using HTTP only towards s3.", exc)
        _producer = None
    return _producer

def _log_latency_to_csv(agent_id, sequence, query_latency_ms, fog_to_kafka_ms, edge_to_fog_ms, edge_to_kafka_ms, ingested_at, forwarded_at):
    csv_file = f"scientific_latency_airwatch_{agent_id}.csv"
    file_exists = os.path.isfile(csv_file)
    with open(csv_file, mode='a', newline='') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(["agent_id", "sequence", "query_latency_ms", "fog_to_kafka_ms", "edge_to_fog_ms", "edge_to_kafka_ms", "ingested_at", "forwarded_at"])
        writer.writerow([agent_id, sequence, query_latency_ms, fog_to_kafka_ms, edge_to_fog_ms, edge_to_kafka_ms, ingested_at, forwarded_at])

# -- Validation --
FIELD_RANGES: dict = {
    "PM25":        (0.0,    999.0),
    "PM10":        (0.0,    999.0),
    "Temperature": (-50.0,  100.0),
    "Humidity":    (0.0,    100.0),
    "CO":          (0.0,   1000.0),
    "NO2":         (0.0,    100.0),
    "Pressure":    (800.0, 1100.0),
    "Wind_speed":  (0.0,    200.0),
    "Gust":        (0.0,    200.0),
    "production":  (0.0,  10000.0),
    "consumption": (0.0,  10000.0),
}

REQUIRED = set()  # Flexible to support different sensor types (e.g., energy)


def normalize(payload: dict) -> tuple:
    fields = payload.get("fields")
    if not isinstance(fields, dict):
        return None, "missing 'fields' field"

    missing = REQUIRED - fields.keys()
    if missing:
        return None, f"missing mandatory fields: {missing}"

    cleaned = {}
    issues  = []

    for field, value in fields.items():
        try:
            v = float(value)
        except (TypeError, ValueError):
            issues.append(f"{field}=non-numeric")
            v = 0.0

        if math.isnan(v) or math.isinf(v):
            issues.append(f"{field}=nan/inf")
            v = 0.0

        if field in FIELD_RANGES:
            lo, hi = FIELD_RANGES[field]
            if not (lo <= v <= hi):
                issues.append(f"{field}={v} out of range [{lo},{hi}]")
                v = max(lo, min(hi, v))

        cleaned[field] = round(v, 4)

    quality = max(0.0, 1.0 - len(issues) * 0.1)

    normalized = {
        **payload,
        "fields":        cleaned,
        "quality_score": round(quality, 2),
        "issues":        issues,
        "hops":          payload.get("hops", []) + ["s2"],
    }
    return normalized, None


def _handle_normalize(payload: dict) -> tuple:
    global _seq_counter
    ingested_at = time.time()
    normalized, err = normalize(payload)
    if err:
        LOG.warning("Discarded: %s", err)
        return 400, {"error": err}

    if normalized["issues"]:
        LOG.info("Normalized with issues: %s", normalized["issues"])

    # 1. HTTP towards s3 (real-time, same fog cluster)
    ok_s3, latency_s3 = http_client.post(config.S3_HOST, config.S3_PORT, "/", normalized)
    if not ok_s3:
        LOG.error("Fan-out to s3 failed.")

    # 2. Kafka towards cloud cluster (Spark aggregation)
    producer = _get_producer()
    fog_to_kafka_ms = 0.0
    if producer:
        try:
            start_kafka = time.time()
            future = producer.send(KAFKA_TOPIC, normalized)
            future.get(timeout=10) # Wait for ACK to measure Fog-to-Kafka
            fog_to_kafka_ms = (time.time() - start_kafka) * 1000
            LOG.info("[TEST-4] Fog-to-Kafka forward latency (Kafka): %.3f ms", fog_to_kafka_ms)
            LOG.debug("Published to Kafka topic=%s device=%s",
                      KAFKA_TOPIC, normalized.get("device_id"))
        except Exception as exc:
            LOG.error("Kafka publication failed: %s", exc)
    else:
        # Fallback: direct HTTP to s4 if Kafka is not available
        ok_s4, fog_to_kafka_ms = http_client.post(config.S4_HOST, config.S4_PORT, "/", normalized)
        if ok_s4:
            LOG.info("[TEST-4] Fog-to-Kafka forward latency (HTTP-Fallback): %.3f ms", fog_to_kafka_ms)
        else:
            LOG.error("HTTP fallback to s4 failed.")

    forwarded_at = time.time()
    proc_latency = (forwarded_at - ingested_at) * 1000
    LOG.info("Normalization latency for %s: %.3f ms", normalized.get("device_id"), proc_latency)
    
    # GAP 3: Log to CSV
    gen_at = payload.get("generated_at")
    edge_to_fog_ms = (ingested_at - float(gen_at)) * 1000 if gen_at else 0.0
    edge_to_kafka_ms = edge_to_fog_ms + fog_to_kafka_ms
    _log_latency_to_csv("s2", _seq_counter, proc_latency, fog_to_kafka_ms, edge_to_fog_ms, edge_to_kafka_ms, ingested_at, forwarded_at)
    _seq_counter += 1
    
    return 200, {"status": "ok", "quality": normalized["quality_score"]}


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        LOG.debug(fmt, *args)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._respond(400, {"error": "Invalid JSON"})
            return

        if self.path == "/normalize":
            status, resp = _handle_normalize(payload)
        else:
            status, resp = 404, {"error": "Unknown path"}

        self._respond(status, resp)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok", "service": "s2"})
        else:
            self._respond(404, {"error": "not found"})

    def _respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    LOG.info("s2 listening on :%d", config.S2_PORT)
    HTTPServer(("0.0.0.0", config.S2_PORT), Handler).serve_forever()
