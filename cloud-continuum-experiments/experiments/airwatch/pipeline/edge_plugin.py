# -*- coding: utf-8 -*-

import json
import logging
import os
import random
import threading
import time
import base64
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime

# MQTT Import
try:
    import paho.mqtt.client as mqtt
except ImportError:
    mqtt = None


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [edge] %(levelname)s %(message)s",
)

LOG = logging.getLogger("edge_plugin")

# Configuration
INGESTION_MODE = os.getenv("INGESTION_MODE", "streaming") # "polling" or "streaming"

# InfluxDB config
INFLUX_HOST = os.getenv("INFLUX_HOST", "<EDGE_GATEWAY_IP>")
INFLUX_PORT = int(os.getenv("INFLUX_PORT", "30086"))
INFLUX_DB = os.getenv("INFLUX_DB", "airwatch")
INFLUX_USER = os.getenv("INFLUX_USER", "admin")
INFLUX_PASS = os.getenv("INFLUX_PASS", "admin")

# MQTT config
MQTT_BROKER = os.getenv("MQTT_BROKER", "<EDGE_GATEWAY_IP>") # Tailscale Edge IP
MQTT_PORT   = int(os.getenv("MQTT_PORT", "31883"))
MQTT_TOPIC  = os.getenv("MQTT_TOPIC", "airwatch/environmental_data")

DEVICE_ID = "edge-node-01"

EDGE_POLL_INTERVAL = 5.0
EDGE_BUFFER_MAXSIZE = 500
EDGE_BUFFER_FILE = "/var/lib/iotronic/plugins/edge_buffer.jsonl"

EDGE_THRESHOLDS = {
    "PM25": 150.0,
    "PM10": 300.0,
    "Temperature": 70.0,
    "CO": 50.0,
    "NO2": 1.0,
}

# Reproducibility: Deterministic Seed
RANDOM_SEED = int(os.getenv("RANDOM_SEED", "42"))
random.seed(RANDOM_SEED + hash(DEVICE_ID) % 1000)

def _escape_tag(value):
    return str(value).replace("\\", "\\\\").replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")

def _escape_measurement(value):
    return str(value).replace("\\", "\\\\").replace(" ", "\\ ").replace(",", "\\,")

def _build_line_protocol(record):
    measurement = _escape_measurement("environmental_data")
    tags = {
        "device_id": record["device_id"],
        "source": record["source"],
        "provenance": record["metadata"]["provenance"],
        "version": record["metadata"]["version"],
        "test_id": record["metadata"]["test_id"]
    }
    tag_str = ",".join(["%s=%s" % (k, _escape_tag(v)) for k, v in tags.items()])
    
    generated_at = float(record["generated_at"])
    influx_written_at = time.time()

    fields = {
        "generated_at": generated_at,
        "influx_written_at": influx_written_at,
    }
    for k, v in record["fields"].items():
        if isinstance(v, (int, float)):
            fields[k] = float(v)
    
    field_str = ",".join(["%s=%s" % (k, v) for k, v in fields.items()])
    ts = int(record["timestamp"])
    
    line = "%s,%s %s %s" % (measurement, tag_str, field_str, ts)
    LOG.info("[PAYLOAD] tag=%s size_bytes=%d", measurement, len(line))
    return line

def _write_influx(client, record):
    line = _build_line_protocol(record)
    if not line:
        return False
    try:
        start_write = time.time()
        req = urllib.request.Request(
            client["url"], 
            data=line.encode("utf-8"), 
            headers=client["headers"]
        )
        response = urllib.request.urlopen(req, timeout=5.0)
        code = response.getcode()
        if code not in (200, 204):
            return False
        LOG.info("InfluxDB write latency: %.3f ms", (time.time() - start_write) * 1000.0)
        return True
    except Exception as exc:
        LOG.error("InfluxDB write error: %s", exc)
        return False

def _publish_mqtt(client, record):
    try:
        payload = json.dumps(record)
        client.publish(MQTT_TOPIC, payload)
        LOG.info("[STREAMING] Published to MQTT: %s", MQTT_TOPIC)
        return True
    except Exception as e:
        LOG.error("MQTT publish error: %s", e)
        return False

