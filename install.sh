#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="new-api"
INSTALL_DIR="/opt/new-api"
DEFAULT_PORT="3000"
APP_IMAGE="calciumion/new-api:latest"
ADMIN_USER="root"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
CREDENTIAL_FILE="${INSTALL_DIR}/admin-credentials.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[信息]${NC} $*"; }
log_ok() { echo -e "${GREEN}[成功]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[提示]${NC} $*"; }
log_err() { echo -e "${RED}[错误]${NC} $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_err "请使用 root 用户运行，或使用 sudo bash install.sh。"
    exit 1
  fi
}

pause_return() {
  echo
  read -r -p "按回车返回主菜单..." _ || true
}

random_string() {
  local length="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "${length}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}"
  fi
}

valid_password() {
  local password="$1"
  [[ ${#password} -ge 8 && ${#password} -le 72 && "${password}" =~ ^[A-Za-z0-9@._%+=:-]+$ ]]
}

choose_admin_password() {
  local choice password password2
  echo
  echo "管理员账号固定为：${ADMIN_USER}"
  echo "请选择管理员密码设置方式："
  echo "  1) 随机生成（推荐，默认）"
  echo "  2) 自定义输入"
  read -r -p "请选择 [1-2，默认 1]: " choice || true
  case "${choice:-1}" in
    2)
      while true; do
        read -r -s -p "请输入管理员密码（至少 8 位，仅支持字母、数字和 @._%+=:-）: " password || true
        echo
        if ! valid_password "${password}"; then
          log_warn "密码长度或字符不符合要求，请重新输入。"
          continue
        fi
        read -r -s -p "请再次输入管理员密码: " password2 || true
        echo
        if [[ "${password}" != "${password2}" ]]; then
          log_warn "两次输入不一致，请重新输入。"
          continue
        fi
        ADMIN_PASSWORD="${password}"
        ADMIN_PASSWORD_MODE="自定义"
        break
      done
      ;;
    *)
      ADMIN_PASSWORD="$(random_string 18)"
      ADMIN_PASSWORD_MODE="随机生成"
      ;;
  esac
}

install_basic_packages() {
  local pkgs=(curl ca-certificates openssl)
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  else
    log_warn "未识别包管理器，跳过基础工具安装。"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  log_info "未检测到 Docker，开始自动安装 Docker。"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-plugin curl ca-certificates openssl || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose curl ca-certificates openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y docker curl ca-certificates openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y docker curl ca-certificates openssl
  else
    log_err "无法自动安装 Docker：不支持当前系统的包管理器。"
    exit 1
  fi
}

ensure_docker_running() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi
  if ! docker info >/dev/null 2>&1; then
    log_err "Docker 未正常运行，请检查 Docker 服务状态。"
    exit 1
  fi
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_MODE="plugin"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_MODE="standalone"
    return
  fi

  log_info "未检测到 Docker Compose，开始安装独立版 Docker Compose。"
  local arch compose_arch url
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) compose_arch="x86_64" ;;
    aarch64|arm64) compose_arch="aarch64" ;;
    *) log_err "不支持的 CPU 架构：${arch}"; exit 1 ;;
  esac
  url="https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-${compose_arch}"
  curl -fsSL "${url}" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  COMPOSE_MODE="standalone"
}

