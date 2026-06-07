"""
r2_notify.py - Remote notifications (Pod: r2, namespace: airwatch-remote).

Exposes POST /alert - receives notifications from s5 (normal FOG_ANOMALY flow)
and directly from the edge (EDGE_EMERGENCY, pipeline bypass).
Routes to external channels: webhook, email, SMS.
Channels are stubs to be completed with appropriate libraries.
"""

import json
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer

import config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [r2] %(levelname)s %(message)s",
)
LOG = logging.getLogger("r2")


def _send_webhook(alert: dict) -> None:
    """Stub - implement with requests.post to Slack, Teams, PagerDuty, etc."""
    LOG.info("[WEBHOOK] %s device=%s fields=%s",
             alert.get("severity"), alert.get("device_id"),
             list(alert.get("violations", {}).keys()))


def _send_email(alert: dict) -> None:
    """Stub - implement with smtplib or provider (SendGrid, SES, etc.)."""
    LOG.info("[EMAIL] %s device=%s", alert.get("severity"), alert.get("device_id"))


def _send_sms(alert: dict) -> None:
    """Stub - implement with Twilio or similar. CRITICAL only."""
    LOG.info("[SMS] CRITICAL device=%s", alert.get("device_id"))


def handle_alert(alert: dict) -> None:
    severity = alert.get("severity", "INFO")
    LOG.warning("Notification received: %s - device=%s", severity, alert.get("device_id"))

    _send_webhook(alert)
    _send_email(alert)

    if severity == "CRITICAL":
        _send_sms(alert)


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
            handle_alert(payload)
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "unknown path"})

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok", "service": "r2"})
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
    LOG.info("r2 listening on :%d", config.R2_PORT)
    HTTPServer(("0.0.0.0", config.R2_PORT), Handler).serve_forever()
