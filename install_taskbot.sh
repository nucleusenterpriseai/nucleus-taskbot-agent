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

# ── 4. Configure Environment Variables & Setup .env file ───────────────────
ENV_FILE=".env"
ENV_EXAMPLE_CONTENT=$(cat <<EOF
# ------------------------------------------------------------------------------
#  Taskbot Environment Configuration
#  This file is auto-generated by the installer based on your inputs.
# ------------------------------------------------------------------------------

# Domain for external access
PUBLIC_DOMAIN=\${PUBLIC_DOMAIN_INPUT}

# Java API Service & Gateway Credentials/Config
TASKBOT_LICENSE_TOKEN=\${TASKBOT_LICENSE_TOKEN_INPUT}

# Database Credentials
# MariaDB
MARIADB_ROOT_PASSWORD=\${MARIADB_ROOT_PASSWORD_INPUT}
MARIADB_DATABASE_NAME=nucleus
MARIADB_USER=nucleus_user
MARIADB_PASSWORD=\${MARIADB_PASSWORD_INPUT}

# MongoDB
MONGODB_ROOT_USERNAME=mongoadmin
MONGODB_ROOT_PASSWORD=\${MONGODB_ROOT_PASSWORD_INPUT}

# Redis
REDIS_PASSWORD=\${REDIS_PASSWORD_INPUT}

# RabbitMQ
RABBITMQ_DEFAULT_USER=rabbituser
RABBITMQ_DEFAULT_PASS=\${RABBITMQ_PASSWORD_INPUT}

# Taskbot Installer Service Configuration
TASKBOT_DEPLOY_MODE=ONPREMISE
FLASK_RUN_PORT=5000

# SSH details for agent deployment (leave blank if not using this feature initially)
INSTALLER_SSH_PRIVATE_KEY_PATH=/etc/taskbot/keys/agent_ssh_key
INSTALLER_SSH_USER=\${INSTALLER_SSH_USER_INPUT}

# Data Persistence Paths
DATA_PATH_BASE=./taskbot-data

# Service Internal Ports
GATEWAY_INTERNAL_PORT=8080
TASKBOT_API_INTERNAL_PORT=18902

# Logging Levels (examples - uncomment and set as needed in .env)
# LOG_LEVEL_API=INFO
# LOG_LEVEL_GATEWAY=INFO
EOF
) # End of ENV_EXAMPLE_CONTENT

echo "⚙️  Configuring environment variables..."

# Function to prompt for a value with a default
prompt_for_value() {
    local prompt_text="$1"
    local variable_name="$2"
    local default_value="$3"
    local current_value
    local input

    # Check if the variable is already set (e.g., from a previous run's .env)
    # This part is tricky if we always regenerate .env from prompts.
    # For simplicity now, we'll always prompt if .env doesn't exist or we decide to re-prompt.

    read -rp "${prompt_text} [${default_value}]: " input
    eval "${variable_name}=\"${input:-${default_value}}\""
}

# Function to prompt for a password with confirmation
prompt_for_password() {
    local prompt_text="$1"
    local variable_name="$2"
    local password
    local password_confirm
    while true; do
        read -rsp "${prompt_text}: " password
        echo # Newline after password input
        read -rsp "Confirm ${prompt_text}: " password_confirm
        echo # Newline
        if [[ "$password" == "$password_confirm" ]]; then
            if [[ -z "$password" ]]; then
                echo "Password cannot be empty. Please try again."
            else
                eval "${variable_name}=\"${password}\""
                break
            fi
        else
            echo "Passwords do not match. Please try again."
        fi
    done
}

# --- Collect User Inputs ---
echo "Please provide the following configuration values."
echo "Press Enter to accept the default value shown in [brackets], if any."

prompt_for_value "Enter the public domain/hostname for Taskbot (e.g., taskbot.example.com)" PUBLIC_DOMAIN_INPUT "localhost"
prompt_for_value "Enter your Taskbot License Token" TASKBOT_LICENSE_TOKEN_INPUT "YOUR_LICENSE_TOKEN_HERE" # User MUST change this

