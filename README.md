# logflow-pipeline

A cloud-native pipeline for streaming synthetic logs from Kafka to Spark (Dataproc) using Terraform-managed infrastructure.

## Architecture

- **Kafka VM**: Runs Apache Kafka for log ingestion.
- **Flog VM**: Generates synthetic logs using [flog](https://github.com/mingrammer/flog) and sends them to Kafka.
- **Dataproc Cluster**: Runs Spark streaming jobs to process logs from Kafka.

## Infrastructure

Provisioned via [Terraform](terraform/):

- VPC network and firewall rules
- Compute instances for Kafka and Flog
- Dataproc cluster with custom service account and GCS buckets

## Setup

1. **Configure variables**

   Edit [`terraform/cred.tfvars`](terraform/cred.tfvars) with your GCP project ID.

2. **Initialize and apply Terraform**

   ```sh
   cd terraform
   terraform init
   terraform apply -var-file=cred.tfvars
   ```

3. **Access instance IPs**

   After apply, Terraform outputs:
   - Kafka external/internal IP
   - Flog external IP

## Kafka & Flog

- Kafka is installed and started automatically on the Kafka VM.
- Flog is installed on the Flog VM and streams logs to Kafka using a Node.js producer ([kafkajs](https://kafka.js.org/)).

## Spark Streaming

- Use [`stream-job.py`](stream-job.py) to consume logs from Kafka in Spark.
- Example Dataproc submit command (see [`dataproc.tf`](terraform/dataproc.tf) output):

   ```sh
   gcloud dataproc jobs submit pyspark gs://script-bucket-logflow/stream-job.py \
     --cluster=spark-streaming-cluster \
     --region=us-central1 \
     --properties=spark.jars.packages=org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.0
   ```

## Customization

- Change Kafka topic in [`stream-job.py`](stream-job.py) and VM startup scripts if needed.
- Modify machine types, regions, or bucket names in [`main.tf`](terraform/main.tf) and [`dataproc.tf`](terraform/dataproc.tf).

## Files

- [`stream-job.py`](stream-job.py): Spark streaming job example.
- [`terraform/main.tf`](terraform/main.tf): Core infrastructure.
- [`terraform/dataproc.tf`](terraform/dataproc.tf): Dataproc cluster and buckets.
- [`terraform/variables.tf`](terraform/variables.tf): Input variables.
- [`terraform/cred.tfvars`](terraform/cred.tfvars): Project credentials.

## License

MIT © 2025 Smit