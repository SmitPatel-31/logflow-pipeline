#!/bin/bash
set -e

# Update and install Java
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jdk wget

# Download and extract Kafka
cd /opt
sudo wget https://downloads.apache.org/kafka/3.6.1/kafka_2.13-3.6.1.tgz
sudo tar -xzf kafka_2.13-3.6.1.tgz
sudo mv kafka_2.13-3.6.1 kafka

# Configure Kafka (set advertised.listeners)
INTERNAL_IP=$(hostname -I | awk '{print $1}')
sudo sed -i "/^#listeners=PLAINTEXT/a advertised.listeners=PLAINTEXT://${INTERNAL_IP}:9092" /opt/kafka/config/server.properties
sudo sed -i "s/^#listeners=.*/listeners=PLAINTEXT://0.0.0.0:9092/" /opt/kafka/config/server.properties

# Start Zookeeper and Kafka in the background
nohup /opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties > /tmp/zookeeper.log 2>&1 &
sleep 5
nohup /opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties > /tmp/kafka.log 2>&1 &
