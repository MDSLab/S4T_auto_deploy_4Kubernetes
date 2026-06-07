import json
import logging
import os
import threading

class PersistentBuffer:
    """Persistent buffer on disk to avoid data loss during offline periods."""
    def __init__(self, path, max_size=1000):
        self.path = path
        self.max_size = max_size
        self._lock = threading.Lock()
        os.makedirs(os.path.dirname(path), exist_ok=True)

    def push(self, record):
        with self._lock:
            try:
                lines = self._read_all()
                if len(lines) >= self.max_size:
                    lines.pop(0) # Remove oldest
                lines.append(json.dumps(record))
                with open(self.path, 'w') as f:
                    f.write("\n".join(lines) + "\n")
            except Exception as e:
                logging.error(f"Buffer write error: {e}")

    def flush(self):
        with self._lock:
            try:
                if not os.path.exists(self.path):
                    return []
                with open(self.path, 'r') as f:
                    lines = f.readlines()
                # Clear file after reading
                open(self.path, 'w').close()
                return [json.loads(l) for l in lines if l.strip()]
            except Exception as e:
                logging.error(f"Buffer read error: {e}")
                return []

    def _read_all(self):
        if not os.path.exists(self.path):
            return []
        with open(self.path, 'r') as f:
            return [l for l in f.read().splitlines() if l.strip()]
