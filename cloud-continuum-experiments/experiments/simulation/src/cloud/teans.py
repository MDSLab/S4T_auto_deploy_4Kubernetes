import time
import json
import logging
from confluent_kafka import Consumer, KafkaError
from common.utils import setup_logging, get_env

log = setup_logging("TEANS")

KAFKA_BOOTSTRAP = get_env("KAFKA_BOOTSTRAP", "kafka:9092")
KAFKA_TOPIC = "production-forecasts"

state = {
    "total_production": 0.0,
    "total_consumption": 0.0,
    "eprem_estimation": 0.0,
}

def send_event(level, message):
    log.info(f"[{level}] {message}")

def process_message(msg):
    try:
        data = json.loads(msg.value().decode('utf-8'))
        msg_type = data.get("type", "UNKNOWN")

        if msg_type == "EPREM_FORECAST":
            state["eprem_estimation"] = data["estimated_production"]
            log.info("Updated global estimation (EPREM): %s kW", state['eprem_estimation'])
            send_event("INFO", f"New production forecast: {state['eprem_estimation']} kW")
        
        elif msg_type == "EDGE_DATA":
            prod = data.get("production", 0.0)
            cons = data.get("consumption", 0.0)
            state["total_production"] += prod
            state["total_consumption"] += cons
            
            balance = state["total_production"] - state["total_consumption"]
            action = "STAY"
            if balance < 0:
                action = "BUY_GRID"
            elif balance > 10:
                action = "SELL_GRID"

            log.info(
                "[DECISION_TRACE] type=%s producer=%s household=%s task_id=%s sequence=%s action=%s balance=%.2f",
                msg_type, data.get("producer_id", "na"), data.get("household_id", "na"),
                data.get("task_id", "na"), data.get("sequence", "na"), action, balance
            )

    except Exception as e:
        log.error(f"Error processing message: {e}")

def main():
    conf = {
        'bootstrap.servers': KAFKA_BOOTSTRAP,
        'group.id': 'teans-group',
        'auto.offset.reset': 'latest'
    }
    consumer = Consumer(conf)
    consumer.subscribe([KAFKA_TOPIC])

    log.info("TEANS Decision Engine started.")
    try:
        while True:
            msg = consumer.poll(1.0)
            if msg is None: continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF: continue
                else: log.error(msg.error()); break
            process_message(msg)
    finally:
        consumer.close()

if __name__ == "__main__":
    main()