class EdgeBuffer(object):
    def __init__(self, path, maxsize):
        self.path = path
        self.maxsize = maxsize
        self._lock = threading.Lock()
        directory = os.path.dirname(path)
        if not os.path.exists(directory):
            os.makedirs(directory)
    def push(self, record):
        with self._lock:
            lines = self._read_lines()
            if len(lines) >= self.maxsize:
                lines = lines[1:]
            lines.append(json.dumps(record))
            f = open(self.path, "w")
            f.write("\n".join(lines) + "\n")
            f.close()
    def flush(self):
        with self._lock:
            lines = self._read_all()
            if lines:
                open(self.path, "w").close()
            result = []
            for l in lines:
                if l.strip():
                    result.append(json.loads(l))
            return result
    def size(self):
        with self._lock:
            return len(self._read_all())
    def _read_all(self):
        if not os.path.exists(self.path):
            return []
        f = open(self.path)
        lines = [l for l in f.read().splitlines() if l.strip()]
        f.close()
        return lines

class SensorReader(object):
    def read(self):
        return {
            "PM25": round(random.uniform(5.0, 40.0), 2),
            "PM10": round(random.uniform(10.0, 80.0), 2),
            "Temperature": round(random.uniform(18.0, 35.0), 2),
            "Humidity": round(random.uniform(30.0, 80.0), 2),
            "CO": round(random.uniform(0.1, 5.0), 3),
            "NO2": round(random.uniform(0.01, 0.08), 4),
            "Pressure": round(random.uniform(1000.0, 1025.0), 1),
            "Wind_speed": round(random.uniform(0.0, 15.0), 2),
            "Gust": round(random.uniform(0.0, 20.0), 2),
            "lat": 40.7128, "lon": -74.0060, "alt": 10.0,
        }

class Worker(threading.Thread):
    def __init__(self, uuid, name, q_result=None, params=None):
        threading.Thread.__init__(self)
        self.daemon = True
        self.uuid = uuid
        self.name = name
        self.params = params or {}
        self._running = True
        self.sensor = SensorReader()
        self.buffer = EdgeBuffer(EDGE_BUFFER_FILE, EDGE_BUFFER_MAXSIZE)
        self.device_id = self.params.get("device_id", DEVICE_ID)
        self.poll_interval = float(self.params.get("poll_interval", EDGE_POLL_INTERVAL))
        
        # Dynamic Ingestion Mode from IoTronic params or Environment
        self.ingestion_mode = self.params.get("INGESTION_MODE", INGESTION_MODE)

        # Influx Client Setup
        raw_auth = "%s:%s" % (INFLUX_USER, INFLUX_PASS)
        token = base64.b64encode(raw_auth.encode("utf-8")).decode("ascii")
        self.influx_client = {
            "url": "http://%s:%d/write?db=%s&precision=s" % (INFLUX_HOST, INFLUX_PORT, INFLUX_DB),
            "headers": {
                "Content-Type": "text/plain",
                "Authorization": "Basic %s" % token
            }
        }

        # MQTT Client Setup
        self.mqtt_client = None
        if self.ingestion_mode == "streaming":
            if mqtt:
                self.mqtt_client = mqtt.Client()
                LOG.info("Connecting to MQTT Broker: %s:%d", MQTT_BROKER, MQTT_PORT)
                self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            else:
                LOG.error("paho-mqtt not installed, falling back to polling if possible")

        LOG.info("Worker started - Mode: %s (device=%s)", self.ingestion_mode, self.device_id)

    def complete(self, action, message):
        return "%s result for %s: %s" % (action, self.uuid, message)
        
    def stop(self):
        self._running = False
        
    def run(self):
        while self._running:
            try:
                reading = self.sensor.read()
                now_ts = time.time()
                record = {
                    "source": "edge-node", "device_id": self.device_id,
                    "timestamp": now_ts, "generated_at": now_ts,
                    "influx_written_at": now_ts,
                    "fields": reading,
                    "metadata": {
                        "provenance": "edge-node-%s" % self.device_id,
                        "version": "1.3.0", "test_id": "FGCS-REV-2026"
                    }
                }

                success = False
                if self.ingestion_mode == "streaming" and self.mqtt_client:
                    success = _publish_mqtt(self.mqtt_client, record)
                else:
                    success = _write_influx(self.influx_client, record)

                if success:
                    for rec in self.buffer.flush():
                        if self.ingestion_mode == "streaming" and self.mqtt_client:
                            _publish_mqtt(self.mqtt_client, rec)
                        else:
                            _write_influx(self.influx_client, rec)
                else:
                    self.buffer.push(record)
            except Exception as exc:
                LOG.error("Loop error: %s", exc)
            time.sleep(self.poll_interval)
