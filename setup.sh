#!/bin/bash

if [ "$UID" != "0" ]; then
    echo "This script needs to be run as root." 1>&2
    exit 1
fi

DEFAULT_DOMAIN=suitcase-ai.com
DEFAULT_HOTSPOT=AI-Suitcase

read -p "Top Level Domain [${DEFAULT_DOMAIN}]: " USER_DOMAIN </dev/tty
read -p "Hotspot Name [${DEFAULT_HOTSPOT}]: " USER_HOTSPOT </dev/tty
read -p "Hotspot Password: " HOTSPOT_PW </dev/tty
read -p "Load default models [Y/n]? " USER_MODELS </dev/tty

DOMAIN=${USER_DOMAIN:-$DEFAULT_DOMAIN}
HOTSPOT=${USER_HOTSPOT:-$DEFAULT_HOTSPOT}
LOAD_MODELS=${USER_MODELS:-y}

echo "Using domain: $DOMAIN"
echo "Using hotspot: $HOTSPOT"
echo "Using password: $HOTSPOT_PW"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

if [ ! -d /opt ]; then
    mkdir -p /opt
fi
cd /opt

# Install necessary packages
PKGS="bzip2 g++"
# - nginx: Provides the HTTPS termination and SNI
PKGS="$PKGS nginx"
# - cerbot: Provides renewal of the SSL certificate
PKGS="$PKGS certbot python3-certbot-nginx"
# - docker: Provides containerization and orchestration of services
PKGS="$PKGS docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
# - coturn: TURN implementation to support rendezvous
PKGS="$PKGS coturn"
# - dnsmasq: DNS/DHCP support for managing the Wifi connections
PKGS="$PKGS dnsmasq"
# - java 17: For compiling App Inventor
PKGS="$PKGS openjdk-17-jdk-headless"
# - ant: For compiling App Inventor
PKGS="$PKGS ant"
# - qemu-user: Enables running Linux Android programs on arm64 architecture
PKGS="$PKGS qemu-user"
# - llama.cpp: For running LLMs
PKGS="$PKGS cmake libssl-dev"
# - llama-swap: For running LLMs

setup_docker() {
    # Add Docker's official GPG key:
    apt update
    apt install ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

setup_docker
apt update
apt -y upgrade
apt -y install $PKGS

# Run certbot
certbot --manual certonly -d \*.$DOMAIN </dev/tty

# Build llama.cpp
git clone https://github.com/ggml-org/llama.cpp
pushd llama.cpp
# git checkout b68d75165ad37ba1256cc45a43ec4f51cf813c3e # checkout the exact commit used during initial testing
if [ -f '/usr/local/cuda/bin/nvcc' ]; then
    LLAMA_CPP_ARGS="-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121-real -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc"
else
    LLAMA_CPP_ARGS="-DGGML_CUDA=OFF"
fi
cmake -B build -DLLAMA_OPENSSL=ON $LLAMA_CPP_ARGS
cmake --build build --config Release -j
LLAMA_SERVER="${PWD}/build/bin/llama-server"
case $LOAD_MODELS in
    [Yy]* )
	echo "Pulling default models..."
	sudo -u www-data build/bin/llama-cli -hf unsloth/medgemma-27b-it-GGUF:UD-Q4_K_XL -st -p "What is 2+2?"
	sudo -u www-data build/bin/llama-cli -hf ggml-org/gpt-oss-120b-GGUF --jinja -st -p "What is 2+2?"
	break;;
esac
popd

# Setup llama-swap
mkdir -p llama-swap
pushd llama-swap
wget https://github.com/mostlygeek/llama-swap/releases/download/v201/llama-swap_201_linux_arm64.tar.gz
tar zxf llama-swap_201_linux_arm64.tar.gz
rm llama-swap_201_linux_arm64.tar.gz
cat >config.yaml <<EOF
models:
  medgemma:
    cmd: $LLAMA_SERVER --port \${PORT} -hf unsloth/medgemma-27b-it-GGUF:UD-Q4_K_XL
  gpt-oss:
    cmd: $LLAMA_SERVER --port \${PORT} -hf ggml-org/gpt-oss-120b-GGUF --jinja
