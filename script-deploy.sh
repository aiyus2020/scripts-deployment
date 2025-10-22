#!/bin/bash

# Stage 1 DevOps Project - Automated Deployment Script

set -e
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[ERROR] Something failed. Check $LOG_FILE for details." >&2' ERR

echo "============================================"
echo "[INFO] Starting Automated Deployment Script"
echo "============================================"

# === 1. Collect User Inputs ===
read -p "Enter Git Repository URL (default: https://github.com/aiyus2020/scripts-deployment): " GIT_URL
GIT_URL=${GIT_URL:-https://github.com/aiyus2020/scripts-deployment}

read -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter remote SSH username: " SSH_USER
read -p "Enter remote host IP or DNS: " SSH_HOST
read -p "Enter SSH port (default: 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

echo "[INFO] Git: $GIT_URL | Branch: $BRANCH"
echo "[INFO] Target Server: $SSH_USER@$SSH_HOST:$SSH_PORT"

# === 2. Validate SSH Connectivity ===
echo "[INFO] Checking SSH connectivity..."
if ssh -o BatchMode=yes -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "echo connected" >/dev/null 2>&1; then
    echo "[INFO] SSH connection successful!"
else
    echo "[ERROR] SSH connection failed. Exiting."
    exit 1
fi

# === 3. Clone or Update Repo ===
if [ -d "deployment-project" ]; then
    echo "[INFO] Repository exists. Pulling latest changes..."
    cd deployment-project && git pull origin "$BRANCH" && cd ..
else
    echo "[INFO] Cloning repository..."
    git clone -b "$BRANCH" "$GIT_URL"
fi

# === 4. Transfer Files to Remote Server ===
echo "[INFO] Copying files to remote server..."
scp -P "$SSH_PORT" -r deployment-project "$SSH_USER@$SSH_HOST:~/deployment-project"

# === 5. Server Preparation ===
echo "[INFO] Preparing server (Docker + Nginx)..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
echo "[REMOTE] Updating packages..."
sudo apt-get update -y

echo "[REMOTE] Installing Docker..."
sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo usermod -aG docker $USER

echo "[REMOTE] Installing Nginx..."
sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
EOF

# === 6. Docker Deployment (Idempotent) ===
echo "[INFO] Deploying Docker container..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
cd ~/deployment-project

# Stop and remove old container if exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "myapp"; then
    echo "[REMOTE] Stopping old container..."
    sudo docker stop myapp || true
    sudo docker rm myapp || true
fi

# Build new image
echo "[REMOTE] Building Docker image..."
sudo docker build -t myapp .

# Run container
echo "[REMOTE] Starting container on port 8080..."
sudo docker run -d --name myapp -p 8080:80 myapp
EOF

# === 7. Configure Nginx Reverse Proxy ===
echo "[INFO] Configuring Nginx reverse proxy..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
sudo bash -c 'cat > /etc/nginx/sites-available/default <<NGINXCONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # SSL placeholder for future use
    # ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
    # ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
}
NGINXCONF'

echo "[REMOTE] Testing and reloading Nginx..."
sudo nginx -t
sudo systemctl reload nginx
EOF

# === 8. Deployment Validation ===
echo "[INFO] Running deployment validation..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
echo "[REMOTE] Checking Docker container status..."
sudo docker ps | grep myapp && echo "[REMOTE] Docker container running."

echo "[REMOTE] Checking Nginx service..."
sudo systemctl status nginx | grep active && echo "[REMOTE] Nginx is active."

echo "[REMOTE] Performing curl check..."
curl -I http://localhost | grep "200 OK" && echo "[REMOTE] App responding successfully."
EOF

# === 9. Cleanup & Idempotency ===
echo "[INFO] Cleaning up temporary files..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "sudo docker system prune -f >/dev/null 2>&1 || true"

echo "[SUCCESS]  Deployment Completed Successfully!"
echo "[INFO] Log file: $LOG_FILE"