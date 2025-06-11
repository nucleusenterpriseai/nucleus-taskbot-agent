#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer (Interactive) - v2.2                          #
#  • Installs Docker + Compose plugin if missing.                             #
#  • Allows user to choose between a secure (HTTPS) or insecure (HTTP) setup. #
#  • Generates Nginx and .env configurations based on the user's choice.      #
#  • Provides clear instructions for any required manual steps.               #
#  • Manages the Docker stack (stops existing, pulls latest, starts new).     #
#  Run as root (or with sudo) on Ubuntu/Debian-like hosts.                    #
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
GH_REPO_OWNER="nucleusenterpriseai"
GH_REPO_NAME="nucleus-taskbot-agent"
GH_BRANCH="main"

RAW_CONTENT_BASE_URL="https://raw.githubusercontent.com/${GH_REPO_OWNER}/${GH_REPO_NAME}/${GH_BRANCH}"

COMPOSE_FILE="docker-compose.yml"
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
# (This section is copied from your original script and is assumed to be correct)
if ! command -v docker &>/dev/null; then
  echo "🐳 Docker not found → installing..."
  curl -fsSL https://get.docker.com | sh || { echo "❌ Docker installation failed." >&2; exit 1; }
  TARGET_USER=${SUDO_USER:-$USER}
  echo "🔑 Adding user '${TARGET_USER}' to docker group..."
  sudo usermod -aG docker "$TARGET_USER"
  echo "✅ Docker installed. You may need to log out and back in for group changes to apply."
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
# 3. Download Core Files
# ─────────────────────────────────────────────────────────────────────────────
echo "⬇️  Downloading stack definition file: ${COMPOSE_FILE}..."
curl -fsSL "${RAW_CONTENT_BASE_URL}/${COMPOSE_FILE}?$(date +%s)" -o "${COMPOSE_FILE}" || {
    echo "   ❌ Failed to download ${COMPOSE_FILE}." >&2; exit 1;
}
echo "   ✅ Downloaded ${COMPOSE_FILE}"
mkdir -p ./keys ./certs ./nginx
echo "ℹ️  Created ./keys, ./certs, and ./nginx directories."

# ─────────────────────────────────────────────────────────────────────────────
# 4. Interactive Configuration
# ─────────────────────────────────────────────────────────────────────────────
echo "------------------------------------------------------------------"
echo "⚙️  Server Configuration Setup"
echo "------------------------------------------------------------------"
echo "You have two options for setting up this server:"
echo ""
echo "  1) SECURE (HTTPS): Requires a domain name and your own SSL certificate files."
echo "     (This is the recommended option for production environments)"
echo ""
echo "  2) INSECURE (HTTP): Uses only the server's IP address. No encryption."
echo "     (Use this for quick tests or if you do not have a domain name)"
echo ""

read -rp "Do you want to configure a SECURE (HTTPS) server? (y/n): " SETUP_CHOICE

# Declare variables that will be set based on the user's choice
PROTOCOL=""
PUBLIC_DOMAIN_OR_IP=""
PUBLIC_URL=""

if [[ "$SETUP_CHOICE" =~ ^[Yy]$ ]]; then
    # --- SECURE (HTTPS) PATH ---
    echo ""
    echo "🔒 Configuring for SECURE (HTTPS) access..."
    PROTOCOL="https"
    read -rp "Enter your fully qualified domain name (e.g., taskbot.yourcompany.com): " PUBLIC_DOMAIN_OR_IP
    if [[ -z "$PUBLIC_DOMAIN_OR_IP" ]]; then
        echo "❌ Domain name cannot be empty. Exiting." >&2; exit 1
    fi
    PUBLIC_URL="${PROTOCOL}://${PUBLIC_DOMAIN_OR_IP}"

    echo ""
    echo "ℹ️  Please provide the absolute paths to your SSL certificate files on this host machine."
    read -rp "Path to your certificate file (e.g., /etc/letsencrypt/live/your.domain/fullchain.pem): " CERT_PATH
    read -rp "Path to your private key file (e.g., /etc/letsencrypt/live/your.domain/privkey.pem): " KEY_PATH

    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
        echo "❌ One or both certificate files not found at the specified paths. Exiting." >&2; exit 1
    fi

    echo "✍️  Generating Nginx configuration for HTTPS..."
    GATEWAY_INTERNAL_PORT=8080
    cat > "$NGINX_CONF_OUTPUT" <<EOF
# Nginx configuration for HTTPS (Auto-generated)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:${GATEWAY_INTERNAL_PORT}; }

