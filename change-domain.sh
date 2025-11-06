#!/bin/bash

set -e # stop script khi loi xay ra

export $(grep -v '^#' .env | xargs) # nạp biến nếu muốn

adminUser=${MONGO_ROOT_USER}
adminPwd=${MONGO_ROOT_PASSWORD}
mongo1Host=${MONGO1_HOST:-mongo1}
mongo2Host=${MONGO2_HOST:-mongo2}
mongo3Host=${MONGO3_HOST:-mongo3}


echo "🛠️ Initializing domain db"
docker exec mongo1 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem --eval "
db = db.getSiblingDB('admin');
db.auth('$adminUser', '$adminPwd');
cfg = rs.conf()

cfg.members[0].host = '$mongo1Host:27017'
cfg.members[1].host = '$mongo2Host:27018'
cfg.members[2].host = '$mongo3Host:27019'

rs.reconfig(cfg, { force: true })
"

echo "🛠️ DONE"
