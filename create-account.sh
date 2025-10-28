#!/bin/bash

set -e # stop script khi loi xay ra

export $(grep -v '^#' .env | xargs) # nạp biến nếu muốn

adminUser=${MONGO_ROOT_USER}
adminPwd=${MONGO_ROOT_PASSWORD}

echo ""
echo "📦 Tạo cấu hình Tài khoản..."
read -p "nhập datase_name: " datase_name
echo "datase_name: $datase_name"

read -p "nhập username: " username
echo "username: $username"

read -p "nhập password: " password_input
password=${password_input:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)}
echo "password: $password"


echo "🛠️ Initializing user admin"
docker exec mongo1 mongosh --tls --tlsCAFile /mongo/ssl/ca.pem --tlsCertificateKeyFile /mongo/ssl/node.pem --eval "
db = db.getSiblingDB('admin');
db.auth('$adminUser', '$adminPwd');
db = db.getSiblingDB('$datase_name');

db.createUser({
    user: '$username',
    pwd: '$password',
    roles: [
        { role: 'readWrite', db: '$datase_name' },
    ]
});
"
echo "#Database App" >> create-account.txt
echo "DATABASE_NAME=$datase_name" >> create-account.txt
echo "DATABASE_USER=$username" >> create-account.txt
echo "DATABASE_PASS=$password" >> create-account.txt
echo "DATABASE_URI=mongodb://$username:$password@mongo1:27017,mongo2:27017,mongo3:27017/$datase_name?replicaSet=rs0&authSource=$datase_name&tls=true" >> create-account.txt
echo " " >> create-account.txt

echo "🛠️ Created user | User: $username | Pwd: $password"
echo "🪣 URI: mongodb://$username:$password@mongo1:27017,mongo2:27017,mongo3:27017/$datase_name?replicaSet=rs0&authSource=$datase_name&tls=true"
