#!/bin/bash
# =====================================================
# HNG DevOps Stage 1 Project - Remote Deployment Script
# Author: AiyusTech
# Description: Deploys a Dockerized app with Docker Compose and Nginx reverse proxy
# =====================================================

set -e

# === LOGGING SETUP ===
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo -e "\n[❌ ERROR] Something failed. Check $LOG_FILE for details.\n" >&2' ERR

# === HELPER FUNCTIONS ===
info() { echo -e "[INFO] $1"; }
success() { echo -e "[SUCCESS] $1"; }
warn() { echo -e "[WARNING] $1"; }

# =====================================================
# STEP 1 — COLLECT USER INPUT
# =====================================================
echo -e "\n=== 🧠 Deployment Setup ==="
read -p "Enter GitHub Repo URL: " REPO_URL
read -p "Enter GitHub Personal Access Token: " PAT
read -p "Enter Branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}
read -p "Enter SSH Username: " SSH_USER
read -p "Enter Server IP Address: " SERVER_IP
read -p "Enter SSH Key Path: " SSH_KEY
read -p "Enter Application Port (host port to map to container 80): " APP_PORT

# =====================================================
# STEP 2 — PREPARE REMOTE DIRECTORY
# =====================================================
info "Preparing remote directory for deployment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
  set -e
  sudo rm -rf /home/$SSH_USER/app
  mkdir -p /home/$SSH_USER/app
  sudo chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/app
EOF
success "Remote directory ready."

# =====================================================
# STEP 3 — CLONE OR UPDATE REPO ON SERVER
# =====================================================
info "Cloning repository on remote server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
  set -e
  cd /home/$SSH_USER/app
  if [ -d ".git" ]; then
    echo "Repository exists. Pulling latest changes..."
    git pull
  else
    git clone -b $BRANCH https://${PAT}@${REPO_URL#https://} .
  fi
EOF
success "Repository cloned/updated on remote server."

# =====================================================
# STEP 4 — INSTALL DEPENDENCIES
# =====================================================
info "Installing Docker, Docker Compose, and Nginx..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
  set -e
  sudo apt update -y
  sudo apt install -y docker.io docker-compose nginx
  sudo systemctl enable docker
  sudo systemctl start docker
  sudo usermod -aG docker $USER
  docker --version
  nginx -v
EOF
success "Dependencies installed successfully."

# =====================================================
# STEP 5 — CREATE DOCKER COMPOSE FILE
# =====================================================
info "Creating Docker Compose file on server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
  cd /home/$SSH_USER/app
  cat > docker-compose.yml <<COMPOSE
version: '3.8'
services:
  app:
    build: .
    container_name: myapp
    ports:
      - "$APP_PORT:80"
COMPOSE
EOF
success "Docker Compose file created."

# =====================================================
# STEP 6 — BUILD AND RUN DOCKER CONTAINERS
# =====================================================
info "Building and running Docker containers..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
  cd /home/$SSH_USER/app
  # Stop existing containers safely
  docker-compose down || true
  # Build and start containers
  docker-compose up -d --build
EOF
success "Docker Compose containers deployed successfully."

# =====================================================
# STEP 7 — CONFIGURE NGINX REVERSE PROXY
# =====================================================
info "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo bash -c "cat > /etc/nginx/sites-available/default <<NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINXCONF"

# Test and reload Nginx safely
sudo nginx -t
sudo systemctl reload nginx
EOF
success "Nginx configured successfully."

# =====================================================
# STEP 8 — VALIDATE DEPLOYMENT
# =====================================================
info "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
docker ps
curl -I localhost
EOF
success "Deployment complete. Visit your server IP in the browser!"

# =====================================================
# STEP 9 — CLEANUP OPTION
# =====================================================
if [[ "$1" == "--cleanup" ]]; then
  warn "Running cleanup operation..."
  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
    docker-compose down
    docker system prune -af
    sudo rm -rf ~/app
    sudo rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    sudo systemctl reload nginx
EOF
  success "All resources removed successfully."
  exit 0
fi

echo -e "\n====================================================="
success "🎉 Deployment completed successfully!"
echo -e "Logs saved in: $LOG_FILE"
echo -e "=====================================================\n"
