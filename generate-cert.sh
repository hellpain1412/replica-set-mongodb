#!/usr/bin/env bash
set -euo pipefail

export $(grep -v '^#' .env | xargs) # nạp biến nếu muốn


# ===========================
# CONFIG
# ===========================
# DOMAIN_BASE="ataji.slova.vn"
# NODES=("mongo1.${DOMAIN_BASE}" "mongo2.${DOMAIN_BASE}" "mongo3.${DOMAIN_BASE}")
NODES=("${MONGO1_HOST}" "${MONGO2_HOST}" "${MONGO3_HOST}")
CERTS=("mongo1" "mongo2" "mongo3" "pbm")

CERTS_DIR="./certs"
KEYFILE_DIR="./keyfile"

CA_KEY="${CERTS_DIR}/ca.key"
CA_CRT="${CERTS_DIR}/ca.pem"

# ===========================
# PREPARE DIRS
# ===========================
mkdir -p "${CERTS_DIR}" "${KEYFILE_DIR}"

# ===========================
# 1) TẠO ROOT CA (NẾU CHƯA CÓ)
# ===========================
if [[ ! -f "${CA_KEY}" || ! -f "${CA_CRT}" ]]; then
    echo "[*] Generating Root CA..."
    openssl genrsa -out "${CA_KEY}" 4096
    
    openssl req -x509 -new -key "${CA_KEY}" -days 3650 -out "${CA_CRT}" \
    -subj "/C=VN/ST=HCM/L=HCM/O=Slova/OU=MongoCA/CN=Slova Mongo Root CA"
    
    chmod 400 "${CA_KEY}"
    echo "    -> CA created at ${CA_CRT}"
else
    echo "[*] Root CA already exists, skipping."
fi

# ===========================
# 2) TẠO CERT CHO TỪNG NODE
# ===========================
for ((i=0; i<${#CERTS[@]}; i++)); do
    NODE=${CERTS[i]}
    HOST=${NODES[i]:+${NODES[i]}}
    KEY="${CERTS_DIR}/${NODE}.key"
    CSR="${CERTS_DIR}/${NODE}.csr"
    CRT="${CERTS_DIR}/${NODE}.crt"
    PEM="${CERTS_DIR}/${NODE}.pem"
    SAN="${CERTS_DIR}/${NODE}-san.cnf"
    
    echo "[*] Generating cert for ${NODE} ..."
    
    # 2.1 Private key
    openssl genrsa -out "${KEY}" 4096
    
    # 2.2 SAN (DNS + 127.0.0.1)
  cat > "${SAN}" <<EOF
subjectAltName = DNS:${NODE}$([ -n "${HOST}" ] && echo ",DNS:${HOST}"),IP:127.0.0.1
EOF
    
    # 2.3 CSR
    openssl req -new -key "${KEY}" -out "${CSR}" \
    -subj "/C=VN/ST=HCM/L=HCM/O=Slova/OU=MongoDB/CN=${HOST}"
    
    # 2.4 Ký bằng Root CA
    openssl x509 -req -in "${CSR}" -CA "${CA_CRT}" -CAkey "${CA_KEY}" \
    -CAcreateserial -out "${CRT}" -days 1825 -sha256 \
    -extfile "${SAN}"
    
    # 2.5 Gộp key + cert thành .pem cho mongod
    cat "${KEY}" "${CRT}" > "${PEM}"
    
    chmod 400 "${KEY}" "${PEM}"
    echo "    -> PEM: ${PEM}"
done

# ===========================
# 3) TẠO KEYFILE CHO REPLICA SET AUTH
# ===========================
KEYFILE_PATH="${KEYFILE_DIR}/mongo-keyfile"
if [[ ! -f "${KEYFILE_PATH}" ]]; then
    echo "[*] Generating replica set keyFile..."
    # dung lượng > 1024 bit như Mongo yêu cầu (756 bytes base64 ok)
    openssl rand -base64 756 | tr -d '\n' | sudo tee "${KEYFILE_PATH}" >/dev/null
    chmod 400 "${KEYFILE_PATH}"
    echo "    -> keyFile: ${KEYFILE_PATH}"
else
    echo "[*] keyFile already exists, skipping."
fi

echo
echo "[✓] Done. Files in ${CERTS_DIR} and ${KEYFILE_DIR}:"
ls -l "${CERTS_DIR}" "${KEYFILE_DIR}"
echo
echo "Nhớ cấu hình DNS:"
echo "  ${MONGO1_HOST} -> IP VPS"
echo "  ${MONGO2_HOST} -> IP VPS"
echo "  ${MONGO3_HOST} -> IP VPS"
echo

# # 1. TẠO CERTIFICATES CHO TLS
# echo "🔐 Tạo SSL certificates..."

# NODES=("${MONGO1_HOST}" "${MONGO1_HOST}" "${MONGO1_HOST}")
# mongo=("mongo1" "mongo2" "mongo3" "pbm")

# mkdir -p /opt/mongo-rs/mongo/keyfile
# openssl rand -base64 756 | tr -d '\n' | sudo tee keyfile/mongo-keyfile >/dev/null
# sudo chmod 400 keyfile/mongo-keyfile
# sudo chown 999:999 keyfile/mongo-keyfile   # 999 = user trong image mongo

# # Tạo CA
# openssl genrsa -out certs/ca.key 4096
# openssl req -x509 -new -nodes -key certs/ca.key -sha256 -days 3650 -out certs/ca.pem -subj "/C=VN/ST=HCM/L=HCM/O=Hellpain/OU=MongoCA/CN=Hellpain Mongo Root CA"

# # Tạo cert cho từng node (SAN phải khớp hostname + FQDN nếu có)
# for ((i=0; i<3; i++)); do
# cat > certs/${mongo[i]}-csr.conf <<EOF
# [ req ]
# default_bits       = 2048
# prompt             = no
# default_md         = sha256
# req_extensions     = req_ext
# distinguished_name = dn

# [ dn ]
# CN = ${mongo[i]}

# [ req_ext ]
# subjectAltName = @alt_names

# [ alt_names ]
# DNS.1 = ${mongo[i]}
# DNS.2 = ${NODES[i]}
# IP.1  = 127.0.0.1
# IP.2  = 103.166.185.163
# EOF

#     openssl genrsa -out certs/${mongo[i]}.key 2048
#     openssl req -new -key certs/${mongo[i]}.key -out certs/${mongo[i]}.csr -config certs/${mongo[i]}-csr.conf

# cat > certs/${mongo[i]}-cert.conf <<EOF
# authorityKeyIdentifier=keyid,issuer
# basicConstraints=CA:FALSE
# keyUsage = digitalSignature, keyEncipherment
# extendedKeyUsage = serverAuth, clientAuth
# subjectAltName = @alt_names

# [alt_names]
# DNS.1 = ${mongo[i]}
# DNS.2 = ${mongo[i]}.ataji.group
# IP.1  = 127.0.0.1
# IP.2  = 103.166.185.163
# EOF

#     openssl x509 -req -in certs/${mongo[i]}.csr -CA certs/ca.pem -CAkey certs/ca.key -CAcreateserial \
#     -out certs/${mongo[i]}.crt -days 3650 -sha256 -extfile certs/${mongo[i]}-cert.conf

#     # Gộp cert + key thành .pem cho mongod
#     cat certs/${mongo[i]}.crt certs/${mongo[i]}.key > certs/${mongo[i]}.pem
# done

# rm certs/*.csr certs/*.srl certs/*.conf certs/*.key certs/*.crt

# sudo chown -R 999:999 certs/
# sudo chmod 400 certs/*.pem