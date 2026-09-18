#!/usr/bin/env bash
# New API 增强包装脚本：不修改上游 install.sh，只在其前后增加镜像源、Nginx 与 HTTPS 配置。
set -Eeuo pipefail

UPSTREAM_URL="https://raw.githubusercontent.com/benmao5201314/new-api-onekey/main/install.sh"
INSTALL_DIR="/opt/new-api"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log(){ echo -e "${BLUE}[信息]${NC} $*"; }
ok(){ echo -e "${GREEN}[成功]${NC} $*"; }
warn(){ echo -e "${YELLOW}[提示]${NC} $*"; }
die(){ echo -e "${RED}[错误]${NC} $*" >&2; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "请使用 root 用户运行：sudo bash $0"; }
read_tty(){ local __v=$1 __p=$2 x; read -r -p "$__p" x < /dev/tty || true; printf -v "$__v" '%s' "$x"; }
confirm(){ local x; read_tty x "$1 [y/N]: "; [[ "$x" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_email(){ [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
wait_apt_lock(){
  command -v apt-get >/dev/null 2>&1 || return 0
  local lock="/var/lib/dpkg/lock-frontend" i=0
  while fuser "$lock" >/dev/null 2>&1; do
    ((i+=1))
    if (( i == 1 )); then
      warn "APT 正被系统自动更新占用，等待锁释放（最多 5 分钟），不要强制删除锁文件。"
    fi
    if (( i >= 60 )); then
      die "APT 锁等待超时。请稍后执行：ps aux | grep -E 'apt|dpkg|unattended'，确认没有安装任务后再重试。"
    fi
    sleep 5
  done
  dpkg --configure -a >/dev/null 2>&1 || true
}

configure_docker_mirrors(){
  log "配置 Docker 国内镜像源。"
  mkdir -p /etc/docker
  local backup="/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  [[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json "$backup"
  cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://mirror.ccs.tencentyun.com"
  ]
}
JSON
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl restart docker 2>/dev/null || true
  fi
  ok "Docker 镜像源已配置。原配置备份：${backup}"
}

collect_proxy_inputs(){
  while :; do
    read_tty DOMAIN "请输入反代域名（例如 claude.example.com）："
    valid_domain "$DOMAIN" && break
    warn "域名格式不正确，请重新输入。"
  done
  read_tty WANT_HTTPS "是否自动申请 Let's Encrypt HTTPS 证书？[Y/n]："
  if [[ "$WANT_HTTPS" =~ ^([Nn][Oo]?|[Nn])$ ]]; then
    HTTPS=no; EMAIL=""
  else
    HTTPS=yes
    while :; do
      read_tty EMAIL "请输入证书通知邮箱："
      valid_email "$EMAIL" && break
      warn "邮箱格式不正确，请重新输入。"
    done
  fi
}

run_upstream(){
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  log "下载并运行上游原始安装脚本（不会修改上游文件）。"
  curl -fsSL "$UPSTREAM_URL" -o "$tmp/install.sh" || die "无法下载上游安装脚本。"
  chmod 700 "$tmp/install.sh"
  cat > "$tmp/proxy.sh" <<'PROXY'
#!/usr/bin/env bash
set -Eeuo pipefail
INSTALL_DIR="/opt/new-api"; COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"; ENV_FILE="$INSTALL_DIR/.env"
read_tty(){ local v=$1 p=$2 x; read -r -p "$p" x < /dev/tty || true; printf -v "$v" '%s' "$x"; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_email(){ [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
get_port(){ APP_PORT=3000; [[ -f "$ENV_FILE" ]] && APP_PORT="$(sed -n 's/^WEB_PORT=//p' "$ENV_FILE" | tail -1)"; [[ "$APP_PORT" =~ ^[0-9]+$ ]] || APP_PORT=3000; }
get_port
while :; do read_tty DOMAIN "请输入反代域名（例如 claude.example.com）："; valid_domain "$DOMAIN" && break; echo "域名格式不正确，请重新输入。"; done
read_tty WANT_HTTPS "是否自动申请 Let's Encrypt HTTPS 证书？[Y/n]："
if [[ "$WANT_HTTPS" =~ ^([Nn][Oo]?|[Nn])$ ]]; then HTTPS=no; else HTTPS=yes; while :; do read_tty EMAIL "请输入证书通知邮箱："; valid_email "$EMAIL" && break; echo "邮箱格式不正确，请重新输入。"; done; fi
if command -v nginx >/dev/null 2>&1; then :; elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y nginx; elif command -v dnf >/dev/null 2>&1; then dnf install -y nginx; else yum install -y nginx; fi
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 100m;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
EOF
ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"; rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx
if [[ "$HTTPS" == yes ]]; then
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y certbot python3-certbot-nginx; elif command -v dnf >/dev/null 2>&1; then dnf install -y certbot python3-certbot-nginx; else yum install -y certbot python3-certbot-nginx; fi
  certbot --nginx --non-interactive --agree-tos --redirect --email "$EMAIL" -d "$DOMAIN"
fi
echo "反代配置完成：${DOMAIN} -> 127.0.0.1:${APP_PORT}"
[[ "$HTTPS" == yes ]] && echo "访问地址：https://${DOMAIN}/" || echo "访问地址：http://${DOMAIN}/"
PROXY
  chmod 700 "$tmp/proxy.sh"
  # 仅修改临时下载副本：原 GitHub install.sh 不会被改动。
  sed -i '/echo.*退出.*"/i\\ echo " 6) 配置域名反向代理与 HTTPS"' "$tmp/install.sh"
  sed -i "s#0) exit 0 ;;#6) bash \"$tmp/proxy.sh\" ;;\\n        0) exit 0 ;;#" "$tmp/install.sh"
  echo
  echo "接下来会进入增强后的上游菜单：安装完成后选择 6 配置反代与 HTTPS。"
  echo
  wait_apt_lock
  bash "$tmp/install.sh"
  [[ -f "$COMPOSE_FILE" ]] || die "未找到 ${COMPOSE_FILE}，请确认已在上游菜单选择安装。"
}

get_port(){
  APP_PORT=3000
  if [[ -f "$ENV_FILE" ]]; then
    local line
    line="$(grep -E '^WEB_PORT=' "$ENV_FILE" | tail -1 || true)"
    [[ "$line" == WEB_PORT=* ]] && APP_PORT="${line#WEB_PORT=}"
  fi
  [[ "$APP_PORT" =~ ^[0-9]+$ ]] || APP_PORT=3000
}
compose_up(){
  cd "$INSTALL_DIR"
  if docker compose version >/dev/null 2>&1; then docker compose --env-file "$ENV_FILE" up -d
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose --env-file "$ENV_FILE" up -d
  else die "未找到 Docker Compose。"; fi
}
wait_api(){
  log "等待 New API 响应。"
  for _ in $(seq 1 90); do
    curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/api/status" >/dev/null 2>&1 && return 0
    sleep 2
  done
  warn "New API 暂未响应，请执行：cd ${INSTALL_DIR} && docker compose logs --tail=100 new-api"
}

configure_nginx(){
  command -v nginx >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y nginx
    elif command -v dnf >/dev/null 2>&1; then dnf install -y nginx
    elif command -v yum >/dev/null 2>&1; then yum install -y nginx
    else die "未找到可用包管理器，无法安装 Nginx。"; fi
  }
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    client_max_body_size 100m;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
EOF
  ln -sfn "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || die "Nginx 配置检查失败。"
  systemctl enable --now nginx
  systemctl reload nginx
  ok "Nginx 反向代理已配置：${DOMAIN} -> 127.0.0.1:${APP_PORT}"
}

configure_https(){
  [[ "$HTTPS" == yes ]] || return 0
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y certbot python3-certbot-nginx
  elif command -v dnf >/dev/null 2>&1; then dnf install -y certbot python3-certbot-nginx
  elif command -v yum >/dev/null 2>&1; then yum install -y certbot python3-certbot-nginx
  else die "无法安装 Certbot。"; fi
  log "申请 HTTPS 证书；请确保 DNS 已指向本机且公网 TCP 80 已放行。"
  certbot --nginx --non-interactive --agree-tos --redirect --email "$EMAIL" -d "$DOMAIN" || die "证书申请失败，请检查 DNS、云安全组和 80 端口。"
  nginx -t && systemctl reload nginx
  ok "HTTPS 配置完成，证书将自动续期。"
}

restrict_port(){
  [[ -f "$COMPOSE_FILE" ]] || return 0
  if grep -qE '^[[:space:]]*- "?\$\{WEB_PORT\}:3000"?' "$COMPOSE_FILE"; then
    cp -a "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i 's#- "\${WEB_PORT}:3000"#- "127.0.0.1:${WEB_PORT}:3000"#' "$COMPOSE_FILE"
    compose_up
    ok "已将 New API 端口限制为本机访问。"
  else
    warn "未自动修改端口映射，请确认 3000 不在云安全组中对公网开放。"
  fi
}

main(){
  require_root
  if [[ -f "$COMPOSE_FILE" ]]; then
    warn "检测到已有 New API：${COMPOSE_FILE}"
    if ! confirm "是否跳过安装，直接继续配置反代和 HTTPS"; then
      die "已取消，未修改现有 New API。"
    fi
    get_port
    compose_up
    wait_api
    echo
    ok "已跳过 New API 安装，现在开始配置域名反向代理。"
    collect_proxy_inputs
    configure_nginx
    if confirm "是否将 Docker 的 ${APP_PORT} 端口限制为仅本机访问"; then restrict_port; fi
    configure_https
    echo
    ok "反代和 HTTPS 配置完成。"
    [[ "$HTTPS" == yes ]] && echo "管理页面：https://${DOMAIN}/" || echo "管理页面：http://${DOMAIN}/"
    [[ "$HTTPS" == yes ]] && echo "API Base URL：https://${DOMAIN}/v1" || echo "API Base URL：http://${DOMAIN}/v1"
    exit 0
  fi
  install -d -m 700 "$INSTALL_DIR"
  if ! command -v docker >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
      wait_apt_lock
      apt-get update -y
      # Ubuntu 22.04 的默认仓库通常没有 docker-compose-plugin，优先使用独立版 compose。
      apt-get install -y docker.io docker-compose curl ca-certificates openssl || \
        apt-get install -y docker.io docker-compose-plugin curl ca-certificates openssl
    elif command -v dnf >/dev/null 2>&1; then dnf install -y docker curl ca-certificates openssl
    elif command -v yum >/dev/null 2>&1; then yum install -y docker curl ca-certificates openssl
    else die "无法自动安装 Docker。"; fi
    systemctl enable --now docker
  fi
  configure_docker_mirrors
  run_upstream
  ok "已返回主流程。反代和 HTTPS 请在上游菜单中选择第 6 项。"
}
main "$@"
