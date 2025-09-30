#!/usr/bin/env bash
set -euo pipefail

export $(grep -v '^#' .env | xargs) # nạp biến nếu muốn

# Biến cấu hình
adminUser=${MONGO_ROOT_USER:-admin}
adminPwd=${MONGO_ROOT_PASSWORD:-$(openssl rand -base64 32)}
rsName=${RS_NAME:-rs0}


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


print('Reconfig done and PRIMARY is ready');
rs.status();
"
echo "Created admin user | User: $adminUser | Pwd: $adminPwd"

echo "Created replica set"