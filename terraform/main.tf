provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_compute_network" "vpc_network" {
  name                    = "log-pipeline-network"
  auto_create_subnetworks = true
}

# Allow internal communication
resource "google_compute_firewall" "allow-internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc_network.name
  
  allow {
    protocol = "tcp"
    ports    = ["22", "9092"]
  }
  
  source_ranges = ["10.128.0.0/9"]
  target_tags   = ["kafka", "flog"]
}

# Allow SSH from external
resource "google_compute_firewall" "allow-ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.name
  
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["kafka", "flog"]
}

resource "google_compute_instance" "kafka" {
  name         = "kafka-instance"
  machine_type = "e2-medium"
  zone         = var.zone
  
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }
  
  network_interface {
    network = google_compute_network.vpc_network.name
    access_config {}
  }
  
  metadata_startup_script = <<-EOF
    #!/bin/bash
    # Don't exit on error immediately
    set +e
    
    # Log all output
    exec > >(tee -a /var/log/startup-script.log)
    exec 2>&1
    
    echo "Starting Kafka installation at $(date)"
    
    # Update and install Java
    apt-get update -y
    apt-get install -y openjdk-17-jdk wget
    
    # Download and extract Kafka (using latest stable version)
    cd /opt
    wget -q https://downloads.apache.org/kafka/3.8.1/kafka_2.13-3.8.1.tgz
    if [ $? -ne 0 ]; then
        echo "Failed to download Kafka 3.8.1, trying 3.7.1..."
        wget -q https://downloads.apache.org/kafka/3.7.1/kafka_2.13-3.7.1.tgz
        tar -xzf kafka_2.13-3.7.1.tgz
        mv kafka_2.13-3.7.1 kafka
        rm kafka_2.13-3.7.1.tgz
    else
        tar -xzf kafka_2.13-3.8.1.tgz
        mv kafka_2.13-3.8.1 kafka
        rm kafka_2.13-3.8.1.tgz
    fi
    
    # Configure Kafka
    INTERNAL_IP=$(hostname -I | awk '{print $1}')
    echo "Internal IP: $INTERNAL_IP"
    
    # Update Kafka configuration
    cat >> /opt/kafka/config/server.properties <<EOL
    
# Custom settings
advertised.listeners=PLAINTEXT://$INTERNAL_IP:9092
listeners=PLAINTEXT://0.0.0.0:9092
EOL
    
    # Create systemd service for Zookeeper
    cat > /etc/systemd/system/zookeeper.service <<EOL
[Unit]
Description=Apache Zookeeper
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL
    
    # Create systemd service for Kafka
    cat > /etc/systemd/system/kafka.service <<EOL
[Unit]
Description=Apache Kafka
After=network.target zookeeper.service
Requires=zookeeper.service

[Service]
Type=simple
User=root
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL
    
    # Reload systemd and start services
    systemctl daemon-reload
    systemctl enable zookeeper
    systemctl enable kafka
    systemctl start zookeeper
    
    # Wait for Zookeeper to start
    sleep 15
    
    systemctl start kafka
    
    # Wait for Kafka to start
    sleep 15
    
    # Create the topic
    /opt/kafka/bin/kafka-topics.sh --create --topic smit-logs --bootstrap-server localhost:9092 --partitions 1 --replication-factor 1 || true
    
    echo "Kafka installation completed at $(date)"
  EOF
  
  tags = ["kafka"]
}

resource "google_compute_instance" "flog" {
  name         = "flog-instance"
  machine_type = "e2-medium"
  zone         = var.zone
  
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }
  
  network_interface {
    network = google_compute_network.vpc_network.name
    access_config {}
  }
  
  metadata_startup_script = <<-EOF
    #!/bin/bash
    # Don't exit on error immediately
    set +e
    
    # Log all output
    exec > >(tee -a /var/log/startup-script.log)
    exec 2>&1
    
    echo "Starting flog installation at $(date)"
    
    # Update and install dependencies
    apt-get update -y
    apt-get install -y curl gnupg wget
    
    # Install Node.js for the producer script
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
    
    # Download and install flog binary (Go-based log generator)
    cd /tmp
    wget -q https://github.com/mingrammer/flog/releases/download/v0.4.4/flog_0.4.4_linux_amd64.tar.gz
    tar -xzf flog_0.4.4_linux_amd64.tar.gz
    mv flog /usr/local/bin/
    chmod +x /usr/local/bin/flog
    rm flog_0.4.4_linux_amd64.tar.gz
    
    # Test flog installation
    /usr/local/bin/flog --version
    
    # Create a directory for the producer script
    mkdir -p /opt/flog-producer
    cd /opt/flog-producer
    
    # Install kafkajs locally
    npm init -y
    npm install kafkajs
    
    # Wait for Kafka to be ready (give it some time to start)
    echo "Waiting for Kafka to be ready..."
    sleep 90
    
    # Get Kafka instance internal IP
    KAFKA_IP="${google_compute_instance.kafka.network_interface.0.network_ip}"
    echo "Kafka IP: $KAFKA_IP"
    
    # Create the Node.js script to send logs to Kafka
    cat > /opt/flog-producer/flog-to-kafka.js <<'SCRIPT'
const { exec } = require('child_process');
const { Kafka } = require('kafkajs');

const kafka = new Kafka({
  clientId: 'flog-producer',
  brokers: ['KAFKA_BROKER_IP:9092']
});

const producer = kafka.producer();

async function connectWithRetry(maxRetries = 10) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      await producer.connect();
      console.log('Connected to Kafka');
      return true;
    } catch (error) {
      console.log('Connection attempt ' + (i + 1) + ' failed:', error.message);
      if (i < maxRetries - 1) {
        await new Promise(resolve => setTimeout(resolve, 10000)); // Wait 10 seconds
      }
    }
  }
  return false;
}

async function run() {
  const connected = await connectWithRetry();
  if (!connected) {
    console.error('Failed to connect to Kafka after multiple attempts');
    process.exit(1);
  }

  console.log('Starting to send logs...');
  
  setInterval(() => {
    exec('/usr/local/bin/flog -n 1 -f json', async (err, stdout) => {
      if (err) {
        console.error('Error generating log:', err);
        return;
      }
      
      try {
        await producer.send({
          topic: 'smit-logs',
          messages: [{ value: stdout.trim() }]
        });
        console.log('Log sent:', new Date().toISOString());
      } catch (error) {
        console.error('Error sending to Kafka:', error);
      }
    });
  }, 1000);
}

run().catch(console.error);
SCRIPT
    
    # Replace KAFKA_BROKER_IP with actual IP
    sed -i "s/KAFKA_BROKER_IP/$KAFKA_IP/g" /opt/flog-producer/flog-to-kafka.js
    
    # Create systemd service for the producer
    cat > /etc/systemd/system/flog-producer.service <<EOL
[Unit]
Description=Flog Log Producer
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/flog-producer
ExecStart=/usr/bin/node /opt/flog-producer/flog-to-kafka.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL
    
    # Start the service
    systemctl daemon-reload
    systemctl enable flog-producer
    systemctl start flog-producer
    
    echo "Flog installation completed at $(date)"
  EOF
  
  tags = ["flog"]
  
  # Ensure flog starts after kafka
  depends_on = [google_compute_instance.kafka]
}

# Output the instance IPs for easy access
output "kafka_external_ip" {
  value = google_compute_instance.kafka.network_interface.0.access_config.0.nat_ip
}

output "flog_external_ip" {
  value = google_compute_instance.flog.network_interface.0.access_config.0.nat_ip
}

output "kafka_internal_ip" {
  value = google_compute_instance.kafka.network_interface.0.network_ip
}