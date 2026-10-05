#!/usr/bin/env bash
# Shared helpers for the swangate command.
# shellcheck disable=SC2034  # Globals are shared across the sourced libraries.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

CONFIG_DIR="${IKEV2_CONFIG_DIR:-/etc/ikev2-vpn}"
STATE_DIR="${IKEV2_STATE_DIR:-/var/lib/ikev2-vpn}"
LETSENCRYPT_DIR="${IKEV2_LETSENCRYPT_DIR:-/etc/letsencrypt}"
MANAGED_MARK="managed-by: ikev2-vpn-installer"

log() {
  printf '[swangate] %s\n' "$*"
}

warn() {
  printf '[swangate] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[swangate] ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run this command as root (sudo)."
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    have_cmd "$cmd" || die "Missing required command: $cmd"
  done
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
    || die "Invalid domain: ${domain}"
}

validate_client_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
    || die "Invalid client name: ${name}. Use letters, digits, dot, underscore, or hyphen."
}

validate_country() {
  local country="$1"
  [[ "$country" =~ ^[A-Z]{2}$ ]] || die "CA country must be two uppercase letters. Got: ${country}"
}

validate_org() {
  local org="$1"
  [[ "$org" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,62}$ ]] \
    || die "CA organization contains unsupported characters: ${org}"
}

normalize_ipv6() {
  local raw="$1"
  python3 - "$raw" <<'PY' || die "Invalid IPv6 address: ${raw}"
import ipaddress, sys
raw = sys.argv[1]
try:
    ip = ipaddress.ip_address(raw)
except ValueError:
    sys.exit(1)
if ip.version != 6 or ip.is_unspecified or ip.is_multicast or ip.is_link_local:
    sys.exit(1)
print(ip.compressed)
PY
}

normalize_network() {
  local raw="$1"
  local family="$2"
  python3 - "$raw" "$family" <<'PY' || die "Invalid ${family} network: ${raw}"
import ipaddress, sys
raw, family = sys.argv[1], sys.argv[2]
try:
    net = ipaddress.ip_network(raw, strict=True)
except ValueError:
    sys.exit(1)
if family == "ipv4" and net.version != 4:
    sys.exit(1)
if family == "ipv6" and net.version != 6:
    sys.exit(1)
if family == "ipv6" and net.prefixlen < 64:
    sys.stderr.write("IPv6 virtual pool must be /64 or smaller. StrongSwan rejects very large pools.\n")
    sys.exit(1)
print(net.compressed)
PY
}

validate_dns_list() {
  local list="$1"
  python3 - "$list" <<'PY' || die "DNS list must be comma-separated IP addresses: ${list}"
import ipaddress, sys
raw = sys.argv[1].strip()
if not raw:
    sys.exit(1)
for item in raw.split(","):
    item = item.strip()
    if not item:
        sys.exit(1)
    ipaddress.ip_address(item)
PY
}

dns_for_family() {
  local list="$1"
  local family="$2"
  python3 - "$list" "$family" <<'PY'
import ipaddress, sys
items = [i.strip() for i in sys.argv[1].split(",") if i.strip()]
want = 4 if sys.argv[2] == "ipv4" else 6
print(",".join(i for i in items if ipaddress.ip_address(i).version == want))
PY
}

config_file() {
  printf '%s/config.env\n' "$CONFIG_DIR"
}

CONFIG_KEYS=(
  VPN_DOMAIN VPN_IPV6 VPN_INTERFACE VPN_EMAIL
  VPN_CA_COUNTRY VPN_CA_ORG VPN_CA_CN VPN_CA_SUBJECT
  VPN_POOL_V4 VPN_POOL_V6 VPN_DNS VPN_CLIENTS_DIR
  VPN_DISTRO_FAMILY VPN_DISTRO_ID VPN_PKG_MANAGER VPN_SERVICE_MANAGER
  VPN_BACKEND VPN_SERVICE VPN_SWAN_ETC VPN_FIREWALL VPN_DATAPLANE
)

save_config() {
  local dest key
  dest="$(config_file)"
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$CONFIG_DIR"
  {
    printf '# %s\n' "$MANAGED_MARK"
    for key in "${CONFIG_KEYS[@]}"; do
      printf '%s=%q\n' "$key" "${!key:-}"
    done
  } >"$dest"
  chmod 644 "$dest"
}

load_config() {
  local dest
  dest="$(config_file)"
  [[ -f "$dest" ]] || die "Missing ${dest}. Run 'swangate install' first."
  # shellcheck disable=SC1090
  source "$dest"
  [[ -n "${VPN_DOMAIN:-}" ]] || die "VPN_DOMAIN is missing from ${dest}"
  [[ -n "${VPN_CA_SUBJECT:-}" ]] || die "VPN_CA_SUBJECT is missing from ${dest}"
  [[ -n "${VPN_CLIENTS_DIR:-}" ]] || die "VPN_CLIENTS_DIR is missing from ${dest}"
  VPN_BACKEND="${VPN_BACKEND:-ipsec}"
  VPN_SWAN_ETC="${VPN_SWAN_ETC:-/etc}"
  VPN_DATAPLANE="${VPN_DATAPLANE:-kernel}"
  VPN_FIREWALL="${VPN_FIREWALL:-iptables}"
  VPN_SERVICE_MANAGER="${VPN_SERVICE_MANAGER:-systemd}"
}

new_uuid() {
  if have_cmd uuidgen; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

find_ipv6_iface() {
  local want="$1"
  local limit="${2:-}"
  local iface fam addr norm found
  found=""
  while read -r _ iface fam addr _; do
    [[ "$fam" == "inet6" ]] || continue
    norm="$(normalize_ipv6 "${addr%%/*}" 2>/dev/null || true)"
    [[ "$norm" == "$want" ]] || continue
    if [[ -n "$limit" && "$iface" != "$limit" ]]; then
      continue
    fi
    found="$iface"
    break
  done < <(ip -6 -o addr show scope global)
  if [[ -z "$found" ]]; then
    if [[ -n "$limit" ]]; then
      die "IPv6 ${want} is not configured on interface ${limit}."
    fi
    die "IPv6 ${want} is not configured on this host. Pass the address that is already assigned to the server."
  fi
  printf '%s\n' "${found%@*}"
}

tcp_port_in_use() {
  local port="$1"
  if have_cmd ss; then
    [[ -n "$(ss -H -ltn "sport = :${port}" 2>/dev/null)" ]]
  elif have_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"
  else
    return 1
  fi
}

port_owner() {
  local port="$1"
  if have_cmd ss; then
    ss -H -ltnp "sport = :${port}" 2>/dev/null | head -n 1
  fi
}
