#!/bin/bash
# =====================================================
# HNG DevOps Stage 1 Project - Automated Deployment Script
# Author: AiyusTech
# Description: Automates the setup and deployment of a Dockerized app
# =====================================================

set -e

# === LOGGING SETUP ===
LOG_DIR="logs"
mkdir -p "$LOG_DIR"  # Create logs folder if it doesn't exist

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
read -p "Enter Application Port: " APP_PORT

# =====================================================
# STEP 3 — REMOTE SERVER SETUP
# =====================================================
info "Connecting to remote server and installing dependencies..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << 'EOF'
  set -e
  echo "Updating system packages..."
  sudo apt update -y

  echo "Installing Docker, Docker Compose, and Nginx..."
  sudo apt install -y docker.io docker-compose nginx

  echo "Enabling and starting Docker service..."
  sudo systemctl enable docker
  sudo systemctl start docker
  sudo usermod -aG docker $USER

  echo "Verifying installations..."
  docker --version
  nginx -v
EOF

success "Remote server setup complete."

# =====================================================
# STEP 4 — TRANSFER PROJECT FILES
# =====================================================
info "Transferring project files to remote server..."
scp -i "$SSH_KEY" -r . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app"
success "Project files successfully transferred."

# =====================================================
# STEP 5 — DEPLOY DOCKER CONTAINER
# =====================================================
info "Deploying Dockerized application..."

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
  set -e
  cd ~/app

  echo "Building Docker image..."
  docker build -t myapp .

  echo "Checking for existing myapp container..."
  # Stop and remove old container if it exists (running or stopped)
  if [ "$(docker ps -a -q -f name=myapp)" ]; then
    echo "Removing existing myapp container..."
    docker rm -f myapp
  fi

  echo "Running new container..."
  docker run -d -p 8082:80 --name myapp myapp
EOF

success "Docker container deployed successfully."


# =====================================================
# STEP 6 — CONFIGURE NGINX REVERSE PROXY
# =====================================================
info "Configuring Nginx reverse proxy..."

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << EOF
sudo bash -c 'cat > /etc/nginx/sites-available/myapp <<EOL
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOL'

sudo ln -sf /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
EOF

success "Nginx configured successfully."

# =====================================================
# STEP 7 — VALIDATE DEPLOYMENT
# =====================================================
info "Validating deployment..."

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
  docker ps
  curl -I localhost
EOF

success "Deployment complete. Visit your server IP in the browser!"

# =====================================================
# STEP 8 — CLEANUP OPTION
# =====================================================
if [[ "$1" == "--cleanup" ]]; then
  warn "Running cleanup operation..."
  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
    docker stop $(docker ps -q) || true
    docker system prune -af
    sudo rm -rf ~/app
    sudo rm -f /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/myapp
    sudo systemctl reload nginx
EOF
  success "All resources removed successfully."
  exit 0
fi

echo -e "\n====================================================="
success "🎉 Deployment completed successfully!"
echo -e "Logs saved in: $LOG_FILE"
echo -e "=====================================================\n"