compose_run() {
  if [[ "${COMPOSE_MODE:-}" == "plugin" ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  else
    return 1
  fi
}

choose_port() {
  APP_PORT="${DEFAULT_PORT}"
  if port_in_use "${APP_PORT}"; then
    log_warn "端口 ${APP_PORT} 已被占用，需要设置一个可用端口。"
    while true; do
      read -r -p "请输入 new-api 对外端口（例如 3001）: " APP_PORT || true
      if [[ "${APP_PORT}" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) && ! port_in_use "${APP_PORT}"; then
        break
      fi
      log_warn "端口无效或已被占用，请重新输入。"
    done
  else
    log_info "使用默认对外端口：${APP_PORT}"
  fi
}

get_public_ip() {
  local ip service
  for service in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip" \
    "https://ip.sb"; do
    ip="$(curl -4 -fsSL --max-time 4 "${service}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "${ip}"
      return 0
    fi
  done
  for ip in $(hostname -I 2>/dev/null || true); do
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ! "${ip}" =~ ^127\. ]]; then
      echo "${ip}"
      return 0
    fi
  done
  echo "服务器IP"
}

write_compose_files() {
  local postgres_password redis_password session_secret crypto_secret
  postgres_password="$(random_string 32)"
  redis_password="$(random_string 32)"
  session_secret="$(random_string 48)"
  crypto_secret="$(random_string 48)"

  mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/logs"
  chmod 700 "${INSTALL_DIR}"

  cat >"${ENV_FILE}" <<EOF
WEB_PORT=${APP_PORT}
POSTGRES_PASSWORD=${postgres_password}
REDIS_PASSWORD=${redis_password}
SESSION_SECRET=${session_secret}
CRYPTO_SECRET=${crypto_secret}
TZ=Asia/Shanghai
EOF
  chmod 600 "${ENV_FILE}"

  cat >"${COMPOSE_FILE}" <<'EOF'
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "${WEB_PORT}:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://root:${POSTGRES_PASSWORD}@postgres:5432/new-api
      - REDIS_CONN_STRING=redis://:${REDIS_PASSWORD}@redis:6379
      - TZ=${TZ}
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - NODE_NAME=new-api-node-1
      - SESSION_SECRET=${SESSION_SECRET}
      - CRYPTO_SECRET=${CRYPTO_SECRET}
    depends_on:
      - postgres
      - redis
    networks:
      - new-api-network
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":\\s*true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  postgres:
    image: postgres:15
    container_name: new-api-postgres
    restart: always
    environment:
      POSTGRES_USER: root
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: new-api
    volumes:
      - new-api-postgres-data:/var/lib/postgresql/data
    networks:
      - new-api-network

  redis:
    image: redis:latest
    container_name: new-api-redis
    restart: always
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    networks:
      - new-api-network

volumes:
  new-api-postgres-data:
    name: new-api-postgres-data

networks:
  new-api-network:
    name: new-api-network
    driver: bridge
EOF
}

wait_for_service() {
  log_info "等待 new-api 服务启动，通常需要 30-120 秒。"
  local i
  for i in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/api/status" 2>/dev/null | grep -q '"success"'; then
      log_ok "new-api 服务已响应。"
      return 0
    fi
    sleep 2
  done
  log_err "new-api 服务启动超时，请使用菜单中的日志功能查看原因。"
  return 1
}

initialize_admin() {
  local payload response
  payload="{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\",\"confirmPassword\":\"${ADMIN_PASSWORD}\",\"SelfUseModeEnabled\":true,\"DemoSiteEnabled\":false}"
  response="$(curl -fsS -X POST "http://127.0.0.1:${APP_PORT}/api/setup" -H 'Content-Type: application/json' -d "${payload}" 2>/dev/null || true)"
  if echo "${response}" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    log_ok "管理员账号已初始化。"
  elif echo "${response}" | grep -q '系统已经初始化完成'; then
    log_warn "系统已经初始化完成，未重复修改管理员账号。"
  else
    log_warn "自动初始化管理员账号未确认成功，请打开 Web 页面按向导完成初始化。"
    [[ -n "${response}" ]] && echo "返回信息：${response}"
  fi

  cat >"${CREDENTIAL_FILE}" <<EOF
new-api 管理员登录信息
安装时间：$(date '+%Y-%m-%d %H:%M:%S %Z')
管理员账号：${ADMIN_USER}
管理员密码：${ADMIN_PASSWORD}
密码来源：${ADMIN_PASSWORD_MODE}
EOF
  chmod 600 "${CREDENTIAL_FILE}"
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
    log_info "已尝试放行 UFW 端口：${APP_PORT}/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${APP_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    log_info "已尝试放行 firewalld 端口：${APP_PORT}/tcp"
  fi
}

print_access_info() {
  local ip base_url
  ip="$(get_public_ip)"
  base_url="http://${ip}:${APP_PORT}"
  echo
  echo "============================================================"
  log_ok "new-api 安装完成"
  echo "============================================================"
  echo "服务首页：${base_url}/"
  echo "登录页面：${base_url}/login"
  echo "Web 管理面板：${base_url}/"
  echo "OpenAI 兼容 API Base URL：${base_url}/v1"
  echo "模型列表接口：${base_url}/v1/models"
  echo "状态接口：${base_url}/api/status"
  echo
  echo "管理员账号：${ADMIN_USER}"
  echo "管理员密码：${ADMIN_PASSWORD}"
  echo "密码来源：${ADMIN_PASSWORD_MODE}"
  echo
  echo "本机安装目录：${INSTALL_DIR}"
  echo "凭据备份文件：${CREDENTIAL_FILE}"
  echo "============================================================"
}

load_env_if_exists() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    APP_PORT="${WEB_PORT:-${DEFAULT_PORT}}"
  else
    APP_PORT="${DEFAULT_PORT}"
  fi
}