server {
    listen 80;
    server_name ${PUBLIC_DOMAIN_OR_IP};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${PUBLIC_DOMAIN_OR_IP};

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100M;
    location / {
        proxy_pass http://frontend_server;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
    location /core/ { proxy_pass http://gateway_server; }
    location /agentrtc/ { proxy_pass http://gateway_server; }
    location /agentws/ {
        proxy_pass http://gateway_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
}
EOF
    echo "   ✅ Nginx configuration generated at ${NGINX_CONF_OUTPUT}"

    echo ""
    echo "⚠️  ACTION REQUIRED: You must now update your docker-compose.yml file!"
    echo "   Find the 'nginx' service and add the following 'ports' and 'volumes' sections."
    echo "   This allows Nginx to handle HTTPS traffic and access your certificates."
    echo ""
    echo "   services:"
    echo "     nginx:"
    echo "       # ..."
    echo "       ports:"
    echo "         - \"80:80\""
    echo "         - \"443:443\""
    echo "       volumes:"
    echo "         - ./nginx/app.conf:/etc/nginx/conf.d/default.conf:ro"
    echo "         - ${CERT_PATH}:/etc/nginx/certs/fullchain.pem:ro"
    echo "         - ${KEY_PATH}:/etc/nginx/certs/privkey.pem:ro"
    echo ""
    read -rp "Have you finished editing docker-compose.yml? Press [Enter] to continue."

else
    # --- INSECURE (HTTP) PATH ---
    echo ""
    echo "🌐 Configuring for INSECURE (HTTP) access..."
    PROTOCOL="http"
    read -rp "Enter the public IP address of this server: " PUBLIC_DOMAIN_OR_IP
    if [[ -z "$PUBLIC_DOMAIN_OR_IP" ]]; then
        echo "❌ IP address cannot be empty. Exiting." >&2; exit 1
    fi
    PUBLIC_URL="${PROTOCOL}://${PUBLIC_DOMAIN_OR_IP}"

    echo "✍️  Generating Nginx configuration for HTTP..."
    GATEWAY_INTERNAL_PORT=8080
    # This is the original Nginx configuration from your script
    cat > "$NGINX_CONF_OUTPUT" <<EOF
# Nginx configuration for HTTP (Auto-generated)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:${GATEWAY_INTERNAL_PORT}; }

server {
    listen 80;
    server_name ${PUBLIC_DOMAIN_OR_IP};
    client_max_body_size 100M;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto http;
    proxy_set_header Host \$host;
    location / {
        proxy_pass http://frontend_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
    location /core/ { proxy_pass http://gateway_server; }
    location /agentrtc/ { proxy_pass http://gateway_server; }
    location /agentws/ {
        proxy_pass http://gateway_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
}
EOF
    echo "   ✅ Nginx configuration generated at ${NGINX_CONF_OUTPUT}"

    echo ""
    echo "⚠️  ACTION REQUIRED: Please ensure your docker-compose.yml is configured for Nginx."
    echo "   Find the 'nginx' service and ensure it has the following 'ports' and 'volumes'."
    echo ""
    echo "   services:"
    echo "     nginx:"
    echo "       # ..."
    echo "       ports:"
    echo "         - \"80:80\""
    echo "       volumes:"
    echo "         - ./nginx/app.conf:/etc/nginx/conf.d/default.conf:ro"
    echo ""
    read -rp "Press [Enter] to acknowledge and continue."

fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Generate Environment Files (.env & .env.gateway)
# ─────────────────────────────────────────────────────────────────────────────
echo "✍️  Generating environment files..."
GENERATED_JWT_SECRET=$(openssl rand -base64 48)

# --- Generate main .env file ---
cat > "$ENV_FILE" <<EOF
# Taskbot Production Environment Configuration (Auto-generated)
# Access URL: ${PUBLIC_URL}

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
JDBC_PWD=NETB2023=BaT

# === Database (MongoDB) =======================================================
SPRING_DATA_MONGODB_URI=mongodb://mymongo:NETaskbotMongoPW@mongodb:27017
MONGO_INITDB_ROOT_USERNAME=mymongo
MONGO_INITDB_ROOT_PASSWORD=NETaskbotMongoPW

# === Redis ====================================================================
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PWD=Coding^2o2!

# === RabbitMQ =================================================================
RABBITMQ_HOST=rabbitmq
RABBITMQ_PORT=5672
RABBITMQ_USERNAME=rbuser
RABBITMQ_PASSWORD=NETaskbotRBPWD
TASK_RUN_REQ_EXCH=kk_task_run_req_exch_prod
TASK_RUN_REQ_QUEUE=kk_task_run_request_prod
TASK_RUN_REQ_ROUTE_KEY=run_task_prod
AGENT_RUN_EVENTS_TOPIC_EXCHANGE=agent_run_events_topic_exchange
MONGO_LOGGER_QUEUE=mongo_event_logger_queue
AGENT_COMMANDS_EXCHANGE=agent_commands_direct_exchange

# === Security & Authentication ================================================
LICENSE_PUBLIC_KEY_B64=${HARDCODED_LICENSE_PUBLIC_KEY_B64}
JWT_BASE64_SECRET=${GENERATED_JWT_SECRET}
JWT_SECRET=${GENERATED_JWT_SECRET}
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
EOF

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
# 6. Manage Docker Stack
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

# ─────────────────────────────────────────────────────────────────────────────
# 7. Final Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "🎉 Taskbot installation/update is complete!"
echo "   Your stack is configured for: ${PROTOCOL^^} access."
echo ""
echo "🔗 Access your portal at: ${PUBLIC_URL}"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "ℹ️  To stop: cd ${INSTALL_DIR} && docker compose down"
echo ""
echo "Script finished."