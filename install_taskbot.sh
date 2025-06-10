#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer (HTTP Only) - v2.0                            #
#  • Installs Docker + Compose plugin if missing                              #
#  • Pulls the latest docker-compose.yml from GitHub.                         #
#  • Generates a complete, production-ready .env file with all required vars. #
#  • Generates Nginx configuration based on user input.                       #
#  • Manages the Docker stack (stops existing, pulls latest, starts new).     #
#  Run as root (or with sudo) on Ubuntu/Debian-like hosts.                    #
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
GH_REPO_OWNER="nucleusenterpriseai"
GH_REPO_NAME="nucleus-taskbot-agent"
GH_BRANCH="main" # Or your specific release branch

RAW_CONTENT_BASE_URL="https://raw.githubusercontent.com/${GH_REPO_OWNER}/${GH_REPO_NAME}/${GH_BRANCH}"

COMPOSE_FILE="docker-compose.yml"
NGINX_CONF_OUTPUT="nginx/app.conf"
ENV_FILE=".env"

INSTALL_DIR="$(pwd)/taskbot_deployment"

# The public key is required for startup to validate future tokens.
HARDCODED_LICENSE_PUBLIC_KEY_B64="LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUNvd0JRWURLMlZ3QXlFQXp4cWkrc1dDZkJDdVQ1RTVyZUtMOHQ0WHk2STlKUWdrOTdoZmFsSjVPNEk9Ci0tLS0tRU5EIFBVQkxJQyBLRVktLS0tLQo="

echo "📦 Taskbot installer starting …"
echo "   Installation directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# ── 1. Install Docker CE if missing ──────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "🐳 Docker not found → installing via convenience script…"
  if curl -fsSL https://get.docker.com | sh; then
    echo "✅ Docker installed successfully."
  else
    echo "❌ Docker installation failed. Please install Docker manually and re-run." >&2
    exit 1
  fi

  TARGET_USER=${SUDO_USER:-$USER}
  echo "🔑 Adding user '${TARGET_USER}' to docker group"
  if id -nG "$TARGET_USER" | grep -qw docker; then
      echo "ℹ︎  User '${TARGET_USER}' already in docker group."
  else
      if sudo usermod -aG docker "$TARGET_USER"; then
        echo "✅ User '${TARGET_USER}' added to docker group."
        echo "⚠️ You MUST log out and log back in for this change to take effect."
      else
        echo "❌ Failed to add '${TARGET_USER}' to docker group."
      fi
  fi
else
  echo "✅ Docker is already installed."
fi

# ── 2. Ensure Docker Compose v2 plugin is available ──────────────────────────
if ! docker compose version &>/dev/null; then
  echo "🔧 Docker Compose plugin not found. Attempting to install…"
  LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$LATEST_COMPOSE_VERSION" ]]; then
    echo "⚠️ Could not fetch latest Docker Compose version. Using v2.27.0 as fallback."
    LATEST_COMPOSE_VERSION="v2.27.0"
  fi
  echo "   Installing Docker Compose version: ${LATEST_COMPOSE_VERSION}"
  DOCKER_CLI_PLUGINS_DIR="/usr/local/lib/docker/cli-plugins"
  sudo mkdir -p "$DOCKER_CLI_PLUGINS_DIR"
  if sudo curl -SL "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" \
       -o "$DOCKER_CLI_PLUGINS_DIR/docker-compose"; then
    sudo chmod +x "$DOCKER_CLI_PLUGINS_DIR/docker-compose"
    echo "✅ Docker Compose plugin installed to $DOCKER_CLI_PLUGINS_DIR."
  else
    echo "❌ Failed to download Docker Compose plugin. Please install it manually." >&2
    exit 1
  fi
else
  echo "✅ Docker Compose plugin is already installed."
fi

# ── 3. Download stack definition files ───────────────────────────────────────
echo "⬇️  Downloading stack definition file: ${COMPOSE_FILE}..."
# Appending a timestamp to the URL to bypass caches and get the latest version
curl -fsSL "${RAW_CONTENT_BASE_URL}/${COMPOSE_FILE}?$(date +%s)" -o "${COMPOSE_FILE}" || {
    echo "   ❌ Failed to download ${COMPOSE_FILE}. Please check URL and network." >&2; exit 1;
}
echo "   ✅ Downloaded ${COMPOSE_FILE}"

mkdir -p ./keys ./certs
echo "ℹ️  Created ./keys and ./certs directories."


# ── 4. Generate Production Environment Configuration (.env file) (REVISED) ───
# Generate a new random JWT secret for this deployment
GENERATED_JWT_SECRET=$(openssl rand -base64 48)

# Prompt for the public domain, which is essential for URL construction
echo "⚙️  Configuring environment variables..."
read -rp "Enter the public domain or IP for this server (e.g., taskbot.yourcompany.com): " PUBLIC_DOMAIN_INPUT
if [[ -z "$PUBLIC_DOMAIN_INPUT" ]]; then
  echo "❌ Public domain cannot be empty. Exiting." >&2
  exit 1
fi
echo ""
echo "✓ Configuration accepted. Proceeding with installation..."

# --- Heredoc block to generate the complete, production-ready .env file ---
echo "✍️  Generating ${ENV_FILE} for production..."
cat > "$ENV_FILE" <<EOF
# ==============================================================================
#  Taskbot Production Environment Configuration (Auto-generated by install.sh)
# ==============================================================================

