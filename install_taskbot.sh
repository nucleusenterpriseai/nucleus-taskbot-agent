#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer (Environment-Aware) - v2.9                    #
#  • Fixes 'scratch' image error by using a correct override method.          #
#  • Fixes missing environment variable warnings by generating all usernames. #
#  • Ensures all required static and dynamic variables are generated in .env. #
#  • Asks user if they want to use an existing host Nginx or run a new one.    #
#  • Securely auto-generates all service passwords.                           #
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
COMPOSE_FILE="docker-compose.yml"
OVERRIDE_FILE="docker-compose.override.yml"
NGINX_CONF_OUTPUT="nginx/app.conf"
ENV_FILE=".env"
GATEWAY_ENV_FILE=".env.gateway"

INSTALL_DIR="$(pwd)/taskbot_deployment"
HARDCODED_LICENSE_PUBLIC_KEY_B64="LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUNvd0JRWURLMlZ3QXlFQXp4cWkrc1dDZkJDdVQ1RTVyZUtMOHQ0WHk2STlKUWdrOTdoZmFsSjVPNEk9Ci0tLS0tRU5EIFBVQkxJQyBLRVktLS0tLQo="

echo "📦 Taskbot installer starting …"
echo "   Installation directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. & 2. Install Docker & Docker Compose (Prerequisites)
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "🐳 Docker not found → installing..."
  curl -fsSL https://get.docker.com | sh || { echo "❌ Docker installation failed." >&2; exit 1; }
  TARGET_USER=${SUDO_USER:-$USER}
  sudo usermod -aG docker "$TARGET_USER"
  echo "✅ Docker installed."
else
  echo "✅ Docker is already installed."
fi
if ! docker compose version &>/dev/null; then
  echo "🔧 Docker Compose plugin not found → installing..."
  LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  DOCKER_CLI_PLUGINS_DIR="/usr/local/lib/docker/cli-plugins"
  sudo mkdir -p "$DOCKER_CLI_PLUGINS_DIR"
  sudo curl -SL "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" -o "$DOCKER_CLI_PLUGINS_DIR/docker-compose"
  sudo chmod +x "$DOCKER_CLI_PLUGINS_DIR/docker-compose"
  echo "✅ Docker Compose plugin installed."
else
  echo "✅ Docker Compose plugin is already installed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Download Core Files & Create Dirs
# ─────────────────────────────────────────────────────────────────────────────
echo "⬇️  Downloading stack definition file: ${COMPOSE_FILE}..."
curl -fsSL "https://raw.githubusercontent.com/nucleusenterpriseai/nucleus-taskbot-agent/main/${COMPOSE_FILE}?$(date +%s)" -o "${COMPOSE_FILE}" || {
    echo "   ❌ Failed to download ${COMPOSE_FILE}." >&2; exit 1;
}
echo "   ✅ Downloaded ${COMPOSE_FILE}"
mkdir -p ./keys ./certs ./nginx
echo "ℹ️  Created ./keys, ./certs, and ./nginx directories."

# ─────────────────────────────────────────────────────────────────────────────
# 4. Interactive Configuration
# ─────────────────────────────────────────────────────────────────────────────
echo "------------------------------------------------------------------"
echo "⚙️  Web Server Configuration"
echo "------------------------------------------------------------------"
read -rp "Do you already have an Nginx server running on this host that you want to use? (y/n): " USE_EXISTING_NGINX

if [[ "$USE_EXISTING_NGINX" =~ ^[Yy]$ ]]; then
    # --- INTEGRATION MODE ---
    echo ""
    echo "🔗 Configuring for integration with your existing Nginx..."
    read -rp "Enter the domain name this service will use (e.g., taskbot.yourcompany.com): " PUBLIC_DOMAIN_OR_IP
    PUBLIC_URL="https://${PUBLIC_DOMAIN_OR_IP}"

    echo "✍️  Generating Docker Compose override file to expose application ports..."
    cat > "$OVERRIDE_FILE" <<EOF
# This file is auto-generated to expose internal services to your host Nginx.
services:
  frontend:
    ports:
      - "127.0.0.1:3000:3000" # Expose frontend only to the host machine
  gateway:
    ports:
      - "127.0.0.1:8080:8080" # Expose gateway only to the host machine
  installer:
    ports:
      - "127.0.0.1:5000:5000"      
  nginx:
    # This correctly disables the Nginx service by making it do nothing and exit.
    entrypoint: /bin/true
