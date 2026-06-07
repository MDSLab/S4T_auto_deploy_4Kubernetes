import json
import threading
from flask import Flask, render_template
from flask_socketio import SocketIO
from common.utils import setup_logging, get_env
from confluent_kafka import Consumer, KafkaError

log = setup_logging("DASHBOARD")

KAFKA_BOOTSTRAP = get_env("KAFKA_BOOTSTRAP", "kafka:9092")
PORT = int(get_env("PORT", 5000))

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*")

@app.route('/')
def index():
    return render_template('index.html')

def kafka_listener():
    c = Consumer({
        'bootstrap.servers': KAFKA_BOOTSTRAP,
        'group.id': 'dashboard-group',
        'auto.offset.reset': 'latest'
    })
    c.subscribe(['energy-raw-data', 'production-forecasts', 'system-events'])

    log.info("Dashboard Kafka Listener avviato...")
    while True:
        msg = c.poll(1.0)
        if msg is None: continue
        if msg.error():
            log.error(f"Kafka error: {msg.error()}")
            continue
        
        try:
            topic = msg.topic()
            data = json.loads(msg.value().decode('utf-8'))
            socketio.emit('new_message', {'topic': topic, 'data': data})
        except Exception as e:
            log.error(f"Error decoding message: {e}")

if __name__ == "__main__":
    threading.Thread(target=kafka_listener, daemon=True).start()
    socketio.run(app, host='0.0.0.0', port=PORT)
