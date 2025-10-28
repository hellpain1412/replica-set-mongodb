#!/bin/bash

# setup.sh - Script khởi tạo toàn bộ hệ thống

set -e

echo "🚀 MongoDB Production Setup - Bắt đầu triển khai..."
docker compose down --volumes

sudo rm -rf {certs,grafana,keyfile,pbm-config,prometheus,scripts,.env,alertmanager}

# Tạo thư mục cần thiết
echo "📁 Tạo cấu trúc thư mục..."
mkdir -p {certs,keyfile,pbm-config,prometheus,grafana/{provisioning/{datasources,dashboards},dashboards},alertmanager}


# 1. TẠO CERTIFICATES CHO TLS
echo "🔐 Tạo SSL certificates..."

mkdir -p /opt/mongo-rs/mongo/keyfile
openssl rand -base64 756 | tr -d '\n' | sudo tee keyfile/mongo-keyfile >/dev/null
sudo chmod 400 keyfile/mongo-keyfile
sudo chown 999:999 keyfile/mongo-keyfile   # 999 = user trong image mongo

# Tạo CA
openssl genrsa -out certs/ca.key 4096
openssl req -x509 -new -nodes -key certs/ca.key -sha256 -days 3650 -out certs/ca.pem -subj "/CN=Mongo Local CA"

# Tạo cert cho từng node (SAN phải khớp hostname + FQDN nếu có)
for host in mongo1 mongo2 mongo3 pbm; do
cat > certs/${host}-csr.conf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = ${host}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${host}
DNS.2 = ${host}.mongo-net
IP.1  = 127.0.0.1
EOF
    
    openssl genrsa -out certs/${host}.key 2048
    openssl req -new -key certs/${host}.key -out certs/${host}.csr -config certs/${host}-csr.conf
    
cat > certs/${host}-cert.conf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${host}
DNS.2 = ${host}.mongo-net
IP.1  = 127.0.0.1
EOF
    
    openssl x509 -req -in certs/${host}.csr -CA certs/ca.pem -CAkey certs/ca.key -CAcreateserial \
    -out certs/${host}.crt -days 3650 -sha256 -extfile certs/${host}-cert.conf
    
    # Gộp cert + key thành .pem cho mongod
    cat certs/${host}.crt certs/${host}.key > certs/${host}.pem
done

rm certs/*.csr certs/*.srl certs/*.conf certs/*.key certs/*.crt

sudo chown -R 999:999 certs/
sudo chmod 400 certs/*.pem

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
