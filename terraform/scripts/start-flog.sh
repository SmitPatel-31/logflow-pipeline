#!/bin/bash
set -e

# Update and install Node.js
sudo apt-get update -y
sudo apt-get install -y curl gnupg
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install flog
sudo npm install -g flog

# Create script to send logs to Kafka
cat <<EOF | sudo tee /opt/flog-to-kafka.js
const { exec } = require('child_process');
const { Kafka } = require('kafkajs');

const kafka = new Kafka({
  clientId: 'flog-producer',
  brokers: ['${KAFKA_BROKER_IP}:9092']
});

const producer = kafka.producer();

(async () => {
  await producer.connect();
  setInterval(() => {
    exec('flog -n 1', async (err, stdout) => {
      if (err) return;
      await producer.send({
        topic: 'smit-logs',
        messages: [{ value: stdout.trim() }]
      });
    });
  }, 1000);
})();
EOF

# Replace placeholder with Kafka instance's internal IP
KAFKA_IP="$(getent hosts kafka-instance | awk '{ print $1 }')"
sudo sed -i "s|\${KAFKA_BROKER_IP}|$KAFKA_IP|g" /opt/flog-to-kafka.js

# Start the log generator
nohup node /opt/flog-to-kafka.js > /tmp/flog-producer.log 2>&1 &
