#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ROUTES_FILE="$ROOT_DIR/routes.conf"
CONFIG_FILE="$ROOT_DIR/cloudflared/config.yml"
SECRETS_DIR="$ROOT_DIR/secrets"
COMPOSE_FILE="$ROOT_DIR/compose.yml"

DEFAULT_IMAGE="cloudflare/cloudflared:2026.7.3"
DEFAULT_NETWORK="cloudflared-gateway"

log() { printf '[gateway] %s\n' "$*"; }
die() { printf '[gateway] ERROR: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
cloudflared-local-gateway

常用格式
  ./start.sh init <根域名> [Tunnel名称]
  ./start.sh add <域名前缀> <本机端口> [Host header]

具体示例
  ./start.sh init domain.com
  ./start.sh add gitlab 8929
  ./start.sh add docsite 5173

上面的 add 示例分别生成：
  gitlab.domain.com  -> 本机的 8929 端口
  docsite.domain.com -> 本机的 5173 端口

只有本地开发服务提示 Invalid Host 或 403 时，才使用：
  ./start.sh add docsite 5173 localhost

Docker 网络直连（高级模式）
  具体用法和 Compose 配置见 README。

命令
  help                         显示帮助
  init <根域名> [Tunnel名称]    首次登录 Cloudflare、创建并启动 Tunnel
  add <前缀> <端口|URL> [Host] 添加或更新路由，并自动启动/重载 gateway
  up                           生成、校验配置并启动/重载 gateway
  status                       查看状态
  logs                         持续查看日志
  stop                         停止 gateway

行为说明
  init 只用于首次创建，不会重置或覆盖现有 Tunnel。
  add 会把路由永久保存到 routes.conf。
  服务未启动时域名仍然匹配，但通常会返回 502。

删除路由
  从 routes.conf 删除对应行，再执行 ./start.sh up。
  Cloudflare DNS 请在控制台确认后人工删除。

安全
  .env、routes.conf、secrets/tunnel.json 和 secrets/cert.pem 不会提交 Git。
  请把它们备份到密码管理器或其他加密存储。
EOF
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "缺少 docker"
  docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2"
  docker info >/dev/null 2>&1 || die "Docker 不可用，请先启动 Docker Desktop"
}

valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_prefix() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_url() {
  [[ "$1" =~ ^https?://[^[:space:]\|\']+$ ]]
}

valid_host() {
  [[ -z "$1" || "$1" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "尚未初始化，请先运行：./start.sh init domain.com"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  : "${DOMAIN:?缺少 DOMAIN}"
  : "${TUNNEL_ID:?缺少 TUNNEL_ID}"
  valid_domain "$DOMAIN" || die ".env 中的 DOMAIN 格式不正确：$DOMAIN"
  [[ "$TUNNEL_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || \
    die ".env 中的 TUNNEL_ID 不是有效 UUID"
  CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-$DEFAULT_IMAGE}"
  GATEWAY_NETWORK="${GATEWAY_NETWORK:-$DEFAULT_NETWORK}"
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

ensure_layout() {
  mkdir -p "$ROOT_DIR/cloudflared" "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  [[ -f "$ROUTES_FILE" ]] || printf '# prefix|origin-url|host-header\n' >"$ROUTES_FILE"
}

ensure_network() {
  if ! docker network inspect "$GATEWAY_NETWORK" >/dev/null 2>&1; then
    log "创建 Docker 网络：$GATEWAY_NETWORK"
    docker network create "$GATEWAY_NETWORK" >/dev/null
  fi
}

cloudflared_cli() {
  local image="${CLOUDFLARED_IMAGE:-$DEFAULT_IMAGE}"
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-it) || tty=(-i)

  docker run --rm "${tty[@]}" \
    --user "$(id -u):$(id -g)" \
    --workdir /tmp \
    --env HOME=/tmp \
    --volume "$SECRETS_DIR:/tmp/.cloudflared" \
    "$image" "$@"
}

ensure_cert() {
  [[ -f "$SECRETS_DIR/cert.pem" ]] && return
  log "请打开接下来显示的 Cloudflare 授权地址，并选择你的域名"
  cloudflared_cli tunnel login
  [[ -f "$SECRETS_DIR/cert.pem" ]] || die "没有生成 secrets/cert.pem"
  chmod 600 "$SECRETS_DIR/cert.pem"
}

render_config() {
  local prefix origin host extra
  local temp
  temp="$(mktemp "${TMPDIR:-/tmp}/cloudflared-config.XXXXXX")"

  {
    printf "tunnel: '%s'\n" "$TUNNEL_ID"
    printf 'credentials-file: /etc/cloudflared/tunnel.json\n\n'
    printf 'ingress:\n'

    while IFS='|' read -r prefix origin host extra; do
      [[ -n "$prefix" && "$prefix" != \#* ]] || continue
      valid_prefix "$prefix" || die "routes.conf 中的前缀不合法：$prefix"
      valid_url "$origin" || die "routes.conf 中的 URL 不合法：$origin"
      valid_host "${host:-}" || die "routes.conf 中的 Host header 不合法：$host"
      [[ -z "${extra:-}" ]] || die "routes.conf 格式错误：$prefix"

      printf "  - hostname: '%s.%s'\n" "$prefix" "$DOMAIN"
      printf "    service: '%s'\n" "$origin"
      if [[ -n "${host:-}" ]]; then
        printf '    originRequest:\n'
        printf "      httpHostHeader: '%s'\n" "$host"
      fi
    done <"$ROUTES_FILE"

    printf '  - service: http_status:404\n'
  } >"$temp"

  mv "$temp" "$CONFIG_FILE"
}

validate_config() {
  [[ -f "$SECRETS_DIR/tunnel.json" ]] || die "缺少 secrets/tunnel.json"
  ensure_network
  compose run --rm --no-deps cloudflared \
    tunnel --config /etc/cloudflared/config.yml ingress validate
}

start_gateway() {
  render_config
  validate_config
  compose up -d --no-deps --force-recreate cloudflared
  compose ps cloudflared
}

route_exists() {
  awk -F'|' -v wanted="$1" '$1 == wanted { found=1 } END { exit !found }' "$ROUTES_FILE"
}

save_route() {
  local prefix="$1" origin="$2" host="$3"
  local temp
  temp="$(mktemp "${TMPDIR:-/tmp}/cloudflared-routes.XXXXXX")"
  awk -F'|' -v wanted="$prefix" '$1 != wanted' "$ROUTES_FILE" >"$temp"
  printf '%s|%s|%s\n' "$prefix" "$origin" "$host" >>"$temp"
  mv "$temp" "$ROUTES_FILE"
}

command_init() {
  local domain="${1:-}"
  local tunnel_name="${2:-}"
  local credential="" candidate tunnel_id

  [[ -n "$domain" && $# -le 2 ]] || die "用法：./start.sh init <根域名> [Tunnel名称]"
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  domain="${domain%.}"
  valid_domain "$domain" || die "域名格式不正确：$domain"
  tunnel_name="${tunnel_name:-local-gateway-${domain//./-}}"
  [[ "$tunnel_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Tunnel 名称格式不正确"

  [[ ! -f "$ENV_FILE" && ! -f "$SECRETS_DIR/tunnel.json" ]] || \
    die "已经初始化；不会覆盖现有 .env 或 Tunnel 密钥"

  check_docker
  ensure_layout
  CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-$DEFAULT_IMAGE}"
  ensure_cert

  if compgen -G "$SECRETS_DIR/*.json" >/dev/null 2>&1; then
    die "secrets/ 中已有 JSON，无法安全创建新 Tunnel"
  fi

  log "创建 Tunnel：$tunnel_name"
  cloudflared_cli tunnel create "$tunnel_name"

  for candidate in "$SECRETS_DIR"/*.json; do
    [[ -e "$candidate" ]] || continue
    [[ -z "$credential" ]] || die "生成了多个 Tunnel JSON，请人工检查 secrets/"
    credential="$candidate"
  done
  [[ -n "$credential" ]] || die "未找到新建 Tunnel 的 JSON"

  tunnel_id="${credential##*/}"
  tunnel_id="${tunnel_id%.json}"
  [[ "$tunnel_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || \
    die "Tunnel JSON 文件名不是有效 UUID"

  mv "$credential" "$SECRETS_DIR/tunnel.json"
  chmod 600 "$SECRETS_DIR/tunnel.json"

  umask 077
  {
    printf 'DOMAIN=%s\n' "$domain"
    printf 'TUNNEL_ID=%s\n' "$tunnel_id"
    printf 'CLOUDFLARED_IMAGE=%s\n' "$CLOUDFLARED_IMAGE"
    printf 'GATEWAY_NETWORK=%s\n' "$DEFAULT_NETWORK"
  } >"$ENV_FILE"

  load_env
  start_gateway
  log "初始化完成。下一步示例：./start.sh add gitlab 8929"
}

command_add() {
  local prefix="${1:-}" target="${2:-}" host="${3:-}"
  local origin port existed="false"

  [[ -n "$prefix" && -n "$target" && $# -le 3 ]] || \
    die "用法：./start.sh add <域名前缀> <本机端口|origin URL> [Host header]"
  valid_prefix "$prefix" || die "域名前缀格式不正确：$prefix"
  valid_host "$host" || die "Host header 格式不正确：$host"

  if [[ "$target" =~ ^[0-9]+$ ]]; then
    port=$((10#$target))
    (( port >= 1 && port <= 65535 )) || die "端口必须在 1-65535 之间"
    origin="http://host.docker.internal:$port"
  else
    valid_url "$target" || die "目标必须是本机端口或 http:// / https:// URL"
    origin="$target"
  fi

  check_docker
  load_env
  ensure_layout
  route_exists "$prefix" && existed="true"

  if [[ "$existed" == "false" ]]; then
    ensure_cert
    log "创建 DNS：$prefix.$DOMAIN"
    cloudflared_cli tunnel route dns "$TUNNEL_ID" "$prefix.$DOMAIN" || \
      die "DNS 创建失败，路由尚未保存；如果同名记录已存在，请先在 Cloudflare 控制台确认并处理，再重新执行本命令"
  fi

  save_route "$prefix" "$origin" "$host"
  start_gateway
  log "已发布：https://$prefix.$DOMAIN -> $origin"
}

command_up() {
  check_docker
  load_env
  ensure_layout
  start_gateway
}

command_status() { check_docker; load_env; compose ps cloudflared; }
command_logs() { check_docker; load_env; compose logs -f --tail=200 cloudflared; }
command_stop() { check_docker; load_env; compose stop cloudflared; }

main() {
  local command="${1:-help}"
  shift || true

  case "$command" in
    help|-h|--help) show_help ;;
    init) command_init "$@" ;;
    add) command_add "$@" ;;
    up) command_up "$@" ;;
    status) command_status "$@" ;;
    logs) command_logs "$@" ;;
    stop) command_stop "$@" ;;
    *) show_help >&2; die "未知命令：$command" ;;
  esac
}

main "$@"
