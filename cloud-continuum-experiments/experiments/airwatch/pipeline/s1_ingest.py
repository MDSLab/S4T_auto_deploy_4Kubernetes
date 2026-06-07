"""
s1_ingest.py - Optimized reading from InfluxDB and forwarding to s2.

Periodically reads data from InfluxDB (measurement: environmental_data) 
and forwards it to the pipeline. Optimized to reduce polling delay.
"""

import json
import logging
import time
import os
import csv
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

import config
import http_client

# MQTT Import
try:
    import paho.mqtt.client as mqtt
except ImportError:
    mqtt = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [s1] %(levelname)s %(message)s",
)
LOG = logging.getLogger("s1")

_influx = None

SENSOR_FIELDS = {
    "PM25", "PM10", "Temperature", "Humidity", "CO", "NO2",
    "Pressure", "Wind_speed", "Gust", "lat", "lon", "alt"
}

def get_influx():
    global _influx
    if _influx is not None:
        return _influx
    from influxdb import InfluxDBClient
    client = InfluxDBClient(
        host=config.INFLUX_HOST, port=config.INFLUX_PORT,
        username=config.INFLUX_USER, password=config.INFLUX_PASSWORD,
        database=config.INFLUX_DB,
        timeout=config.INFLUX_TIMEOUT,
    )
    _influx = client
    return _influx

def _safe_float(value):
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def _ms_delta(later_s, earlier_s):
    if later_s is None or earlier_s is None:
        return None
    return max(0.0, (later_s - earlier_s) * 1000.0)


def _log_latency_to_csv(
    agent_id,
    sequence,
    query_latency_ms,
    forward_latency_ms,
    edge_to_influx_ms,
    db_residency_ms,
    edge_to_fog_ms,
    edge_to_cloud_ms,
    ingested_at,
    forwarded_at,
):
    csv_file = f"scientific_latency_airwatch_{agent_id}.csv"
    file_exists = os.path.isfile(csv_file)
    with open(csv_file, mode='a', newline='') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow([
                "agent_id",
                "sequence",
                "query_latency_ms",
                "forward_latency_ms",
                "edge_to_influx_ms",
                "db_residency_ms",
                "edge_to_fog_ms",
                "edge_to_cloud_ms",
                "ingested_at",
                "forwarded_at",
            ])
        writer.writerow([
            agent_id,
            sequence,
            query_latency_ms,
            forward_latency_ms,
            edge_to_influx_ms,
            db_residency_ms,
            edge_to_fog_ms,
            edge_to_cloud_ms,
            ingested_at,
            forwarded_at,
        ])

def process_record(payload, source_type="polling", read_latency=0.0):
    ingested_at = time.time()
    
    # FGCS Metrics
    gen_at = _safe_float(payload.get("generated_at"))
    influx_written_at = _safe_float(payload.get("influx_written_at"))

    edge_to_influx_ms = _ms_delta(influx_written_at, gen_at)
    db_residency_ms = _ms_delta(ingested_at, influx_written_at)
    edge_to_fog_ms = _ms_delta(ingested_at, gen_at)

    if edge_to_fog_ms is not None:
        if source_type == "polling":
            LOG.info(
                "[TEST-3] Edge-to-Fog (s1-polling) E2E latency: %.3f ms "
                "(edge->influx: %.3f ms, db-residency: %.3f ms, query: %.2f ms)",
                edge_to_fog_ms,
                edge_to_influx_ms,
                db_residency_ms,
                read_latency,
            )
        else:
            LOG.info(
                "[TEST-3] Edge-to-Fog (s1-streaming) E2E latency: %.3f ms (mqtt-delay: %.3f ms)",
                edge_to_fog_ms,
                edge_to_fog_ms # In streaming, edge_to_fog is the main metric
            )

    # GAP 1 & 3: Fog-to-Fog forward latency
    ok, forward_latency_ms = http_client.post(config.S2_HOST, config.S2_PORT, "/normalize", payload)
    forwarded_at = time.time()
    if ok:
        LOG.info("[TEST-4] Fog-to-Fog forward latency: %.3f ms", forward_latency_ms)
        
        # GAP 3: Log to CSV
        edge_to_cloud_ms = None if edge_to_fog_ms is None else edge_to_fog_ms + forward_latency_ms
        _log_latency_to_csv(
            "s1",
            int(time.time()), # sequence approximation
            read_latency,
            forward_latency_ms,
            edge_to_influx_ms,
            db_residency_ms,
            edge_to_fog_ms,
            edge_to_cloud_ms,
            ingested_at,
            forwarded_at,
        )
    else:
        LOG.error("Forwarding to s2 failed for device=%s", payload.get("device_id"))

def poll_and_forward(last_time=None):
    client = get_influx()
    query = f"SELECT * FROM environmental_data WHERE source='{config.S1_SOURCE_FILTER}'"
    if last_time:
        query += f" AND time > '{last_time}'"
    query += f" ORDER BY time ASC LIMIT {config.S1_BATCH_LIMIT}"

    start_read = time.time()
    try:
        result = client.query(query)
    except Exception as exc:
        LOG.error("InfluxDB query error: %s", exc)
        return last_time
        
    read_latency = (time.time() - start_read) * 1000
    points = list(result.get_points())

    if not points:
        return last_time

    LOG.info("[TEST-1] Ingested %d records from DB (Query latency: %.2f ms)", len(points), read_latency)

    new_last_time = last_time
    for point in points:
        new_last_time = point.get("time")
        fields = {
            k: v for k, v in point.items()
            if k in SENSOR_FIELDS and isinstance(v, (int, float))
        }
        payload = {
            "device_id": point.get("device_id"),
            "source": point.get("source"),
            "timestamp": point.get("time"),
            "generated_at": point.get("generated_at"),
            "influx_written_at": point.get("influx_written_at"),
            "fields": fields,
            "provenance": {
                "tag": point.get("provenance"),
                "version": point.get("version"),
                "test_id": point.get("test_id"),
            },
        }
        process_record(payload, source_type="polling", read_latency=read_latency)
    
    return new_last_time

# MQTT Callbacks
def on_connect(client, userdata, flags, rc):
    LOG.info("Connected to MQTT Broker with result code "+str(rc))
    client.subscribe(config.MQTT_TOPIC)

def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload.decode())
        LOG.info("[STREAMING] Received record via MQTT from %s", payload.get("device_id"))
        process_record(payload, source_type="streaming")
    except Exception as e:
        LOG.error("Error processing MQTT message: %s", e)

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status": "ok"}')

if __name__ == "__main__":
    LOG.info("s1 starting (Mode: %s)...", config.INGESTION_MODE)
    threading.Thread(target=lambda: ThreadingHTTPServer(("0.0.0.0", config.S1_PORT), HealthHandler).serve_forever(), daemon=True).start()
    
    if config.INGESTION_MODE == "streaming":
        if mqtt is None:
            LOG.error("paho-mqtt not installed, cannot use streaming mode")
            exit(1)
        client = mqtt.Client()
        client.on_connect = on_connect
        client.on_message = on_message
        LOG.info("Connecting to MQTT Broker: %s:%d", config.MQTT_BROKER, config.MQTT_PORT)
        client.connect(config.MQTT_BROKER, config.MQTT_PORT, 60)
        client.loop_forever()
    else:
        last_time = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        while True:
            last_time = poll_and_forward(last_time)
            time.sleep(1)
