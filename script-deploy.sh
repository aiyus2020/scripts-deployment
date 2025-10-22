#!/bin/bash
# =====================================================
# HNG DevOps Stage 1 Project - Remote Deployment Script
# Author: AiyusTech
# Description: Deploys a Dockerized app with Nginx reverse proxy using Docker Compose
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
read -p "Enter Application Port (host port to expose app, e.g., 8080): " APP_PORT

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
# STEP 4 — INSTALL DOCKER AND DOCKER COMPOSE
# =====================================================
info "Installing Docker and Docker Compose..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
  set -e
  sudo apt update -y
  sudo apt install -y docker.io docker-compose
  sudo systemctl enable docker
  sudo systemctl start docker
  docker --version
  docker-compose --version
EOF
success "Dependencies installed successfully."

# =====================================================
# STEP 5 — CREATE DOCKER COMPOSE CONFIG AND RUN
# =====================================================
info "Creating Docker Compose configuration and starting containers..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -e
cd /home/$SSH_USER/app

# Create docker-compose.yml
cat > docker-compose.yml <<COMPOSE
version: '3.8'

services:
  app:
    build: .
    container_name: myapp
    expose:
      - "80"

  nginx:
    image: nginx:latest
    container_name: myapp-nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - app
COMPOSE

# Create Nginx config file
cat > nginx.conf <<NGINX
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://app:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX

# Stop and remove existing containers if any
docker-compose down || true

# Build and start containers
docker-compose up -d --build
EOF
success "Docker Compose deployment complete. Both app and Nginx containers are running."

# =====================================================
# STEP 6 — VALIDATE DEPLOYMENT
# =====================================================
info "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
docker ps
curl -I localhost
EOF
success "Deployment complete. Visit your server IP in the browser!"

# =====================================================
# STEP 7 — CLEANUP OPTION
# =====================================================
if [[ "$1" == "--cleanup" ]]; then
  warn "Running cleanup operation..."
  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
    docker-compose down
    docker system prune -af
    sudo rm -rf ~/app
EOF
  success "All resources removed successfully."
  exit 0
fi

echo -e "\n====================================================="
success "🎉 Deployment completed successfully!"
echo -e "Logs saved in: $LOG_FILE"
echo -e "=====================================================\n"
