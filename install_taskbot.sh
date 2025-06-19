#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer (Environment-Aware) - v11.0 (Cleanup)         #
#  • Adds interactive cleanup of previous installations.                      #
#  • Adds 'proxy_set_header Host $host' to all gateway routes in Nginx.       #
#  • All previous fixes for frontend, installer, and gateway ports included.  #
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# 0. Cleanup Previous Installation (If it exists)
# ─────────────────────────────────────────────────────────────────────────────
INSTALL_DIR_NAME="taskbot_deployment"
INSTALL_DIR="$(pwd)/${INSTALL_DIR_NAME}"

if [ -d "${INSTALL_DIR}" ]; then
    echo "⚠️  An existing Taskbot installation was found at: ${INSTALL_DIR}"
    read -rp "Do you want to COMPLETELY REMOVE the existing installation (including all data) and start fresh? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "   -> User confirmed cleanup."
        echo "   Shutting down existing services and removing volumes..."
        # Use a subshell to run compose down from the correct directory without changing our current path
        (cd "${INSTALL_DIR}" && docker compose down --volumes) || echo "   (Could not run 'docker compose down'. This is OK if the directory is corrupted. Continuing cleanup.)"
        
        echo "   Removing old installation directory..."
        # The script is run with sudo, so we need sudo to remove the directory it created
        sudo rm -rf "${INSTALL_DIR}"
        echo "✅ Previous installation cleaned up successfully."
    else
        echo "❌ Aborting installation as requested. Your existing data is safe."
        exit 0
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
COMPOSE_FILE="docker-compose.yml"
OVERRIDE_FILE="docker-compose.override.yml"
NGINX_CONF_OUTPUT="nginx/app.conf"
NGINX_FRONTEND_CONFIG_JSON="nginx/frontend_config.json"
ENV_FILE=".env"
GATEWAY_ENV_FILE=".env.gateway"

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
  echo "✅ Docker installed. IMPORTANT: The current user ($TARGET_USER) was added to the 'docker' group. You may need to log out and log back in for this to take full effect."
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
    ports: ["127.0.0.1:3000:3000"]
  gateway:
    ports: ["127.0.0.1:8808:8808"]
  installer:
    ports: ["127.0.0.1:5001:5001"]
  nginx:
    image: alpine:latest
    entrypoint: ["/bin/sh", "-c", "echo 'Nginx is disabled in integration mode. Your host Nginx is responsible for routing.'; sleep 3600"]
