import os
import logging
import requests
import time

def setup_logging(name):
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(name)s] %(levelname)s %(message)s'
    )
    return logging.getLogger(name)

def get_env(key, default):
    return os.environ.get(key, default)

class ReliableHttpClient:
    """HTTP client with automatic retry and timeout management."""
    def __init__(self, max_retries=3, backoff=2):
        self.max_retries = max_retries
        self.backoff = backoff

    def post(self, url, data, timeout=5):
        for attempt in range(self.max_retries + 1):
            try:
                resp = requests.post(url, json=data, timeout=timeout)
                if resp.status_code < 300:
                    return True
                logging.warning(f"POST {url} failed with status {resp.status_code}")
            except Exception as e:
                logging.warning(f"POST {url} error (attempt {attempt+1}): {e}")
            
            if attempt < self.max_retries:
                time.sleep(self.backoff ** attempt)
        return False
