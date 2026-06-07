"""
http_client.py - Shared HTTP utility for AirWatch services.

Replaces comms.py (raw TCP). Each service uses post() to send
JSON payloads to the next service in the pipeline.
Retry with exponential backoff is managed here, not in individual services.
"""

import json
import logging
import threading
import time
import urllib.error
import urllib.request
from typing import Optional

import config

LOG = logging.getLogger(__name__)


def post(
    host: str,
    port: int,
    path: str,
    payload: dict,
    retries: int = config.MAX_RETRIES,
    backoff: float = config.RETRY_BACKOFF,
) -> tuple[bool, float]:
    """
    Sends JSON payload via HTTP POST to http://{host}:{port}{path}.
    Retries up to `retries` times with exponential backoff.
    Returns (True, latency_ms) if response is 2xx, (False, 0.0) otherwise.
    """
    url  = f"http://{host}:{port}{path}"
    data = json.dumps(payload).encode("utf-8")

    for attempt in range(retries + 1):
        start_time = time.time()
        try:
            req = urllib.request.Request(
                url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=config.HTTP_TIMEOUT) as resp:
                latency_ms = (time.time() - start_time) * 1000
                if 200 <= resp.status < 300:
                    LOG.debug("POST %s -> %d (%.2f ms)", url, resp.status, latency_ms)
                    return True, latency_ms
                LOG.warning("POST %s -> unexpected response %d", url, resp.status)
                return False, latency_ms
        except urllib.error.URLError as exc:
            latency_ms = (time.time() - start_time) * 1000
            wait = backoff ** attempt
            LOG.warning(
                "POST %s failed (attempt %d/%d): %s - retry in %.1fs",
                url, attempt + 1, retries + 1, exc.reason, wait,
            )
            if attempt < retries:
                time.sleep(wait)
        except Exception as exc:
            latency_ms = (time.time() - start_time) * 1000
            LOG.error("POST %s unexpected error: %s", url, exc)
            break

    LOG.error("POST %s abandoned after %d attempts.", url, retries + 1)
    return False, 0.0


def post_all(targets: list, path: str, payload: dict) -> dict:
    """
    Sends the same payload to multiple (host, port) in parallel.
    Returns {host:port -> bool}.
    """
    results: dict = {}
    lock = threading.Lock()

    def _send(host, port):
        ok = post(host, port, path, payload)
        with lock:
            results[f"{host}:{port}"] = ok

    threads = [
        threading.Thread(target=_send, args=(h, p), daemon=True)
        for h, p in targets
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results
