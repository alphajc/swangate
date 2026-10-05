#!/usr/bin/env bash
# Issue a client certificate for the IPv6 IKEv2 VPN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/certs.sh
source "${SCRIPT_DIR}/lib/certs.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./issue-client.sh [--force] NAME

Issue a client certificate signed by the local VPN CA and write:
  NAME.crt NAME.key NAME.p12 NAME.mobileconfig connection.txt

The PKCS#12 password is random and is printed here. It is also embedded
in the Apple profile so iOS and macOS can import it.

  --force    Revoke the existing certificate for NAME and issue a new one
  -h, --help Show this help
EOF
}

force=0
name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "$name" ]] || die "Unexpected argument: $1"
      name="$1"
      shift
      ;;
  esac
done

[[ -n "$name" ]] || die "Missing client name. Usage: sudo ./issue-client.sh <name>"

require_root
require_ubuntu
require_cmd openssl python3
load_config
validate_client_name "$name"
[[ -f "$CA_CRT_PATH" && -f "$CA_KEY_PATH" ]] || die "Client CA is missing. Run install.sh first."
[[ -f "$OPENSSL_CNF" ]] || die "Missing ${OPENSSL_CNF}. Run install.sh first."

work_dir="${VPN_CLIENTS_DIR}/${name}"
crt="${work_dir}/${name}.crt"
if [[ -f "$crt" ]]; then
  if [[ "$force" -ne 1 ]]; then
    die "Client ${name} already exists at ${work_dir}. Run again with --force to revoke and reissue."
  fi
  log "Revoking the previous certificate for ${name}."
  revoke_certificate "$crt"
fi

mkdir -p "$work_dir"
chmod 700 "$work_dir"
log "Issuing client certificate for ${name}."
issue_client_cert "$name" "$work_dir"

key="${work_dir}/${name}.key"
crt="${work_dir}/${name}.crt"
p12="${work_dir}/${name}.p12"
raw="${work_dir}/${name}.raw.mobileconfig"
profile="${work_dir}/${name}.mobileconfig"
note="${work_dir}/connection.txt"
p12_pass="$(openssl rand -hex 12)"
umask 077
openssl pkcs12 -export \
  -inkey "$key" \
  -in "$crt" \
  -certfile "$CA_CRT_PATH" \
  -out "$p12" \
  -name "$name" \
  -passout "pass:${p12_pass}"
chmod 600 "$p12" "$key"

p12_b64="$(base64 -w 0 "$p12")"
cert_uuid="$(new_uuid)"
vpn_uuid="$(new_uuid)"
profile_uuid="$(new_uuid)"
write_mobileconfig_xml "$raw" "$name" "$VPN_DOMAIN" "$p12_pass" "$p12_b64" "$cert_uuid" "$vpn_uuid" "$profile_uuid"

signer="/etc/letsencrypt/live/${VPN_DOMAIN}/cert.pem"
inkey="/etc/letsencrypt/live/${VPN_DOMAIN}/privkey.pem"
chain="/etc/letsencrypt/live/${VPN_DOMAIN}/chain.pem"
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
  log "WARNING: Server certificate was not found. Wrote an unsigned Apple profile."
fi
chmod 644 "$profile" "$crt"

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
  Apple profile: ${profile}

iOS and macOS: open the .mobileconfig profile in Safari or AirDrop.
Windows: import the .p12, then add an IKEv2 VPN and choose certificate authentication.
Android: use the strongSwan app, IKEv2 certificate, and select the .p12.
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
  Apple profile:     ${profile}
  Notes:             ${note}
EOF
