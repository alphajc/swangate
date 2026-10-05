#!/usr/bin/env bash
# Subcommands for the swangate command.
# shellcheck disable=SC2034  # Globals are shared across the sourced libraries.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

IKEV2_PREFIX="${IKEV2_PREFIX:-/usr/local/lib/swangate}"
IKEV2_BIN="${IKEV2_BIN:-/usr/local/bin/swangate}"
RENEW_HOOK="${LETSENCRYPT_DIR}/renewal-hooks/deploy/ikev2-vpn"

usage_main() {
  cat <<'EOF'
Usage: swangate <command> [options]

Commands:
  install   Install or update the IPv6 IKEv2 VPN server
  issue     Issue a client certificate
  revoke    Revoke a client certificate
  status    Show server, firewall, and client status
  help      Show this help

Run 'swangate <command> --help' for the options of a command.
EOF
}

usage_install() {
  cat <<'EOF'
Usage: swangate install --domain NAME [options]

Install StrongSwan IKEv2 with a Let's Encrypt server certificate and a local
CA for client certificates. Safe to run again.

Required:
  --domain NAME          VPN hostname, already pointed at this server

Options:
  --ipv6 ADDRESS         IPv6 address already configured on this server
                         (default: detect from DNS AAAA or the host)
  --email ADDRESS        Let's Encrypt contact email
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

write_sysctl() {
  local file=/etc/sysctl.d/99-ikev2-vpn.conf
  mkdir -p /etc/sysctl.d
  cat >"$file" <<EOF
# ${MANAGED_MARK}
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF
  sysctl -p "$file" >/dev/null
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
  VPN_DNS="${VPN_DNS:-1.1.1.1,8.8.8.8,2606:4700:4700::1111}"
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

  [[ -n "$VPN_DOMAIN" ]] || die "Missing --domain. Run 'swangate install --help'."
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

  local p12_b64
  p12_b64="$(base64 "$p12" | tr -d '\r\n')"
  write_mobileconfig_xml "$raw" "$name" "$VPN_DOMAIN" "$p12_pass" "$p12_b64" \
    "$(new_uuid)" "$(new_uuid)" "$(new_uuid)"

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

swangate_main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    install) cmd_install "$@" ;;
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
