#!/usr/bin/env bash
# Subcommands for the swangate command.
# shellcheck disable=SC2034  # Globals are shared across the sourced libraries.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

IKEV2_PREFIX="${IKEV2_PREFIX:-/usr/local/lib/swangate}"
IKEV2_BIN="${IKEV2_BIN:-/usr/local/bin/swangate}"
IKEV2_REPO="${IKEV2_REPO:-alphajc/swangate}"
IKEV2_REF="${IKEV2_REF:-main}"
IKEV2_TARBALL_URL="${IKEV2_TARBALL_URL:-}"
RENEW_HOOK="${LETSENCRYPT_DIR}/renewal-hooks/deploy/ikev2-vpn"

usage_main() {
  cat <<'EOF'
Usage: swangate <command> [options]

Commands:
  install   Install or reconfigure the IPv6 IKEv2 VPN server
  update    Download the latest swangate and re-apply saved settings
  issue     Issue a client certificate
  revoke    Revoke a client certificate
  status    Show server, firewall, and client status
  help      Show this help

Run 'swangate <command> --help' for the options of a command.
EOF
}

usage_install() {
  cat <<'EOF'
Usage: swangate install [--domain NAME] [options]

Install StrongSwan IKEv2 with a Let's Encrypt server certificate and a local
CA for client certificates. Safe to run again.

On a terminal, missing --domain / --email are prompted interactively.
Non-interactive runs still need --domain (or VPN_DOMAIN).

Options:
  --domain NAME          VPN hostname, already pointed at this server
  --ipv6 ADDRESS         IPv6 address already configured on this server
                         (default: detect from DNS AAAA or the host)
  --email ADDRESS        Let's Encrypt contact email (optional)
  --interface NAME       Outbound interface for NAT (default: the interface
                         that owns the chosen IPv6)
  --ca-country CC        Client CA country (default: CN)
  --ca-org NAME          Client CA organization (default: IKEv2)
  --pool-v4 CIDR         IPv4 virtual pool (default: 10.10.10.0/24)
  --pool-v6 CIDR         IPv6 virtual pool (default: fd00:10:10::/64)
  --dns LIST             Comma-separated DNS servers pushed to clients
  --clients-dir PATH     Where client files are written (default: /root/vpn-clients)
  --backend NAME         auto, ipsec, or swanctl (default: auto)
  --firewall NAME        auto, firewalld, iptables, or nftables (default: auto)
  --dataplane NAME       auto, kernel, or libipsec (default: auto)
  --staging              Use the Let's Encrypt staging server
  --skip-certbot         Do not run certbot; reuse an existing certificate
  -h, --help             Show this help

Environment variables (flags override them):
  VPN_DOMAIN VPN_IPV6 VPN_EMAIL VPN_INTERFACE VPN_CA_COUNTRY VPN_CA_ORG
  VPN_POOL_V4 VPN_POOL_V6 VPN_DNS VPN_CLIENTS_DIR
EOF
}

# Read missing install inputs from stdin. Called only when stdin is a TTY.
prompt_install_inputs() {
  local reply
  if [[ -z "${VPN_DOMAIN:-}" ]]; then
    printf 'VPN domain (AAAA must point at this server): ' >&2
    IFS= read -r reply || true
    VPN_DOMAIN="${reply}"
  fi
  if [[ -z "${VPN_EMAIL:-}" ]]; then
    printf "Let's Encrypt email (optional, Enter to skip): " >&2
    IFS= read -r reply || true
    VPN_EMAIL="${reply}"
  fi
}

usage_issue() {
  cat <<'EOF'
Usage: swangate issue [--force] NAME

Issue a client certificate signed by the local VPN CA and write:
  NAME.crt NAME.key NAME.p12 NAME.mobileconfig ca.crt connection.txt

The PKCS#12 password is random and is printed here. It is also embedded
in the Apple profile so iOS and macOS can import it.

  --force    Revoke the existing certificate for NAME and issue a new one
  -h, --help Show this help
EOF
}

usage_revoke() {
  cat <<'EOF'
Usage: swangate revoke NAME

Revoke the client certificate for NAME, publish a CRL, and restart
StrongSwan so the certificate is rejected immediately.
EOF
}

usage_status() {
  cat <<'EOF'
Usage: swangate status

Show the StrongSwan service, loaded connection, server certificate,
dataplane, firewall, and issued client certificates.
EOF
}

