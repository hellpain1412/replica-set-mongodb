#!/bin/bash

# setup.sh - Script khởi tạo toàn bộ hệ thống

set -e

echo "🚀 MongoDB Production Setup - Bắt đầu triển khai..."

# Tạo thư mục cần thiết
echo "📁 Tạo cấu trúc thư mục..."
mkdir -p {certs,keyfile,pbm-config,prometheus,grafana/{provisioning/{datasources,dashboards},dashboards},alertmanager}


# 1. TẠO CERTIFICATES CHO TLS
echo "🔐 Tạo SSL certificates..."

# Tạo CA key và certificate
openssl genrsa -out certs/ca-key.pem 4096
openssl req -new -x509 -days 365 -key certs/ca-key.pem -out certs/ca.pem -subj "/C=VN/ST=HCM/L=HCM/O=MongoDB/OU=DBA/CN=MongoDB-CA"

# subjectAltName=DNS:mongo${i},DNS:localhost,IP:127.0.0.1
# extendedKeyUsage=serverAuth,clientAuth
# Tạo certificates cho từng node MongoDB
for i in {1..3}; do
    # SAN config file cho mỗi node
    cat > certs/san-mongo${i}.cnf <<EOF
subjectAltName=DNS:mongo${i},DNS:localhost,IP:127.0.0.1,IP:172.20.0.1${i}
extendedKeyUsage=serverAuth,clientAuth
EOF
    # Server certificate
    openssl genrsa -out certs/mongo${i}-key.pem 4096
    openssl req -new -key certs/mongo${i}-key.pem -out certs/mongo${i}.csr -subj "/C=VN/ST=HCM/L=HCM/O=MongoDB/OU=DBA/CN=mongo${i}"
    openssl x509 -req -in certs/mongo${i}.csr -CA certs/ca.pem -CAkey certs/ca-key.pem -CAcreateserial -out certs/mongo${i}-cert.pem -days 365 -sha256 -extfile certs/san-mongo${i}.cnf
    cat certs/mongo${i}-key.pem certs/mongo${i}-cert.pem > certs/mongo${i}.pem
    rm certs/mongo${i}.csr certs/mongo${i}-cert.pem certs/mongo${i}-key.pem certs/san-mongo${i}.cnf
done

# PBM certificate
openssl genrsa -out certs/pbm-key.pem 4096
openssl req -new -key certs/pbm-key.pem -out certs/pbm.csr -subj "/C=VN/ST=HCM/L=HCM/O=MongoDB/OU=DBA/CN=pbm"
cat > certs/san-pbm.cnf <<EOF
subjectAltName=DNS:mongo1,DNS:mongo2,DNS:mongo3,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
EOF
openssl x509 -req -in certs/pbm.csr -CA certs/ca.pem -CAkey certs/ca-key.pem -CAcreateserial -out certs/pbm-cert.pem -days 365 -sha256 -extfile certs/san-pbm.cnf
cat certs/pbm-key.pem certs/pbm-cert.pem > certs/pbm.pem
rm certs/pbm.csr certs/pbm-cert.pem certs/pbm-key.pem certs/san-pbm.cnf
sudo chmod 644 certs/pbm.pem
sudo chown 999:999 certs/pbm.pem

# Client certificate
openssl genrsa -out certs/client-key.pem 4096
openssl req -new -key certs/client-key.pem -out certs/client.csr -subj "/C=VN/ST=HCM/L=HCM/O=MongoDB/OU=DBA/CN=client"
cat > certs/san-client.cnf <<EOF
subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
EOF
openssl x509 -req -in certs/client.csr -CA certs/ca.pem -CAkey certs/ca-key.pem -CAcreateserial -out certs/client-cert.pem -days 365 -sha256 -extfile certs/san-client.cnf
cat certs/client-key.pem certs/client-cert.pem > certs/client.pem
rm certs/client.csr certs/client-cert.pem certs/client-key.pem certs/san-client.cnf

