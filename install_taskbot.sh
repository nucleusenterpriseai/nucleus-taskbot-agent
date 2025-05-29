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
GH_BRANCH="main" # Consider making this configurable or using a specific tag/release

RAW_CONTENT_BASE_URL="https://raw.githubusercontent.com/${GH_REPO_OWNER}/${GH_REPO_NAME}/${GH_BRANCH}"

COMPOSE_FILE="docker-compose.yml"
NGINX_CONF_OUTPUT="nginx/app.conf" # Relative to INSTALL_DIR

INSTALL_DIR="$(pwd)/taskbot_deployment" # Installs in a subdirectory of the current path

echo "📦 Taskbot installer starting …"
echo "   Installation directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}" # IMPORTANT: All subsequent relative paths are from here

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
  DOCKER_CLI_PLUGINS_DIR="/usr/local/lib/docker/cli-plugins" # Common location
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
echo "⬇️  Downloading stack definition file: ${COMPOSE_FILE}..."
download_file() {
  local remote_path="$1" # e.g., "docker-compose.yml"
  local local_path="$2"  # e.g., "./docker-compose.yml" (relative to INSTALL_DIR)

  mkdir -p "$(dirname "$local_path")" # Ensure directory for local_path exists
  echo "   Fetching ${RAW_CONTENT_BASE_URL}/${remote_path} to ${local_path}..."
  if curl -fsSL "${RAW_CONTENT_BASE_URL}/${remote_path}" -o "${local_path}"; then
    echo "   ✅ Downloaded ${local_path}"
  else
    echo "   ❌ Failed to download ${remote_path}. Please check URL and network." >&2
    exit 1
  fi
}

download_file "${COMPOSE_FILE}" "${COMPOSE_FILE}" # Download to current dir (INSTALL_DIR)

mkdir -p ./keys # Relative to INSTALL_DIR
echo "ℹ️  Created ./keys directory. If your installer service needs SSH keys to deploy agents,"
echo "   please place the private key (e.g., 'agent_ssh_key') in this './keys' directory."
echo "   (This is configured later, typically via the UI or by editing the .env file)."


# ── 4. Configure Environment Variables & Setup .env file ───────────────────
ENV_FILE=".env" # Relative to INSTALL_DIR

DEFAULT_MARIADB_ROOT_PASSWORD="supersecretrootpassword"
DEFAULT_MARIADB_PASSWORD="secretpassword"
DEFAULT_MONGODB_ROOT_PASSWORD="secretmongopassword"
DEFAULT_REDIS_PASSWORD="secretredispassword"
DEFAULT_RABBITMQ_PASSWORD="rabbitpassword"
GENERATED_JWT_SECRET=$(openssl rand -base64 48) # Generate the secret

