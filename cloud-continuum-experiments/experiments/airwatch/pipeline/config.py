"""
config.py - Centralized AirWatch configuration.

All values are overridable via environment variables, 
allowing k3s manifests to inject ConfigMaps and Secrets without code modifications.
"""

import os

PIPELINE_NS = os.getenv("PIPELINE_NS", "airwatch")
REMOTE_NS   = os.getenv("REMOTE_NS",   "airwatch-remote")


def _svc(name: str, ns: str) -> str:
    return f"{name}.{ns}.svc.cluster.local"


# -- Pipeline services (namespace: airwatch) --
S1_HOST = os.getenv("S1_HOST", _svc("s1", PIPELINE_NS))
S2_HOST = os.getenv("S2_HOST", _svc("s2", PIPELINE_NS))
S3_HOST = os.getenv("S3_HOST", _svc("s3", PIPELINE_NS))
S4_HOST = os.getenv("S4_HOST", _svc("s4", PIPELINE_NS))
S5_HOST = os.getenv("S5_HOST", _svc("s5", PIPELINE_NS))

S1_PORT = int(os.getenv("S1_PORT", "8001"))

# ---- Workflow Metadata (for Provenance - Test 3) ----
WF_VERSION = "1.2.0-provenance-enabled"
SITE_ID = os.getenv("SLICES_SITE_ID", "edge-cloud-node-01")

S2_PORT = int(os.getenv("S2_PORT", "8002"))
S3_PORT = int(os.getenv("S3_PORT", "8003"))
S4_PORT = int(os.getenv("S4_PORT", "8004"))
S5_PORT = int(os.getenv("S5_PORT", "8005"))

# -- Remote services (namespace: airwatch-remote) --
R2_HOST = os.getenv("R2_HOST", _svc("r2", REMOTE_NS))
R2_PORT = int(os.getenv("R2_PORT", "8010"))

# -- External InfluxDB (reached via ExternalName Service) --
INFLUX_HOST     = os.getenv("INFLUX_HOST",     _svc("influxdb-external", PIPELINE_NS))
INFLUX_PORT     = int(os.getenv("INFLUX_PORT", "8086"))
INFLUX_USER     = os.getenv("INFLUX_USER",     "admin")
INFLUX_PASSWORD = os.getenv("INFLUX_PASSWORD", "changeme")
INFLUX_DB       = os.getenv("INFLUX_DB",       "airwatch")
INFLUX_TIMEOUT  = float(os.getenv("INFLUX_TIMEOUT", "2.0"))

# -- Fog thresholds (s3) - updatable via ConfigMap, zero re-deploy --
FOG_THRESHOLDS: dict = {
    "PM25":        float(os.getenv("THR_PM25",  "25.0")),
    "PM10":        float(os.getenv("THR_PM10",  "50.0")),
    "Temperature": float(os.getenv("THR_TEMP",  "45.0")),
    "Humidity":    float(os.getenv("THR_HUM",   "90.0")),
    "CO":          float(os.getenv("THR_CO",    "10.0")),
    "NO2":         float(os.getenv("THR_NO2",    "0.1")),
}

# -- Edge thresholds - hardcoded by design (see edge_plugin.py) --
EDGE_THRESHOLDS: dict = {
    "PM25":        150.0,
    "PM10":        300.0,
    "Temperature":  70.0,
    "CO":           50.0,
    "NO2":           1.0,
}

# -- HTTP Parameters --
HTTP_TIMEOUT  = float(os.getenv("HTTP_TIMEOUT",  "5.0"))
MAX_RETRIES   = int(os.getenv("MAX_RETRIES",     "3"))
RETRY_BACKOFF = float(os.getenv("RETRY_BACKOFF", "2.0"))

# -- Edge plugin --
EDGE_POLL_INTERVAL  = float(os.getenv("EDGE_POLL_INTERVAL", "5.0"))
EDGE_BUFFER_MAXSIZE = int(os.getenv("EDGE_BUFFER_MAXSIZE",  "500"))
EDGE_BUFFER_FILE    = os.getenv("EDGE_BUFFER_FILE", "/opt/data/edge_buffer.jsonl")

# -- s4 aggregation --
AGG_WINDOW_SEC = int(os.getenv("AGG_WINDOW", "60"))

# -- s5 alerting --
DEDUP_WINDOW_SEC = int(os.getenv("DEDUP_WINDOW", "60"))

# -- s1 ingest / replay control --
INGESTION_MODE = os.getenv("INGESTION_MODE", "polling") # "polling" or "streaming"
MQTT_BROKER    = os.getenv("MQTT_BROKER",    "<EDGE_GATEWAY_IP>") # Tailscale Edge IP
MQTT_PORT      = int(os.getenv("MQTT_PORT",   "31883"))     # NodePort
MQTT_TOPIC     = os.getenv("MQTT_TOPIC",     "airwatch/environmental_data")

S1_SOURCE_FILTER = os.getenv("S1_SOURCE_FILTER", "edge-node")
S1_START_FROM_NOW = os.getenv("S1_START_FROM_NOW", "true").lower() == "true"
S1_BATCH_LIMIT = int(os.getenv("S1_BATCH_LIMIT", "200"))
