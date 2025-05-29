#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  Taskbot All-in-One Installer (HTTP Only)                                   #
#  • Installs Docker + Compose plugin if missing                              #
#  • Pulls docker-compose.yml from GitHub.                                    #
#  • Generates .env and Nginx configuration (HTTP only).                      #
#  • Starts the stack.                                                        #
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
    if ! docker compose version &>/dev/null; then
        echo "❌ Docker Compose still not found after installation. Check PATH or try manual install." >&2
        exit 1
    fi
  else
    echo "❌ Failed to download Docker Compose plugin. Please install it manually." >&2
    echo "   See: https://docs.docker.com/compose/install/" >&2
    exit 1
  fi
else
  echo "✅ Docker Compose plugin is already installed."
fi

# ── 3. Download stack definition files ───────────────────────────────────────
echo "⬇️  Downloading ${COMPOSE_FILE} from ${RAW_CONTENT_BASE_URL}…" # Changed log message slightly
download_file() {
  local remote_path="$1"
  local local_path="$2"
  # dir variable was unused, removed. local_path includes dirname if needed.
  mkdir -p "$(dirname "$local_path")" # Ensure directory exists
  echo "   Downloading ${remote_path} to ${local_path}..."
  if curl -fsSL "${RAW_CONTENT_BASE_URL}/${remote_path}" -o "${local_path}"; then
    echo "   ✅ Downloaded ${local_path}"
  else
    echo "   ❌ Failed to download ${remote_path}. Please check URL and network." >&2
    exit 1
  fi
}

download_file "${COMPOSE_FILE}" "${COMPOSE_FILE}"

mkdir -p ./keys
echo "ℹ️  Created ./keys directory. If your installer service needs SSH keys to deploy agents,"
echo "   please place the private key (e.g., 'agent_ssh_key') in this './keys' directory."
echo "   (This is configured later, typically via the UI or by editing the .env file)."


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
#  Taskbot Environment Configuration (HTTP Only)
#  This file is auto-generated by the installer based on your inputs
#  and pre-defined defaults for internal services.
# ------------------------------------------------------------------------------

# Domain/IP for external access (used for constructing HTTP URLs)
PUBLIC_DOMAIN=\${PUBLIC_DOMAIN_INPUT}

# Java API Service & Gateway Credentials/Config
TASKBOT_LICENSE_TOKEN=\${TASKBOT_LICENSE_TOKEN_INPUT}
JWT_SECRET=${GENERATED_JWT_SECRET} 

# Database Credentials (Using pre-defined defaults for internal services)
# MariaDB
MARIADB_ROOT_PASSWORD=${DEFAULT_MARIADB_ROOT_PASSWORD}
MARIADB_DATABASE_NAME=nucleus
MARIADB_USER=nucleus_user
MARIADB_PASSWORD=${DEFAULT_MARIADB_PASSWORD}

# MongoDB
MONGODB_ROOT_USERNAME=mongoadmin
MONGODB_ROOT_PASSWORD=${DEFAULT_MONGODB_ROOT_PASSWORD}

# Redis
REDIS_PASSWORD=${DEFAULT_REDIS_PASSWORD}

# RabbitMQ
RABBITMQ_DEFAULT_USER=rabbituser
RABBITMQ_DEFAULT_PASS=${DEFAULT_RABBITMQ_PASSWORD}

# Taskbot Installer Service Configuration
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5000

# SSH details for agent deployment (configure via UI or by editing this file when needed)
INSTALLER_SSH_PRIVATE_KEY_PATH=/etc/taskbot/keys/agent_ssh_key
INSTALLER_SSH_USER= # Defaults to blank, to be configured later

# Data Persistence Paths
DATA_PATH_BASE=./taskbot-data

# Service Internal Ports (ensure services listen on these HTTP ports)
GATEWAY_INTERNAL_PORT=8080
TASKBOT_API_INTERNAL_PORT=18902

# Logging Levels (examples - uncomment and set as needed in .env)
# LOG_LEVEL_API=INFO
# LOG_LEVEL_GATEWAY=INFO
EOF
)

echo "⚙️  Configuring environment variables..."

prompt_for_value() {
    local prompt_text="$1"
    local variable_name="$2"
    local default_value="$3"
    local input
    read -rp "${prompt_text} [${default_value}]: " input
    eval "${variable_name}=\"${input:-${default_value}}\""
}

echo "Please provide the following configuration values."
echo "Press Enter to accept the default value shown in [brackets], if any."

prompt_for_value "Enter the public domain/hostname for Taskbot (e.g., taskbot.example.com or server IP)" PUBLIC_DOMAIN_INPUT "localhost"
prompt_for_value "Enter your Taskbot License Token (Required - Get from https://nucleusenterprise.ai/licenses/)" TASKBOT_LICENSE_TOKEN_INPUT ""

if [[ -z "$TASKBOT_LICENSE_TOKEN_INPUT" || "$TASKBOT_LICENSE_TOKEN_INPUT" == "YOUR_LICENSE_TOKEN_HERE" ]]; then
    echo "❌ ERROR: A valid Taskbot License Token is required." >&2
    echo "Please obtain one from https://nucleusenterprise.ai/licenses/ and re-run the installer." >&2
    exit 1
fi

echo ""
echo "-------------------------------------------------------"
echo "Please review your configuration:"
echo "-------------------------------------------------------"
echo "Public Domain/Host:         ${PUBLIC_DOMAIN_INPUT}"
echo "Taskbot License Token:        ${TASKBOT_LICENSE_TOKEN_INPUT}"
echo "Internal Service Passwords:   [Using pre-defined defaults]"
echo "-------------------------------------------------------"