# === Core Application Settings ================================================
ACTIVE_PROFILE=prod
LOG_LEVEL=INFO
SERVER_PORT=18902
RUNNING_ON_CLUSTER=false

# === Endpoints & Public Domain ================================================
PUBLIC_DOMAIN=http://${PUBLIC_DOMAIN_INPUT}
DATA_API_ENDPOINT=http://taskbot-api-service:8080
CORE_API_ENDPOINT=http://taskbot-api-service:18902
FRONT_ENDPOINT=http://${PUBLIC_DOMAIN_INPUT}:3000

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
# The public key is required for startup.
LICENSE_PUBLIC_KEY_B64=${HARDCODED_LICENSE_PUBLIC_KEY_B64}
JWT_BASE64_SECRET=${GENERATED_JWT_SECRET}
JWT_SECRET=${GENERATED_JWT_SECRET}
# --- Google OAuth (EXPLICITLY DISABLED FOR ON-PREMISE DEPLOYMENT) ---
GOOGLE_OAUTH_ENABLED=false

# === Cloud & Email Services ===================================================
aws.s3.enabled=false

# === Local Storage (For Docker) ===============================================
storage.local.path=/storage/uploads

# === Branding =================================================================
company.name=Nucleus AI
email.logo.url=http://${PUBLIC_DOMAIN_INPUT}/images/logo.png
email.branding.image.url=http://${PUBLIC_DOMAIN_INPUT}/images/headerbg.png
website.link=http://${PUBLIC_DOMAIN_INPUT}

# === Other service variables needed by docker-compose.yml =====================
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5000
DATA_PATH_BASE=./taskbot-data
TASKBOT_API_INTERNAL_PORT=18902
EOF

echo "   ✅ ${ENV_FILE} generated successfully."


# ── 4b. Generate Gateway-Specific Environment File (.env.gateway) ──────────────
echo "✍️  Generating .env.gateway for the Gateway service..."
cat > ".env.gateway" <<EOF
# ==============================================================================
#  Gateway Service Environment Configuration (Auto-generated by install.sh)
# ==============================================================================

# === Redis (for rate limiting, session management, etc.) ======================
# The gateway connects to the 'redis' service name inside the Docker network.
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=\${REDIS_PWD}

# === Upstream Service URL (for the Docker API service) ========================
CORE_API_URL=http://taskbot-api-service:18902

# === Security & Authentication ================================================
JWT_SECRET=\${JWT_SECRET}

EOF
echo "   ✅ .env.gateway generated successfully."

# ── 5. Generate Nginx Configuration File ─────────────────────────────────────
echo "⚙️  Generating Nginx configuration file (HTTP only)..."
mkdir -p "$(dirname "$NGINX_CONF_OUTPUT")"

# The GATEWAY_INTERNAL_PORT is needed for the Nginx upstream block
GATEWAY_INTERNAL_PORT=8080 # Define it here for clarity

cat > "$NGINX_CONF_OUTPUT" <<EOF
# Dynamically generated Nginx configuration by install_taskbot.sh (HTTP Only)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:${GATEWAY_INTERNAL_PORT}; }

server {
    listen 80;
    server_name ${PUBLIC_DOMAIN_INPUT};
    client_max_body_size 100M;
    access_log /var/log/nginx/taskbot.access.log;
    error_log /var/log/nginx/taskbot.error.log;

    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto http;
    proxy_set_header Host \$host;

    location /uploads/ {
        alias /var/www/uploads/;
        expires 7d;
        add_header Cache-Control "public";
    }
    location / {
        proxy_pass http://frontend_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    location /core/ {
        proxy_pass http://gateway_server;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    location /agentrtc/ {
        proxy_pass http://gateway_server;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    location /agentws/ {
        proxy_pass http://gateway_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
}
EOF
echo "   ✅ Nginx configuration dynamically generated at ${NGINX_CONF_OUTPUT}"

# ── 6. Manage Docker Stack (Stop, Pull, Start) ───────────────────────────────
echo "🔄 Managing Docker stack..."

if [ -n "$(docker compose ps -q 2>/dev/null)" ]; then
  echo "ℹ️  Existing containers found. Stopping and removing them..."
  docker compose down --remove-orphans || echo "⚠️  Failed to stop/remove existing containers. Proceeding anyway."
fi

echo "🚀 Pulling latest specified Docker images … (this may take a while)"
docker compose pull || echo "⚠️  Failed to pull some images. Proceeding with local versions if available."

echo "🟢 Starting containers …"
if docker compose up -d --remove-orphans; then
  echo "✅ Docker containers started successfully."
else
  echo "❌ Failed to start Docker containers. Check 'docker compose logs' for errors." >&2
  exit 1
fi

echo ""
echo "🎉 Taskbot installation/update is complete! (HTTP ONLY)"
echo "   The application stack should now be running."
echo ""
echo "🔗 Access Points (HTTP):"
echo "   ↪  Portal   : http://${PUBLIC_DOMAIN_INPUT}/"
echo "   ↪  Gateway  : http://${PUBLIC_DOMAIN_INPUT}/core/"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "ℹ️  To stop: cd ${INSTALL_DIR} && docker compose down"
echo "ℹ️  Data is stored in: ${INSTALL_DIR}/taskbot-data"
echo "ℹ️  Uploaded files are stored in a Docker volume named 'uploads-data'."
echo ""
echo "Script finished."