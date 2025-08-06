# postgres.tf - Simple PostgreSQL Database for storing logs

# Create a PostgreSQL instance with public IP only
resource "google_sql_database_instance" "postgres" {
  name             = "log-postgres-instance"
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier = "db-f1-micro"  # Small instance for development
    
    ip_configuration {
      ipv4_enabled = true
      
      # Allow access from anywhere (restrict in production!)
      authorized_networks {
        name  = "allow-all-for-dev"
        value = "0.0.0.0/0"
      }
    }
  }
  
  deletion_protection = false  # Set to true in production
}

# Create database
resource "google_sql_database" "logs_db" {
  name     = "logs"
  instance = google_sql_database_instance.postgres.name
}

# Create user
resource "google_sql_user" "postgres_user" {
  name     = "loguser"
  instance = google_sql_database_instance.postgres.name
  password = "changeme123!"  # Use a secret manager in production
}

# Output connection details
output "postgres_public_ip" {
  value = google_sql_database_instance.postgres.public_ip_address
}

output "postgres_connection_string" {
  value     = "postgresql://loguser:changeme123!@${google_sql_database_instance.postgres.public_ip_address}/logs"
  sensitive = true
}