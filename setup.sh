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

# Đặt quyền sở hữu cho user MongoDB (UID 999)
sudo chown -R 999:999 certs keyfile pbm-config prometheus grafana alertmanager


# 3. TẠO ENVIRONMENT FILE
echo "📋 Tạo .env file..."
cat > .env << EOF
MONGO_VER=8.0
RS_NAME=rs0
TZ=Asia/Bangkok

# MongoDB
MONGO_ROOT_USER=admin
MONGO_ROOT_PASSWORD=$(openssl rand -base64 32)

# PBM User
PBM_PASSWORD=$(openssl rand -base64 32)

# Monitor User
MONITOR_USER=monitor  
MONITOR_PASSWORD=$(openssl rand -base64 32)

# MinIO
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)

# Grafana
GRAFANA_PASSWORD=$(openssl rand -base64 16)
EOF