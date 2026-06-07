import time
import random
from common.utils import setup_logging, get_env, RobustClient
from common.buffer import PersistentBuffer

log = setup_logging("FOG")

EPREM_URL = get_env("EPREM_URL", "http://eprem:5000/data")
PRODUCER_ID = get_env("PRODUCER_ID", "fog-plant-01")
BUFFER_FILE = "/data/fog_buffer.jsonl"

client = RobustClient()
buffer = PersistentBuffer(BUFFER_FILE)

def producer_loop():
    while True:
        payload = {
            "producer_id": PRODUCER_ID,
            "timestamp": time.time(),
            "production": round(random.uniform(50.0, 200.0), 2)
        }
        
        success, _ = client.post(EPREM_URL, payload)
        
        if success:
            log.info(f"Dati produzione inviati a EPREM.")
            pending = buffer.pop_all()
            if pending:
                log.info(f"Svuotamento buffer: {len(pending)} record in sospeso.")
                for old_record in pending:
                    ok, _ = client.post(EPREM_URL, old_record)
                    if not ok:
                        buffer.push(old_record)
        else:
            log.warning("EPREM irraggiungibile. Salvataggio nel buffer locale.")
            buffer.push(payload)
            
        time.sleep(5)

if __name__ == "__main__":
    producer_loop()
