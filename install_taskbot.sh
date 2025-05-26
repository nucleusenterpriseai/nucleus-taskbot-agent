#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer                                               #
#  • Installs Docker + Compose plugin if missing                              #
#  • Pulls docker-compose.yml, .env.example, nginx config, SQL init           #
#    from GitHub.                                                             #
#  • Generates self-signed TLS certificate.                                   #
#  • Starts the stack.                                                        #
#  Run as root (or with sudo) on Ubuntu/Debian-like hosts.                    #
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# Configuration - Assumes this script and other files are in the same GitHub repo and branch
GH_REPO_OWNER="nucleusenterpriseai"
GH_REPO_NAME="nucleus-taskbot-agent" # This repo where all files reside
GH_BRANCH="main" # Or your default branch

RAW_CONTENT_BASE_URL="https://raw.githubusercontent.com/${GH_REPO_OWNER}/${GH_REPO_NAME}/${GH_BRANCH}"

COMPOSE_FILE="docker-compose.yml"
NGINX_CONF_OUTPUT="nginx/app.conf" 

INSTALL_DIR="$(pwd)/taskbot_deployment" # Install everything into a subdirectory

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
    echo "❌ Docker installation failed. Please install Docker manually and re-run."
    exit 1
  fi

  TARGET_USER=${SUDO_USER:-$USER}
  echo "🔑 Adding user '${TARGET_USER}' to docker group"
  if id -nG "$TARGET_USER" | grep -qw docker; then
      echo "ℹ︎  User '${TARGET_USER}' already in docker group."
  else
      if sudo usermod -aG docker "$TARGET_USER"; then
        echo "✅ User '${TARGET_USER}' added to docker group."
        echo "⚠️ You MUST log out and log back in for this change to take effect before running docker commands without sudo."
        echo "   Alternatively, you can run 'newgrp docker' in your current shell to apply group changes temporarily."
      else
        echo "❌ Failed to add '${TARGET_USER}' to docker group. You may need to run docker commands with sudo."
      fi
  fi
else
  echo "✅ Docker is already installed."
fi

# ── 2. Ensure Docker Compose v2 plugin is available ──────────────────────────
if ! docker compose version &>/dev/null; then
  echo "🔧 Docker Compose plugin not found. Attempting to install…"
  # System-wide installation attempt
  LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$LATEST_COMPOSE_VERSION" ]]; then
    echo "⚠️ Could not fetch latest Docker Compose version. Using v2.27.0 as fallback."
    LATEST_COMPOSE_VERSION="v2.27.0"
  fi
  echo "   Installing Docker Compose version: ${LATEST_COMPOSE_VERSION}"
  
  DOCKER_CLI_PLUGINS_DIR="/usr/local/lib/docker/cli-plugins" # Common system-wide path
  sudo mkdir -p "$DOCKER_CLI_PLUGINS_DIR"
  if sudo curl -SL "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" \
       -o "$DOCKER_CLI_PLUGINS_DIR/docker-compose"; then
    sudo chmod +x "$DOCKER_CLI_PLUGINS_DIR/docker-compose"
    echo "✅ Docker Compose plugin installed to $DOCKER_CLI_PLUGINS_DIR."
    if ! docker compose version &>/dev/null; then
        echo "❌ Docker Compose still not found after installation. Check PATH or try manual install."
        exit 1
    fi
  else
    echo "❌ Failed to download Docker Compose plugin. Please install it manually."
    echo "   See: https://docs.docker.com/compose/install/"
    exit 1
  fi
else
  echo "✅ Docker Compose plugin is already installed."
fi

# ── 3. Download stack definition files ───────────────────────────────────────
echo "⬇️  Downloading stack definition files from ${RAW_CONTENT_BASE_URL}…"
download_file() {
  local remote_path="$1"
  local local_path="$2"
  local dir
  dir=$(dirname "$local_path")
  mkdir -p "$dir"
  echo "   Downloading ${remote_path} to ${local_path}..."
  if curl -fsSL "${RAW_CONTENT_BASE_URL}/${remote_path}" -o "${local_path}"; then
    echo "   ✅ Downloaded ${local_path}"
  else
    echo "   ❌ Failed to download ${remote_path}. Please check URL and network."
    exit 1
  fi
}

download_file "${COMPOSE_FILE}" "${COMPOSE_FILE}"
# Create keys directory for user to place SSH keys
mkdir -p ./keys
echo "ℹ️  Created ./keys directory. If your installer service needs SSH keys to deploy agents,"
echo "   please place the private key (e.g., 'agent_ssh_key') in this './keys' directory."
echo "   Ensure the INSTALLER_SSH_PRIVATE_KEY_PATH in your .env file matches the filename."

