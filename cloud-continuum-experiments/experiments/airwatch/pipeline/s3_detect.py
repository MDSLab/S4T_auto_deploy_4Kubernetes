"""
s4_aggregate.py - Temporal aggregation (Pod: s4, namespace: airwatch).

Exposes POST / - accumulates records in time windows (default 60s),
calculates mean/min/max/count per field and writes to InfluxDB.
"""

import json
import logging
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [s4] %(levelname)s %(message)s",
)
LOG = logging.getLogger("s4")

_influx = None

def get_influx():
    global _influx
    if _influx is not None:
        return _influx
    from influxdb import InfluxDBClient
    client = InfluxDBClient(
        host=config.INFLUX_HOST, port=config.INFLUX_PORT,
        username=config.INFLUX_USER, password=config.INFLUX_PASSWORD,
        database=config.INFLUX_DB,
    )
    try:
        client.create_database(config.INFLUX_DB)
    except Exception as exc:
        LOG.warning("create_database: %s", exc)
    _influx = client
    return _influx


class TimeWindowAggregator:

    def __init__(self):
        self._windows: dict = {}
        self._raw_count = 0  # Test 1: Count raw records
        self._lock = threading.Lock()
        threading.Thread(target=self._flush_loop, daemon=True).start()

    def ingest(self, payload: dict) -> None:
        device_id = payload.get("device_id", "unknown")
        fields    = payload.get("fields", {})
        now       = time.monotonic()

        with self._lock:
            self._raw_count += 1 # Test 1
            if device_id not in self._windows:
                self._windows[device_id] = {"_start": now}
            win = self._windows[device_id]
            for field, value in fields.items():
                if isinstance(value, (int, float)):
                    win.setdefault(field, []).append(float(value))

    def _flush_loop(self) -> None:
        while True:
            time.sleep(config.AGG_WINDOW_SEC)
            self._flush_all()

    def _flush_all(self) -> None:
        with self._lock:
            snapshot = dict(self._windows)
            raw_count = self._raw_count # Test 1
            self._windows.clear()
            self._raw_count = 0 # Reset for next window

        if not snapshot:
            return

        points = []
        ts = datetime.now(timezone.utc).isoformat()
        
        # Test 1: Calculate Reduction Ratio
        agg_count = len(snapshot)
        reduction_ratio = (1.0 - (agg_count / raw_count)) * 100 if raw_count > 0 else 0
        LOG.info("[TEST-1] Data Reduction: %d raw records -> %d aggregated points (Ratio: %.2f%%)", 
                 raw_count, agg_count, reduction_ratio)

        process_start = time.time()
        for device_id, win in snapshot.items():
            agg = {}
            for field, values in win.items():
                if field.startswith("_") or not values:
                    continue
                agg[f"{field}_mean"]  = round(sum(values) / len(values), 4)
                agg[f"{field}_min"]   = round(min(values), 4)
                agg[f"{field}_max"]   = round(max(values), 4)
                agg[f"{field}_count"] = float(len(values))

            if agg:
                points.append({
                    "measurement": "env_aggregated",
                    "tags":   {"device_id": device_id},
                    "time":   ts,
                    "fields": agg,
                })
                LOG.info("Flush device=%s %d fields window=%ds",
                         device_id, len(agg) // 4, config.AGG_WINDOW_SEC)

        if points:
            try:
                get_influx().write_points(points)
            except Exception as exc:
                LOG.error("InfluxDB write of aggregated data failed: %s", exc)


_aggregator = TimeWindowAggregator()


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

        _aggregator.ingest(payload)
        self._respond(200, {"status": "ok"})

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok", "service": "s4"})
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
    LOG.info("s4 listening on :%d (window=%ds)", config.S4_PORT, config.AGG_WINDOW_SEC)
    HTTPServer(("0.0.0.0", config.S4_PORT), Handler).serve_forever()
TTPServer(("0.0.0.0", config.S3_PORT), Handler).serve_forever()
