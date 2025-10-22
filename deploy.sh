#!/bin/bash
# =====================================================
# HNG DevOps Stage 1 Deployment Script - Containerized
# Author: AiyusTech
# Description: Deploys app + Nginx inside Docker containers
# =====================================================

set -e

# === LOGGING SETUP ===
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i "$LOG_FILE")
exec 2>&1
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
read -p "Enter Application Internal Port (container port, e.g., 80): " APP_PORT

# =====================================================
# STEP 2 — PREPARE REMOTE DIRECTORY
# =====================================================
info "Preparing remote directory..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
set -e
sudo rm -rf ~/app
mkdir -p ~/app
EOF
success "Remote directory ready."

# =====================================================
# STEP 3 — CLONE OR UPDATE REPO ON SERVER
# =====================================================
info "Cloning repository on remote server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -e
cd ~/app
if [ -d ".git" ]; then
  echo "Repository exists. Pulling latest changes..."
  git pull origin $BRANCH
else
  git clone -b $BRANCH https://${PAT}@${REPO_URL#https://} .
fi
EOF
success "Repository cloned/updated."

# =====================================================
# STEP 4 — INSTALL DEPENDENCIES (Docker & Compose)
# =====================================================
info "Installing Docker & Docker Compose..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -e
sudo apt update -y
sudo apt install -y docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker

# ✅ Fix permission issues for the actual SSH user
sudo usermod -aG docker $SSH_USER
sudo chown root:docker /var/run/docker.sock || true
sudo chmod 660 /var/run/docker.sock || true

docker --version
docker-compose --version
EOF
success "Dependencies installed successfully."


# =====================================================
# STEP 5 — CREATE NGINX CONFIG (inside repo)
# =====================================================
info "Creating Nginx config for Docker..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -e
mkdir -p ~/app/nginx
cat > ~/app/nginx/default.conf <<NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://app:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF
EOF
success "Nginx config created."

# =====================================================
# STEP 6 — CREATE DOCKER-COMPOSE FILE
# =====================================================
info "Creating docker-compose.yml..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -e
cat > ~/app/docker-compose.yml <<COMPOSE
version: '3.9'

services:
  app:
    build: .
    container_name: myapp
    expose:
      - "$APP_PORT"
    networks:
      - webnet

  nginx:
    image: nginx:latest
    container_name: nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - app
    networks:
      - webnet

networks:
  webnet:
    driver: bridge
COMPOSE
EOF
success "Docker Compose file created."

# =====================================================
# STEP 7 — DEPLOY CONTAINERS
# =====================================================
info "Deploying containers with Docker Compose..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -e
cd ~/app

sudo systemctl start docker
sudo usermod -aG docker $SSH_USER
sudo chown root:docker /var/run/docker.sock || true
sudo chmod 660 /var/run/docker.sock || true

docker-compose down || true
docker-compose up -d --build
EOF
success "Containers deployed successfully."


# =====================================================
# STEP 8 — VALIDATE DEPLOYMENT
# =====================================================
info "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
docker ps
curl -I http://localhost || true
EOF
success "Deployment completed! Visit your app at http://$SERVER_IP"

echo -e "\n🎉 Deployment logs saved to $LOG_FILE\n"
