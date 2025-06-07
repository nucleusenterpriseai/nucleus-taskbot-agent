#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer (HTTP Only)                                   #
#  • Installs Docker + Compose plugin if missing                              #
#  • Pulls docker-compose.yml from GitHub.                                    #
#  • Generates .env and Nginx configuration (HTTP only).                      #
#  • Manages the Docker stack (stops existing, pulls latest, starts new).     #
#  Run as root (or with sudo) on Ubuntu/Debian-like hosts.                    #
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
GH_REPO_OWNER="nucleusenterpriseai"
GH_REPO_NAME="nucleus-taskbot-agent"
GH_BRANCH="main"

RAW_CONTENT_BASE_URL="https://raw.githubusercontent.com/${GH_REPO_OWNER}/${GH_REPO_NAME}/${GH_BRANCH}"

COMPOSE_FILE="docker-compose.yml"
NGINX_CONF_OUTPUT="nginx/app.conf"

INSTALL_DIR="$(pwd)/taskbot_deployment"

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
curl -fsSL "${RAW_CONTENT_BASE_URL}/${COMPOSE_FILE}?$(date +%s)" -o "${COMPOSE_FILE}" || {
    echo "   ❌ Failed to download ${COMPOSE_FILE}. Please check URL and network." >&2; exit 1;
}
echo "   ✅ Downloaded ${COMPOSE_FILE}"

mkdir -p ./keys ./certs
echo "ℹ️  Created ./keys directory for agent SSH keys."


# ── 4. Configure Environment Variables & Setup .env file ───────────────────
ENV_FILE=".env"
DEFAULT_MARIADB_ROOT_PASSWORD="supersecretrootpassword"
DEFAULT_MARIADB_PASSWORD="secretpassword"
DEFAULT_MONGODB_ROOT_PASSWORD="secretmongopassword"
DEFAULT_REDIS_PASSWORD="secretredispassword"
DEFAULT_RABBITMQ_PASSWORD="rabbitpassword"
GENERATED_JWT_SECRET=$(openssl rand -base64 48)

ENV_FILE_CONTENT=$(cat <<EOF
# ------------------------------------------------------------------------------
#  Taskbot Environment Configuration (Auto-generated)
# ------------------------------------------------------------------------------
PUBLIC_DOMAIN=\${PUBLIC_DOMAIN_INPUT}
LICENSE_PUBLIC_KEY_B64=${HARDCODED_LICENSE_PUBLIC_KEY_B64}
JWT_SECRET=${GENERATED_JWT_SECRET}
MARIADB_ROOT_PASSWORD=${DEFAULT_MARIADB_ROOT_PASSWORD}
MARIADB_DATABASE_NAME=nucleus
MARIADB_USER=nucleus_user
MARIADB_PASSWORD=${DEFAULT_MARIADB_PASSWORD}
MONGODB_ROOT_USERNAME=mongoadmin
MONGODB_ROOT_PASSWORD=${DEFAULT_MONGODB_ROOT_PASSWORD}
REDIS_PASSWORD=${DEFAULT_REDIS_PASSWORD}
RABBITMQ_DEFAULT_USER=rabbituser
RABBITMQ_DEFAULT_PASS=${DEFAULT_RABBITMQ_PASSWORD}
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5000
INSTALLER_SSH_PRIVATE_KEY_PATH=/etc/taskbot/keys/agent_ssh_key
INSTALLER_SSH_USER=
DATA_PATH_BASE=./taskbot-data
GATEWAY_INTERNAL_PORT=8080
TASKBOT_API_INTERNAL_PORT=18902
EOF
)

echo "⚙️  Configuring environment variables..."
read -rp "Enter the public domain/hostname for Taskbot (e.g., taskbot.example.com or server IP) [localhost]: " PUBLIC_DOMAIN_INPUT
PUBLIC_DOMAIN_INPUT=${PUBLIC_DOMAIN_INPUT:-localhost}
echo ""
echo "✓ Configuration accepted. Proceeding with installation..."

echo "✍️  Generating ${ENV_FILE}..."
TEMP_ENV_CONTENT=$(echo "$ENV_FILE_CONTENT" | sed "s|\\\${PUBLIC_DOMAIN_INPUT}|${PUBLIC_DOMAIN_INPUT}|g")
echo "$TEMP_ENV_CONTENT" > "$ENV_FILE" || { echo "   ❌ Failed to generate ${ENV_FILE}."; exit 1; }
echo "   ✅ ${ENV_FILE} generated successfully."

set -a
source "./${ENV_FILE}"
set +a


# ── 5. Generate Nginx Configuration File ─────────────────────────────────────
echo "⚙️  Generating Nginx configuration file (HTTP only)..."
mkdir -p "$(dirname "$NGINX_CONF_OUTPUT")"

if cat > "$NGINX_CONF_OUTPUT" <<EOF
# Dynamically generated Nginx configuration by install_taskbot.sh (HTTP Only)
upstream frontend_server { server frontend:3000; }
upstream gateway_server { server gateway:${GATEWAY_INTERNAL_PORT}; }

server {
    listen 80;
    server_name ${PUBLIC_DOMAIN} host.docker.internal;
    client_max_body_size 100M;
    access_log /var/log/nginx/taskbot.access.log;
    error_log /var/log/nginx/taskbot.error.log;

    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto http;
    proxy_set_header Host \$host;

    # *** THIS IS THE CRITICAL NEW SECTION ***
    # Route for the Local File Storage uploads.
    # This serves static files from the shared 'uploads-data' volume.
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
then
  echo "   ✅ Nginx configuration dynamically generated at ${NGINX_CONF_OUTPUT}"
else
  echo "   ❌ Failed to generate Nginx configuration." >&2
  exit 1
fi

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
echo "   ↪  Portal   : http://${PUBLIC_DOMAIN}/"
echo "   ↪  Gateway  : http://${PUBLIC_DOMAIN}/core/"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "ℹ️  To stop: cd ${INSTALL_DIR} && docker compose down"
echo "ℹ️  Data is stored in: ${INSTALL_DIR}/${DATA_PATH_BASE:-./taskbot-data}"
echo "ℹ️  Uploaded files are stored in a Docker volume named 'uploads-data'."
echo ""
echo "Script finished."