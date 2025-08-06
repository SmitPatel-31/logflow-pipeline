from pyspark.sql import SparkSession
from pyspark.sql.functions import *
from pyspark.sql.types import *
import sys
import os

# Get IPs from environment variables or command line arguments
if len(sys.argv) > 2:
    kafka_broker = sys.argv[1]
    postgres_host = sys.argv[2]
else:
    # Default values - UPDATE THESE with your actual IPs
    kafka_broker = os.environ.get("KAFKA_BROKER", "10.128.0.2:9092")  # Update with your Kafka IP
    postgres_host = os.environ.get("POSTGRES_HOST", "34.27.40.71")  # Update with your PostgreSQL IP

print(f"Using Kafka broker: {kafka_broker}")
print(f"Using PostgreSQL host: {postgres_host}")

# PostgreSQL credentials
postgres_user = "loguser"
postgres_password = "changeme123!"

# Create Spark session with PostgreSQL driver
spark = SparkSession.builder \
    .appName("KafkaToPostgresStreaming") \
    .config("spark.jars.packages", 
            "org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.0,"
            "org.postgresql:postgresql:42.5.1") \
    .getOrCreate()

spark.sparkContext.setLogLevel("WARN")

# Kafka configuration
topic = "smit-logs"

# PostgreSQL configuration
jdbc_url = f"jdbc:postgresql://{postgres_host}:5432/logs"
properties = {
    "user": postgres_user,
    "password": postgres_password,
    "driver": "org.postgresql.Driver"
}

# Define schema for the log data (based on flog JSON format)
log_schema = StructType([
    StructField("host", StringType(), True),
    StructField("user_identifier", StringType(), True),
    StructField("datetime", StringType(), True),
    StructField("method", StringType(), True),
    StructField("request", StringType(), True),
    StructField("protocol", StringType(), True),
    StructField("status", IntegerType(), True),
    StructField("bytes", IntegerType(), True),
    StructField("referer", StringType(), True)
])

# Read from Kafka
print(f"Connecting to Kafka at {kafka_broker} on topic {topic}")
df = spark.readStream.format("kafka") \
    .option("kafka.bootstrap.servers", kafka_broker) \
    .option("subscribe", topic) \
    .option("startingOffsets", "latest") \
    .option("failOnDataLoss", "false") \
    .load()

# Parse JSON logs
parsed_logs = df.select(
    from_json(col("value").cast("string"), log_schema).alias("data")
).select(
    col("data.*"),
    current_timestamp().alias("processed_at")
)

# Write to PostgreSQL in batches
def write_batch_to_postgres(batch_df, batch_id):
    print(f"Writing batch {batch_id} to PostgreSQL...")
    
    # Filter out null records
    valid_records = batch_df.filter(col("host").isNotNull())
    
    if valid_records.count() > 0:
        # Create table if not exists (first batch only)
        if batch_id == 0:
            create_table_query = """
            (SELECT 1 FROM kafka_logs LIMIT 0) UNION ALL
            (SELECT NULL::varchar as host, NULL::varchar as user_identifier, 
                    NULL::varchar as datetime, NULL::varchar as method,
                    NULL::varchar as request, NULL::varchar as protocol,
                    NULL::int as status, NULL::int as bytes,
                    NULL::text as referer, NULL::timestamp as processed_at
             WHERE FALSE)
            """
            try:
                spark.sql("SELECT 1").write.jdbc(
                    url=jdbc_url,
                    table="kafka_logs",
                    mode="overwrite",
                    properties={**properties, "createTableOptions": "AS SELECT * FROM (VALUES (NULL)) AS t WHERE FALSE"}
                )
            except:
                pass  # Table might already exist
        
        valid_records.write \
            .mode("append") \
            .jdbc(url=jdbc_url, table="kafka_logs", properties=properties)
        
        print(f"Batch {batch_id} written successfully. Rows: {valid_records.count()}")
        
        # Print sample for monitoring
        valid_records.select("method", "status", "processed_at").show(5, truncate=False)
    else:
        print(f"Batch {batch_id} had no valid records")

# Option 1: Write to console for debugging (uncomment to test)
# console_query = parsed_logs.writeStream \
#     .outputMode("append") \
#     .format("console") \
#     .option("truncate", False) \
#     .start()

# Option 2: Write to PostgreSQL
print("Starting streaming to PostgreSQL...")
postgres_query = parsed_logs.writeStream \
    .foreachBatch(write_batch_to_postgres) \
    .outputMode("append") \
    .trigger(processingTime='30 seconds') \
    .option("checkpointLocation", "/tmp/kafka-postgres-checkpoint") \
    .start()

# Monitor the stream
print("Stream started. Monitoring...")
postgres_query.awaitTermination()


'''gcloud dataproc jobs submit pyspark gs://script-bucket-logflow/stream-job.py \
  --cluster=spark-streaming-cluster \
  --region=us-central1 \
  --properties-file=gs://script-bucket-logflow/spark-properties.txt \
  -- \
  "10.128.0.2:9092" \
  "34.27.40.71"'''