usage_update() {
  cat <<'EOF'
Usage: swangate update [options]

Download the latest swangate release, replace /usr/local/lib/swangate,
and re-apply the VPN configuration saved by the last install.

On a host that still runs an older swangate without this command:
  curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash -s -- update

Options:
  --ref REF            Git ref to download (default: main, or IKEV2_REF)
  --skip-self          Do not download; only re-apply config with current code
  --reissue-clients    Re-issue profiles for every non-revoked client
  -h, --help           Show this help

Environment:
  IKEV2_REPO IKEV2_REF IKEV2_TARBALL_URL IKEV2_PREFIX IKEV2_BIN
EOF
}

# Reads "--name value" or "--name=value" into OPT_VALUE and sets OPT_SHIFT.
take_value() {
  local opt="$1"
  local inline="$2"
  local next="${3-}"
  local has_next="$4"
  if [[ -n "$inline" ]]; then
    OPT_VALUE="${inline#=}"
    OPT_SHIFT=1
  else
    [[ "$has_next" -eq 1 ]] || die "Missing value for ${opt}"
    OPT_VALUE="$next"
    OPT_SHIFT=2
  fi
}

load_runtime() {
  load_config
  SERVICE_MANAGER="$VPN_SERVICE_MANAGER"
  set_swan_paths "$VPN_BACKEND" "$VPN_SWAN_ETC"
}