read -rp "Is this configuration correct? (yes/no) [yes]: " confirmation
if [[ "${confirmation:-yes}" != "yes" && "${confirmation:-YES}" != "YES" ]]; then
    echo "Configuration aborted by user. Please re-run the installer." >&2
    exit 1
fi

echo "✍️  Generating ${ENV_FILE}..."
GENERATED_ENV_CONTENT="$ENV_FILE_CONTENT"
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${PUBLIC_DOMAIN_INPUT}|${PUBLIC_DOMAIN_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${TASKBOT_LICENSE_TOKEN_INPUT}|${TASKBOT_LICENSE_TOKEN_INPUT}|g")

if echo "$GENERATED_ENV_CONTENT" > "$ENV_FILE"; then
    echo "   ✅ ${ENV_FILE} generated successfully with your inputs and default service passwords."
    echo "   ℹ️  Internal service passwords are set to defaults. See script/documentation for details."
    echo "   ⚠️  For enhanced security in production, consider changing these default passwords"
    echo "       in the .env file and restarting the services."
else
    echo "   ❌ Failed to generate ${ENV_FILE}." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env # PUBLIC_DOMAIN, GATEWAY_INTERNAL_PORT, etc. are now available
set +a


# ── 5. Generate Nginx Configuration File (Was Section 6 - HTTP Only) ────────
echo "⚙️  Generating Nginx configuration file (HTTP only)..."
NGINX_CONF_DIR=$(dirname "$NGINX_CONF_OUTPUT") # Should be ./nginx
mkdir -p "$NGINX_CONF_DIR"

# Variables are sourced from .env now
EFFECTIVE_PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-localhost}"
EFFECTIVE_GATEWAY_PORT="${GATEWAY_INTERNAL_PORT:-8080}"
EFFECTIVE_FLASK_PORT="${FLASK_RUN_PORT:-5000}"

if cat > "$NGINX_CONF_OUTPUT" <<EOF
# Dynamically generated Nginx configuration by install_taskbot.sh (HTTP Only)

upstream frontend_server {
    server frontend:3000;
}

upstream gateway_server { # Assuming gateway listens on HTTP
    server gateway:${EFFECTIVE_GATEWAY_PORT};
}

# Optional: Upstream for installer service if Nginx needs to proxy to it directly
# upstream installer_api_server {
#     server installer:${EFFECTIVE_FLASK_PORT};
# }

server {
    listen 80;
    server_name ${EFFECTIVE_PUBLIC_DOMAIN} host.docker.internal; # host.docker.internal is useful for Docker Desktop

    client_max_body_size 100M; # Example: Allow larger uploads
    access_log /var/log/nginx/taskbot.access.log;
    error_log /var/log/nginx/taskbot.error.log;

    # Standard proxy headers
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto http; # Indicate original request was HTTP
    proxy_set_header Host \$host;

    location / {
        proxy_pass http://frontend_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade"; # For WebSockets if frontend uses them on /
        # Add other necessary proxy settings for Next.js if needed
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /core/ {
        proxy_pass http://gateway_server; # Nginx to Gateway is HTTP
        # Add any specific headers or settings for the gateway proxy
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /agentrtc/ {
        proxy_pass http://gateway_server; # Nginx to Gateway is HTTP
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /agentws/ { # WebSocket over plain HTTP is ws://
        proxy_pass http://gateway_server; # Nginx to Gateway is HTTP
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_buffering off;
        proxy_read_timeout 86400s; # Long timeout for persistent connections
        proxy_send_timeout 86400s;
    }

    # Example: If you need to expose the installer API via Nginx (uncomment upstream too)
    # location /installer_api/ {
    #     proxy_pass http://installer_api_server;
    #     # Add specific headers or settings
    # }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }
    location = /robots.txt {
        access_log off;
        log_not_found off;
    }
}
EOF
then
  echo "   ✅ Nginx configuration dynamically generated at ${NGINX_CONF_OUTPUT}"
else
  echo "   ❌ Failed to generate Nginx configuration." >&2
  exit 1
fi

# ── 6. Pull & start the stack (Was Section 7) ────────────────────────────────
echo "🚀 Pulling Docker images … (this may take a while)"
if docker compose pull; then
  echo "✅ Images pulled successfully."
else
  echo "❌ Failed to pull Docker images. Check image names, network, and Docker Hub access." >&2
  exit 1
fi

echo "🟢 Starting containers …"
if docker compose up -d; then
  echo "✅ Docker containers started successfully."
else
  echo "❌ Failed to start Docker containers. Check 'docker compose logs' for errors." >&2
  exit 1
fi

echo ""
echo "🎉 Taskbot installation is complete! (HTTP ONLY)"
echo "   The application stack should now be running."
echo ""
echo "🔗 Access Points (HTTP):"
# PUBLIC_DOMAIN is sourced from .env, so it will have the user's input or 'localhost'
echo "   ↪  Portal   : http://${PUBLIC_DOMAIN}/"
echo "   ↪  Gateway  : http://${PUBLIC_DOMAIN}/core/" # Assuming /core/ is the primary base for gateway APIs
# If you have an installer API exposed via Nginx:
# echo "   ↪  Installer API : http://${PUBLIC_DOMAIN}/installer_api/"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "ℹ️  To stop: cd ${INSTALL_DIR} && docker compose down"
# DATA_PATH_BASE is sourced from .env
echo "ℹ️  Data is stored in: ${INSTALL_DIR}/${DATA_PATH_BASE:-./taskbot-data}"
# No certs directory message needed