#!/usr/bin/env bash
set -Eeuo pipefail

domain="${BETTERDESK_DOMAIN:-${1:-}}"
env_file="${BETTERDESK_ENV_FILE:-/opt/BetterDeskConsole/.env}"
server_unit="${BETTERDESK_SERVER_UNIT:-/etc/systemd/system/betterdesk-server.service}"
console_unit="${BETTERDESK_CONSOLE_UNIT:-/etc/systemd/system/betterdesk-console.service}"
caddy_target="${CADDYFILE_PATH:-/etc/caddy/Caddyfile}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
caddy_template="${CADDYFILE_TEMPLATE:-${script_dir}/Caddyfile.example}"
backup_dir="${BACKUP_DIR:-/root/betterdesk-one-port-443-preconfig-$(date -u +%Y%m%dT%H%M%SZ)}"
temporary_caddy=""

cleanup() {
  if [ -n "$temporary_caddy" ] && [ -f "$temporary_caddy" ]; then
    rm -f -- "$temporary_caddy"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  sudo BETTERDESK_DOMAIN=desk.example.com REPLACE_CADDYFILE=Y \
    bash ./configure-one-port-443.sh

This script backs up and then changes the BetterDesk .env, both systemd units,
and /etc/caddy/Caddyfile. It does not change firewall rules.
EOF
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [ -z "$domain" ]; then
  usage >&2
  exit 2
fi

if ! [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
  echo "Invalid DNS hostname: $domain" >&2
  exit 2
fi

if [ "${REPLACE_CADDYFILE:-N}" != "Y" ]; then
  echo "Refusing to replace $caddy_target without REPLACE_CADDYFILE=Y." >&2
  echo "The current file will be backed up, but unrelated Caddy sites would not be merged." >&2
  exit 2
fi

for required in "$env_file" "$server_unit" "$console_unit" "$caddy_template"; do
  if [ ! -f "$required" ]; then
    echo "Missing required file: $required" >&2
    exit 1
  fi
done

for command_name in caddy systemctl sed grep install mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

install -d -m 700 "$backup_dir"
for source_file in "$env_file" "$server_unit" "$console_unit" "$caddy_target"; do
  if [ -e "$source_file" ]; then
    cp -a -- "$source_file" "$backup_dir/"
  fi
done

upsert_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}

replace_unit_env() {
  local unit_file="$1"
  local key="$2"
  local value="$3"
  if ! grep -q "^Environment=${key}=" "$unit_file"; then
    echo "Expected Environment=${key}=... in $unit_file" >&2
    exit 1
  fi
  sed -i "s|^Environment=${key}=.*|Environment=${key}=${value}|" "$unit_file"
}

upsert_env HOST 127.0.0.1
upsert_env PORT 5000
upsert_env HTTPS_ENABLED false
upsert_env HTTP_REDIRECT_HTTPS false
upsert_env TRUST_PROXY Y
upsert_env TRUSTED_PROXIES 127.0.0.1/32,::1/128
upsert_env PANEL_PUBLIC_HOST "$domain"
upsert_env PANEL_PUBLIC_URL "https://${domain}"
upsert_env PUBLIC_SERVER_ID "$domain"
upsert_env PUBLIC_RELAY_SERVER "$domain"
upsert_env PUBLIC_API_URL "https://${domain}"
upsert_env WS_ALLOWED_ORIGINS "https://${domain}"
upsert_env P2P_FIRST N
upsert_env ALWAYS_USE_RELAY Y
upsert_env UPDATE_GITHUB_BRANCH "${BETTERDESK_UPDATE_BRANCH:-dev}"

# External Caddy owns TLS. Remove native Go TLS flags that may have been added
# by the installer. The current unit writes these flags as one contiguous block.
sed -i -E 's/[[:space:]]+-tls-cert[[:space:]]+[^[:space:]]+[[:space:]]+-tls-key[[:space:]]+[^[:space:]]+[[:space:]]+-tls-signal[[:space:]]+-tls-relay//g' "$server_unit"
replace_unit_env "$server_unit" P2P_FIRST N
replace_unit_env "$server_unit" ALWAYS_USE_RELAY Y

# The panel and API stay plain HTTP behind Caddy. Remove systemd values that
# override the .env file and bind the console to localhost.
sed -i '/^Environment=HTTPS_ENABLED=/d' "$console_unit"
sed -i '/^Environment=SSL_CERT_PATH=/d' "$console_unit"
sed -i '/^Environment=SSL_KEY_PATH=/d' "$console_unit"
sed -i '/^Environment=RUSTDESK_API_TLS=/d' "$console_unit"
sed -i '/^Environment=NODE_EXTRA_CA_CERTS=/d' "$console_unit"
replace_unit_env "$console_unit" HOST 127.0.0.1
replace_unit_env "$console_unit" API_HOST 127.0.0.1

temporary_caddy="$(mktemp)"
sed "s/__BETTERDESK_DOMAIN__/${domain}/g" "$caddy_template" > "$temporary_caddy"
caddy validate --config "$temporary_caddy" --adapter caddyfile
install -o root -g root -m 644 "$temporary_caddy" "$caddy_target"

systemctl daemon-reload
systemctl restart betterdesk-server betterdesk-console caddy

systemctl is-active --quiet betterdesk-server
systemctl is-active --quiet betterdesk-console
systemctl is-active --quiet caddy

echo "BetterDesk single-port configuration applied."
echo "Public URL: https://${domain}"
echo "Backup: $backup_dir"
echo "Firewall was not changed; follow docs/setup/SINGLE_PORT_443_NATIVE.md."
