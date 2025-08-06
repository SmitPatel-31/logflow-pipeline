# Create a custom service account for Dataproc
resource "google_service_account" "dataproc_sa" {
  account_id   = "dataproc-cluster-sa"
  display_name = "Dataproc Cluster Service Account"
}

# Grant necessary IAM roles
resource "google_project_iam_member" "dataproc_worker" {
  project = var.project_id
  role    = "roles/dataproc.worker"
  member  = "serviceAccount:${google_service_account.dataproc_sa.email}"
}

resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.dataproc_sa.email}"
}

# Create custom staging and temp buckets
resource "google_storage_bucket" "dataproc_staging" {
  name     = "${var.project_id}-dataproc-staging"
  location = var.region
  force_destroy = true
}

resource "google_storage_bucket" "dataproc_temp" {
  name     = "${var.project_id}-dataproc-temp"
  location = var.region
  force_destroy = true
}

# IAM bindings for buckets
resource "google_storage_bucket_iam_member" "staging_writer" {
  bucket = google_storage_bucket.dataproc_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataproc_sa.email}"
}

resource "google_storage_bucket_iam_member" "temp_writer" {
  bucket = google_storage_bucket.dataproc_temp.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataproc_sa.email}"
}

# Dataproc Cluster
resource "google_dataproc_cluster" "spark_cluster" {
  name   = "spark-streaming-cluster"
  region = var.region

  cluster_config {
    staging_bucket = google_storage_bucket.dataproc_staging.name
    temp_bucket    = google_storage_bucket.dataproc_temp.name

    master_config {
      num_instances = 1
      machine_type  = "e2-standard-4"
      disk_config {
        boot_disk_type    = "pd-standard"
        boot_disk_size_gb = 100
      }
    }

    worker_config {
      num_instances = 2
      machine_type  = "e2-standard-4"
      disk_config {
        boot_disk_type    = "pd-standard"
        boot_disk_size_gb = 100
      }
    }

    software_config {
      image_version = "2.1-debian11"
      optional_components = ["JUPYTER", "ZEPPELIN"]
    }

    gce_cluster_config {
      network = google_compute_network.vpc_network.self_link
      tags    = ["spark", "dataproc"]
      service_account = google_service_account.dataproc_sa.email
      service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  graceful_decommission_timeout = "120s"

  depends_on = [
    google_project_iam_member.dataproc_worker,
    google_project_iam_member.storage_admin,
    google_storage_bucket_iam_member.staging_writer,
    google_storage_bucket_iam_member.temp_writer
  ]
}

# Dataproc firewall
resource "google_compute_firewall" "dataproc_firewall" {
  name    = "allow-dataproc-internal"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["7077", "8080", "8088", "9870", "8032", "8042", "10000", "18080", "4040"]
  }
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["10.0.0.0/8"] # Adjust based on your subnet CIDR

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }


  source_tags = ["dataproc", "spark"]
  target_tags = ["dataproc", "spark"]
}

# Outputs
output "spark_cluster_name" {
  value = google_dataproc_cluster.spark_cluster.name
}

output "dataproc_staging_bucket" {
  value = google_storage_bucket.dataproc_staging.name
}

output "spark_master_instance" {
  value = length(google_dataproc_cluster.spark_cluster.cluster_config[0].master_config[0].instance_names) > 0 ? google_dataproc_cluster.spark_cluster.cluster_config[0].master_config[0].instance_names[0] : "Not yet created"
}

output "kafka_broker_info" {
  value = "Kafka broker: ${google_compute_instance.kafka.network_interface.0.network_ip}:9092"
}

output "dataproc_web_ui" {
  value = "https://console.cloud.google.com/dataproc/clusters/${google_dataproc_cluster.spark_cluster.name}/monitoring?region=${var.region}&project=${var.project_id}"
}

output "spark_submit_example" {
  value = <<-EOT

  Example Spark submit command for Kafka streaming:

  gcloud dataproc jobs submit pyspark \
    --cluster=${google_dataproc_cluster.spark_cluster.name} \
    --region=${var.region} \
    --packages=org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.0 \
    --properties=spark.executor.memory=4g,spark.executor.cores=2 \
    your_streaming_job.py \
    -- \
    --kafka-brokers=${google_compute_instance.kafka.network_interface.0.network_ip}:9092 \
    --topic=smit-logs

  EOT
}

resource "null_resource" "submit_pyspark_job" {
  provisioner "local-exec" {
    command = <<EOT
      # Wait for all resources to be ready
      echo "Waiting for resources to be ready..."
      sleep 60
      
      # Get the IPs
      KAFKA_IP="${google_compute_instance.kafka.network_interface.0.network_ip}"
      POSTGRES_IP="${google_sql_database_instance.postgres.public_ip_address}"
      
      # Submit the job with properly escaped properties
      gcloud dataproc jobs submit pyspark gs://script-bucket-logflow/stream-job.py \
        --cluster=spark-streaming-cluster \
        --region=${var.region} \
        --properties='spark.jars.packages=org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.0,org.postgresql:postgresql:42.5.1' \
        -- \
        "$${KAFKA_IP}:9092" \
        "$${POSTGRES_IP}"
    EOT
  }
  
  depends_on = [
    google_dataproc_cluster.spark_cluster,
    google_sql_database_instance.postgres,
    google_sql_database.logs_db,
    google_sql_user.postgres_user
  ]
}




