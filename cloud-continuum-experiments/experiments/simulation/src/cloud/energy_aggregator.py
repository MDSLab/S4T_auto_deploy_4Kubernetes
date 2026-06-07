import os
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json, window, avg, sum as spark_sum, to_timestamp
from pyspark.sql.types import StructType, StructField, StringType, DoubleType

# Configurazione Kafka
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka-cluster-kafka-bootstrap:9092")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "production-forecasts")
CHECKPOINT_DIR = os.getenv("CHECKPOINT_DIR", "/tmp/checkpoints/energy-aggregator")

def main():
    print(f"Starting Spark Job - Bootstrap: {KAFKA_BOOTSTRAP}, Topic: {KAFKA_TOPIC}")
    
    spark = SparkSession.builder \
        .appName("Simulation-Energy-Aggregator-Edge") \
        .getOrCreate()

    spark.sparkContext.setLogLevel("INFO") # Alziamo il log level per vedere più dettagli Kafka

    schema = StructType([
        StructField("producer_id", StringType(), True),
        StructField("estimated_production", DoubleType(), True),
        StructField("confidence", DoubleType(), True),
        StructField("timestamp", DoubleType(), True),
        StructField("type", StringType(), True),
    ])

    # Usiamo 'earliest' per assicurarci di leggere i dati già presenti
    df = spark.readStream \
        .format("kafka") \
        .option("kafka.bootstrap.servers", KAFKA_BOOTSTRAP) \
        .option("subscribe", KAFKA_TOPIC) \
        .option("startingOffsets", "earliest") \
        .option("failOnDataLoss", "false") \
        .load()

    # Stream 1: Dati grezzi per debug (con output immediato)
    raw_query = df.selectExpr("CAST(value AS STRING) as raw_json") \
        .writeStream \
        .format("console") \
        .option("truncate", "false") \
        .start()

    # Stream 2: Aggregazione
    parsed_df = df.select(
        from_json(col("value").cast("string"), schema).alias("data")
    ).select("data.*") \
     .withColumn("time", to_timestamp(col("timestamp")))

    edge_df = parsed_df.filter(col("producer_id") == "edge-house-01")

    aggregated_df = edge_df \
        .withWatermark("time", "2 minutes") \
        .groupBy(
            window(col("time"), "60 seconds"),
            col("producer_id")
        ) \
        .agg(
            avg("estimated_production").alias("avg_prod"),
            spark_sum("estimated_production").alias("total_prod")
        )

    agg_query = aggregated_df.writeStream \
        .outputMode("update") \
        .format("console") \
        .option("truncate", "false") \
        .trigger(processingTime="60 seconds") \
        .start()

    spark.streams.awaitAnyTermination()

if __name__ == "__main__":
    main()
