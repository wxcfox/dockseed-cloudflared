#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${0##*/}" == "docker" ]]; then
  printf '%s\n' "$*" >>"${MOCK_DOCKER_LOG:?}"
  exit 0
fi

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockseed-cloudflared-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/cloudflared" "$TEST_DIR/secrets"
cp "$REPO_DIR/start.sh" "$REPO_DIR/compose.yml" "$TEST_DIR/"
ln -s "$REPO_DIR/tests/start_test.sh" "$TEST_DIR/bin/docker"

printf '%s\n' \
  'DOMAIN=example.com' \
  'TUNNEL_ID=00000000-0000-0000-0000-000000000001' \
  'CLOUDFLARED_IMAGE=cloudflare/cloudflared:test' \
  'GATEWAY_NETWORK=dockseed-gateway-test' >"$TEST_DIR/.env"
printf '{}\n' >"$TEST_DIR/secrets/tunnel.json"
printf '# prefix|origin-url|host-header\n' >"$TEST_DIR/routes.conf"

export MOCK_DOCKER_LOG="$TEST_DIR/docker.log"
export PATH="$TEST_DIR/bin:$PATH"
touch "$MOCK_DOCKER_LOG"

cd "$TEST_DIR"

add_route_output="$(./start.sh add-route gitlab 8929)"
[[ "$add_route_output" == *'本地路由已保存'* ]] || fail 'add-route success message is missing'
[[ "$add_route_output" != *'已发布'* ]] || fail 'add-route must not claim that DNS is published'
assert_contains routes.conf 'gitlab|http://host.docker.internal:8929|'
assert_contains cloudflared/config.yml "hostname: 'gitlab.example.com'"
assert_not_contains "$MOCK_DOCKER_LOG" 'tunnel route dns'

./start.sh add-route gitlab 9000 >/dev/null
[[ "$(awk -F'|' '$1 == "gitlab" { count++ } END { print count+0 }' routes.conf)" == '1' ]] || \
  fail 'repeated add-route must keep one route per prefix'
assert_contains routes.conf 'gitlab|http://host.docker.internal:9000|'
assert_not_contains routes.conf 'gitlab|http://host.docker.internal:8929|'
assert_not_contains "$MOCK_DOCKER_LOG" 'tunnel route dns'

./start.sh up >/dev/null
assert_contains routes.conf 'gitlab|http://host.docker.internal:9000|'
assert_not_contains "$MOCK_DOCKER_LOG" 'tunnel route dns'

printf 'test certificate\n' >secrets/cert.pem
add_output="$(./start.sh add docsite 5173)"
[[ "$add_output" == *'已发布'* ]] || fail 'add success message is missing'
[[ "$(grep -Fc 'tunnel route dns' "$MOCK_DOCKER_LOG")" == '1' ]] || \
  fail 'add must create DNS exactly once for a new prefix'

./start.sh add docsite 5180 >/dev/null
[[ "$(grep -Fc 'tunnel route dns' "$MOCK_DOCKER_LOG")" == '1' ]] || \
  fail 'repeated add must not recreate DNS'
assert_contains routes.conf 'docsite|http://host.docker.internal:5180|'

printf 'PASS: start.sh route tests\n'