# ── 4. Setup .env file ───────────────────────────────────────────────────────
ENV_EXAMPLE_FILE=".env.example" # Define the name for the generated example file
ENV_FILE=".env"

echo "⚙️  Generating ${ENV_EXAMPLE_FILE}..."
# Use a 'here document' to write the .env.example content
# Add comments to explain each variable.
if cat > "$ENV_EXAMPLE_FILE" <<EOF
# ------------------------------------------------------------------------------
#  Taskbot Environment Configuration Example
#  This file is auto-generated by the installer.
#  Copy this to .env and fill in your actual values.
# ------------------------------------------------------------------------------

# Domain for external access. If you have a real domain, set it here.
# Otherwise, 'localhost' will be used, and a self-signed certificate for 'localhost' generated.
# This is used by Nginx and for constructing public URLs.
PUBLIC_DOMAIN=localhost

# ------------------------------------------------------------------------------
#  Java API Service & Gateway Credentials/Config
# ------------------------------------------------------------------------------
TASKBOT_LICENSE_TOKEN=YOUR_LICENSE_TOKEN_HERE

# ------------------------------------------------------------------------------
#  Database Credentials
# ------------------------------------------------------------------------------
# MariaDB
MARIADB_ROOT_PASSWORD=supersecretrootpassword
MARIADB_DATABASE_NAME=nucleus
MARIADB_USER=nucleus_user
MARIADB_PASSWORD=secretpassword

# MongoDB
MONGODB_ROOT_USERNAME=mongoadmin
MONGODB_ROOT_PASSWORD=secretmongopassword

# Redis
REDIS_PASSWORD=secretredispassword

# RabbitMQ
RABBITMQ_DEFAULT_USER=rabbituser
RABBITMQ_DEFAULT_PASS=rabbitpassword

# ------------------------------------------------------------------------------
#  Taskbot Installer Service Configuration
# ------------------------------------------------------------------------------
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5000

# Path to the SSH private key within the installer container, used to deploy agents
# The key file itself should be placed in ./keys/agent_ssh_key on the host
INSTALLER_SSH_PRIVATE_KEY_PATH=/etc/taskbot/keys/agent_ssh_key
INSTALLER_SSH_USER=your_remote_agent_user # User for SSHing into agent VMs

# ------------------------------------------------------------------------------
#  Data Persistence Paths
# ------------------------------------------------------------------------------
# Base directory for all persistent data, relative to docker-compose.yml
DATA_PATH_BASE=./taskbot-data

# ------------------------------------------------------------------------------
#  Service Internal Ports (if different from common defaults)
# ------------------------------------------------------------------------------
# Port the Gateway service listens on internally
GATEWAY_INTERNAL_PORT=8080
# Port the Taskbot API Service listens on internally
TASKBOT_API_INTERNAL_PORT=18902

# ------------------------------------------------------------------------------
#  Logging Levels (examples - uncomment and set as needed)
# ------------------------------------------------------------------------------
# LOG_LEVEL_API=INFO
# LOG_LEVEL_GATEWAY=INFO
EOF
then
  echo "   ✅ ${ENV_EXAMPLE_FILE} generated successfully."
else
  echo "   ❌ Failed to generate ${ENV_EXAMPLE_FILE}."
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
  echo "⚠️  A new '${ENV_FILE}' file has been created from the generated '${ENV_EXAMPLE_FILE}'."
  echo "   Please EDIT '${ENV_FILE}' NOW with your specific configurations (passwords, tokens, etc.)."
  read -rp "Press Enter when you have edited .env and are ready to continue …"
else
  echo "ℹ️  Existing '${ENV_FILE}' file found. Please ensure it is up-to-date by comparing with '${ENV_EXAMPLE_FILE}'."
  read -rp "Press Enter to continue with the existing .env file, or Ctrl+C to edit it now …"
fi

# Source .env to get PUBLIC_DOMAIN for cert generation and Nginx config
set -a # automatically export all variables
# shellcheck disable=SC1091
source .env
set +a

# ── 5. Generate Self-Signed TLS Certificate ──────────────────────────────────
CERT_DIR="./certs"
mkdir -p "$CERT_DIR"
# Use PUBLIC_DOMAIN from .env, default to localhost if not set or empty
DOMAIN_FOR_CERT="${PUBLIC_DOMAIN:-localhost}"

