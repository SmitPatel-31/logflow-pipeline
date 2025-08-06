# logflow-pipeline

A cloud-native pipeline for streaming synthetic logs from Kafka to Spark (Dataproc) and storing them in PostgreSQL, all provisioned with Terraform.

---

## Architecture

- **Kafka VM**: Runs Apache Kafka for log ingestion.
- **Flog VM**: Generates synthetic logs using [flog](https://github.com/mingrammer/flog) and streams them to Kafka via a Node.js producer.
- **Dataproc Cluster**: Runs Spark streaming jobs to process logs from Kafka and write to PostgreSQL.
- **Cloud SQL PostgreSQL**: Stores processed log data.

---

## Infrastructure Overview

Provisioned via [Terraform](terraform/):

- VPC network and firewall rules
- Compute instances for Kafka and Flog
- Dataproc cluster with custom service account and GCS buckets
- Cloud SQL PostgreSQL instance, database, and user

---

## Setup Instructions

### 1. Configure Variables

Edit [`terraform/cred.tfvars`](terraform/cred.tfvars) with your GCP project ID, region, and zone.

### 2. Initialize and Apply Terraform

```sh
cd terraform
terraform init
terraform apply -var-file=cred.tfvars
```

### 3. Access Output Values

After `terraform apply`, note the outputs:
- Kafka external/internal IP
- Flog external IP
- PostgreSQL public IP and connection string
- Dataproc cluster name

---

## How the Pipeline Works

1. **Kafka VM**: Installs and starts Kafka automatically.
2. **Flog VM**: Installs flog and a Node.js producer that generates logs and sends them to Kafka.
3. **Dataproc Cluster**: Runs a Spark streaming job (`stream-job2.py`) that:
   - Reads logs from Kafka
   - Parses and transforms them
   - Writes batches to PostgreSQL using JDBC

---

## Running the Spark Streaming Job

The Spark job is designed to run on Dataproc and write to PostgreSQL.

### Submit the Job Manually

```sh
gcloud dataproc jobs submit pyspark gs://script-bucket-logflow/stream-job2.py \
  --cluster=spark-streaming-cluster \
  --region=us-central1 \
  --properties=spark.jars.packages=org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.0,org.postgresql:postgresql:42.5.1 \
  -- \
  "<KAFKA_INTERNAL_IP>:9092" \
  "<POSTGRES_PUBLIC_IP>"
```

- Replace `<KAFKA_INTERNAL_IP>` and `<POSTGRES_PUBLIC_IP>` with the Terraform outputs.

### Automatic Submission

A `null_resource` in Terraform can submit the job automatically after provisioning.

---

## PostgreSQL Details

- **Instance**: Cloud SQL PostgreSQL, public IP enabled for development.
- **Database**: `logs`
- **User**: `loguser` / password from Terraform (`changeme123!` by default)
- **Table**: `kafka_logs` (created automatically by the Spark job)

**Connection string example:**
```
postgresql://loguser:changeme123!@<POSTGRES_PUBLIC_IP>/logs
```

---

## File Reference

- [`stream-job2.py`](../stream-job2.py): Spark streaming job (Kafka → PostgreSQL)
- [`terraform/main.tf`](main.tf): Core infrastructure (Kafka, Flog, VPC)
- [`terraform/dataproc.tf`](dataproc.tf): Dataproc cluster and buckets
- [`terraform/postgres.tf`](postgres.tf): Cloud SQL PostgreSQL resources
- [`terraform/variables.tf`](variables.tf): Input variables
- [`terraform/cred.tfvars`](cred.tfvars): Project credentials

---

## Security Notes

- The PostgreSQL instance is open to all IPs for development (`0.0.0.0/0`). Restrict this in production.
- Store secrets (like DB passwords) in Secret Manager for production.

---

## License

MIT © 2025 Smit Patel