self_install() {
  local src dest
  src="$(cd "$IKEV2_HOME" && pwd -P)"
  mkdir -p "$IKEV2_PREFIX"
  dest="$(cd "$IKEV2_PREFIX" && pwd -P)"
  if [[ "$src" != "$dest" ]]; then
    install -d -m 755 "${IKEV2_PREFIX}/lib"
    install -m 755 "${IKEV2_HOME}/swangate" "${IKEV2_PREFIX}/swangate"
    install -m 644 "${IKEV2_HOME}"/lib/*.sh "${IKEV2_PREFIX}/lib/"
  fi
  install -d -m 755 "$(dirname "$IKEV2_BIN")"
  ln -sfn "${IKEV2_PREFIX}/swangate" "$IKEV2_BIN"
  if [[ -f /usr/local/lib/ikev2-vpn/certs.sh ]]; then
    rm -rf /usr/local/lib/ikev2-vpn
  fi
}

# True when this process is running the installed /usr/local copy (not a git tree).
running_from_prefix() {
  local current installed bin
  current="$(readlink -f "$IKEV2_SELF")"
  installed="$(readlink -f "${IKEV2_PREFIX}/swangate" 2>/dev/null || true)"
  bin="$(readlink -f "$IKEV2_BIN" 2>/dev/null || true)"
  [[ -n "$installed" && "$current" == "$installed" ]] && return 0
  [[ -n "$bin" && "$current" == "$bin" ]] && return 0
  return 1
}

# Atomically install swangate files from a source tree into IKEV2_PREFIX.
install_tree_to_prefix() {
  local src="$1"
  [[ -f "${src}/swangate" && -f "${src}/lib/commands.sh" ]] \
    || die "Source tree is missing swangate or lib/commands.sh: ${src}"
  rm -rf "${IKEV2_PREFIX}.new"
  install -d -m 755 "${IKEV2_PREFIX}.new/lib"
  install -m 755 "${src}/swangate" "${IKEV2_PREFIX}.new/swangate"
  install -m 644 "${src}"/lib/*.sh "${IKEV2_PREFIX}.new/lib/"
  rm -rf "$IKEV2_PREFIX"
  mv "${IKEV2_PREFIX}.new" "$IKEV2_PREFIX"
  install -d -m 755 "$(dirname "$IKEV2_BIN")"
  ln -sfn "${IKEV2_PREFIX}/swangate" "$IKEV2_BIN"
  if [[ -f /usr/local/lib/ikev2-vpn/certs.sh ]]; then
    rm -rf /usr/local/lib/ikev2-vpn
  fi
  log "Installed ${IKEV2_BIN}"
}

# Download a release tarball and install it into IKEV2_PREFIX.
fetch_and_install_release() {
  local ref="${1:-$IKEV2_REF}"
  local url work src
  url="${IKEV2_TARBALL_URL:-https://codeload.github.com/${IKEV2_REPO}/tar.gz/${ref}}"
  command -v tar >/dev/null 2>&1 || die "tar is required to update swangate."
  command -v gzip >/dev/null 2>&1 || die "gzip is required to update swangate."
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  log "Downloading ${url}"
  if have_cmd curl; then
    curl -fsSL --retry 3 -o "${work}/swangate.tar.gz" "$url" || die "Download failed: ${url}"
  elif have_cmd wget; then
    wget -q -O "${work}/swangate.tar.gz" "$url" || die "Download failed: ${url}"
  else
    die "curl or wget is required to update swangate."
  fi
  mkdir -p "${work}/src"
  tar -xzf "${work}/swangate.tar.gz" -C "${work}/src" || die "The downloaded archive is not a valid tarball."
  src="$(find "${work}/src" -maxdepth 2 -type f -name swangate | head -n 1)"
  [[ -n "$src" ]] || die "The archive does not contain the swangate command."
  src="$(dirname "$src")"
  install_tree_to_prefix "$src"
  trap - RETURN
  rm -rf "$work"
}

# Prints sysctl settings. $1 is the outbound interface (dots become slashes).
# $2 is yes to enable BBR. $3 is yes to raise conntrack limits.
sysctl_settings() {
  local iface="$1"
  local bbr="${2:-no}"
  local conntrack="${3:-no}"
  local sysctl_iface="${iface//./\/}"
  cat <<EOF
# ${MANAGED_MARK}
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 12582912
net.core.wmem_max = 12582912
net.ipv4.tcp_rmem = 10240 87380 12582912
net.ipv4.tcp_wmem = 10240 87380 12582912
EOF
  if [[ -n "$sysctl_iface" ]]; then
    cat <<EOF
net.ipv4.conf.${sysctl_iface}.rp_filter = 0
net.ipv4.conf.${sysctl_iface}.send_redirects = 0
net.ipv6.conf.${sysctl_iface}.forwarding = 1
net.ipv6.conf.${sysctl_iface}.accept_ra = 2
EOF
  fi
  if [[ "$bbr" == "yes" ]]; then
    cat <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  fi
  if [[ "$conntrack" == "yes" ]]; then
    cat <<EOF
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 300
EOF
  fi
}

# True when this kernel can use BBR. tcp_bbr is loaded earlier, when it exists.
kernel_supports_bbr() {
  [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] || return 1
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] || return 1
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control
}

# True when conntrack sysctls are present. They appear only after nf_conntrack loads.
kernel_has_conntrack() {
  [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] \
    && [[ -e /proc/sys/net/netfilter/nf_conntrack_udp_timeout ]] \
    && [[ -e /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream ]]
}

write_sysctl() {
  local file=/etc/sysctl.d/99-ikev2-vpn.conf
  local bbr=no conntrack=no
  kernel_supports_bbr && bbr=yes
  kernel_has_conntrack && conntrack=yes
  mkdir -p /etc/sysctl.d
  sysctl_settings "$VPN_INTERFACE" "$bbr" "$conntrack" >"$file"
  chmod 644 "$file"
  # -e skips keys this kernel does not have, same approach as setup-ipsec-vpn.
  sysctl -e -q -p "$file" || warn "Some kernel settings in ${file} were not applied."
}

install_renew_hook() {
  mkdir -p "$(dirname "$RENEW_HOOK")"
  cat >"$RENEW_HOOK" <<EOF
#!/bin/sh
# ${MANAGED_MARK}
exec ${IKEV2_BIN} renew-hook
EOF
  chmod 755 "$RENEW_HOOK"
}

server_cert_is_current() {
  local live="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}"
  [[ -f "${live}/cert.pem" && -f "${live}/privkey.pem" && -f "${live}/chain.pem" ]] || return 1
  openssl x509 -in "${live}/cert.pem" -noout -checkend 2592000 >/dev/null 2>&1
}

warn_dns_mismatch() {
  local addrs
  have_cmd getent || return 0
  addrs="$(domain_aaaa_addrs "$VPN_DOMAIN")"
  if [[ -z "$addrs" ]]; then
    warn "${VPN_DOMAIN} has no AAAA record visible from this server. Let's Encrypt and IPv6 clients need one."
    return 0
  fi
  local addr
  while read -r addr; do
    [[ "$addr" == "$VPN_IPV6" ]] && return 0
  done <<<"$addrs"
  warn "${VPN_DOMAIN} resolves to $(tr '\n' ' ' <<<"$addrs")but not to ${VPN_IPV6}. Continuing."
}

run_certbot() {
  local live="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}/cert.pem"
  local -a args
  if [[ "$VPN_CERTBOT_STAGING" == "1" && -f "$live" ]] \
    && ! openssl x509 -in "$live" -noout -issuer | grep -qi staging; then
    die "A production certificate already exists. Refusing --staging."
  fi
  args=("$CERTBOT_BIN" certonly --standalone --non-interactive --agree-tos
    --preferred-challenges http --domain "$VPN_DOMAIN" --keep-until-expiring)
  if "$CERTBOT_BIN" --help all 2>/dev/null | grep -q -- '--key-type'; then
    args+=(--key-type ecdsa --elliptic-curve secp256r1)
  fi
  [[ "$VPN_CERTBOT_STAGING" == "1" ]] && args+=(--staging)
  if [[ -n "$VPN_EMAIL" ]]; then
    args+=(--email "$VPN_EMAIL")
  else
    args+=(--register-unsafely-without-email)
    warn "No --email given. Registering with Let's Encrypt without an email address."
  fi
  log "Requesting a Let's Encrypt certificate for ${VPN_DOMAIN}."
  firewall_http_open
  trap firewall_http_close EXIT
  "${args[@]}"
  firewall_http_close
  trap - EXIT
}

cmd_install() {
  local backend_arg="auto" firewall_arg="auto" dataplane_arg="auto"
  local opt inline has_next need_fw need_cert
  VPN_DOMAIN="${VPN_DOMAIN:-}"
  VPN_IPV6="${VPN_IPV6:-}"
  VPN_EMAIL="${VPN_EMAIL:-}"
  VPN_INTERFACE="${VPN_INTERFACE:-}"
  VPN_CA_COUNTRY="${VPN_CA_COUNTRY:-CN}"
  VPN_CA_ORG="${VPN_CA_ORG:-IKEv2}"
  VPN_POOL_V4="${VPN_POOL_V4:-10.10.10.0/24}"
  VPN_POOL_V6="${VPN_POOL_V6:-fd00:10:10::/64}"
  # Prefer one IPv4 + one IPv6 DNS. Extra CPRP DNS attributes inflate IKE_AUTH
  # and push mobile IPv6 responses over the IKE fragmentation threshold.
  VPN_DNS="${VPN_DNS:-1.1.1.1,2606:4700:4700::1111}"
  VPN_CLIENTS_DIR="${VPN_CLIENTS_DIR:-/root/vpn-clients}"
  VPN_CERTBOT_STAGING="${VPN_CERTBOT_STAGING:-0}"
  VPN_SKIP_CERTBOT="${VPN_SKIP_CERTBOT:-0}"

  while [[ $# -gt 0 ]]; do
    opt="${1%%=*}"
    inline=""
    [[ "$1" == *=* ]] && inline="=${1#*=}"
    has_next=0
    [[ $# -ge 2 ]] && has_next=1
    case "$opt" in
      -h|--help)
        usage_install
        return 0
        ;;
      --staging)
        VPN_CERTBOT_STAGING=1
        shift
        continue
        ;;
      --skip-certbot)
        VPN_SKIP_CERTBOT=1
        shift
        continue
        ;;
      --domain|--ipv6|--email|--interface|--ca-country|--ca-org|--pool-v4|--pool-v6|--dns|--clients-dir|--backend|--firewall|--dataplane)
        take_value "$opt" "$inline" "${2-}" "$has_next"
        ;;
      *)
        die "Unknown option for install: $1. Run 'swangate install --help'."
        ;;
    esac
    case "$opt" in
      --domain) VPN_DOMAIN="$OPT_VALUE" ;;
      --ipv6) VPN_IPV6="$OPT_VALUE" ;;
      --email) VPN_EMAIL="$OPT_VALUE" ;;
      --interface) VPN_INTERFACE="$OPT_VALUE" ;;
      --ca-country) VPN_CA_COUNTRY="$OPT_VALUE" ;;
      --ca-org) VPN_CA_ORG="$OPT_VALUE" ;;
      --pool-v4) VPN_POOL_V4="$OPT_VALUE" ;;
      --pool-v6) VPN_POOL_V6="$OPT_VALUE" ;;
      --dns) VPN_DNS="$OPT_VALUE" ;;
      --clients-dir) VPN_CLIENTS_DIR="$OPT_VALUE" ;;
      --backend) backend_arg="$OPT_VALUE" ;;
      --firewall) firewall_arg="$OPT_VALUE" ;;
      --dataplane) dataplane_arg="$OPT_VALUE" ;;
    esac
    shift "$OPT_SHIFT"
  done

  # update (and other non-interactive callers) set VPN_ASSUME_DEFAULTS=1 so an
  # empty optional --email does not block on a TTY prompt.
  if [[ "${VPN_ASSUME_DEFAULTS:-0}" != "1" ]] \
    && { [[ -z "$VPN_DOMAIN" ]] || [[ -z "$VPN_EMAIL" ]]; } \
    && [[ -t 0 ]]; then
    prompt_install_inputs
  fi
  [[ -n "$VPN_DOMAIN" ]] || die "Missing --domain. Pass --domain or run 'swangate install' in a terminal."
  case "$backend_arg" in auto|ipsec|swanctl) ;; *) die "Unknown --backend: ${backend_arg}" ;; esac
  case "$firewall_arg" in auto|firewalld|iptables|nftables) ;; *) die "Unknown --firewall: ${firewall_arg}" ;; esac
  case "$dataplane_arg" in auto|kernel|libipsec) ;; *) die "Unknown --dataplane: ${dataplane_arg}" ;; esac

  require_root
  detect_distro
  detect_pkg_manager
  detect_service_manager
  ensure_python
  if ! have_cmd ip; then
    pkg_refresh
    case "$DISTRO_FAMILY" in
      rhel) pkg_install iproute ;;
      *) pkg_install iproute2 ;;
    esac
  fi
  require_cmd ip

  validate_domain "$VPN_DOMAIN"
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
  if [[ -n "$VPN_IPV6" ]]; then
    VPN_IPV6="$(normalize_ipv6 "$VPN_IPV6")"
  else
    VPN_IPV6="$(detect_server_ipv6 "$VPN_INTERFACE")"
    log "Detected IPv6 ${VPN_IPV6}."
  fi
  VPN_INTERFACE="$(find_ipv6_iface "$VPN_IPV6" "$VPN_INTERFACE")"
  log "Using outbound interface ${VPN_INTERFACE} for ${VPN_IPV6}."

  need_cert=1
  if [[ "$VPN_SKIP_CERTBOT" == "1" ]]; then
    need_cert=0
  elif have_cmd openssl && server_cert_is_current; then
    need_cert=0
    log "The Let's Encrypt certificate for ${VPN_DOMAIN} is valid for more than 30 days. Skipping certbot."
  fi
  if [[ "$need_cert" -eq 1 ]]; then
    if tcp_port_in_use 80; then
      die "Port 80/tcp is in use ($(port_owner 80)). Stop that service so certbot can answer the HTTP challenge, or rerun with --skip-certbot if ${LETSENCRYPT_DIR}/live/${VPN_DOMAIN} already holds a certificate."
    fi
    warn_dns_mismatch
  fi

  need_fw=1
  if [[ "$firewall_arg" == "firewalld" ]] || { [[ "$firewall_arg" == "auto" ]] && firewalld_running; }; then
    need_fw=0
  fi
  install_packages "$need_fw"
  select_backend "$backend_arg"
  select_firewall "$firewall_arg"
  load_kernel_modules
  select_dataplane "$dataplane_arg"
  [[ "$need_cert" -eq 1 ]] && resolve_certbot

  VPN_DISTRO_FAMILY="$DISTRO_FAMILY"
  VPN_DISTRO_ID="$DISTRO_ID"
  VPN_PKG_MANAGER="$PKG_MANAGER"
  VPN_SERVICE_MANAGER="$SERVICE_MANAGER"
  VPN_SWAN_ETC="$(detect_swan_etc)"
  set_swan_paths "$VPN_BACKEND" "$VPN_SWAN_ETC"

  write_sysctl
  self_install
  create_client_ca
  publish_client_ca
  write_libipsec_conf "$STRONGSWAN_D" "$VPN_DATAPLANE"
  if [[ -n "${OTHER_SWAN_SERVICE:-}" ]]; then
    svc_disable_stop "$OTHER_SWAN_SERVICE"
    log "Disabled ${OTHER_SWAN_SERVICE} so only ${VPN_SERVICE} runs."
  fi
  firewall_apply
  install_firewall_boot_hook "$IKEV2_BIN"

  if [[ "$need_cert" -eq 1 ]]; then
    run_certbot
  fi
  sync_server_cert
  write_swan_config
  publish_crl
  install_renew_hook
  save_config
  mkdir -p "$VPN_CLIENTS_DIR"
  chmod 700 "$VPN_CLIENTS_DIR"

  restart_strongswan
  verify_strongswan

  cat <<EOF

IKEv2 VPN is installed.
  Distribution:    ${DISTRO_NAME}
  Domain:          ${VPN_DOMAIN}
  IPv6:            ${VPN_IPV6}
  Interface:       ${VPN_INTERFACE}
  StrongSwan:      ${VPN_BACKEND} (${VPN_SERVICE})
  Dataplane:       ${VPN_DATAPLANE}
  Firewall:        ${VPN_FIREWALL}
  Client CA:       ${VPN_CA_SUBJECT}
  IPv4 pool:       ${VPN_POOL_V4}
  IPv6 pool:       ${VPN_POOL_V6}
  Client files:    ${VPN_CLIENTS_DIR}

Issue a client certificate with:
  sudo swangate issue <name>
EOF
}

cmd_issue() {
  local force=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      -h|--help) usage_issue; return 0 ;;
      -*) die "Unknown option for issue: $1" ;;
      *)
        [[ -z "$name" ]] || die "Unexpected argument: $1"
        name="$1"
        ;;
    esac
    shift
  done
  [[ -n "$name" ]] || die "Missing client name. Usage: sudo swangate issue <name>"

  require_root
  require_cmd openssl python3
  validate_client_name "$name"
  load_runtime
  [[ -f "$CA_CRT_PATH" && -f "$CA_KEY_PATH" ]] || die "Client CA is missing. Run 'swangate install' first."
  [[ -f "$OPENSSL_CNF" ]] || die "Missing ${OPENSSL_CNF}. Run 'swangate install' first."

  local work_dir="${VPN_CLIENTS_DIR}/${name}"
  local key="${work_dir}/${name}.key"
  local crt="${work_dir}/${name}.crt"
  local p12="${work_dir}/${name}.p12"
  local raw="${work_dir}/${name}.raw.mobileconfig"
  local profile="${work_dir}/${name}.mobileconfig"
  local ca_copy="${work_dir}/ca.crt"
  local note="${work_dir}/connection.txt"
  if [[ -f "$crt" ]]; then
    if [[ "$force" -ne 1 ]]; then
      die "Client ${name} already exists at ${work_dir}. Run again with --force to revoke and reissue."
    fi
    log "Revoking the previous certificate for ${name}."
    revoke_certificate "$crt"
  fi

  mkdir -p "$work_dir"
  chmod 700 "$work_dir"
  rm -f "${work_dir}/REVOKED"
  log "Issuing client certificate for ${name}."
  issue_client_cert "$name" "$work_dir"

  local p12_pass old_umask
  p12_pass="$(openssl rand -hex 12)"
  old_umask="$(umask)"
  umask 077
  openssl pkcs12 -export \
    -inkey "$key" \
    -in "$crt" \
    -certfile "$CA_CRT_PATH" \
    -out "$p12" \
    -name "$name" \
    -passout "pass:${p12_pass}"
  umask "$old_umask"
  chmod 600 "$p12" "$key"
  install -m 644 "$CA_CRT_PATH" "$ca_copy"

  local p12_b64 cert_type issuer_cn server_cn
  p12_b64="$(base64 "$p12" | tr -d '\r\n')"
  # CertificateType is the client cert in PayloadCertificateUUID (RSA here).
  cert_type="$(apple_certificate_type "$crt")"
  issuer_cn=""
  server_cn="$VPN_DOMAIN"
  if [[ -f "$SERVER_CRT" ]]; then
    issuer_cn="$(cert_common_name "$SERVER_CRT" issuer)"
    server_cn="$(cert_common_name "$SERVER_CRT" subject)"
  fi
  write_mobileconfig_xml "$raw" "$name" "$VPN_DOMAIN" "$p12_pass" "$p12_b64" \
    "$(new_uuid)" "$(new_uuid)" "$(new_uuid)" "$cert_type" "$issuer_cn" "$server_cn"

  local signer="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}/cert.pem"
  local inkey="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}/privkey.pem"
  local chain="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}/chain.pem"
  if [[ ! -f "$signer" || ! -f "$inkey" ]]; then
    signer="$SERVER_CRT"
    inkey="$SERVER_KEY"
    chain="$SERVER_CHAIN"
  fi
  if [[ -f "$signer" && -f "$inkey" ]]; then
    sign_mobileconfig "$raw" "$profile" "$signer" "$inkey" "$chain"
    rm -f "$raw"
    log "Signed the Apple profile."
  else
    mv "$raw" "$profile"
    warn "Server certificate was not found. Wrote an unsigned Apple profile."
  fi
  chmod 600 "$profile"
  chmod 644 "$crt"

  cat >"$note" <<EOF
IKEv2 client ${name}
Server: ${VPN_DOMAIN}
Remote ID: ${VPN_DOMAIN}
Local ID: ${name}
Authentication: certificate
CA subject: ${VPN_CA_SUBJECT}
PKCS#12 password: ${p12_pass}

Files:
  Certificate: ${crt}
  Private key: ${key}
  PKCS#12: ${p12}
  CA certificate: ${ca_copy}
  Apple profile: ${profile}

iOS and macOS: open the .mobileconfig profile in Safari or AirDrop.
Windows: import the .p12 into the computer store, then add an IKEv2 VPN with certificate authentication.
Android: use the strongSwan app, IKEv2 certificate, select the .p12, and import ca.crt if asked.
EOF
  chmod 600 "$note"

  cat <<EOF
Client certificate issued.
  Name:              ${name}
  Directory:         ${work_dir}
  Certificate:       ${crt}
  Private key:       ${key}
  PKCS#12:           ${p12}
  PKCS#12 password:  ${p12_pass}
  CA certificate:    ${ca_copy}
  Apple profile:     ${profile}
  Notes:             ${note}
EOF
}

cmd_revoke() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage_revoke; return 0 ;;
      -*) die "Unknown option for revoke: $1" ;;
      *)
        [[ -z "$name" ]] || die "Unexpected argument: $1"
        name="$1"
        ;;
    esac
    shift
  done
  [[ -n "$name" ]] || die "Missing client name. Usage: sudo swangate revoke <name>"

  require_root
  require_cmd openssl
  validate_client_name "$name"
  load_runtime

  local crt="${VPN_CLIENTS_DIR}/${name}/${name}.crt"
  [[ -f "$crt" ]] || die "No certificate for ${name} at ${crt}"
  revoke_certificate "$crt"
  printf 'Revoked at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${VPN_CLIENTS_DIR}/${name}/REVOKED"

  cat <<EOF
Client certificate revoked.
  Name:        ${name}
  Certificate: ${crt}
  CRL:         ${CRL_PATH}
EOF
}

cmd_status() {
  case "${1:-}" in
    -h|--help) usage_status; return 0 ;;
    "") ;;
    *) die "Unknown option for status: $1" ;;
  esac
  require_root
  load_runtime

  local active="inactive" loaded="not loaded" listing key_type="missing" expiry="unknown"
  local sas=0 crl="missing"
  if [[ -n "${VPN_SERVICE:-}" ]] && svc_is_active "$VPN_SERVICE"; then
    active="running"
  fi
  listing="$(swan_listing || true)"
  grep -q 'ikev2-cert' <<<"$listing" && loaded="loaded"
  [[ -f "$SERVER_KEY" ]] && key_type="$(detect_key_type "$SERVER_KEY")"
  if [[ -f "$SERVER_CRT" ]]; then
    expiry="$(openssl x509 -in "$SERVER_CRT" -noout -enddate | cut -d= -f2)"
  fi
  case "$VPN_BACKEND" in
    swanctl) sas="$(swanctl --list-sas 2>/dev/null | grep -c 'ESTABLISHED' || true)" ;;
    ipsec) sas="$("$(ipsec_command)" status 2>/dev/null | grep -c 'ESTABLISHED' || true)" ;;
  esac
  [[ -f "$CRL_PATH" ]] && crl="$CRL_PATH"

  cat <<EOF
IKEv2 VPN status
  Distribution:    ${VPN_DISTRO_ID:-unknown} (${VPN_DISTRO_FAMILY:-unknown})
  Domain:          ${VPN_DOMAIN}
  IPv6:            ${VPN_IPV6}
  Interface:       ${VPN_INTERFACE}
  StrongSwan:      ${VPN_BACKEND} (${VPN_SERVICE:-unknown}) ${active}
  Connection:      ikev2-cert ${loaded}
  Server key:      ${key_type}
  Server cert:     expires ${expiry}
  Dataplane:       ${VPN_DATAPLANE}
  Firewall:        ${VPN_FIREWALL}
  Established SAs: ${sas}
  CRL:             ${crl}
  Client files:    ${VPN_CLIENTS_DIR}
Clients:
EOF
  local clients
  clients="$(list_issued_clients)"
  if [[ -z "$clients" ]]; then
    printf '  none\n'
  else
    awk '{printf "  %-24s %s\n", $2, $1}' <<<"$clients"
  fi
}

cmd_firewall_apply() {
  require_root
  load_runtime
  firewall_apply
}

cmd_renew_hook() {
  local domain matched=0
  require_root
  [[ -f "$(config_file)" ]] || exit 0
  load_runtime
  if [[ -n "${RENEWED_DOMAINS:-}" ]]; then
    for domain in $RENEWED_DOMAINS; do
      [[ "$domain" == "$VPN_DOMAIN" ]] && matched=1
    done
    [[ "$matched" -eq 1 ]] || exit 0
  fi
  log "Let's Encrypt certificate renewed for ${VPN_DOMAIN}. Updating StrongSwan."
  sync_server_cert
  write_swan_config
  restart_strongswan
}

# Re-issue Apple/Windows client files for every non-revoked certificate.
reissue_valid_clients() {
  local status name serial count=0
  while read -r status name serial; do
    [[ "$status" == "valid" ]] || continue
    [[ -n "$name" ]] || continue
    log "Re-issuing client profile for ${name}."
    cmd_issue --force "$name"
    count=$((count + 1))
  done < <(list_issued_clients)
  if [[ "$count" -eq 0 ]]; then
    log "No valid client certificates to re-issue."
  else
    log "Re-issued ${count} client profile(s)."
  fi
}

cmd_update() {
  local skip_self=0 reissue=0 ref="$IKEV2_REF"
  local -a exec_args install_args

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage_update
        return 0
        ;;
      --skip-self)
        skip_self=1
        ;;
      --reissue-clients)
        reissue=1
        ;;
      --ref)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --ref"
        ref="$1"
        ;;
      --ref=*)
        ref="${1#--ref=}"
        ;;
      *)
        die "Unknown option for update: $1. Run 'swangate update --help'."
        ;;
    esac
    shift
  done

  require_root

  if [[ "$skip_self" -eq 0 ]]; then
    if running_from_prefix; then
      fetch_and_install_release "$ref"
    else
      install_tree_to_prefix "$(cd "$IKEV2_HOME" && pwd -P)"
    fi
    exec_args=(update --skip-self)
    [[ "$reissue" -eq 1 ]] && exec_args+=(--reissue-clients)
    exec "$IKEV2_BIN" "${exec_args[@]}"
  fi

  [[ -f "$(config_file)" ]] || die "Missing $(config_file). Run 'swangate install' first."
  load_config

  install_args=(
    --domain "$VPN_DOMAIN"
    --ipv6 "$VPN_IPV6"
    --interface "$VPN_INTERFACE"
    --ca-country "$VPN_CA_COUNTRY"
    --ca-org "$VPN_CA_ORG"
    --pool-v4 "$VPN_POOL_V4"
    --pool-v6 "$VPN_POOL_V6"
    --dns "$VPN_DNS"
    --clients-dir "$VPN_CLIENTS_DIR"
    --backend "$VPN_BACKEND"
    --firewall "$VPN_FIREWALL"
    --dataplane "$VPN_DATAPLANE"
    --skip-certbot
  )
  [[ -n "${VPN_EMAIL:-}" ]] && install_args+=(--email "$VPN_EMAIL")

  log "Re-applying VPN configuration for ${VPN_DOMAIN}."
  VPN_ASSUME_DEFAULTS=1 cmd_install "${install_args[@]}"

  if [[ "$reissue" -eq 1 ]]; then
    reissue_valid_clients
  else
    cat <<'EOF'

Client Apple profiles were not regenerated.
Refresh one phone with:
  sudo swangate issue --force <name>
Or re-issue every valid client:
  sudo swangate update --skip-self --reissue-clients
EOF
  fi
}

swangate_main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    issue) cmd_issue "$@" ;;
    revoke) cmd_revoke "$@" ;;
    status) cmd_status "$@" ;;
    firewall-apply) cmd_firewall_apply "$@" ;;
    renew-hook) cmd_renew_hook "$@" ;;
    help|-h|--help) usage_main ;;
    "")
      usage_main >&2
      return 1
      ;;
    *)
      printf '[swangate] ERROR: Unknown command: %s\n\n' "$cmd" >&2
      usage_main >&2
      return 1
      ;;
  esac
}