ENV_FILE_CONTENT=$(cat <<EOF
# ------------------------------------------------------------------------------
#  Taskbot Environment Configuration (HTTP Only)
#  This file is auto-generated by the installer.
# ------------------------------------------------------------------------------

# Domain/IP for external access (used for constructing HTTP URLs)
PUBLIC_DOMAIN=\${PUBLIC_DOMAIN_INPUT}

# Java API Service & Gateway Credentials/Config
TASKBOT_LICENSE_TOKEN=\${TASKBOT_LICENSE_TOKEN_INPUT}
JWT_SECRET=${GENERATED_JWT_SECRET} # Embed the generated secret directly

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
DATA_PATH_BASE=./taskbot-data # Relative to INSTALL_DIR

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
echo "Taskbot License Token:      ${TASKBOT_LICENSE_TOKEN_INPUT}"
echo "API JWT Secret:             [Auto-generated and secured]"
echo "Internal Service Passwords: [Using pre-defined defaults]"
echo "-------------------------------------------------------"

read -rp "Is this configuration correct? (yes/no) [yes]: " confirmation
if [[ "${confirmation:-yes}" != "yes" && "${confirmation:-YES}" != "YES" ]]; then
    echo "Configuration aborted by user. Please re-run the installer." >&2
    exit 1
fi

echo "✍️  Generating ${ENV_FILE}..."
# Substitute placeholders in the ENV_FILE_CONTENT
# Note: GENERATED_JWT_SECRET and other defaults are already embedded.
# We only need to substitute the prompted values.
TEMP_ENV_CONTENT="$ENV_FILE_CONTENT" # Use a temporary variable for substitutions
TEMP_ENV_CONTENT=$(echo "$TEMP_ENV_CONTENT" | sed "s|\\\${PUBLIC_DOMAIN_INPUT}|${PUBLIC_DOMAIN_INPUT}|g")
TEMP_ENV_CONTENT=$(echo "$TEMP_ENV_CONTENT" | sed "s|\\\${TASKBOT_LICENSE_TOKEN_INPUT}|${TASKBOT_LICENSE_TOKEN_INPUT}|g")

if echo "$TEMP_ENV_CONTENT" > "$ENV_FILE"; then
    echo "   ✅ ${ENV_FILE} generated successfully."
    echo "   ℹ️  A unique, strong JWT secret for the API service has been auto-generated."
    echo "   ℹ️  Internal service passwords are set to defaults. See script/documentation for details."
    echo "   ⚠️  For enhanced security in production, consider changing default passwords"
    echo "       in the .env file and restarting the services if this is a sensitive environment."
else
    echo "   ❌ Failed to generate ${ENV_FILE}." >&2
    exit 1
fi

# Source the .env file to make its variables available for Nginx config, etc.
# This should be done *after* the .env file is fully generated and written.
set -a
# shellcheck disable=SC1090 # Disables warning about non-constant source path
source "./${ENV_FILE}" # Source the .env file from the current directory (INSTALL_DIR)
set +a


# ── 5. Generate Nginx Configuration File ─────────────────────────────────────
echo "⚙️  Generating Nginx configuration file (HTTP only)..."
NGINX_CONF_DIR=$(dirname "$NGINX_CONF_OUTPUT") # e.g., "nginx"
mkdir -p "$NGINX_CONF_DIR" # Create ./nginx if it doesn't exist

# Variables are sourced from .env now
EFFECTIVE_PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-localhost}" # Fallback if not set in .env
EFFECTIVE_GATEWAY_PORT="${GATEWAY_INTERNAL_PORT:-8080}"
EFFECTIVE_FLASK_PORT="${FLASK_RUN_PORT:-5000}"

# NGINX_CONF_OUTPUT is relative to INSTALL_DIR, e.g., "nginx/app.conf"
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
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /core/ {
        proxy_pass http://gateway_server; # Nginx to Gateway is HTTP
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
    # }

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

# We are already in ${INSTALL_DIR}, so Docker Compose commands will use this context.
# Docker Compose uses the directory name as the default project name.

# Check if any containers for this project exist and stop/remove them
# The `docker compose ps -q` command lists IDs of containers for the current project.
# If it outputs anything, containers exist.
if [ -n "$(docker compose ps -q)" ]; then # Check if output of ps -q is non-empty
  echo "ℹ️  Existing containers found. Stopping and removing them..."
  if docker compose down; then # Use 'down' to stop and remove containers, networks.
    echo "✅ Existing containers stopped and removed successfully."
  else
    echo "⚠️  Failed to stop/remove existing containers. Please check manually."
    # Consider exiting if 'down' fails, as 'up' might have issues.
    # exit 1
  fi
else
  echo "ℹ️  No existing containers found for this project."
fi

echo "🚀 Pulling latest specified Docker images … (this may take a while)"
if docker compose pull; then
  echo "✅ Images pulled successfully."
else
  echo "❌ Failed to pull Docker images. Check image names, network, and Docker Hub access." >&2
  # Depending on policy, you might want to exit or allow proceeding with local/old images.
  # exit 1
fi

echo "🟢 Starting containers …"
# --remove-orphans removes containers for services not defined in the Compose file.
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
# PUBLIC_DOMAIN is sourced from .env
echo "   ↪  Portal   : http://${PUBLIC_DOMAIN:-localhost}/" # Fallback for PUBLIC_DOMAIN
echo "   ↪  Gateway  : http://${PUBLIC_DOMAIN:-localhost}/core/"
echo ""
echo "ℹ️  To view logs: cd ${INSTALL_DIR} && docker compose logs -f"
echo "ℹ️  To stop: cd ${INSTALL_DIR} && docker compose down"
# DATA_PATH_BASE is sourced from .env
echo "ℹ️  Data is stored in: ${INSTALL_DIR}/${DATA_PATH_BASE:-./taskbot-data}" # Fallback for DATA_PATH_BASE
echo ""
echo "Script finished."