echo "🔒 Generating self-signed TLS certificate for '${DOMAIN_FOR_CERT}'…"
if [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
  echo "   Found existing certificates in $CERT_DIR. Re-using them."
  echo "   If you need to regenerate, please remove them manually and re-run."
else
  if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$CERT_DIR/privkey.pem" \
      -out "$CERT_DIR/fullchain.pem" \
      -subj "/CN=${DOMAIN_FOR_CERT}"; then
    echo "   ✅ Self-signed certificate generated successfully."
  else
    echo "   ❌ Failed to generate self-signed certificate."
    exit 1
  fi
fi

# ── 6. Generate Nginx Configuration File ─────────────────────────────────────
echo "⚙️  Generating Nginx configuration file..."
NGINX_CONF_DIR=$(dirname "$NGINX_CONF_OUTPUT")
mkdir -p "$NGINX_CONF_DIR"

# Ensure variables from .env have defaults if not set, to avoid errors in the conf
EFFECTIVE_PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-localhost}"
EFFECTIVE_GATEWAY_PORT="${GATEWAY_INTERNAL_PORT:-8080}"
# EFFECTIVE_FLASK_PORT is no longer strictly needed for Nginx if /testapi/ is removed,
# but the installer service might still be running. We'll keep it for completeness
# in case you add other Nginx mappings to it later or for clarity.
# If installer has NO Nginx-exposed endpoints, you could remove its upstream too.
EFFECTIVE_FLASK_PORT="${FLASK_RUN_PORT:-5000}"

# Use a 'here document' to write the Nginx configuration.
if cat > "$NGINX_CONF_OUTPUT" <<EOF
# Dynamically generated Nginx configuration by install_taskbot.sh

# Upstream definitions for Docker services
upstream frontend_server {
    server frontend:3000;
}

upstream gateway_server {
    server gateway:${EFFECTIVE_GATEWAY_PORT};
}

# Upstream for installer_api_server is kept in case it's used by other means
# or if you decide to expose an endpoint for it later.
# If it's truly not needed by Nginx at all, this upstream block can be removed.
upstream installer_api_server {
    server installer:${EFFECTIVE_FLASK_PORT};
}

# HTTP (port 80) server block
server {
    listen 80;
    server_name ${EFFECTIVE_PUBLIC_DOMAIN} host.docker.internal;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS (port 443) server block
server {
    listen 443 ssl http2;
    server_name ${EFFECTIVE_PUBLIC_DOMAIN} host.docker.internal;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 100M;
    access_log /var/log/nginx/taskbot.access.log;
    error_log /var/log/nginx/taskbot.error.log;

    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Host \$host;

    location / {
        proxy_pass http://frontend_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_cache_bypass \$http_upgrade;
        proxy_no_cache 1;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        proxy_send_timeout 300s;

        if (\$request_method = OPTIONS) {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' '*' always;
            add_header 'Access-Control-Max-Age' 1728000 always;
            add_header 'Content-Type' 'text/plain; charset=UTF-8' always;
            add_header 'Content-Length' 0 always;
            return 204;
        }
    }

    # Removed: location /testapi/

    location /core/ {
        proxy_pass http://gateway_server; # Gateway receives /core/...
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
    }

    # Removed: location /data/

    location /agentrtc/ {
        proxy_pass http://gateway_server; # Gateway receives /agentrtc/...
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
    }

    location /agentws/ {
        proxy_pass http://gateway_server; # Gateway receives /agentws/...
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 75s;
        add_header 'Access-Control-Allow-Origin' '*' always;
    }

    # Removed: location /dataapi/

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        log_not_found off;
        access_log off;
    }
}
EOF
then
  echo "   ✅ Nginx configuration dynamically generated at ${NGINX_CONF_OUTPUT}"
else
  echo "   ❌ Failed to generate Nginx configuration."
  exit 1
fi

# ── 7. Pull & start the stack ────────────────────────────────────────────────
echo "🚀 Pulling Docker images … (this may take a while)"
if docker compose pull; then
  echo "✅ Images pulled successfully."
else
  echo "❌ Failed to pull one or more Docker images. Check image names and network."
  exit 1
fi

echo "🟢 Starting containers …"
if docker compose up -d; then
  echo "✅ Docker containers started successfully."
else
  echo "❌ Failed to start Docker containers. Check 'docker compose logs' for errors."
  exit 1
fi

echo ""
echo "🎉 Taskbot installation is complete!"
echo "   The application stack should now be running."
echo ""
echo "🔗 Access Points:"
echo "   ↪  Portal   : https://${PUBLIC_DOMAIN:-localhost}/"
echo "   ↪  Gateway  : https://${PUBLIC_DOMAIN:-localhost}/gateway/"
echo "   ↪  Installer API (example): https://${PUBLIC_DOMAIN:-localhost}/installer_api/"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "ℹ️  To stop: cd ${INSTALL_DIR} && docker compose down"
echo "ℹ️  Data is stored in: ${INSTALL_DIR}/${DATA_PATH_BASE:-./taskbot-data}"
echo "ℹ️  Certificates are in: ${INSTALL_DIR}/certs"