EOF
    echo "   ✅ Override file generated."

    echo ""
    echo "⚠️  ACTION REQUIRED: Add the following configuration to your HOST's Nginx setup."
    echo "   You must also manually create the JSON file referenced in the '/api/config' block."
    echo "------------------------------------------------------------------"
    echo "# --- Start of Taskbot Nginx Configuration ---"
    echo "location = /api/config { root /path/to/your/www; try_files /frontend_config.json =404; add_header Content-Type application/json; }"
    echo "location / { proxy_pass http://127.0.0.1:3000; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"Upgrade\"; }"
    echo "location /core/ { proxy_pass http://127.0.0.1:8808; proxy_set_header Host \$host; }"
    echo "location /agentrtc/ { proxy_pass http://127.0.0.1:8808; proxy_set_header Host \$host; }"
    echo "location /agentws/ { proxy_pass http://127.0.0.1:8808; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"Upgrade\"; }"
    echo "location /installer/ { proxy_pass http://127.0.0.1:5001/; }"
    echo "# --- End of Taskbot Nginx Configuration ---"
    echo ""
    read -rp "Press [Enter] to acknowledge and continue with the installation."
    PROTOCOL="https"

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
upstream gateway_server { server gateway:8808; }
upstream installer_server { server installer:5001; }
server { listen 80; server_name ${PUBLIC_DOMAIN_OR_IP}; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2; server_name ${PUBLIC_DOMAIN_OR_IP};
    ssl_certificate /etc/nginx/certs/fullchain.pem; ssl_certificate_key /etc/nginx/certs/privkey.pem;
    location = /api/config { alias /etc/nginx/conf.d/frontend_config.json; add_header Content-Type application/json; }
    location / { proxy_pass http://frontend_server; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /core/ { proxy_pass http://gateway_server; proxy_set_header Host \$host; }
    location /agentrtc/ { proxy_pass http://gateway_server; proxy_set_header Host \$host; }
    location /agentws/ { proxy_pass http://gateway_server; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /installer/ { proxy_pass http://installer_server/; }
}
EOF
        cat > "$OVERRIDE_FILE" <<EOF
services:
  nginx:
    ports: ["80:80", "443:443"]
    volumes:
      - ./nginx/app.conf:/etc/nginx/conf.d/default.conf:ro
      - ./${NGINX_FRONTEND_CONFIG_JSON}:/etc/nginx/conf.d/frontend_config.json:ro
      - "${CERT_PATH}:/etc/nginx/certs/fullchain.pem:ro"
      - "${KEY_PATH}:/etc/nginx/certs/privkey.pem:ro"
EOF
    else
        PROTOCOL="http"
        read -rp "Enter the public IP address of this server: " PUBLIC_DOMAIN_OR_IP
        PUBLIC_URL="http://${PUBLIC_DOMAIN_OR_IP}"
        cat > "$NGINX_CONF_OUTPUT" <<EOF
# Nginx configuration for HTTP (Auto-generated)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:8808; }
upstream installer_server { server installer:5001; }
server {
    listen 80; server_name ${PUBLIC_DOMAIN_OR_IP};
    location = /api/config { alias /etc/nginx/conf.d/frontend_config.json; add_header Content-Type application/json; }
    location / { proxy_pass http://frontend_server; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /core/ { proxy_pass http://gateway_server; proxy_set_header Host \$host; }
    location /agentrtc/ { proxy_pass http://gateway_server; proxy_set_header Host \$host; }
    location /agentws/ { proxy_pass http://gateway_server; proxy_set_header Host \$host; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "Upgrade"; }
    location /installer/ { proxy_pass http://installer_server/; }
}
EOF
        cat > "$OVERRIDE_FILE" <<EOF
services:
  nginx:
    ports: ["80:80"]
    volumes:
      - ./nginx/app.conf:/etc/nginx/conf.d/default.conf:ro
      - ./${NGINX_FRONTEND_CONFIG_JSON}:/etc/nginx/conf.d/frontend_config.json:ro
EOF
    fi
    echo "   ✅ Nginx configuration and override file generated."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Configure Service Credentials & Initial Admin User
# ─────────────────────────────────────────────────────────────────────────────
echo "🔐 Generating secure, random passwords for services..."
JDBC_PASSWORD=$(openssl rand -hex 16)
MONGO_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
RABBITMQ_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 48)
echo "   ✅ Passwords generated."

echo "------------------------------------------------------------------"
echo "👤 Initial Admin User Configuration"
echo "   These details will be used to create the first admin user for the Taskbot API service."
echo "   Default values are shown in brackets []."
echo "------------------------------------------------------------------"
read -rp "Enter initial admin email [admin@example.com]: " SCRIPT_INITIAL_ADMIN_EMAIL
INITIAL_ADMIN_EMAIL_ENV=${SCRIPT_INITIAL_ADMIN_EMAIL:-admin@example.com}

read -srp "Enter initial admin password (use a strong password) [SecureAdminP@ss1]: " SCRIPT_INITIAL_ADMIN_PASSWORD
echo # Newline after password input
INITIAL_ADMIN_PASSWORD_ENV=${SCRIPT_INITIAL_ADMIN_PASSWORD:-SecureAdminP@ss1}

read -rp "Enter initial admin first name [Admin]: " SCRIPT_INITIAL_ADMIN_FIRST_NAME
INITIAL_ADMIN_FIRST_NAME_ENV=${SCRIPT_INITIAL_ADMIN_FIRST_NAME:-Admin}

read -rp "Enter initial admin last name [User]: " SCRIPT_INITIAL_ADMIN_LAST_NAME
INITIAL_ADMIN_LAST_NAME_ENV=${SCRIPT_INITIAL_ADMIN_LAST_NAME:-User}

read -rp "Enter initial admin organization name [Default Organization]: " SCRIPT_INITIAL_ADMIN_ORG_NAME
INITIAL_ADMIN_ORG_NAME_ENV=${SCRIPT_INITIAL_ADMIN_ORG_NAME:-Default Organization}

INITIAL_ADMIN_ENABLED_ENV="true"

echo "✍️  Generating environment files..."

cat > "$NGINX_FRONTEND_CONFIG_JSON" <<EOF
{
    "NEXT_PUBLIC_FLASK_API_URL": "${PUBLIC_URL}/installer",
    "NEXT_PUBLIC_API_ENDPOINT_CORE": "${PUBLIC_URL}/core",
    "NEXT_PUBLIC_API_ENDPOINT_DATA": "${PUBLIC_URL}/data",
    "NEXT_PUBLIC_FRONTEND_URL": "${PUBLIC_URL}",
    "NEXT_PUBLIC_DEPLOY_MODE": "ONPREMISE",
    "NEXT_PUBLIC_GOOGLE_CLIENT_ID": "disabled"
}
EOF
echo "   ✅ Frontend static config JSON generated."

cat > "$ENV_FILE" <<EOF
# Taskbot Production Environment Configuration (Auto-generated)
ACTIVE_PROFILE=prod
LOG_LEVEL=INFO
SERVER_PORT=18902
RUNNING_ON_CLUSTER=false
PUBLIC_DOMAIN=${PUBLIC_URL}
DATA_API_ENDPOINT=http://gateway:8808
CORE_API_ENDPOINT=http://taskbot-api-service:18902
FRONT_ENDPOINT=${PUBLIC_URL}
JDBC_URL=jdbc:mariadb://mariadb:3306/nucleus?zeroDateTimeBehavior=convertToNull&allowMultiQueries=true&useSSL=false&serverTimezone=UTC
JDBC_USR=taskbot_user
JDBC_PWD=${JDBC_PASSWORD}
SPRING_DATA_MONGODB_URI=mongodb://mymongo:${MONGO_PASSWORD}@mongodb:27017
MONGO_INITDB_ROOT_USERNAME=mymongo
MONGO_INITDB_ROOT_PASSWORD=${MONGO_PASSWORD}
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PWD=${REDIS_PASSWORD}
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
JWT_BASE64_SECRET=${JWT_SECRET}
JWT_SECRET=${JWT_SECRET}
GOOGLE_OAUTH_ENABLED=false
INITIAL_ADMIN_ENABLED=${INITIAL_ADMIN_ENABLED_ENV}
INITIAL_ADMIN_EMAIL=${INITIAL_ADMIN_EMAIL_ENV}
INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD_ENV}
INITIAL_ADMIN_FIRST_NAME=${INITIAL_ADMIN_FIRST_NAME_ENV}
INITIAL_ADMIN_LAST_NAME=${INITIAL_ADMIN_LAST_NAME_ENV}
INITIAL_ADMIN_ORG_NAME=${INITIAL_ADMIN_ORG_NAME_ENV}
aws.s3.enabled=false
storage.local.path=/storage/uploads
company.name=Nucleus AI
email.logo.url=${PUBLIC_URL}/images/logo.png
email.branding.image.url=${PUBLIC_URL}/images/headerbg.png
website.link=${PUBLIC_URL}
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5001
CORS_ORIGINS=${PUBLIC_URL}
EOF
echo "   ✅ Main .env file generated."

cat > ".env.frontend" <<EOF
# This file is generated to satisfy docker-compose.yml. Config is served by Nginx.
NODE_ENV=production
NEXT_PUBLIC_DEPLOY_MODE=ONPREMISE
NEXT_PUBLIC_FRONTEND_URL=${PUBLIC_URL}
NEXT_PUBLIC_API_ENDPOINT_CORE=${PUBLIC_URL}/core
NEXT_PUBLIC_API_ENDPOINT_DATA=${PUBLIC_URL}/data
NEXT_PUBLIC_FLASK_API_URL=${PUBLIC_URL}/installer
NEXT_PUBLIC_GOOGLE_CLIENT_ID=disabled
EOF
echo "   ✅ Frontend .env.frontend file generated."

cat > "$GATEWAY_ENV_FILE" <<EOF
# Gateway Service Environment Configuration (Auto-generated)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
CORE_API_URL=http://taskbot-api-service:18902
JWT_SECRET=${JWT_SECRET}
EOF
echo "   ✅ Gateway .env.gateway file generated."

# ─────────────────────────────────────────────────────────────────────────────
# 6. Manage Docker Stack & Final Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "🔄 Managing Docker stack..."
# The cleanup at the start of the script ensures no old containers are running.
# We can still run 'down' here as a safety net in case of a partial failure.
docker compose down --remove-orphans >/dev/null 2>&1 || true

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
echo "ℹ️  To stop the services: cd ${INSTALL_DIR} && docker compose down"
echo "ℹ️  To restart the services: cd ${INSTALL_DIR} && docker compose up -d"
echo ""
echo "🔐 Your auto-generated service passwords have been saved in the .env file inside ${INSTALL_DIR}."
echo ""
echo "Script finished."