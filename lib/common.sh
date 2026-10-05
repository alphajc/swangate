#!/usr/bin/env bash
# Shared helpers for the IPv6 IKEv2 installer. English only.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

log() {
  printf '[ikev2] %s\n' "$*"
}

die() {
  printf '[ikev2] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run this command as root (sudo)."
  fi
}

require_ubuntu() {
  local os_id os_version
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release. This installer requires Ubuntu."
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  os_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-unknown}")"
  if [[ "$os_id" != "ubuntu" ]]; then
    die "This installer requires Ubuntu. Detected: ${os_id:-unknown}."
  fi
  case "$os_version" in
    22.04|24.04)
      log "Ubuntu ${os_version} detected."
      ;;
    *)
      log "WARNING: Ubuntu ${os_version} is outside the tested 22.04 and 24.04 releases. Continuing."
      ;;
  esac
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
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
    if not item or item != item.strip():
        sys.exit(1)
    ipaddress.ip_address(item)
PY
}

config_file() {
  printf '%s\n' /etc/ikev2-vpn/config.env
}

save_config() {
  local dest
  dest="$(config_file)"
  mkdir -p /etc/ikev2-vpn
  umask 022
  {
    printf 'VPN_DOMAIN=%q\n' "$VPN_DOMAIN"
    printf 'VPN_IPV6=%q\n' "$VPN_IPV6"
    printf 'VPN_INTERFACE=%q\n' "$VPN_INTERFACE"
    printf 'VPN_EMAIL=%q\n' "${VPN_EMAIL:-}"
    printf 'VPN_CA_COUNTRY=%q\n' "$VPN_CA_COUNTRY"
    printf 'VPN_CA_ORG=%q\n' "$VPN_CA_ORG"
    printf 'VPN_CA_CN=%q\n' "$VPN_CA_CN"
    printf 'VPN_CA_SUBJECT=%q\n' "$VPN_CA_SUBJECT"
    printf 'VPN_POOL_V4=%q\n' "$VPN_POOL_V4"
    printf 'VPN_POOL_V6=%q\n' "$VPN_POOL_V6"
    printf 'VPN_DNS=%q\n' "$VPN_DNS"
    printf 'VPN_CLIENTS_DIR=%q\n' "$VPN_CLIENTS_DIR"
  } >"$dest"
  chmod 644 "$dest"
}

load_config() {
  local dest
  dest="$(config_file)"
  [[ -f "$dest" ]] || die "Missing ${dest}. Run install.sh first."
  # shellcheck disable=SC1090
  source "$dest"
  [[ -n "${VPN_DOMAIN:-}" ]] || die "VPN_DOMAIN is missing from ${dest}"
  [[ -n "${VPN_CA_SUBJECT:-}" ]] || die "VPN_CA_SUBJECT is missing from ${dest}"
  [[ -n "${VPN_CLIENTS_DIR:-}" ]] || die "VPN_CLIENTS_DIR is missing from ${dest}"
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
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
  printf '%s\n' "$found"
}