EOF
cat >/etc/systemd/system/llama-swap.service <<EOF
[Unit]
Description=llama-swap - OpenAI compatible proxy for model swapping
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=${PWD}
ExecStart=${PWD}/llama-swap --config config.yaml --watch-config
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl start llama-swap
popd

# Setup nginx
cat >/etc/letsencrypt/options-ssl-nginx.conf <<EOF
# This file contains important security parameters. If you modify this file
# manually, Certbot will be unable to automatically provide future security
# updates. Instead, Certbot will print and log an error message with a path to
# the up-to-date file that you will need to refer to when manually updating
# this file. Contents are based on https://ssl-config.mozilla.org

ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
EOF
openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
cat >/etc/nginx/sites-available/default <<EOF
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}
server {
  server_name code.$DOMAIN;
  location / {
    proxy_pass http://localhost:8888/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
  }
  client_max_body_size 2048M;
  listen [::]:443 ssl;
  listen 443 ssl;
  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
  include /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
  listen 80;
  listen [::]:80;
  server_name _;
  return 301 https://\$host\$request_uri;
}
EOF
cat >/etc/nginx/sites-available/chatbot <<EOF
server {
        server_name chatbot.$DOMAIN;
        location / {
                proxy_pass http://localhost:8081;
                proxy_http_version 1.1;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_read_timeout 600s;
        }
        client_max_body_size 100M;
        listen [::]:443 ssl; # managed by Certbot
        listen 443 ssl; # managed by Certbot
        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # managed by Certbot
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # managed by Certbot
        include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
        ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
EOF
cat >/etc/nginx/sites-available/classifier <<EOF
server {
        server_name classifier.$DOMAIN;
        location / {
                proxy_pass http://localhost:3000;
                proxy_http_version 1.1;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
        }
        client_max_body_size 2048M;
        listen [::]:443 ssl; # managed by Certbot
        listen 443 ssl; # managed by Certbot
        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # managed by Certbot
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # managed by Certbot
        include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
        ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
server {
        server_name classifier-backend.$DOMAIN;
        location / {
                proxy_pass http://localhost:5000;
                proxy_http_version 1.1;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Host \$host;
                proxy_set_header X-Forwarded-Proto \$scheme;
                proxy_read_timeout 600s;
        }
        client_max_body_size 2048M;
        listen [::]:443 ssl; # managed by Certbot
        listen 443 ssl; # managed by Certbot
        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # managed by Certbot
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # managed by Certbot
        include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
        ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
EOF
cat >/etc/nginx/sites-available/rendezvous <<EOF
server {
        listen 80;
        listen [::]:80;

        server_name rendezvous.appinventor.mit.edu rendezvous.$DOMAIN;

        location / {
                proxy_pass http://localhost:8000;
                proxy_http_version 1.1;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
        }
}
server {
        listen 443 ssl; # managed by Certbot
        listen [::]:443 ssl; # manged by Certbot
        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # managed by Certbot
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # managed by Certbot
        include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
        ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

        server_name rendezvous.$DOMAIN;
        location / {
                proxy_pass http://localhost:8000;
                proxy_http_version 1.1;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
        }
}
EOF
# Turn on all sites
sites="chatbot classifier default rendezvous"
for site in $sites; do
    rm -f /etc/nginx/sites-enabled/$site
    ln -s /etc/nginx/sites-{available,enabled}/$site
done
nginx -s reload

# Setup coturn
echo >>/etc/turnserver.conf <<EOF
listening-ip=10.42.0.1
EOF
echo >/etc/default/coturn <<EOF
#
# Uncomment it if you want to have the turnserver running as
# an automatic system service daemon
#
TURNSERVER_ENABLED=1
EOF
systemctl restart coturn.service

# Setup secrets
mkdir -p /root/secrets/authkey
dd if=/dev/urandom bs=24 count=1 | base64 > /root/secrets/pgsql_pass.txt
dd if=/dev/urandom bs=24 count=1 | base64 > /root/secrets/chatbot_secret.txt

if [ ! -f /root/secrets/authkey/meta ]; then
    wget https://raw.githubusercontent.com/appinventor-foundation/appinventor-sources/refs/heads/master/appinventor/lib/keyczar/KeyczarTool.jar
    java -jar KeyczarTool.jar create --purpose=crypt --location=/root/secrets/authkey
    java -jar KeyczarTool.jar addkey --location=/root/secrets/authkey
    java -jar KeyczarTool.jar promote --location=/root/secrets/authkey --version=1
fi
pushd /root/secrets
tar czf appinvconfig.tar.gz authkey
popd

# Load Images
mkdir -p ai-suitcase-orchestration
pushd ai-suitcase-orchestration
if [ -f "${SCRIPT_DIR}/images.tar.bz2" ]; then
    echo "Loading Docker images..."
    bunzip2 -c "${SCRIPT_DIR}/images.tar.bz2" | docker image load
else
    curl "https://drive.usercontent.google.com/download?id=1erqGDzkvn8UsJx8y3ErrOv7QpW2GVbHn&confirm=t" -o images.tar.bz2
    echo "Loading Docker images..."
    bunzip2 -c images.tar.bz2 | docker image load
fi
cat >docker-compose.yaml <<EOF
services:
  postgres:
    image: "postgres:17-alpine"
    restart: always
    shm_size: 128mb
    volumes:
      - db_data:/var/lib/postgresql
    secrets:
      - db_root_pass
    environment:
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_root_pass
      - POSTGRES_DB=appinventor
      - POSTGRES_USER=appinventor
      - POSTGRES_HOST_AUTH_METHOD=md5
      - POSTGRES_INITDB_ARGS="--auth-host=md5"
  buildserver:
    image: "ai-suitcase-orchestration-buildserver:latest"
    restart: always
    ports:
      - "127.0.0.1:9990:9990"
    volumes:
      - dex_cache:/var/dexCache
  appinventor:
    image: "ai-suitcase-orchestration-appinventor:latest"
    restart: always
    depends_on:
      - buildserver
      - postgres
    ports:
      - "127.0.0.1:8888:8888"
    secrets:
      - appinv_config
      - chatbot_secret
      - db_root_pass
    environment:
      - CHATBOT_BASE_URL=https://chatbot.$DOMAIN/
      - CHATBOT_SECRET_FILE=/run/secrets/chatbot_secret
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_root_pass
  redis:
    image: redis
    restart: always
  logger:
    image: "ai-suitcase-orchestration-logger:latest"
    restart: always
  rendezvous:
    image: "ai-suitcase-orchestration-rendezvous:latest"
    restart: always
    depends_on:
      - redis
      - logger
    ports:
      - "127.0.0.1:8000:8000"
  pic-backend:
    image: "ai-suitcase-orchestration-pic-backend:latest"
    restart: always
    ports:
      - "127.0.0.1:5000:5000"
    environment:
      - UV_THREADPOOL_SIZE=20
    tmpfs:
      - /tmp:size=16G,mode=1777
  pic:
    image: "ai-suitcase-orchestration-pic:latest"
    restart: always
    environment:
      - BACKEND_SERVER=classifier-backend.$DOMAIN
    ports:
      - "127.0.0.1:3000:3000"
  chatbot-proxy:
    image: "ai-suitcase-orchestration-chatbot-proxy:latest"
    restart: always
    ports:
      - "127.0.0.1:8081:8080"

secrets:
  db_root_pass:
    file: /root/secrets/pgsql_pass.txt
  appinv_config:
    file: /root/secrets/appinvconfig.tar.gz
  chatbot_secret:
    file: /root/secrets/chatbot_secret.txt

volumes:
  db_data:
  dex_cache:
EOF
docker compose up -d
popd

# Setup dnsmasq
echo "address=/$DOMAIN/10.42.0.1" >> /etc/dnsmasq.conf
ln -s /etc/dnsmasq.conf /etc/NetworkManager/dnsmasq-shared.d/

# Set up the hotspot. Since this will change the Wifi settings and we may be configuring over Wifi, we save it as the last step.
nmcli con del Hotspot
nmcli dev wifi hotspot ssid "$HOTSPOT" password "$HOTSPOT_PW"
nmcli con modify Hotspot connection.autoconnect yes

systemctl restart coturn.service

echo ""
echo "Done"
