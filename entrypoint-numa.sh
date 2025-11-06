#!/usr/bin/env bash
set -euo pipefail

# Luôn chạy script này bằng root (service sẽ set user: root)
install -d -m 700 -o 999 -g 999 /mongo/keyfile /mongo/ssl

# Copy từ /opt/keyfile (0400 root-only) → /mongo/*, rồi chown/chmod cho 999
if [ -f /opt/keyfile/mongo-keyfile ]; then
    chmod 644 /opt/keyfile/mongo-keyfile
    cp /opt/keyfile/mongo-keyfile /mongo/keyfile/mongo-keyfile
    chmod 600 /mongo/keyfile/mongo-keyfile
    chown 999:999 /mongo/keyfile/mongo-keyfile
fi

if [ -n "${NODE_CERT:-}" ] && [ -f /opt/ssl/"${NODE_CERT}" ]; then
    chmod 644 /opt/ssl/"${NODE_CERT}"
    cp /opt/ssl/"${NODE_CERT}" /mongo/ssl/node.pem
    chmod 600 /mongo/ssl/node.pem
    chown 999:999 /mongo/ssl/node.pem
fi

if [ -f /opt/ssl/ca.pem ]; then
    chmod 644 /opt/ssl/ca.pem
    cp /opt/ssl/ca.pem /mongo/ssl/ca.pem
    chmod 600 /mongo/ssl/ca.pem
    chown 999:999 /mongo/ssl/ca.pem
fi

# Tham số mongod
MONGO_ARGS=()
MONGO_ARGS+=(--replSet "${RS_NAME:-rs0}")
MONGO_ARGS+=(--bind_ip_all)
MONGO_ARGS+=(--port 27017)
MONGO_ARGS+=(--auth)

if [ -f /mongo/keyfile/mongo-keyfile ]; then
    MONGO_ARGS+=(--keyFile /mongo/keyfile/mongo-keyfile)
fi
if [ -f /mongo/ssl/node.pem ] && [ -f /mongo/ssl/ca.pem ]; then
    MONGO_ARGS+=(--tlsMode requireTLS)
    MONGO_ARGS+=(--tlsCertificateKeyFile /mongo/ssl/node.pem)
    MONGO_ARGS+=(--tlsCAFile /mongo/ssl/ca.pem)
    MONGO_ARGS+=(--tlsAllowConnectionsWithoutCertificates)
fi

MONGO_ARGS+=(--oplogSize ${OPLOG_SIZE_MB:-2048})
MONGO_ARGS+=(--wiredTigerCacheSizeGB ${WT_CACHE_GB:-1})

# NUMA policy
NUMACTL_BIN="$(command -v numactl || true)"
if [ -n "${NUMA_NODE:-}" ] && [ -n "${NUMACTL_BIN}" ]; then
    echo "[entrypoint] Pin mongod to NUMA node ${NUMA_NODE}"
    exec "${NUMACTL_BIN}" --cpunodebind="${NUMA_NODE}" --membind="${NUMA_NODE}" mongod "${MONGO_ARGS[@]}"
    elif [ -n "${DISABLE_INTERLEAVE:-}" ]; then
    echo "[entrypoint] Run mongod without numactl (DISABLE_INTERLEAVE set)"
    exec mongod "${MONGO_ARGS[@]}"
    elif [ -n "${NUMA_INTERLEAVE:-1}" ] && [ -n "${NUMACTL_BIN}" ]; then
    echo "[entrypoint] Run mongod with numactl --interleave=all"
    exec "${NUMACTL_BIN}" --interleave=all mongod "${MONGO_ARGS[@]}"
else
    echo "[entrypoint] numactl not available; starting mongod normally"
    exec mongod "${MONGO_ARGS[@]}"
fi
