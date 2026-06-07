import time
import json
import uuid
import logging
from flask import Flask, request, jsonify
from confluent_kafka import Producer
from common.utils import setup_logging, get_env

log = setup_logging("ECREM")

KAFKA_BOOTSTRAP = get_env("KAFKA_BOOTSTRAP", "kafka:9092")
KAFKA_TOPIC = "production-forecasts"

app = Flask(__name__)

kafka_conf = {
    'bootstrap.servers': KAFKA_BOOTSTRAP,
}
producer = Producer(kafka_conf)

@app.route('/collect', methods=['POST'])
def collect():
    data = request.json
    data["task_id"] = str(uuid.uuid4())
    data["timestamp"] = time.time()
    data["type"] = "EDGE_DATA"

    try:
        producer.produce(
            KAFKA_TOPIC,
            key=data["producer_id"],
            value=json.dumps(data)
        )
        producer.flush(1.0)
        log.info(f"Data from {data['producer_id']} sent to Kafka.")
    except Exception as e:
        log.error(f"Error sending to Kafka: {e}")

    return jsonify({"status": "received", "id": data["task_id"]})

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000)