EOF
    echo "   ✅ Override file generated. The installer's Nginx container is now disabled."

    echo ""
    echo "⚠️  ACTION REQUIRED: Add the following configuration to your HOST's Nginx setup."
    echo "   (e.g., inside a 'server' block in /etc/nginx/sites-available/your-site.conf)"
    echo "------------------------------------------------------------------"
    echo ""
    echo "# --- Start of Taskbot Nginx Configuration ---"
    echo "location / { proxy_pass http://127.0.0.1:3000; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"Upgrade\"; }"
    echo "location /core/ { proxy_pass http://127.0.0.1:8080; }"
    echo "location /agentrtc/ { proxy_pass http://127.0.0.1:8080; }"
    echo "location /installer/ { proxy_pass http://127.0.0.1:5000; }"
    echo "location /agentws/ { proxy_pass http://127.0.0.1:8080; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"Upgrade\"; }"
    echo "# --- End of Taskbot Nginx Configuration ---"
    echo ""
    echo "------------------------------------------------------------------"
    echo "After adding this, test your Nginx config with 'sudo nginx -t' and reload with 'sudo systemctl reload nginx'."
    echo ""
    read -rp "Press [Enter] to acknowledge and continue with the installation."
    PROTOCOL="https" # Assume integration is always for a secure domain

else
    # --- STANDALONE MODE ---
    echo ""
    echo "🚀 Configuring a new, dedicated Nginx container for this stack..."
    read -rp "Do you want to configure this Nginx for SECURE (HTTPS)? (y/n): " SETUP_CHOICE

    if [[ "$SETUP_CHOICE" =~ ^[Yy]$ ]]; then
        PROTOCOL="https"
        read -rp "Enter your fully qualified domain name: " PUBLIC_DOMAIN_OR_IP
        PUBLIC_URL="https://${PUBLIC_DOMAIN_OR_IP}"
        read -rp "Path to your certificate file: " CERT_PATH
        read -rp "Path to your private key file: " KEY_PATH
        if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then echo "❌ Cert files not found." >&2; exit 1; fi
        
        cat > "$NGINX_CONF_OUTPUT" <<EOF
