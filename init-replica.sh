#!/usr/bin/env bash
set -euo pipefail

export $(grep -v '^#' .env | xargs) # nạp biến nếu muốn

# Biến cấu hình
adminUser=${MONGO_ROOT_USER:-admin}
adminPwd=${MONGO_ROOT_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)}
monitorUser=${MONGO_MONITOR_USER:-monitor}
monitorPwd=${MONGO_MONITOR_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)}
pbmPwd=${PBM_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)}
minioUser=${MINIO_ROOT_USER:-minio}
minioPwd=${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)}
grafanaPwd=${GRAFANA_PASSWORD:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c1-16)}
rsName=${RS_NAME:-rs0}

# Start containers
echo "📦 Starting containers..."
docker compose up --build -d --force-recreate mongo1 mongo2 mongo3


# Đợi mongod sẵn sàng
until docker exec mongo1 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem  \
--host mongo1 --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; do
echo "Waiting for mongo1..."; sleep 2; done
until docker exec mongo2 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem \
--host mongo2 --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; do
echo "Waiting for mongo2..."; sleep 2; done
until docker exec mongo3 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem \
--host mongo3 --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; do
echo "Waiting for mongo3..."; sleep 2; done

echo "3 node mongod are up."



# Tạo replica set và user admin
echo "🛠️ Initializing replica set... $rsName"

docker exec mongo1 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem --eval "
if (!db.runCommand({ isMaster: 1 }).setName) {
    rs.initiate({
        _id: '$rsName',
        members: [
            { _id: 0, host: 'mongo1:27017', priority: 2 },
            { _id: 1, host: 'mongo2:27017', priority: 1 },
            { _id: 2, host: 'mongo3:27017', priority: 0 }
        ]
    });
    print('Replica set initiated');
}


// Đợi tới khi node hiện tại có thể ghi (PRIMARY)
function waitPrimary(maxMs){
  const t0 = Date.now();
  for(;;){
    try {
      const h = db.hello();
      if (h.isWritablePrimary) return true;
    } catch(e) {}
    if (Date.now() - t0 > maxMs) return false;
    sleep(500);
  }
}
if (!waitPrimary(60000)) { throw new Error('Timeout waiting for PRIMARY'); }
print('PRIMARY is ready');
"

echo "🛠️ Initializing user admin"
docker exec mongo1 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem --eval "
db = db.getSiblingDB('admin');

// Tạo user nếu chưa có (tránh chạy lại bị lỗi)
db.createUser({user:'$adminUser', pwd:'$adminPwd', roles:[{role:'root', db:'admin'}]});
print('Admin user created');

sleep(2000);
db.auth('$adminUser', '$adminPwd');

// Cấu hình member thứ 3 làm secondary trễ 10 phút (hidden, no vote)
var cfg = rs.conf();
cfg.members[2].hidden = true;
cfg.members[2].votes = 0;
cfg.members[2].priority = 0;
cfg.members[2].secondaryDelaySecs = 600;
try {
  rs.reconfig(cfg);
} catch (e) {
  print('reconfig raised: ' + e);
  // Nếu vừa step-down, chờ PRIMARY mới rồi thử lại 1 lần
  function waitPrimary(maxMs){
    const t0 = Date.now();
    for(;;){
      try { if (db.hello().isWritablePrimary) return true; } catch(e) {}
      if (Date.now()-t0 > maxMs) return false;
      sleep(500);
    }
  }
  if (waitPrimary(60000)) {
    rs.reconfig(cfg);
  } else {
    throw e;
  }
}

// Chờ ổn định lại PRIMARY sau reconfig
(function(){
  const t0 = Date.now();
  for(;;){
    try { if (db.hello().isWritablePrimary) break; } catch(e) {}
    if (Date.now()-t0 > 60000) throw new Error('Timeout waiting PRIMARY after reconfig');
    sleep(500);
  }
})();

// PBM user for backup
db.createUser({
  user: 'pbm_user',
  pwd: '$pbmPwd',
  roles: [
    { role: 'clusterMonitor', db: 'admin' },
    { role: 'restore', db: 'admin' },
    { role: 'backup', db: 'admin' },
    { role: 'readWrite', db: 'admin' }
  ]
});

// Monitor user for metrics
db.createUser({
  user: '$monitorUser',
  pwd: '$monitorPwd',
  roles: [
    { role: 'clusterMonitor', db: 'admin' },
    { role: 'read', db: 'local' }
  ]
});


print('Reconfig done and PRIMARY is ready');
"

echo "Created admin user | User: $adminUser | Pwd: $adminPwd"
echo "Created PBM user | User: 'pbm_user | Pwd: $pbmPwd"
echo "Created Monitor user | User: $monitorUser | Pwd: $monitorPwd"
echo "Created replica set"

# Setup MinIO bucket
# echo "🪣 Tạo MinIO bucket cho backup..."
# docker run --rm --network $(basename "$(pwd)")_mongo_net \
#     --entrypoint sh \
#     minio/mc:latest \
#     -c "mc alias set myminio http://minio:9000 $minioUser $minioPwd && mc mb myminio/mongodb-backups"

# # Configure PBM
# echo "📦 Cấu hình PBM..."
# docker exec -it pbm sh -c "
#     pbm config --file /etc/pbm/pbm.conf &&
#     pbm config --set pitr.enabled=true &&
#     pbm config --set pitr.compression=gzip
# "

# Start monitoring stack
echo "📊 Starting monitoring stack..."
# docker compose up -d prometheus grafana mongo_exporter node_exporter alertmanager minio pbm

echo "✅ Triển khai hoàn tất!"
echo ""
echo "🌐 Các services đang chạy tại:"
echo "   - MongoDB Primary: localhost:27017"
echo "   - MongoDB Secondary 1: localhost:27018" 
echo "   - MongoDB Secondary 2 (delayed): localhost:27019"
echo "   - MinIO Console: http://localhost:9001"
echo "   - Prometheus: http://localhost:9090"
echo "   - Grafana: http://localhost:3000 (admin/$(grep GRAFANA_PASSWORD .env | cut -d= -f2))"
echo "   - AlertManager: http://localhost:9093"
echo ""
echo "🔐 Thông tin đăng nhập:"
echo "   - MongoDB admin: $adminUser | $adminPwd"
echo "   - MinIO: $minioUser | $minioPwd"
echo ""
echo "📋 Các lệnh hữu ích:"
echo "   - Kiểm tra replica set: docker exec -it mongo1 mongosh --eval 'rs.status()'"
echo "   - Backup ngay: docker exec -it pbm pbm backup"
echo "   - Xem backup: docker exec -it pbm pbm list"
echo "   - PITR restore: docker exec -it pbm pbm restore --time '2024-01-01T12:00:00Z'"