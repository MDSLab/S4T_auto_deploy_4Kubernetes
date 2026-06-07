"""
s5_alert.py - Structured Alerting (Pod: s5, namespace: airwatch).

Exposes POST /alert - receives events from s3 (FOG_ANOMALY).
Applies de-duplication to avoid flooding identical notifications,
then sends HTTP towards r2 (notify) in the airwatch-remote namespace.
"""

import json
import logging
import time
import threading
import os
import csv
from http.server import BaseHTTPRequestHandler, HTTPServer

import config
import http_client

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [s5] %(levelname)s %(message)s",
)
LOG = logging.getLogger("s5")

SEVERITY_MAP = {
    "EDGE_EMERGENCY": "CRITICAL",
    "FOG_ANOMALY":    "WARNING",
}

_seq_counter = 0

def _log_latency_to_csv(agent_id, sequence, query_latency_ms, fog_to_cloud_ms, edge_to_fog_ms, edge_to_cloud_ms, ingested_at, forwarded_at):
    csv_file = f"scientific_latency_airwatch_{agent_id}.csv"
    file_exists = os.path.isfile(csv_file)
    with open(csv_file, mode='a', newline='') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(["agent_id", "sequence", "query_latency_ms", "fog_to_cloud_ms", "edge_to_fog_ms", "edge_to_cloud_ms", "ingested_at", "forwarded_at"])
        writer.writerow([agent_id, sequence, query_latency_ms, fog_to_cloud_ms, edge_to_fog_ms, edge_to_cloud_ms, ingested_at, forwarded_at])


class AlertRouter:

    def __init__(self):
        self._dedup: dict = {}
        self._lock = threading.Lock()

    def route(self, payload: dict) -> None:
        global _seq_counter
        ingested_at = time.time()
        alert_type = payload.get("type", "UNKNOWN")
        device_id  = payload.get("device_id", "unknown")
        violations = payload.get("violations", {})
        severity   = SEVERITY_MAP.get(alert_type, "INFO")
        
        # Test 3: Provenance validation at the final stage
        prov = payload.get("provenance", {})
        if prov:
            LOG.info("[TEST-3] E2E Provenance confirmed: site=%s ver=%s hops=%s", 
                     prov.get("site_id"), prov.get("wf_version"), payload.get("hops", []))

        # De-duplication: does not notify the same severity level for the same
        # device more than once every DEDUP_WINDOW_SEC seconds.
        # This avoids floods when violating fields oscillate rapidly.
        now = time.monotonic()
        dedup_key = (device_id, severity)
        with self._lock:
            last_ts = self._dedup.get(dedup_key, 0)
            if now - last_ts < config.DEDUP_WINDOW_SEC:
                LOG.debug(
                    "Alert suppressed by dedup for device=%s severity=%s fields=%s",
                    device_id,
                    severity,
                    list(violations.keys()),
                )
                return
            self._dedup[dedup_key] = now

        LOG.log(
            logging.CRITICAL if severity == "CRITICAL" else logging.WARNING,
            "[%s] device=%s fields=%s", severity, device_id, list(violations.keys()),
        )

        notification = {
            "type":       alert_type,
            "severity":   severity,
            "device_id":  device_id,
            "timestamp":  payload.get("timestamp"),
            "violations": violations,
        }

        # GAP 1 & 3: Fog-to-Cloud forward latency (S5 -> R2)
        ok, fog_to_cloud_ms = http_client.post(config.R2_HOST, config.R2_PORT, "/alert", notification)
        forwarded_at = time.time()
        
        proc_latency = (forwarded_at - ingested_at) * 1000
        LOG.info("Alert routing latency for %s: %.3f ms", device_id, proc_latency)

        if ok:
            LOG.info("[TEST-4] Fog-to-Cloud forward latency: %.3f ms", fog_to_cloud_ms)
            
            # GAP 3: Log to CSV
            gen_at = payload.get("generated_at")
            edge_to_fog_ms = (ingested_at - float(gen_at)) * 1000 if gen_at else 0.0
            edge_to_cloud_ms = edge_to_fog_ms + fog_to_cloud_ms
            _log_latency_to_csv("s5", _seq_counter, proc_latency, fog_to_cloud_ms, edge_to_fog_ms, edge_to_cloud_ms, ingested_at, forwarded_at)
            _seq_counter += 1
        else:
            LOG.error("Notification to r2 failed for device=%s.", device_id)


_router = AlertRouter()


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

        if self.path == "/alert":
            _router.route(payload)
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "Unknown path"})

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok", "service": "s5"})
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
    LOG.info("s5 listening on :%d", config.S5_PORT)
    HTTPServer(("0.0.0.0", config.S5_PORT), Handler).serve_forever()