# Nginx configuration for HTTPS (Auto-generated)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:8080; }
server { listen 80; server_name ${PUBLIC_DOMAIN_OR_IP}; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2; server_name ${PUBLIC_DOMAIN_OR_IP};
    ssl_certificate /etc/nginx/certs/fullchain.pem; ssl_certificate_key /etc/nginx/certs/privkey.pem;
    location / { proxy_pass http://frontend_server; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /core/ { proxy_pass http://gateway_server; }
    location /agentrtc/ { proxy_pass http://gateway_server; }
    location /agentws/ { proxy_pass http://gateway_server; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /installer/ { proxy_pass http://installer:5000; }
}
EOF
        cat > "$OVERRIDE_FILE" <<EOF
services:
  nginx:
    ports: ["80:80", "443:443"]
    volumes: ["./nginx/app.conf:/etc/nginx/conf.d/default.conf:ro", "${CERT_PATH}:/etc/nginx/certs/fullchain.pem:ro", "${KEY_PATH}:/etc/nginx/certs/privkey.pem:ro", "uploads-data:/var/www/uploads:ro"]
EOF
    else
        PROTOCOL="http"
        read -rp "Enter the public IP address of this server: " PUBLIC_DOMAIN_OR_IP
        PUBLIC_URL="http://${PUBLIC_DOMAIN_OR_IP}"
        cat > "$NGINX_CONF_OUTPUT" <<EOF
# Nginx configuration for HTTP (Auto-generated)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:8080; }
server {
    listen 80; server_name ${PUBLIC_DOMAIN_OR_IP};
    location / { proxy_pass http://frontend_server; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /core/ { proxy_pass http://gateway_server; }
    location /agentrtc/ { proxy_pass http://gateway_server; }
    location /agentws/ { proxy_pass http://gateway_server; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /installer/ { proxy_pass http://installer:5000; }
}
EOF
        cat > "$OVERRIDE_FILE" <<EOF
services:
  nginx:
    ports: ["80:80"]
    volumes: ["./nginx/app.conf:/etc/nginx/conf.d/default.conf:ro", "uploads-data:/var/www/uploads:ro"]
EOF
    fi
    echo "   ✅ Nginx configuration and override file generated."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Generate Secure Environment Files
# ─────────────────────────────────────────────────────────────────────────────
echo "🔐 Generating secure, random passwords for services..."
JDBC_PASSWORD=$(openssl rand -hex 16)
MONGO_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
RABBITMQ_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 48) # hex is also safer here
echo "   ✅ Passwords generated."

echo "✍️  Generating environment files..."
# --- Generate main .env file ---
cat > "$ENV_FILE" <<EOF
# Taskbot Production Environment Configuration (Auto-generated)

# === Core Application Settings ================================================
ACTIVE_PROFILE=prod
LOG_LEVEL=INFO
SERVER_PORT=18902
RUNNING_ON_CLUSTER=false

# === Endpoints & Public Domain ================================================
PUBLIC_DOMAIN=${PUBLIC_URL}
DATA_API_ENDPOINT=http://taskbot-api-service:8080
CORE_API_ENDPOINT=http://taskbot-api-service:18902
FRONT_ENDPOINT=${PUBLIC_URL}

# === Database (MariaDB) =======================================================
JDBC_URL=jdbc:mariadb://mariadb:3306/nucleus?zeroDateTimeBehavior=convertToNull&allowMultiQueries=true&useSSL=false&serverTimezone=UTC
JDBC_USR=taskbot_user
JDBC_PWD=${JDBC_PASSWORD}

# === Database (MongoDB) =======================================================
SPRING_DATA_MONGODB_URI=mongodb://mymongo:${MONGO_PASSWORD}@mongodb:27017
MONGO_INITDB_ROOT_USERNAME=mymongo
MONGO_INITDB_ROOT_PASSWORD=${MONGO_PASSWORD}

# === Redis ====================================================================
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PWD=${REDIS_PASSWORD}

# === RabbitMQ =================================================================
RABBITMQ_HOST=rabbitmq
RABBITMQ_PORT=5672
RABBITMQ_USERNAME=rbuser
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}
TASK_RUN_REQ_EXCH=kk_task_run_req_exch_prod
TASK_RUN_REQ_QUEUE=kk_task_run_request_prod
TASK_RUN_REQ_ROUTE_KEY=run_task_prod
AGENT_RUN_EVENTS_TOPIC_EXCHANGE=agent_run_events_topic_exchange
MONGO_LOGGER_QUEUE=mongo_event_logger_queue
AGENT_COMMANDS_EXCHANGE=agent_commands_direct_exchange

# === Security & Authentication ================================================
LICENSE_PUBLIC_KEY_B64=${HARDCODED_LICENSE_PUBLIC_KEY_B64}
JWT_BASE64_SECRET=${JWT_SECRET}
JWT_SECRET=${JWT_SECRET}
GOOGLE_OAUTH_ENABLED=false

# === Cloud & Email Services ===================================================
aws.s3.enabled=false

# === Local Storage (For Docker) ===============================================
storage.local.path=/storage/uploads

# === Branding =================================================================
company.name=Nucleus AI
email.logo.url=${PUBLIC_URL}/images/logo.png
email.branding.image.url=${PUBLIC_URL}/images/headerbg.png
website.link=${PUBLIC_URL}

# === Other service variables needed by docker-compose.yml =====================
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5000
DATA_PATH_BASE=./taskbot-data
TASKBOT_API_INTERNAL_PORT=18902
CORS_ORIGINS=${PUBLIC_URL}
EOF

# --- Generate .env.frontend file (for the Next.js service) ---
cat > ".env.frontend" <<EOF
# Taskbot Frontend Environment Configuration (.env.frontend)

# This tells Next.js to run in production mode.
NODE_ENV=production

# These are the public variables needed by the browser-side code.
NEXT_PUBLIC_DEPLOY_MODE=ONPREMISE
NEXT_PUBLIC_FRONTEND_URL=${PUBLIC_URL}
NEXT_PUBLIC_API_ENDPOINT_CORE=${PUBLIC_URL}/core
NEXT_PUBLIC_API_ENDPOINT_DATA=${PUBLIC_URL}/data
NEXT_PUBLIC_FLASK_API_URL=${PUBLIC_URL}/installer
NEXT_PUBLIC_GOOGLE_CLIENT_ID=disabled
EOF
echo "   ✅ Frontend .env.frontend file generated."

# --- Generate .env.gateway file ---
cat > "$GATEWAY_ENV_FILE" <<EOF
# Gateway Service Environment Configuration (Auto-generated)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=\${REDIS_PWD}
CORE_API_URL=http://taskbot-api-service:18902
JWT_SECRET=\${JWT_SECRET}
EOF
echo "   ✅ Environment files generated successfully."

# ─────────────────────────────────────────────────────────────────────────────
# 6. & 7. Manage Docker Stack & Final Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "🔄 Managing Docker stack..."
if [ -n "$(docker compose ps -q 2>/dev/null)" ]; then
  echo "ℹ️  Existing containers found. Stopping and removing them..."
  docker compose down --remove-orphans || echo "⚠️  Failed to stop/remove existing containers. Proceeding anyway."
fi

echo "🚀 Pulling latest specified Docker images (this may take a while)..."
docker compose pull || echo "⚠️  Failed to pull some images. Proceeding with local versions if available."

echo "🟢 Starting containers..."
if docker compose up -d --remove-orphans; then
  echo "✅ Docker containers started successfully."
else
  echo "❌ Failed to start Docker containers. Check 'docker compose logs' for errors." >&2
  exit 1
fi

echo ""
echo "🎉 Taskbot installation/update is complete!"
echo "   Your stack is configured for: ${PROTOCOL^^} access."
echo ""
echo "🔗 Access your portal at: ${PUBLIC_URL}"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "🔐 Your auto-generated service passwords have been saved in the .env file."
echo ""
echo "Script finished."