sudo chmod 400 certs/*
sudo chown $(whoami):$(whoami) certs/client.pem
sudo chown 999:999 certs/ca.pem
sudo chmod 600 certs/client.pem certs/ca.pem
echo "Certificates được tạo trong 'certs/'."

# 2. TẠO KEYFILE CHO INTERNAL AUTHENTICATION
echo "🔑 Tạo MongoDB keyfile..."
openssl rand -base64 756 > keyfile/mongo-keyfile
sudo chmod 600 keyfile/mongo-keyfile

minioUser=${MINIO_ROOT_USER:-minio}
minioPwd=${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)}


# 3. TẠO ENVIRONMENT FILE
echo "📋 Tạo .env file..."
cat > .env << EOF
MONGO_VER=8.0
RS_NAME=rs0
TZ=Asia/Bangkok

# MongoDB
MONGO_ROOT_USER=admin
MONGO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)

# PBM User
PBM_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)

# Monitor User
MONITOR_USER=monitor
MONITOR_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)

# MinIO
MINIO_ROOT_USER=$minioUser
MINIO_ROOT_PASSWORD=$minioPwd

# Grafana
GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c1-16)
EOF

# 4. TẠO PBM CONFIGURATION
echo "📦 Tạo PBM configuration..."
cat > pbm-config/pbm.conf << EOF
storage:
  type: s3
  s3:
    region: us-east-1
    bucket: mongodb-backups
    prefix: pbm
    endpointUrl: http://minio:9000
    credentials:
      access-key-id: $minioUser
      secret-access-key: $minioPwd
    serverSideEncryption:
      sseAlgorithm: AES256

restore:
  batchSize: 1000
  numInsertionWorkers: 10

backup:
  oplogSpanMin: 10
  compression: gzip
  compressionLevel: 6
EOF

# 5. TẠO PROMETHEUS CONFIGURATION
echo "📊 Tạo Prometheus configuration..."
cat > prometheus/prometheus.yml << EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s

rule_files:
  - "mongodb_rules.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

scrape_configs:
  - job_name: 'mongodb'
    static_configs:
      - targets: ['mongo_exporter:9216']
    scrape_interval: 30s
    scrape_timeout: 10s

  - job_name: 'node'
    static_configs:
      - targets: ['node_exporter:9100']
    scrape_interval: 30s

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF

# 6. TẠO MONGODB ALERTING RULES
cat > prometheus/mongodb_rules.yml << 'EOF'
groups:
- name: mongodb
  rules:
  - alert: MongoDBDown
    expr: mongodb_up == 0
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "MongoDB instance is down"
      description: "MongoDB instance {{ $labels.instance }} has been down for more than 2 minutes."

  - alert: MongoDBReplicationLag
    expr: mongodb_rs_members_lastHeartbeat{state="SECONDARY"} - mongodb_rs_members_optimeDate{state="PRIMARY"} > 300
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "MongoDB replication lag is high"
      description: "MongoDB replica {{ $labels.instance }} is lagging behind primary by {{ $value }} seconds."

  - alert: MongoDBHighConnections
    expr: mongodb_connections{state="current"} / mongodb_connections{state="available"} > 0.8
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "MongoDB high connection usage"
      description: "MongoDB instance {{ $labels.instance }} is using {{ $value | humanizePercentage }} of available connections."

  - alert: MongoDBHighMemoryUsage
    expr: mongodb_memory{type="resident"} / 1024 / 1024 > 1500
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "MongoDB high memory usage"
      description: "MongoDB instance {{ $labels.instance }} is using {{ $value }}MB of memory."
EOF

# 7. TẠO GRAFANA DATASOURCE
cat > grafana/provisioning/datasources/prometheus.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

# 8. TẠO GRAFANA DASHBOARD PROVISIONING
cat > grafana/provisioning/dashboards/dashboard.yml << EOF
apiVersion: 1

providers:
  - name: 'MongoDB Dashboards'
    type: file
    folder: ''
    options:
      path: /var/lib/grafana/dashboards
EOF

# 9. TẠO ALERTMANAGER CONFIG
cat > alertmanager/alertmanager.yml << EOF
global:
  smtp_smarthost: 'localhost:587'
  smtp_from: 'alertmanager@company.com'

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'web.hook'

receivers:
- name: 'web.hook'
  webhook_configs:
  - url: 'http://127.0.0.1:5001/'
    send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'dev', 'instance']
EOF

# Đặt quyền sở hữu cho user MongoDB (UID 999)
sudo chown -R 999:999 certs keyfile pbm-config prometheus grafana alertmanager

echo "✅ Setup hoàn tất! Cấu trúc thư mục và files đã được tạo."