install_new_api() {
  if [[ -f "${COMPOSE_FILE}" ]]; then
    log_warn "检测到 ${INSTALL_DIR} 已存在。若要重装，请先执行彻底卸载。"
    return 0
  fi

  install_basic_packages
  install_docker
  ensure_docker_running
  ensure_compose
  choose_port
  choose_admin_password
  write_compose_files
  open_firewall_port

  log_info "开始拉取镜像并启动 new-api。"
  (cd "${INSTALL_DIR}" && compose_run --env-file "${ENV_FILE}" up -d)
  wait_for_service
  initialize_admin
  print_access_info
}

update_new_api() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log_warn "未检测到安装目录，请先安装。"
    return 0
  fi
  install_docker
  ensure_docker_running
  ensure_compose
  load_env_if_exists
  log_info "开始更新 new-api 镜像并重启服务。"
  (cd "${INSTALL_DIR}" && compose_run --env-file "${ENV_FILE}" pull new-api && compose_run --env-file "${ENV_FILE}" up -d)
  wait_for_service || true
  log_ok "更新完成。"
  show_status
}

show_status() {
  ensure_docker_running
  ensure_compose
  load_env_if_exists
  echo
  echo "============================================================"
  echo "new-api 运行状态"
  echo "============================================================"
  docker ps --filter "name=new-api" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" || true
  echo
  if curl -fsS "http://127.0.0.1:${APP_PORT}/api/status" >/dev/null 2>&1; then
    log_ok "本机状态接口正常：http://127.0.0.1:${APP_PORT}/api/status"
  else
    log_warn "本机状态接口暂未响应。"
  fi
  if [[ -f "${CREDENTIAL_FILE}" ]]; then
    echo
    cat "${CREDENTIAL_FILE}"
  fi
}

show_logs() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log_warn "未检测到安装目录。"
    return 0
  fi
  ensure_docker_running
  ensure_compose
  echo "按 Ctrl+C 可退出日志查看。"
  (cd "${INSTALL_DIR}" && compose_run --env-file "${ENV_FILE}" logs -f --tail=120 new-api)
}

uninstall_new_api() {
  log_warn "即将彻底卸载 new-api：删除容器、专用网络、数据卷、配置、数据和日志。"
  log_warn "该操作不会保留任何 new-api 相关数据。"
  ensure_docker_running || true
  ensure_compose || true

  if [[ -f "${COMPOSE_FILE}" ]]; then
    (cd "${INSTALL_DIR}" && compose_run --env-file "${ENV_FILE}" down -v --remove-orphans) || true
  fi

  docker rm -f new-api new-api-postgres new-api-redis >/dev/null 2>&1 || true
  docker volume rm new-api-postgres-data >/dev/null 2>&1 || true
  docker network rm new-api-network >/dev/null 2>&1 || true
  docker rmi "${APP_IMAGE}" >/dev/null 2>&1 || true
  rm -rf "${INSTALL_DIR}"
  log_ok "new-api 已彻底卸载，相关容器、数据卷、网络、配置、数据和日志已删除。"
}

show_menu() {
  clear || true
  echo "============================================================"
  echo " new-api 极简一键安装脚本"
  echo " 项目：https://github.com/QuantumNous/new-api"
  echo "============================================================"
  echo " 1) 安装 new-api（默认部署）"
  echo " 2) 更新 new-api"
  echo " 3) 查看状态与凭据"
  echo " 4) 查看日志"
  echo " 5) 彻底卸载 new-api"
  echo " 0) 退出"
  echo "============================================================"
}

main() {
  require_root
  while true; do
    show_menu
    read -r -p "请选择操作 [0-5]: " choice || true
    case "${choice}" in
      1) install_new_api; pause_return ;;
      2) update_new_api; pause_return ;;
      3) show_status; pause_return ;;
      4) show_logs; pause_return ;;
      5) uninstall_new_api; pause_return ;;
      0) exit 0 ;;
      *) log_warn "无效选择，请重新输入。"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
