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

# MQTT Import
try:
    import paho.mqtt.client as mqtt
except ImportError:
    mqtt = None


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [lr-edge-sensor] %(levelname)s %(message)s",
)
LOG = logging.getLogger("lr_edge_sensor_plugin")

# Configuration
INGESTION_MODE = os.getenv("INGESTION_MODE", "streaming") # "polling" or "streaming"

# InfluxDB 1.x config
INFLUX_HOST = os.getenv("INFLUX_HOST", "<DATABASE_IP>")
INFLUX_PORT = int(os.getenv("INFLUX_PORT", "30086"))
INFLUX_DB = os.getenv("INFLUX_DB", "airwatch")
INFLUX_USER = os.getenv("INFLUX_USER", "admin")
INFLUX_PASS = os.getenv("INFLUX_PASS", "admin")

# MQTT config
MQTT_BROKER = os.getenv("MQTT_BROKER", "<EDGE_GATEWAY_IP>") # Tailscale Edge IP
MQTT_PORT   = int(os.getenv("MQTT_PORT", "31883"))
MQTT_TOPIC  = os.getenv("MQTT_TOPIC", "airwatch/energy_data")

HOUSEHOLD_ID = "edge-house-01"
POLL_INTERVAL = 5.0
BUFFER_MAXSIZE = 500
BUFFER_FILE = "/var/lib/iotronic/plugins/edge_sensor_buffer.jsonl"

def _escape_tag(value):
    return str(value).replace("\\", "\\\\").replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")

def _escape_measurement(value):
    return str(value).replace("\\", "\\\\").replace(" ", "\\ ").replace(",", "\\,")

def _build_line_protocol(record):
    measurement = _escape_measurement("environmental_data")
    tags = {
        "device_id": record["device_id"],
        "source": "edge-energy",
    }
    tag_str = ",".join(["%s=%s" % (k, _escape_tag(v)) for k, v in tags.items()])

    fields = {
        "production": float(record["production"]),
        "consumption": float(record["consumption"]),
        "generated_at": float(record.get("generated_at", record["timestamp"])),
    }
    field_str = ",".join(["%s=%s" % (k, v) for k, v in fields.items()])
    ts = int(record["timestamp"])
    return "%s,%s %s %s" % (measurement, tag_str, field_str, ts)

def _write_influx(client, record):
    line = _build_line_protocol(record)
    try:
        start_write = time.time()
        req = urllib.request.Request(
            client["url"],
            data=line.encode("utf-8"),
            headers=client["headers"],
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            resp.read()
            if resp.status not in (204, 200):
                return False
        LOG.info("InfluxDB write latency: %.3f ms", (time.time() - start_write) * 1000)
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

class SensorBuffer:
    def __init__(self, path, maxsize):
        self.path = path
        self.maxsize = maxsize
        self._lock = threading.Lock()
        os.makedirs(os.path.dirname(path), exist_ok=True)

    def push(self, record):
        with self._lock:
            lines = self._read_all()
            if len(lines) >= self.maxsize:
                lines = lines[-(self.maxsize - 1):]
            lines.append(json.dumps(record))
            with open(self.path, "w") as f:
                f.write("\n".join(lines) + "\n")

    def flush(self):
        with self._lock:
            lines = self._read_all()
            if lines:
                open(self.path, "w").close()
            return [json.loads(line) for line in lines if line.strip()]

    def size(self):
        with self._lock:
            return len(self._read_all())

    def _read_all(self):
        if not os.path.exists(self.path):
            return []
        with open(self.path) as f:
            return [line for line in f.read().splitlines() if line.strip()]

class EnergyReader:
    def read(self):
        production = round(random.uniform(0.5, 3.0), 2)
        consumption = round(random.uniform(0.3, 2.5), 2)
        return {
            "production": production,
            "consumption": consumption,
        }

class Worker(threading.Thread):
    def __init__(self, uuid, name, q_result=None, params=None):
        super().__init__(daemon=True)
        self.uuid = uuid
        self.name = name
        self.params = params or {}
        self._running = True

        self.reader = EnergyReader()
        self.buffer = SensorBuffer(BUFFER_FILE, BUFFER_MAXSIZE)

        # Dynamic Ingestion Mode from IoTronic params or Environment
        self.ingestion_mode = self.params.get("INGESTION_MODE", INGESTION_MODE)

        # Influx Setup
        self.influx_host = self._cfg("influx_host", os.getenv("INFLUX_HOST", INFLUX_HOST))
        self.influx_port = self._cfg("influx_port", os.getenv("INFLUX_PORT", INFLUX_PORT), int)
        self.influx_db = self._cfg("influx_db", os.getenv("INFLUX_DB", INFLUX_DB))
        self.influx_user = self._cfg("influx_user", os.getenv("INFLUX_USER", INFLUX_USER))
        self.influx_pass = self._cfg("influx_pass", os.getenv("INFLUX_PASS", os.getenv("INFLUX_PASSWORD", INFLUX_PASS)))
        self.household_id = self._cfg("household_id", os.getenv("HOUSEHOLD_ID", HOUSEHOLD_ID))
        self.poll_interval = self._cfg("poll_interval", POLL_INTERVAL, float)

        query = urllib.parse.urlencode({"db": self.influx_db, "precision": "s"})
        headers = {"Content-Type": "text/plain; charset=utf-8"}
        if self.influx_user:
            token = base64.b64encode(("%s:%s" % (self.influx_user, self.influx_pass)).encode("utf-8")).decode("ascii")
            headers["Authorization"] = "Basic %s" % token

        self.influx_client = {
            "url": "http://%s:%d/write?%s" % (self.influx_host, self.influx_port, query),
            "headers": headers,
        }

        # MQTT Setup
        self.mqtt_client = None
        if self.ingestion_mode == "streaming":
            if mqtt:
                self.mqtt_client = mqtt.Client()
                LOG.info("Connecting to MQTT Broker: %s:%d", MQTT_BROKER, MQTT_PORT)
                self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            else:
                LOG.error("paho-mqtt not installed")

        LOG.info("Worker started - Mode=%s household=%s" % (self.ingestion_mode, self.household_id))

    def _cfg(self, key, default, cast=None):
        value = self.params.get(key, default)
        if cast is None: return value
        try: return cast(value)
        except: return default

    def complete(self, action, message):
        return "%s result for %s: %s" % (action, self.uuid, message)

    def stop(self):
        self._running = False

    def run(self):
        while self._running:
            try:
                now_ts = time.time()
                reading = self.reader.read()
                record = {
                    "device_id": self.household_id,
                    "timestamp": now_ts,
                    "production": reading["production"],
                    "consumption": reading["consumption"],
                    "generated_at": now_ts,
                }

                success = False
                if self.ingestion_mode == "streaming" and self.mqtt_client:
                    success = _publish_mqtt(self.mqtt_client, record)
                else:
                    success = _write_influx(self.influx_client, record)

                if success:
                    pending = self.buffer.flush()
                    for rec in pending:
                        if self.ingestion_mode == "streaming" and self.mqtt_client:
                            _publish_mqtt(self.mqtt_client, rec)
                        else:
                            _write_influx(self.influx_client, rec)
                else:
                    self.buffer.push(record)

            except Exception as exc:
                LOG.error("Worker loop error: %s", exc)
            time.sleep(self.poll_interval)

if __name__ == "__main__":
    worker = Worker(uuid="edge-sensor", name="edge-sensor")
    worker.run()
