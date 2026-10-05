#!/usr/bin/env bash
# Install an IPv6-capable IKEv2 VPN (StrongSwan, certificate authentication).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/certs.sh
source "${SCRIPT_DIR}/lib/certs.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh --domain NAME --ipv6 ADDRESS [options]

Install StrongSwan IKEv2 with a Let's Encrypt server certificate and a
local CA for client certificates. Safe to run again.

Required:
  --domain NAME          VPN hostname, already pointed at this server
  --ipv6 ADDRESS         IPv6 address already configured on this server

Options:
  --email ADDRESS        Let's Encrypt contact email
  --interface NAME       Outbound interface for NAT (default: the interface
                         that owns --ipv6)
  --ca-country CC        Client CA country (default: CN)
  --ca-org NAME          Client CA organization (default: IKEv2)
  --pool-v4 CIDR         IPv4 virtual pool (default: 10.10.10.0/24)
  --pool-v6 CIDR         IPv6 virtual pool (default: fd00:10:10::/64)
  --dns LIST             Comma-separated DNS servers pushed to clients
  --clients-dir PATH     Where client files are written (default: /root/vpn-clients)
  --staging              Use the Let's Encrypt staging server
  --skip-certbot         Do not run certbot; reuse an existing certificate
  -h, --help             Show this help

Environment variables (flags override them):
  VPN_DOMAIN VPN_IPV6 VPN_EMAIL VPN_INTERFACE VPN_CA_COUNTRY VPN_CA_ORG
  VPN_POOL_V4 VPN_POOL_V6 VPN_DNS VPN_CLIENTS_DIR
EOF
}

VPN_DOMAIN="${VPN_DOMAIN:-}"
VPN_IPV6="${VPN_IPV6:-}"
VPN_EMAIL="${VPN_EMAIL:-}"
VPN_INTERFACE="${VPN_INTERFACE:-}"
VPN_CA_COUNTRY="${VPN_CA_COUNTRY:-CN}"
VPN_CA_ORG="${VPN_CA_ORG:-IKEv2}"
VPN_POOL_V4="${VPN_POOL_V4:-10.10.10.0/24}"
VPN_POOL_V6="${VPN_POOL_V6:-fd00:10:10::/64}"
VPN_DNS="${VPN_DNS:-1.1.1.1,8.8.8.8,2606:4700:4700::1111}"
VPN_CLIENTS_DIR="${VPN_CLIENTS_DIR:-/root/vpn-clients}"
VPN_CERTBOT_STAGING="${VPN_CERTBOT_STAGING:-0}"
VPN_SKIP_CERTBOT="${VPN_SKIP_CERTBOT:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      VPN_DOMAIN="${2:-}"
      shift 2
      ;;
    --domain=*)
      VPN_DOMAIN="${1#*=}"
      shift
      ;;
    --ipv6)
      VPN_IPV6="${2:-}"
      shift 2
      ;;
    --ipv6=*)
      VPN_IPV6="${1#*=}"
      shift
      ;;
    --email)
      VPN_EMAIL="${2:-}"
      shift 2
      ;;
    --email=*)
      VPN_EMAIL="${1#*=}"
      shift
      ;;
    --interface)
      VPN_INTERFACE="${2:-}"
      shift 2
      ;;
    --interface=*)
      VPN_INTERFACE="${1#*=}"
      shift
      ;;
    --ca-country)
      VPN_CA_COUNTRY="${2:-}"
      shift 2
      ;;
    --ca-country=*)
      VPN_CA_COUNTRY="${1#*=}"
      shift
      ;;
    --ca-org)
      VPN_CA_ORG="${2:-}"
      shift 2
      ;;
    --ca-org=*)
      VPN_CA_ORG="${1#*=}"
      shift
      ;;
    --pool-v4)
      VPN_POOL_V4="${2:-}"
      shift 2
      ;;
    --pool-v4=*)
      VPN_POOL_V4="${1#*=}"
      shift
      ;;
    --pool-v6)
      VPN_POOL_V6="${2:-}"
      shift 2
      ;;
    --pool-v6=*)
      VPN_POOL_V6="${1#*=}"
      shift
      ;;
    --dns)
      VPN_DNS="${2:-}"
      shift 2
      ;;
    --dns=*)
      VPN_DNS="${1#*=}"
      shift
      ;;
    --clients-dir)
      VPN_CLIENTS_DIR="${2:-}"
      shift 2
      ;;
    --clients-dir=*)
      VPN_CLIENTS_DIR="${1#*=}"
      shift
      ;;
    --staging)
      VPN_CERTBOT_STAGING=1
      shift
      ;;
    --skip-certbot)
      VPN_SKIP_CERTBOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$VPN_DOMAIN" ]] || die "Missing --domain or VPN_DOMAIN."
