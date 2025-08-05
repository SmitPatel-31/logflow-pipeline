from pyspark.sql import SparkSession
from pyspark.sql.functions import expr

spark = SparkSession.builder \
    .appName("KafkaLogStreaming") \
    .getOrCreate()

# Replace with your Kafka broker IP and topic
kafka_broker = "10.128.0.12:9092"  # replace with your Kafka VM's internal IP
topic = "smit-logs"

# Read from Kafka
df = spark.readStream.format("kafka") \
    .option("kafka.bootstrap.servers", kafka_broker) \
    .option("subscribe", topic) \
    .option("startingOffsets", "latest") \
    .load()

# Convert binary key/value to string
logs = df.selectExpr("CAST(key AS STRING)", "CAST(value AS STRING)")

# Print to console (or write to BigQuery, GCS, PostgreSQL etc.)
query = logs.writeStream \
    .outputMode("append") \
    .format("console") \
    .start()

query.awaitTermination()

# submit a job in pyspark

'''gcloud dataproc jobs submit pyspark gs://script-bucket-logflow/stream-job.py \
  --cluster=spark-streaming-cluster \
  --region=us-central1 \
  --properties=spark.jars.packages=org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.0'''