echo ""
echo "Please set strong, unique passwords for the services:"
prompt_for_password "MariaDB Root Password" MARIADB_ROOT_PASSWORD_INPUT
prompt_for_password "MariaDB User Password (for 'nucleus_user')" MARIADB_PASSWORD_INPUT
prompt_for_password "MongoDB Root Password (for 'mongoadmin')" MONGODB_ROOT_PASSWORD_INPUT
prompt_for_password "Redis Password" REDIS_PASSWORD_INPUT
prompt_for_password "RabbitMQ Password (for 'rabbituser')" RABBITMQ_PASSWORD_INPUT

echo ""
prompt_for_value "Enter SSH username for deploying agents to remote VMs (leave blank if not used now)" INSTALLER_SSH_USER_INPUT ""

# --- Confirm Inputs (Optional but Recommended) ---
echo ""
echo "-------------------------------------------------------"
echo "Please review your configuration:"
echo "-------------------------------------------------------"
echo "Public Domain:                ${PUBLIC_DOMAIN_INPUT}"
echo "Taskbot License Token:        ${TASKBOT_LICENSE_TOKEN_INPUT}"
echo "MariaDB Root Password:        [set]"
echo "MariaDB User Password:        [set]"
echo "MongoDB Root Password:        [set]"
echo "Redis Password:               [set]"
echo "RabbitMQ Password:            [set]"
echo "SSH User for Agent Deploy:    ${INSTALLER_SSH_USER_INPUT:-N/A}"
echo "-------------------------------------------------------"

read -rp "Is this configuration correct? (yes/no) [yes]: " confirmation
if [[ "${confirmation:-yes}" != "yes" && "${confirmation:-YES}" != "YES" ]]; then
    echo "Configuration aborted by user. Please re-run the installer."
    exit 1
fi

# --- Generate .env file from inputs ---
echo "✍️  Generating ${ENV_FILE}..."
# Substitute the collected variables into the template content
# Using eval to expand the ENV_EXAMPLE_CONTENT which contains variable placeholders
# This is a bit of a hack; a more robust way would be sed or a proper template engine.
# For this limited set, it can work if placeholders are simple like \${VAR_NAME}
# Ensure ENV_EXAMPLE_CONTENT uses \${VAR_NAME} for placeholders to be substituted by eval.

# Create the .env content by substituting placeholders
# This uses a here-string and parameter expansion.
# It's safer than full eval if ENV_EXAMPLE_CONTENT is complex.
# We need to export the _INPUT variables so envsubst can see them if we used it,
# or use direct substitution here.

# Direct substitution method:
# Create a temporary script to do the echo with variable expansion
TEMP_ENV_GENERATOR=$(mktemp)
# Ensure placeholders in ENV_EXAMPLE_CONTENT are like ${PUBLIC_DOMAIN_INPUT} not \$PUBLIC_DOMAIN_INPUT
# The ENV_EXAMPLE_CONTENT above is already defined with \${VAR_NAME} which is good for the eval approach.
# Let's try with eval for simplicity, assuming ENV_EXAMPLE_CONTENT is well-behaved.
# We need to escape the content properly for eval.
# A safer way is to use `envsubst` if available, or multiple `sed` commands.

# Using multiple sed commands for safety and clarity:
GENERATED_ENV_CONTENT="$ENV_EXAMPLE_CONTENT" # Start with the template
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${PUBLIC_DOMAIN_INPUT}|${PUBLIC_DOMAIN_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${TASKBOT_LICENSE_TOKEN_INPUT}|${TASKBOT_LICENSE_TOKEN_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${MARIADB_ROOT_PASSWORD_INPUT}|${MARIADB_ROOT_PASSWORD_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${MARIADB_PASSWORD_INPUT}|${MARIADB_PASSWORD_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${MONGODB_ROOT_PASSWORD_INPUT}|${MONGODB_ROOT_PASSWORD_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${REDIS_PASSWORD_INPUT}|${REDIS_PASSWORD_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${RABBITMQ_PASSWORD_INPUT}|${RABBITMQ_PASSWORD_INPUT}|g")
GENERATED_ENV_CONTENT=$(echo "$GENERATED_ENV_CONTENT" | sed "s|\\\${INSTALLER_SSH_USER_INPUT}|${INSTALLER_SSH_USER_INPUT}|g")


if echo "$GENERATED_ENV_CONTENT" > "$ENV_FILE"; then
    echo "   ✅ ${ENV_FILE} generated successfully with your inputs."
else
    echo "   ❌ Failed to generate ${ENV_FILE}."
    exit 1
fi

# Source the newly created .env file
set -a
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