[[ -n "$VPN_IPV6" ]] || die "Missing --ipv6 or VPN_IPV6."

require_root
require_ubuntu
require_cmd python3 ip

validate_domain "$VPN_DOMAIN"
VPN_IPV6="$(normalize_ipv6 "$VPN_IPV6")"
validate_country "$VPN_CA_COUNTRY"
validate_org "$VPN_CA_ORG"
VPN_CA_CN="${VPN_CA_ORG} VPN Client CA"
VPN_CA_SUBJECT="C=${VPN_CA_COUNTRY}, O=${VPN_CA_ORG}, CN=${VPN_CA_CN}"
VPN_POOL_V4="$(normalize_network "$VPN_POOL_V4" ipv4)"
VPN_POOL_V6="$(normalize_network "$VPN_POOL_V6" ipv6)"
VPN_DNS="${VPN_DNS// /}"
validate_dns_list "$VPN_DNS"
[[ "$VPN_CLIENTS_DIR" == /* ]] || die "--clients-dir must be an absolute path."
if [[ -n "$VPN_INTERFACE" ]]; then
  [[ "$VPN_INTERFACE" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid interface name: ${VPN_INTERFACE}"
  ip link show "$VPN_INTERFACE" >/dev/null 2>&1 || die "Interface not found: ${VPN_INTERFACE}"
fi
if [[ -n "$VPN_EMAIL" && ! "$VPN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
  die "Invalid email address: ${VPN_EMAIL}"
fi

VPN_INTERFACE="$(find_ipv6_iface "$VPN_IPV6" "$VPN_INTERFACE")"
log "Using outbound interface ${VPN_INTERFACE} for ${VPN_IPV6}."

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log "Installing packages."
apt-get update
if command -v debconf-set-selections >/dev/null 2>&1; then
  debconf-set-selections <<'EOF'
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
fi
packages=(
  certbot
  strongswan
  strongswan-pki
  strongswan-starter
  libcharon-extra-plugins
  libcharon-extauth-plugins
  iptables-persistent
  uuid-runtime
  openssl
  python3
  iptables
  iproute2
)
if apt-cache show strongswan-libcharon >/dev/null 2>&1; then
  packages+=(strongswan-libcharon)
fi
apt-get install -y "${packages[@]}"
require_cmd openssl certbot ipsec uuidgen python3
if apt-cache show "linux-modules-extra-$(uname -r)" >/dev/null 2>&1; then
  apt-get install -y "linux-modules-extra-$(uname -r)" || log "WARNING: Could not install linux-modules-extra. Continuing."
fi

log "Enabling IPv4 and IPv6 forwarding."
cat >/etc/sysctl.d/99-ikev2-vpn.conf <<'EOF'
# managed-by: ikev2-vpn-installer
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF
sysctl --system >/dev/null

log "Loading IPsec kernel modules."
modules=(esp4 esp6 xfrm_user xfrm_algo af_key authenc cryptd crypto_user aes sha256 sha512 gcm cbc ip6table_nat nf_nat)
for mod_name in "${modules[@]}"; do
  if modprobe "$mod_name" 2>/dev/null; then
    log "Loaded kernel module ${mod_name}."
  else
    log "WARNING: Kernel module ${mod_name} is not available. It may already be built in."
  fi
done
for mod_name in esp4 esp6 xfrm_user xfrm_algo authenc; do
  if [[ -f /etc/modules ]] && grep -qxF "$mod_name" /etc/modules; then
    continue
  fi
  printf '%s\n' "$mod_name" >>/etc/modules
done

create_client_ca
save_config
mkdir -p "$VPN_CLIENTS_DIR"
chmod 700 "$VPN_CLIENTS_DIR"

backup_unmanaged() {
  local path="$1"
  if [[ -f "$path" ]] && ! grep -q "$MANAGED_MARK" "$path"; then
    cp -a "$path" "${path}.bak.$(date +%Y%m%d%H%M%S)"
    log "Backed up unmanaged ${path}."
  fi
}

backup_unmanaged /etc/ipsec.conf
backup_unmanaged /etc/ipsec.secrets
write_ipsec_conf /etc/ipsec.conf

install_runtime_files() {
  local lib_dir="/usr/local/lib/ikev2-vpn"
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  install -d -m 755 "$lib_dir" "$hook_dir"
  install -m 644 "${SCRIPT_DIR}/lib/common.sh" "${lib_dir}/common.sh"
  install -m 644 "${SCRIPT_DIR}/lib/certs.sh" "${lib_dir}/certs.sh"
  install -m 755 "${SCRIPT_DIR}/scripts/certbot-deploy.sh" "${hook_dir}/ikev2-vpn"
}

install_runtime_files

if [[ "$VPN_SKIP_CERTBOT" == "1" ]]; then
  log "Skipping certbot because --skip-certbot was set."
else
  live="/etc/letsencrypt/live/${VPN_DOMAIN}/cert.pem"
  if [[ "$VPN_CERTBOT_STAGING" == "1" && -f "$live" ]]; then
    issuer="$(openssl x509 -in "$live" -noout -issuer)"
    if ! grep -qi staging <<<"$issuer"; then
      die "A production certificate already exists. Refusing --staging."
    fi
  fi
  log "Requesting a Let's Encrypt certificate for ${VPN_DOMAIN}."
  certbot_args=(
    certbot certonly --standalone --non-interactive --agree-tos
    --domain "$VPN_DOMAIN"
    --key-type ecdsa
    --elliptic-curve secp256r1
    --keep-until-expiring
  )
  if [[ "$VPN_CERTBOT_STAGING" == "1" ]]; then
    certbot_args+=(--staging)
  fi
  if [[ -n "$VPN_EMAIL" ]]; then
    certbot_args+=(--email "$VPN_EMAIL")
  else
    certbot_args+=(--register-unsafely-without-email)
    log "WARNING: No --email given. Registering with Let's Encrypt without an email address."
  fi
  "${certbot_args[@]}"
fi

sync_server_cert
write_ipsec_secrets /etc/ipsec.secrets "$VPN_SERVER_KEY_TYPE"

ensure_rule() {
  local bin="$1"
  local table="$2"
  shift 2
  if ! "$bin" -t "$table" -C "$@" 2>/dev/null; then
    "$bin" -t "$table" -A "$@"
  fi
}

log "Installing firewall rules on ${VPN_INTERFACE}."
ensure_rule iptables filter INPUT -p udp --dport 500 -j ACCEPT
ensure_rule iptables filter INPUT -p udp --dport 4500 -j ACCEPT
ensure_rule iptables filter FORWARD -m policy --pol ipsec --dir in -j ACCEPT
ensure_rule iptables filter FORWARD -m policy --pol ipsec --dir out -j ACCEPT
ensure_rule iptables nat POSTROUTING -s "$VPN_POOL_V4" -o "$VPN_INTERFACE" -j MASQUERADE
ensure_rule iptables mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ensure_rule ip6tables filter INPUT -p udp --dport 500 -j ACCEPT
ensure_rule ip6tables filter INPUT -p udp --dport 4500 -j ACCEPT
ensure_rule ip6tables filter FORWARD -m policy --pol ipsec --dir in -j ACCEPT
ensure_rule ip6tables filter FORWARD -m policy --pol ipsec --dir out -j ACCEPT
ensure_rule ip6tables nat POSTROUTING -s "$VPN_POOL_V6" -o "$VPN_INTERFACE" -j MASQUERADE
ensure_rule ip6tables mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
  systemctl enable netfilter-persistent >/dev/null 2>&1 || true
fi

restart_strongswan
sleep 1
if journalctl -u strongswan-starter -u strongswan -u charon --no-pager -n 120 | grep -Eiq "loaded (ECDSA|RSA) private key"; then
  log "StrongSwan loaded the server private key."
else
  journalctl -u strongswan-starter -u strongswan -u charon --no-pager -n 40 >&2 || true
  die "StrongSwan did not log a loaded server private key."
fi
if ! ipsec statusall | grep -q "ikev2-cert"; then
  die "StrongSwan did not load connection ikev2-cert."
fi

cat <<EOF

IKEv2 VPN is installed.
  Domain:          ${VPN_DOMAIN}
  IPv6:            ${VPN_IPV6}
  Interface:       ${VPN_INTERFACE}
  Client CA:       ${VPN_CA_SUBJECT}
  IPv4 pool:       ${VPN_POOL_V4}
  IPv6 pool:       ${VPN_POOL_V6}
  Client files:    ${VPN_CLIENTS_DIR}

Issue a client certificate with:
  sudo ${SCRIPT_DIR}/issue-client.sh <name>
EOF
