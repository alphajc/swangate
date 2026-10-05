#!/usr/bin/env bash
# Certbot deploy hook. Copy the renewed server certificate into StrongSwan.
set -euo pipefail

LIB_DIR="/usr/local/lib/ikev2-vpn"
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/certs.sh
source "${LIB_DIR}/certs.sh"

if [[ ! -f "$(config_file)" ]]; then
  exit 0
fi
load_config

if [[ -n "${RENEWED_DOMAINS:-}" ]]; then
  matched=0
  renewed_domain=""
  # shellcheck disable=SC2086
  for renewed_domain in ${RENEWED_DOMAINS}; do
    if [[ "$renewed_domain" == "$VPN_DOMAIN" ]]; then
      matched=1
      break
    fi
  done
  if [[ "$matched" -ne 1 ]]; then
    exit 0
  fi
fi

log "Let's Encrypt certificate renewed for ${VPN_DOMAIN}. Updating StrongSwan."
sync_server_cert
write_ipsec_secrets /etc/ipsec.secrets "$VPN_SERVER_KEY_TYPE"
restart_strongswan
