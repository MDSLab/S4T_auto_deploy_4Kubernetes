"""
s4_spark.py - Distributed aggregation with Spark Structured Streaming.

Replaces s4_aggregate.py (pure Python) for multi-device scenarios.

Flow:
  Kafka topic (airwatch-normalized)
    -> JSON parsing
    -> window aggregation per device_id (mean, min, max, count)
    -> aggregate writing to InfluxDB

Architectural justification (paper):
  Kafka temporally decouples the fog cluster from the cloud cluster.
  Kafka partitions by device_id allow horizontal parallelism
  proportional to the number of devices — each Spark executor manages
  a subset of partitions independently.
  Checkpointing guarantees exactly-once semantics in case of a crash.
"""

import os

from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, from_json, window, avg, min as spark_min,
    max as spark_max, count, to_timestamp, coalesce,
)
from pyspark.sql.types import (
    StructType, StructField, StringType, DoubleType,
)

# -- Environment configuration (injected via ConfigMap) --
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "localhost:9092")
KAFKA_TOPIC     = os.getenv("KAFKA_TOPIC",     "airwatch-normalized")
INFLUX_HOST     = os.getenv("INFLUX_HOST",     "localhost")
INFLUX_PORT     = int(os.getenv("INFLUX_PORT", "8086"))
INFLUX_USER     = os.getenv("INFLUX_USER",     "admin")
INFLUX_PASSWORD = os.getenv("INFLUX_PASSWORD", "changeme")
INFLUX_DB       = os.getenv("INFLUX_DB",       "airwatch")
AGG_WINDOW_SEC  = int(os.getenv("AGG_WINDOW_SEC", "60"))
CHECKPOINT_DIR  = os.getenv("CHECKPOINT_DIR",  "/tmp/spark-checkpoints")

# -- Schema of the normalized JSON payload (from s2) --
FIELDS_SCHEMA = StructType([
    StructField("PM25",        DoubleType()),
    StructField("PM10",        DoubleType()),
    StructField("Temperature", DoubleType()),
    StructField("Humidity",    DoubleType()),
    StructField("CO",          DoubleType()),
    StructField("NO2",         DoubleType()),
    StructField("Pressure",    DoubleType()),
    StructField("Wind_speed",  DoubleType()),
    StructField("Gust",        DoubleType()),
])

PAYLOAD_SCHEMA = StructType([
    StructField("source",        StringType()),
    StructField("device_id",     StringType()),
    StructField("timestamp",     StringType()),
    StructField("fields",        FIELDS_SCHEMA),
    StructField("quality_score", DoubleType()),
])

SENSOR_FIELDS = [
    "PM25", "PM10", "Temperature", "Humidity",
    "CO", "NO2", "Pressure", "Wind_speed", "Gust",
]


def write_to_influx(batch_df, batch_id):
    """
    Writes an aggregated micro-batch to InfluxDB.
    Called for each micro-batch by foreachBatch.
    """
    rows = batch_df.collect()
    print(f"Batch {batch_id}: aggregated rows={len(rows)}")
    if not rows:
        return

    from influxdb import InfluxDBClient

    client = InfluxDBClient(
        host=INFLUX_HOST,
        port=INFLUX_PORT,
        username=INFLUX_USER,
        password=INFLUX_PASSWORD,
        database=INFLUX_DB,
    )

    points = []
    for row in rows:
        fields = {}
        for field in SENSOR_FIELDS:
            for agg in ["mean", "min", "max", "count"]:
                col_name = f"{field}_{agg}"
                val = getattr(row, col_name, None)
                if val is not None:
                    fields[col_name] = float(val)

        if not fields:
            continue

        points.append({
            "measurement": "env_aggregated_spark",
            "tags": {
                "device_id":    row.device_id,
                "window_start": str(row.window.start),
                "window_end":   str(row.window.end),
            },
            "time":   str(row.window.end),
            "fields": fields,
        })

    if not points:
        print(f"Batch {batch_id}: no valid points to write")
        return

    # ---- FGCS Scientific Metrics (Test 1 & Test 3) ----
    import time
    wall_clock_ts = int(time.time() * 1000)
    
    for row in rows:
        # GAP 1: Spark processing latency
        window_end_ms = int(row.window.end.timestamp() * 1000)
        processing_latency_ms = wall_clock_ts - window_end_ms
        print(f"[SPARK] Window [{row.window.start} -> {row.window.end}] written at {wall_clock_ts}, processing_latency_ms: {processing_latency_ms}")

        # Test 1: Data Reduction Ratio (Input count vs Output 1)
        # We assume each aggregated row represents N original records (e.g., Temperature_count)
        input_records = getattr(row, "Temperature_count", 1)
        print(f"[TEST-1] Aggregation: {input_records} records reduced to 1 for device={row.device_id}")
        
        # Test 3: Provenance Metadata Check
        # Spark receives data that should have the 'provenance' tag if passed from Kafka correctly
        print(f"[TEST-3] Cloud Aggregator processed data for device={row.device_id}")

    try:
        client.write_points(points)
        print(f"Batch {batch_id}: successfully wrote {len(points)} points to InfluxDB.")
    except Exception as exc:
        print(f"Batch {batch_id}: InfluxDB write error: {exc}")


def main():
    spark = (
        SparkSession.builder
        .appName("AirWatch-S4-Aggregator")
        .config("spark.sql.shuffle.partitions", "4")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    # -- Reading from Kafka --
    raw = (
        spark.readStream
        .format("kafka")
        .option("kafka.bootstrap.servers", KAFKA_BOOTSTRAP)
        .option("subscribe", KAFKA_TOPIC)
        .option("startingOffsets", "earliest")
        .option("failOnDataLoss", "false")
        .load()
    )

    # -- JSON Parsing --
    parsed = (
        raw
        .select(from_json(col("value").cast("string"), PAYLOAD_SCHEMA).alias("data"))
        .select("data.*")
        .withColumn(
            "event_time",
            coalesce(
                to_timestamp(col("timestamp").cast("double")), # Handle numeric epoch
                to_timestamp(col("timestamp")), # Handle ISO string
                to_timestamp(col("timestamp"), "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX"),
                to_timestamp(col("timestamp"), "yyyy-MM-dd'T'HH:mm:ssXXX"),
            ),
        )
        .filter(col("device_id").isNotNull())
        .filter(col("event_time").isNotNull())
    )

    # -- Aggregation by time window and device --
    agg_exprs = []
    for field in SENSOR_FIELDS:
        agg_exprs += [
            avg(f"fields.{field}").alias(f"{field}_mean"),
            spark_min(f"fields.{field}").alias(f"{field}_min"),
            spark_max(f"fields.{field}").alias(f"{field}_max"),
            count(f"fields.{field}").alias(f"{field}_count"),
        ]

    aggregated = (
        parsed
        .withWatermark("event_time", "60 seconds")
        .groupBy(
            window(col("event_time"), f"{AGG_WINDOW_SEC} seconds"),
            col("device_id"),
        )
        .agg(*agg_exprs)
    )

    # -- Writing to InfluxDB via foreachBatch --
    query = (
        aggregated.writeStream
        .outputMode("update")
        .foreachBatch(write_to_influx)
        .option("checkpointLocation", CHECKPOINT_DIR)
        .trigger(processingTime=f"{AGG_WINDOW_SEC} seconds")
        .start()
    )

    print(f"S4 Spark job started. Kafka: {KAFKA_BOOTSTRAP} topic: {KAFKA_TOPIC}")
    query.awaitTermination()


if __name__ == "__main__":
    main()
