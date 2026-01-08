#!/bin/bash
# ==============================================================================
# Claude Relay Service 一键部署脚本
# 用法: bash install.sh
# ==============================================================================
set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ========== 配置 ==========
DOMAIN="crs.flu.qzz.io"
DEPLOY_DIR="$HOME/claude-relay-service"
REPO_URL="https://github.com/Flutter233PM/claude-relay-service.git"

# 提示输入邮箱
read -p "请输入你的邮箱（用于 SSL 证书）: " CERTBOT_EMAIL
if [ -z "$CERTBOT_EMAIL" ]; then
    CERTBOT_EMAIL="admin@flu.qzz.io"
    log_warn "使用默认邮箱: $CERTBOT_EMAIL"
fi

echo ""
echo "=============================================="
echo "  Claude Relay Service 部署"
echo "  域名: $DOMAIN"
echo "  邮箱: $CERTBOT_EMAIL"
echo "=============================================="
echo ""

# ========== 1. 系统初始化 ==========
log_info "1/9 更新系统..."
apt update -y && apt upgrade -y
apt install -y curl wget git vim ufw ca-certificates gnupg openssl
log_success "系统更新完成"

# ========== 2. 安装 Docker ==========
log_info "2/9 安装 Docker..."
if command -v docker &> /dev/null; then
    log_warn "Docker 已安装，跳过"
else
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi
docker --version
docker compose version
log_success "Docker 就绪"

# ========== 3. 配置防火墙 ==========
log_info "3/9 配置防火墙..."
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
log_success "防火墙配置完成"

# ========== 4. 克隆项目 ==========
log_info "4/9 克隆项目..."
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

if [ -d ".git" ]; then
    log_warn "项目已存在，执行 git pull"
    git pull
else
    git clone "$REPO_URL" .
fi

mkdir -p logs data redis_data certbot/conf certbot/www nginx/conf.d
log_success "项目准备完成"

# ========== 5. 生成环境变量 ==========
log_info "5/9 生成环境变量..."
if [ -f ".env" ]; then
    log_warn ".env 已存在，跳过生成"
else
    JWT_SECRET=$(openssl rand -hex 32)
    ENCRYPTION_KEY=$(openssl rand -hex 16)
    
    cat > .env << EOF
JWT_SECRET=$JWT_SECRET
ENCRYPTION_KEY=$ENCRYPTION_KEY
DOMAIN=$DOMAIN
CERTBOT_EMAIL=$CERTBOT_EMAIL
BIND_HOST=127.0.0.1
EOF
    log_success ".env 文件已生成"
fi

# ========== 6. 创建 docker-compose.prod.yml ==========
log_info "6/9 创建 Docker Compose 配置..."
cat > docker-compose.prod.yml << 'EOF'
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    container_name: crs-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    depends_on:
      - claude-relay
    networks:
      - crs-network

  certbot:
    image: certbot/certbot
    container_name: crs-certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
    networks:
      - crs-network

  claude-relay:
    image: weishaw/claude-relay-service:latest
    container_name: crs-app
    restart: unless-stopped
    expose:
      - "3000"
    volumes:
      - ./logs:/app/logs
      - ./data:/app/data
    environment:
      - NODE_ENV=production
      - PORT=3000
      - HOST=0.0.0.0
      - JWT_SECRET=${JWT_SECRET}
      - ENCRYPTION_KEY=${ENCRYPTION_KEY}
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - TRUST_PROXY=true
      - DEFAULT_PROXY_TIMEOUT=600000
    depends_on:
      - redis
    networks:
      - crs-network

  redis:
    image: redis:7-alpine
    container_name: crs-redis
    restart: unless-stopped
    expose:
      - "6379"
    volumes:
      - ./redis_data:/data
    command: redis-server --save 60 1 --appendonly yes
    networks:
      - crs-network

networks:
  crs-network:
    driver: bridge
EOF
log_success "Docker Compose 配置完成"

# ========== 7. 创建 Nginx 初始配置 ==========
log_info "7/9 创建 Nginx 配置..."
cat > nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'Waiting for SSL setup...\\n';
        add_header Content-Type text/plain;
    }
}
EOF
log_success "Nginx 初始配置完成"

# ========== 8. DNS 检查 ==========
log_info "8/9 检查 DNS..."
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com)
DNS_IP=$(dig +short "$DOMAIN" | head -1)

echo ""
echo "  服务器 IP: $SERVER_IP"
echo "  DNS 解析:  $DNS_IP"
echo ""

if [ -z "$DNS_IP" ]; then
    log_warn "域名 $DOMAIN 尚未解析"
    echo ""
    echo "请在 Cloudflare 添加 DNS 记录:"
    echo "  类型: A"
    echo "  名称: crs"
    echo "  内容: $SERVER_IP"
    echo "  代理: 关闭（灰色云朵）"
    echo ""
    read -p "DNS 配置完成后按 Enter 继续..." _
fi

# ========== 9. 获取 SSL 证书 ==========
log_info "9/9 获取 SSL 证书..."

# 启动 nginx
docker compose -f docker-compose.prod.yml up -d nginx redis claude-relay
sleep 5

# 申请证书
docker compose -f docker-compose.prod.yml run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$CERTBOT_EMAIL" \
    --agree-tos \
    --no-eff-email \
    -d "$DOMAIN"

if [ $? -ne 0 ]; then
    log_error "SSL 证书申请失败，请检查 DNS 配置"
fi

log_success "SSL 证书获取成功"

# ========== 更新 Nginx HTTPS 配置 ==========
log_info "更新 Nginx HTTPS 配置..."
cat > nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 60M;

    location / {
        proxy_pass http://claude-relay:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        proxy_buffering off;
    }
}
EOF

# 重启服务
docker compose -f docker-compose.prod.yml restart nginx

# ========== 完成 ==========
echo ""
echo "=============================================="
log_success "部署完成！"
echo "=============================================="
echo ""
echo "访问地址: https://$DOMAIN"
echo ""
echo "管理员凭据:"
cat "$DEPLOY_DIR/data/init.json" 2>/dev/null || echo "(首次访问时会显示)"
echo ""
echo "常用命令:"
echo "  cd $DEPLOY_DIR"
echo "  docker compose -f docker-compose.prod.yml logs -f     # 查看日志"
echo "  docker compose -f docker-compose.prod.yml restart     # 重启服务"
echo "  docker compose -f docker-compose.prod.yml down        # 停止服务"
echo "  docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d  # 更新"
echo ""
echo "Cloudflare 设置（可选）:"
echo "  1. 开启代理（橙色云朵）"
echo "  2. SSL/TLS 模式设为 Full (strict)"
echo ""
