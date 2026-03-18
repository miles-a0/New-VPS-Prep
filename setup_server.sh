#!/usr/bin/env bash
# =============================================================================
#  setup_server.sh
#  Ubuntu 24.04 — Update Docker & Docker Compose, install Portainer + Nginx
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Privilege check ───────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || error "Please run as root or with sudo: sudo bash $0"

# ── Config — edit these before running if needed ─────────────────────────────
PORTAINER_PORT=9443          # HTTPS UI port for Portainer
PORTAINER_HTTP_PORT=9000     # HTTP fallback port (optional)
NGINX_HTTP_PORT=80
NGINX_HTTPS_PORT=443
PORTAINER_DATA_VOL="portainer_data"
NGINX_CONF_DIR="/opt/nginx/conf.d"
NGINX_HTML_DIR="/opt/nginx/html"
NGINX_LOG_DIR="/opt/nginx/logs"

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Docker Update + Portainer + Nginx  —  Ubuntu 24   ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo

# =============================================================================
#  STEP 1 — System update
# =============================================================================
info "Updating apt package index..."
apt-get update -qq
apt-get upgrade -y -qq
success "System packages updated."

# =============================================================================
#  STEP 2 — Update Docker Engine
# =============================================================================
info "Ensuring the official Docker apt repository is configured..."

# Install prerequisites
apt-get install -y -qq ca-certificates curl gnupg lsb-release

DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
if [[ ! -f "$DOCKER_KEYRING" ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o "$DOCKER_KEYRING"
    chmod a+r "$DOCKER_KEYRING"
fi

DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
if [[ ! -f "$DOCKER_LIST" ]]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > "$DOCKER_LIST"
fi

apt-get update -qq
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

success "Docker Engine updated to: $(docker --version)"
success "Docker Compose updated to: $(docker compose version)"

# Ensure Docker daemon is running
systemctl enable --now docker
success "Docker daemon is enabled and running."

# =============================================================================
#  STEP 3 — Install Portainer CE (Docker container)
# =============================================================================
info "Setting up Portainer CE..."

# Remove old container if it exists (preserves existing volume data)
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
    warn "Existing 'portainer' container found — stopping and removing it (data volume is preserved)."
    docker stop portainer  >/dev/null 2>&1 || true
    docker rm   portainer  >/dev/null 2>&1 || true
fi

# Pull latest Portainer CE image
docker pull portainer/portainer-ce:latest

# Run Portainer
docker run -d \
  --name portainer \
  --restart always \
  -p "${PORTAINER_HTTP_PORT}:9000" \
  -p "${PORTAINER_PORT}:9443" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PORTAINER_DATA_VOL}:/data" \
  portainer/portainer-ce:latest

success "Portainer is running."
echo -e "  ${CYAN}→ HTTPS UI :${RESET} https://<your-server-ip>:${PORTAINER_PORT}"
echo -e "  ${CYAN}→ HTTP  UI :${RESET} http://<your-server-ip>:${PORTAINER_HTTP_PORT}"

# =============================================================================
#  STEP 4 — Install Nginx (Docker container)
# =============================================================================
info "Setting up Nginx..."

# Create host directories for config, html, and logs
mkdir -p "${NGINX_CONF_DIR}" "${NGINX_HTML_DIR}" "${NGINX_LOG_DIR}"

# Write a default config if none exists
NGINX_DEFAULT_CONF="${NGINX_CONF_DIR}/default.conf"
if [[ ! -f "$NGINX_DEFAULT_CONF" ]]; then
    cat > "$NGINX_DEFAULT_CONF" <<'NGINXCONF'
server {
    listen 80 default_server;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # Health-check endpoint
    location /health {
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINXCONF
    success "Default Nginx config written to ${NGINX_DEFAULT_CONF}"
fi

# Write a simple welcome page if none exists
NGINX_INDEX="${NGINX_HTML_DIR}/index.html"
if [[ ! -f "$NGINX_INDEX" ]]; then
    cat > "$NGINX_INDEX" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Server Ready</title>
  <style>
    body { font-family: sans-serif; display:flex; justify-content:center;
           align-items:center; height:100vh; margin:0; background:#1a1a2e; color:#eee; }
    .box { text-align:center; }
    h1   { font-size:2.5rem; margin-bottom:.5rem; }
    p    { color:#aaa; }
  </style>
</head>
<body>
  <div class="box">
    <h1>🚀 Nginx is running</h1>
    <p>Replace this page with your own content in /opt/nginx/html</p>
  </div>
</body>
</html>
HTML
    success "Welcome page written to ${NGINX_INDEX}"
fi

# Remove old container if it exists
if docker ps -a --format '{{.Names}}' | grep -q '^nginx$'; then
    warn "Existing 'nginx' container found — stopping and removing it."
    docker stop nginx >/dev/null 2>&1 || true
    docker rm   nginx >/dev/null 2>&1 || true
fi

# Pull latest Nginx image
docker pull nginx:latest

# Run Nginx
docker run -d \
  --name nginx \
  --restart always \
  -p "${NGINX_HTTP_PORT}:80" \
  -p "${NGINX_HTTPS_PORT}:443" \
  -v "${NGINX_CONF_DIR}:/etc/nginx/conf.d:ro" \
  -v "${NGINX_HTML_DIR}:/usr/share/nginx/html:ro" \
  -v "${NGINX_LOG_DIR}:/var/log/nginx" \
  nginx:latest

success "Nginx is running."
echo -e "  ${CYAN}→ HTTP  :${RESET} http://<your-server-ip>:${NGINX_HTTP_PORT}"
echo -e "  ${CYAN}→ HTML  :${RESET} ${NGINX_HTML_DIR}"
echo -e "  ${CYAN}→ Conf  :${RESET} ${NGINX_CONF_DIR}"
echo -e "  ${CYAN}→ Logs  :${RESET} ${NGINX_LOG_DIR}"

# =============================================================================
#  STEP 5 — UFW firewall rules (if ufw is present)
# =============================================================================
if command -v ufw &>/dev/null; then
    info "Configuring UFW firewall rules..."
    ufw allow OpenSSH            >/dev/null 2>&1 || true
    ufw allow "${NGINX_HTTP_PORT}/tcp"    >/dev/null 2>&1 || true
    ufw allow "${NGINX_HTTPS_PORT}/tcp"   >/dev/null 2>&1 || true
    ufw allow "${PORTAINER_PORT}/tcp"     >/dev/null 2>&1 || true
    ufw allow "${PORTAINER_HTTP_PORT}/tcp" >/dev/null 2>&1 || true
    # Enable UFW non-interactively only if it was already active
    if ufw status | grep -q "Status: active"; then
        ufw reload >/dev/null 2>&1 || true
        success "UFW rules reloaded."
    else
        warn "UFW is installed but not active. Run 'sudo ufw enable' to activate it."
    fi
fi

# =============================================================================
#  STEP 6 — Summary
# =============================================================================
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                  Setup Complete ✓                    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${BOLD}Docker${RESET}           $(docker --version)"
echo -e "  ${BOLD}Docker Compose${RESET}   $(docker compose version)"
echo
echo -e "  ${BOLD}Running containers:${RESET}"
docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" | column -t
echo
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. Open Portainer at ${CYAN}https://<your-ip>:${PORTAINER_PORT}${RESET} and create your admin account."
echo -e "  2. Add your site files to ${CYAN}${NGINX_HTML_DIR}${RESET}."
echo -e "  3. Add virtual-host configs to ${CYAN}${NGINX_CONF_DIR}${RESET} and run:"
echo -e "     ${CYAN}docker exec nginx nginx -s reload${RESET}"
echo -e "  4. For HTTPS, consider adding a Certbot container or Nginx Proxy Manager."
echo
