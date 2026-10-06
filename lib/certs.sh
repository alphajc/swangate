#!/usr/bin/env bash
# Certificates, StrongSwan configuration, CRLs, and Apple profiles.
# shellcheck disable=SC2034  # Globals are shared across the sourced libraries.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

CA_DIR="${CONFIG_DIR}/ca"
CA_KEY_PATH="${CA_DIR}/ca.key"
CA_CRT_PATH="${CA_DIR}/ca.crt"
CA_STATE_DIR="${STATE_DIR}/ca"
OPENSSL_CNF="${STATE_DIR}/openssl.cnf"
LEGACY_CA_KEY="/etc/ipsec.d/private/vpn_client_ca.key"
LEGACY_CA_CRT="/etc/ipsec.d/cacerts/vpn_client_ca.crt"

# Sets StrongSwan file locations for backend ipsec or swanctl under etc (/etc or /etc/strongswan).
set_swan_paths() {
  local backend="$1"
  local etc="$2"
  local base
  SWAN_ETC="$etc"
  STRONGSWAN_D="${etc}/strongswan.d"
  case "$backend" in
    ipsec)
      base="${etc}/ipsec.d"
      SWAN_CONF="${etc}/ipsec.conf"
      SWAN_SECRETS="${etc}/ipsec.secrets"
      CERT_DIR="${base}/certs"
      KEY_DIR="${base}/private"
      CACERT_DIR="${base}/cacerts"
      CRL_DIR="${base}/crls"
      ;;
    swanctl)
      base="${etc}/swanctl"
      SWANCTL_MAIN="${base}/swanctl.conf"
      SWAN_CONF="${base}/conf.d/ikev2-vpn.conf"
      SWAN_SECRETS=""
      CERT_DIR="${base}/x509"
      KEY_DIR="${base}/private"
      CACERT_DIR="${base}/x509ca"
      CRL_DIR="${base}/x509crl"
      ;;
    *)
      die "Unknown backend: ${backend}"
      ;;
  esac
  SERVER_CRT="${CERT_DIR}/server.crt"
  SERVER_KEY="${KEY_DIR}/server.key"
  # Keep the Let's Encrypt intermediate outside StrongSwan's CA directory.
  # If it lives in cacerts/x509ca, charon sends CERT CERT and IKE_AUTH often
  # needs fragmentation; many mobile IPv6 paths drop those fragments, so the
  # phone keeps retrying while the server only shows DPD retransmits.
  SERVER_CHAIN="${CONFIG_DIR}/server-chain.pem"
  CA_PUBLISHED_CRT="${CACERT_DIR}/vpn_client_ca.crt"
  CRL_PATH="${CRL_DIR}/vpn_client_ca.crl"
}

pubkey_md5() {
  local kind="$1"
  local file="$2"
  if [[ "$kind" == "cert" ]]; then
    openssl x509 -in "$file" -pubkey -noout
  else
    openssl pkey -in "$file" -pubout
  fi | openssl md5 | awk '{print $NF}'
}

detect_key_type() {
  local key="$1"
  local text
  text="$(openssl pkey -in "$key" -noout -text 2>/dev/null)" || die "Cannot read private key ${key}"
  if grep -q "ASN1 OID:" <<<"$text"; then
    printf 'ECDSA\n'
  elif grep -q "modulus:" <<<"$text"; then
    printf 'RSA\n'
  else
    die "Unrecognized private key type in ${key}"
  fi
}

# Apple IKEv2 CertificateType for a certificate's public key.
# Per Apple MDM docs this describes PayloadCertificateUUID (the client identity).
# In practice NEIKEv2Provider also rejects server AUTH that disagrees with it
# (RSASignature vs DigitalSignatureECDSA256), so client and server leaves must
# share the same Apple type.
apple_certificate_type() {
  local crt="$1"
  local text
  text="$(openssl x509 -in "$crt" -noout -text 2>/dev/null)" || die "Cannot read certificate ${crt}"
  if grep -Eq 'Public Key Algorithm: (id-ecPublicKey|.*EC)' <<<"$text"; then
    if grep -Eq 'ASN1 OID: secp384r1|NIST CURVE: P-384' <<<"$text"; then
      printf 'ECDSA384\n'
    elif grep -Eq 'ASN1 OID: secp521r1|NIST CURVE: P-521' <<<"$text"; then
      printf 'ECDSA521\n'
    else
      printf 'ECDSA256\n'
    fi
  else
    printf 'RSA\n'
  fi
}

# OpenSSL curve name matching an Apple CertificateType.
ec_curve_for_apple_type() {
  case "$1" in
    ECDSA256) printf 'prime256v1\n' ;;
    ECDSA384) printf 'secp384r1\n' ;;
    ECDSA521) printf 'secp521r1\n' ;;
    *) return 1 ;;
  esac
}

# Prints the PEM certificate in BUNDLE whose subject CN is CN.
bundle_cert_by_cn() {
  local want="$1"
  local bundle="$2"
  local tmp part cn
  [[ -n "$want" && -f "$bundle" ]] || return 1
  tmp="$(mktemp -d)"
  # Split a PEM bundle into individual cert files.
  awk -v dir="$tmp" '
    /BEGIN CERTIFICATE/ { n++; f=sprintf("%s/%05d.pem", dir, n) }
    f { print > f }
    /END CERTIFICATE/ { f="" }
  ' "$bundle"
  for part in "$tmp"/*.pem; do
    [[ -f "$part" ]] || continue
    cn="$(cert_common_name "$part" subject 2>/dev/null || true)"
    if [[ "$cn" == "$want" ]]; then
      openssl x509 -in "$part"
      rm -rf "$tmp"
      return 0
    fi
  done
  rm -rf "$tmp"
  return 1
}

# Prints the PEM certificate in BUNDLE that issued LEAF.
server_issuer_pem() {
  bundle_cert_by_cn "$(cert_common_name "$1" issuer)" "$2"
}

# Prints base64(DER) of the certificate in BUNDLE that issued LEAF. Needed so
# ServerCertificateIssuerCommonName (YE2/E7) matches the embedded
# com.apple.security.pkcs1 payload.
apple_issuer_der_b64() {
  local pem
  pem="$(server_issuer_pem "$1" "$2")" || return 1
  openssl x509 -outform der <<<"$pem" | base64 | tr -d '\r\n'
}

SYSTEM_CA_BUNDLES="${IKEV2_SYSTEM_CA_BUNDLES:-/etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem}"

# Prints the CA certificate Android should trust for the server. The server
# sends LEAF and its issuer, so the anchor is whoever signed that issuer:
# taken from BUNDLE (e.g. Root YR cross-signed by ISRG Root X1), or else from
# the system CA store (e.g. ISRG Root X1 above R12).
android_server_ca_pem() {
  local leaf="$1"
  local bundle="$2"
  local issuer anchor_cn file
  issuer="$(server_issuer_pem "$leaf" "$bundle")" || return 1
  anchor_cn="$(cert_common_name /dev/stdin issuer <<<"$issuer")"
  if [[ "$anchor_cn" == "$(cert_common_name /dev/stdin subject <<<"$issuer")" ]]; then
    printf '%s\n' "$issuer"
    return 0
  fi
  bundle_cert_by_cn "$anchor_cn" "$bundle" && return 0
  for file in $SYSTEM_CA_BUNDLES; do
    bundle_cert_by_cn "$anchor_cn" "$file" && return 0
  done
  return 1
}

# Prints the CN from a certificate subject or issuer (RFC2253).
cert_common_name() {
  local crt="$1"
  local which="$2"
  local out
  case "$which" in
    subject|issuer) ;;
    *) die "cert_common_name: expected subject or issuer" ;;
  esac
  out="$(openssl x509 -in "$crt" -noout "-${which}" -nameopt RFC2253 2>/dev/null)" \
    || die "Cannot read certificate ${crt}"
  python3 - "$out" <<'PY'
import sys
line = sys.argv[1]
dn = line.split("=", 1)[1].strip() if "=" in line else line
for item in dn.split(","):
    key, _, value = item.partition("=")
    if key.strip() == "CN":
        sys.stdout.write(value.strip() + "\n")
        raise SystemExit(0)
raise SystemExit("CN not found")
PY
}

subject_for_rightca() {
  local crt="$1"
  python3 - "$crt" <<'PY'
import subprocess, sys
crt = sys.argv[1]
out = subprocess.check_output(
    ["openssl", "x509", "-in", crt, "-noout", "-subject", "-nameopt", "RFC2253"],
    text=True,
).strip()
dn = out.split("=", 1)[1].strip()
parts = {}
for item in dn.split(","):
    key, value = item.split("=", 1)
    parts[key.strip()] = value.strip()
missing = [key for key in ("C", "O", "CN") if key not in parts]
if missing:
    sys.stderr.write("CA certificate is missing %s\n" % ", ".join(missing))
    sys.exit(1)
sys.stdout.write("C=%s, O=%s, CN=%s\n" % (parts["C"], parts["O"], parts["CN"]))
PY
}

ca_subject_fields() {
  local crt="$1"
  python3 - "$crt" <<'PY'
import shlex, subprocess, sys
crt = sys.argv[1]
out = subprocess.check_output(
    ["openssl", "x509", "-in", crt, "-noout", "-subject", "-nameopt", "RFC2253"],
    text=True,
).strip()
dn = out.split("=", 1)[1].strip()
parts = {}
for item in dn.split(","):
    key, value = item.split("=", 1)
    parts[key.strip()] = value.strip()
print("VPN_CA_COUNTRY=%s" % shlex.quote(parts["C"]))
print("VPN_CA_ORG=%s" % shlex.quote(parts["O"]))
print("VPN_CA_CN=%s" % shlex.quote(parts["CN"]))
print("VPN_CA_SUBJECT=%s" % shlex.quote("C=%s, O=%s, CN=%s" % (parts["C"], parts["O"], parts["CN"])))
PY
}

init_ca_db() {
  local ca_dir="$1"
  mkdir -p "${ca_dir}/newcerts" "${ca_dir}/certs"
  [[ -f "${ca_dir}/index.txt" ]] || : >"${ca_dir}/index.txt"
  if [[ ! -f "${ca_dir}/index.txt.attr" ]]; then
    printf 'unique_subject = no\n' >"${ca_dir}/index.txt.attr"
  fi
  [[ -f "${ca_dir}/serial" ]] || printf '01\n' >"${ca_dir}/serial"
  [[ -f "${ca_dir}/crlnumber" ]] || printf '01\n' >"${ca_dir}/crlnumber"
}

write_openssl_cnf() {
  local dest="$1"
  local ca_dir="$2"
  local ca_crt="$3"
  local ca_key="$4"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
# ${MANAGED_MARK}
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${ca_dir}
certs             = \$dir/certs
database          = \$dir/index.txt
new_certs_dir     = \$dir/newcerts
certificate       = ${ca_crt}
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl.pem
private_key       = ${ca_key}
default_days      = 3650
default_crl_days  = 3650
default_md        = sha256
preserve          = no
policy            = policy_loose
x509_extensions   = client_ext
crl_extensions    = crl_ext
unique_subject    = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ client_ext ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF
}

migrate_legacy_ca() {
  [[ -f "$CA_CRT_PATH" && -f "$CA_KEY_PATH" ]] && return 0
  [[ -f "$LEGACY_CA_CRT" && -f "$LEGACY_CA_KEY" ]] || return 0
  mkdir -p "$CA_DIR"
  chmod 700 "$CA_DIR"
  cp -p "$LEGACY_CA_CRT" "$CA_CRT_PATH"
  install -m 600 "$LEGACY_CA_KEY" "$CA_KEY_PATH"
  rm -f "$LEGACY_CA_KEY"
  log "Moved the existing client CA into ${CA_DIR}."
}

create_client_ca() {
  local subj old_umask
  migrate_legacy_ca
  mkdir -p "$CA_DIR"
  chmod 700 "$CA_DIR"
  if [[ ! -f "$CA_CRT_PATH" || ! -f "$CA_KEY_PATH" ]]; then
    subj="/C=${VPN_CA_COUNTRY}/O=${VPN_CA_ORG}/CN=${VPN_CA_CN}"
    log "Creating client CA: ${subj}"
    old_umask="$(umask)"
    umask 077
    openssl req -x509 -new -nodes -newkey rsa:2048 \
      -keyout "$CA_KEY_PATH" \
      -out "$CA_CRT_PATH" \
      -days 3650 \
      -subj "$subj" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" 2>/dev/null
    chmod 600 "$CA_KEY_PATH"
    chmod 644 "$CA_CRT_PATH"
    umask "$old_umask"
  else
    log "Client CA already exists. Keeping the existing key and certificate."
  fi
  eval "$(ca_subject_fields "$CA_CRT_PATH")"
  init_ca_db "$CA_STATE_DIR"
  write_openssl_cnf "$OPENSSL_CNF" "$CA_STATE_DIR" "$CA_CRT_PATH" "$CA_KEY_PATH"
}

publish_client_ca() {
  mkdir -p "$CACERT_DIR"
  install -m 644 "$CA_CRT_PATH" "$CA_PUBLISHED_CRT"
  rm -f "${CACERT_DIR}/vpn_client_ca.srl"
}

write_ipsec_conf() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
# ${MANAGED_MARK}
config setup
    charondebug="ike 1, knl 1, cfg 1"
    uniqueids=never

conn %default
    keyexchange=ikev2
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    ikelifetime=24h
    lifetime=8h

conn ikev2-cert
    auto=add
    type=tunnel
    compress=no
    # yes + charon.fragment_size=576: iOS sends fragmented IKE_AUTH; RFC 7383
    # says the responder should answer in kind. A single ~1376-byte reply is
    # over the IPv6 minimum MTU and is dropped on many mobile paths.
    fragmentation=yes
    forceencaps=yes
    mobike=no
    ike=aes256-sha256-modp2048,aes128-sha256-modp2048,aes256-sha1-modp2048
    esp=aes256-sha256-modp2048,aes128-sha256-modp2048,aes256gcm16-modp2048,aes128gcm16-modp2048,aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1
    left=%any
    leftid=${VPN_DOMAIN}
    leftcert=server.crt
    leftsendcert=always
    leftsubnet=0.0.0.0/0,::/0
    right=%any
    rightid=%any
    rightauth=pubkey
    rightca="${VPN_CA_SUBJECT}"
    rightdns=${VPN_DNS}
    rightsourceip=${VPN_POOL_V4},${VPN_POOL_V6}
EOF
  chmod 644 "$dest"
}

write_ipsec_secrets() {
  local dest="$1"
  local key_type="$2"
  local old_umask
  old_umask="$(umask)"
  mkdir -p "$(dirname "$dest")"
  umask 077
  cat >"$dest" <<EOF
# ${MANAGED_MARK}
: ${key_type} server.key
${VPN_DOMAIN} : ${key_type} server.key
@${VPN_DOMAIN} : ${key_type} server.key
: ${key_type} ${SERVER_KEY}
${VPN_DOMAIN} : ${key_type} ${SERVER_KEY}
@${VPN_DOMAIN} : ${key_type} ${SERVER_KEY}
EOF
  chmod 600 "$dest"
  umask "$old_umask"
}

write_swanctl_conf() {
  local dest="$1"
  local dns4 dns6 pool_v4_dns="" pool_v6_dns=""
  dns4="$(dns_for_family "$VPN_DNS" ipv4)"
  dns6="$(dns_for_family "$VPN_DNS" ipv6)"
  [[ -n "$dns4" ]] && pool_v4_dns=$'\n'"        dns = ${dns4}"
  [[ -n "$dns6" ]] && pool_v6_dns=$'\n'"        dns = ${dns6}"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
# ${MANAGED_MARK}
connections {
    ikev2-cert {
        version = 2
        local_addrs = %any
        proposals = aes256-sha256-modp2048,aes128-sha256-modp2048,aes256-sha1-modp2048
        pools = ikev2-vpn-v4,ikev2-vpn-v6
        # yes + charon.fragment_size=576: mirror iOS fragmented IKE_AUTH and keep
        # each UDP datagram under the IPv6 minimum MTU on mobile paths.
        fragmentation = yes
        encap = yes
        mobike = no
        dpd_delay = 30s
        dpd_timeout = 120s
        rekey_time = 24h
        send_cert = always
        unique = never
        local {
            auth = pubkey
            certs = server.crt
            id = ${VPN_DOMAIN}
        }
        remote {
            auth = pubkey
            cacerts = vpn_client_ca.crt
        }
        children {
            ikev2-cert {
                local_ts = 0.0.0.0/0,::/0
                esp_proposals = aes256-sha256-modp2048,aes128-sha256-modp2048,aes256gcm16-modp2048,aes128gcm16-modp2048,aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1
                life_time = 8h
                rekey_time = 7h
                dpd_action = clear
            }
        }
    }
}

pools {
    ikev2-vpn-v4 {
        addrs = ${VPN_POOL_V4}${pool_v4_dns}
    }
    ikev2-vpn-v6 {
        addrs = ${VPN_POOL_V6}${pool_v6_dns}
    }
}
EOF
  chmod 644 "$dest"
}

ensure_swanctl_include() {
  local main="$1"
  mkdir -p "$(dirname "$main")/conf.d"
  if [[ ! -f "$main" ]]; then
    printf '# %s\ninclude conf.d/*.conf\n' "$MANAGED_MARK" >"$main"
    chmod 644 "$main"
  elif ! grep -Eq '^[[:space:]]*include[[:space:]]+conf\.d/\*\.conf' "$main"; then
    printf '\ninclude conf.d/*.conf\n' >>"$main"
  fi
}

backup_unmanaged() {
  local path="$1"
  if [[ -f "$path" ]] && ! grep -q "$MANAGED_MARK" "$path"; then
    cp -a "$path" "${path}.bak.$(date +%Y%m%d%H%M%S)"
    log "Backed up ${path}."
  fi
}

write_swan_config() {
  case "$VPN_BACKEND" in
    ipsec)
      backup_unmanaged "$SWAN_CONF"
      backup_unmanaged "$SWAN_SECRETS"
      write_ipsec_conf "$SWAN_CONF"
      write_ipsec_secrets "$SWAN_SECRETS" "$VPN_SERVER_KEY_TYPE"
      ;;
    swanctl)
      ensure_swanctl_include "$SWANCTL_MAIN"
      write_swanctl_conf "$SWAN_CONF"
      ;;
  esac
}

sync_server_cert() {
  local live="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}"
  local cert_hash key_hash
  [[ -f "${live}/cert.pem" ]] || die "Missing ${live}/cert.pem. Obtain a Let's Encrypt certificate first."
  [[ -f "${live}/privkey.pem" ]] || die "Missing ${live}/privkey.pem."
  [[ -f "${live}/chain.pem" ]] || die "Missing ${live}/chain.pem."
  mkdir -p "$CERT_DIR" "$KEY_DIR" "$CACERT_DIR" "$CONFIG_DIR"
  chmod 700 "$KEY_DIR"
  cp -L "${live}/cert.pem" "$SERVER_CRT"
  cp -L "${live}/privkey.pem" "$SERVER_KEY"
  cp -L "${live}/chain.pem" "$SERVER_CHAIN"
  chmod 644 "$SERVER_CRT" "$SERVER_CHAIN"
  chmod 600 "$SERVER_KEY"
  cert_hash="$(pubkey_md5 cert "$SERVER_CRT")"
  key_hash="$(pubkey_md5 key "$SERVER_KEY")"
  if [[ -z "$cert_hash" || "$cert_hash" != "$key_hash" ]]; then
    die "Server certificate and private key do not match after copy."
  fi
  VPN_SERVER_KEY_TYPE="$(detect_key_type "$SERVER_KEY")"
  log "Server certificate matches its ${VPN_SERVER_KEY_TYPE} private key."
  # ECDSA: keep the intermediate out of cacerts so IKE_AUTH stays small (older
  # installs put it there). RSA: the Android built-in VPN does not fetch
  # intermediates, so charon must send the leaf's issuer; that lets phones
  # trust the stable CA above it while Let's Encrypt rotates YR1/YR2.
  rm -f "${CACERT_DIR}/intermediate.crt"
  if [[ "$VPN_SERVER_KEY_TYPE" == "RSA" ]]; then
    if server_issuer_pem "$SERVER_CRT" "$SERVER_CHAIN" >"${CACERT_DIR}/intermediate.crt"; then
      chmod 644 "${CACERT_DIR}/intermediate.crt"
    else
      rm -f "${CACERT_DIR}/intermediate.crt"
      warn "The server certificate issuer is not in ${SERVER_CHAIN}. Android clients cannot verify the server."
    fi
  fi
}

swanctl_load() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if swanctl --load-all >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  swanctl --load-all
}

restart_strongswan() {
  local i
  [[ "${IKEV2_SKIP_SERVICE:-0}" == "1" ]] && return 0
  svc_enable_restart "$VPN_SERVICE"
  for i in 1 2 3 4 5; do
    svc_is_active "$VPN_SERVICE" && break
    sleep 1
  done
  svc_is_active "$VPN_SERVICE" || die "Service ${VPN_SERVICE} is not running. Check its logs."
  [[ "$VPN_BACKEND" == "swanctl" ]] && swanctl_load
  log "Restarted ${VPN_SERVICE}."
}

# Prints the loaded connection and certificate listing from the running daemon.
swan_listing() {
  local cmd
  case "$VPN_BACKEND" in
    ipsec)
      cmd="$(ipsec_command)"
      [[ -n "$cmd" ]] || return 1
      "$cmd" statusall 2>/dev/null
      "$cmd" listall 2>/dev/null
      ;;
    swanctl)
      swanctl --list-conns 2>/dev/null
      swanctl --list-certs 2>/dev/null
      ;;
  esac
}

verify_strongswan() {
  local listing
  for _ in 1 2 3 4 5; do
    listing="$(swan_listing || true)"
    if grep -q 'ikev2-cert' <<<"$listing" && grep -q 'has private key' <<<"$listing"; then
      log "StrongSwan loaded connection ikev2-cert and the server private key."
      return 0
    fi
    sleep 1
  done
  grep -q 'ikev2-cert' <<<"$listing" || die "StrongSwan did not load connection ikev2-cert."
  die "StrongSwan did not load the private key for ${VPN_DOMAIN}."
}

# The SAN carries NAME because iOS and other clients send it as their IKE identity.
# When the server leaf is ECDSA, issue a matching ECDSA client key: Apple's
# CertificateType must match PayloadCertificateUUID and also server AUTH.
issue_client_cert() {
  local name="$1"
  local work_dir="$2"
  local key crt csr ext old_umask server_type curve
  old_umask="$(umask)"
  key="${work_dir}/${name}.key"
  csr="${work_dir}/${name}.csr"
  crt="${work_dir}/${name}.crt"
  ext="${work_dir}/${name}.ext"
  umask 077
  server_type=RSA
  if [[ -f "$SERVER_CRT" ]]; then
    server_type="$(apple_certificate_type "$SERVER_CRT")"
  fi
  if curve="$(ec_curve_for_apple_type "$server_type")"; then
    openssl req -new -newkey ec -pkeyopt "ec_paramgen_curve:${curve}" -nodes \
      -keyout "$key" \
      -out "$csr" \
      -subj "/C=${VPN_CA_COUNTRY}/O=${VPN_CA_ORG}/CN=${name}" 2>/dev/null
  else
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout "$key" \
      -out "$csr" \
      -subj "/C=${VPN_CA_COUNTRY}/O=${VPN_CA_ORG}/CN=${name}" 2>/dev/null
  fi
  chmod 600 "$key"
  cat >"$ext" <<EOF
[ client_ext ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = DNS:${name}
EOF
  openssl ca -config "$OPENSSL_CNF" -batch -notext \
    -extfile "$ext" -extensions client_ext \
    -in "$csr" \
    -out "$crt" \
    -days 3650 >/dev/null 2>&1 || die "Failed to sign the certificate for ${name}."
  chmod 644 "$crt"
  rm -f "$csr" "$ext"
  umask "$old_umask"
}

revoke_certificate() {
  local crt="$1"
  local output rc
  [[ -f "$crt" ]] || die "Certificate not found: ${crt}"
  [[ -f "$OPENSSL_CNF" ]] || die "Missing ${OPENSSL_CNF}. Run 'swangate install' first."
  set +e
  output="$(openssl ca -config "$OPENSSL_CNF" -revoke "$crt" -crl_reason keyCompromise -batch 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    if grep -qi "already revoked" <<<"$output"; then
      log "Certificate is already revoked: ${crt}"
    else
      printf '%s\n' "$output" >&2
      die "Failed to revoke ${crt}"
    fi
  else
    log "Revoked ${crt}"
  fi
  publish_crl
  restart_strongswan
}

publish_crl() {
  local crl_tmp
  [[ -f "$OPENSSL_CNF" ]] || die "Missing ${OPENSSL_CNF}. Run 'swangate install' first."
  mkdir -p "$CRL_DIR"
  crl_tmp="$(mktemp)"
  openssl ca -config "$OPENSSL_CNF" -gencrl -out "$crl_tmp" -batch >/dev/null 2>&1 \
    || die "Failed to generate the CRL."
  install -m 644 "$crl_tmp" "$CRL_PATH"
  rm -f "$crl_tmp"
  log "Published CRL at ${CRL_PATH}"
}

# Prints "status name serial" for every issued client certificate.
list_issued_clients() {
  local index="${CA_STATE_DIR}/index.txt"
  [[ -f "$index" ]] || return 0
  awk -F'\t' '{
    status = ($1 == "R") ? "revoked" : (($1 == "V") ? "valid" : "expired")
    n = split($6, parts, "/")
    cn = ""
    for (i = 1; i <= n; i++) if (parts[i] ~ /^CN=/) cn = substr(parts[i], 4)
    print status, cn, $4
  }' "$index"
}

# Apple .mobileconfig layout follows hwdsl2/setup-ipsec-vpn extras/ikev2setup.sh
# (create_mobileconfig) and Apple's VPN.IKEv2 schema, with SwanGate-specific
# choices: AES-CBC+SHA2-256+DH14 (iOS/kernel), EnablePFS, dual-stack OverridePrimary,
# and Let's Encrypt ServerCertificate* fields. CertificateType must match both
# the server AUTH algorithm and the client signing key (ECDSA256 + ECDSA client
# certs when using default certbot ECDSA). Apple also requires
# ServerCertificateIssuerCommonName when CertificateType is set; embed that
# issuer as pkcs1 so iOS can resolve CN lookups such as YE2/E7.
write_mobileconfig_xml() {
  local dest="$1"
  local name="$2"
  local domain="$3"
  local p12_pass="$4"
  local p12_b64="$5"
  local cert_uuid="$6"
  local vpn_uuid="$7"
  local profile_uuid="$8"
  local cert_type="${9:-RSA}"
  local issuer_cn="${10:-}"
  local server_cn="${11:-$domain}"
  local issuer_b64="${12:-}"
  local issuer_uuid="${13:-}"
  local cert_type_xml="" issuer_xml="" server_cn_xml="" issuer_payload=""
  # Apple requires ServerCertificateIssuerCommonName when CertificateType is set.
  if [[ -n "$issuer_cn" ]]; then
    cert_type_xml=$'\n'"                <key>CertificateType</key>"$'\n'"                <string>${cert_type}</string>"
    issuer_xml=$'\n'"                <key>ServerCertificateIssuerCommonName</key>"$'\n'"                <string>${issuer_cn}</string>"
  fi
  if [[ -n "$server_cn" ]]; then
    server_cn_xml=$'\n'"                <key>ServerCertificateCommonName</key>"$'\n'"                <string>${server_cn}</string>"
  fi
  if [[ -n "$issuer_b64" && -n "$issuer_uuid" ]]; then
    issuer_payload=$(cat <<ISSUER
        <dict>
            <key>PayloadCertificateFileName</key>
            <string>server-issuer.crt</string>
            <key>PayloadContent</key>
            <data>${issuer_b64}</data>
            <key>PayloadDescription</key>
            <string>Server certificate issuer</string>
            <key>PayloadDisplayName</key>
            <string>${issuer_cn:-Server issuer}</string>
            <key>PayloadIdentifier</key>
            <string>com.ikev2vpn.issuer.${issuer_uuid}</string>
            <key>PayloadType</key>
            <string>com.apple.security.pkcs1</string>
            <key>PayloadUUID</key>
            <string>${issuer_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
ISSUER
)
  fi
  cat >"$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>IKEv2</key>
            <dict>
                <key>AuthenticationMethod</key>
                <string>Certificate</string>${cert_type_xml}
                <key>ChildSecurityAssociationParameters</key>
                <dict>
                    <key>DiffieHellmanGroup</key>
                    <integer>14</integer>
                    <key>EncryptionAlgorithm</key>
                    <string>AES-256</string>
                    <key>IntegrityAlgorithm</key>
                    <string>SHA2-256</string>
                    <key>LifeTimeInMinutes</key>
                    <integer>480</integer>
                </dict>
                <key>DeadPeerDetectionRate</key>
                <string>Medium</string>
                <key>DisableMOBIKE</key>
                <true/>
                <key>DisableRedirect</key>
                <true/>
                <key>EnableCertificateRevocationCheck</key>
                <false/>
                <key>EnablePFS</key>
                <true/>
                <key>IKESecurityAssociationParameters</key>
                <dict>
                    <key>DiffieHellmanGroup</key>
                    <integer>14</integer>
                    <key>EncryptionAlgorithm</key>
                    <string>AES-256</string>
                    <key>IntegrityAlgorithm</key>
                    <string>SHA2-256</string>
                    <key>LifeTimeInMinutes</key>
                    <integer>1440</integer>
                </dict>
                <key>LocalIdentifier</key>
                <string>${name}</string>
                <key>OnDemandEnabled</key>
                <false/>
                <key>OnDemandRules</key>
                <array>
                    <dict>
                        <key>InterfaceTypeMatch</key>
                        <string>WiFi</string>
                        <key>URLStringProbe</key>
                        <string>http://captive.apple.com/hotspot-detect.html</string>
                        <key>Action</key>
                        <string>Connect</string>
                    </dict>
                    <dict>
                        <key>InterfaceTypeMatch</key>
                        <string>Cellular</string>
                        <key>Action</key>
                        <string>Disconnect</string>
                    </dict>
                    <dict>
                        <key>Action</key>
                        <string>Ignore</string>
                    </dict>
                </array>
                <key>PayloadCertificateUUID</key>
                <string>${cert_uuid}</string>
                <key>RemoteAddress</key>
                <string>${domain}</string>
                <key>RemoteIdentifier</key>
                <string>${domain}</string>${issuer_xml}${server_cn_xml}
                <key>UseConfigurationAttributeInternalIPSubnet</key>
                <false/>
            </dict>
            <key>IPv4</key>
            <dict>
                <key>OverridePrimary</key>
                <true/>
            </dict>
            <key>IPv6</key>
            <dict>
                <key>OverridePrimary</key>
                <true/>
            </dict>
            <key>PayloadDescription</key>
            <string>Configures certificate-authenticated IKEv2 VPN for ${domain}</string>
            <key>PayloadDisplayName</key>
            <string>IKEv2 VPN (${domain})</string>
            <key>PayloadOrganization</key>
            <string>IKEv2 VPN</string>
            <key>PayloadIdentifier</key>
            <string>com.ikev2vpn.profile.${vpn_uuid}</string>
            <key>PayloadType</key>
            <string>com.apple.vpn.managed</string>
            <key>PayloadUUID</key>
            <string>${vpn_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>Proxies</key>
            <dict>
                <key>HTTPEnable</key>
                <false/>
                <key>HTTPSEnable</key>
                <false/>
            </dict>
            <key>UserDefinedName</key>
            <string>IKEv2 - ${domain}</string>
            <key>VPNType</key>
            <string>IKEv2</string>
        </dict>
        <dict>
            <key>Password</key>
            <string>${p12_pass}</string>
            <key>PayloadCertificateFileName</key>
            <string>${name}.p12</string>
            <key>PayloadContent</key>
            <data>${p12_b64}</data>
            <key>PayloadDescription</key>
            <string>Adds a PKCS#12-formatted certificate</string>
            <key>PayloadDisplayName</key>
            <string>${name}</string>
            <key>PayloadIdentifier</key>
            <string>com.ikev2vpn.cert.${cert_uuid}</string>
            <key>PayloadType</key>
            <string>com.apple.security.pkcs12</string>
            <key>PayloadUUID</key>
            <string>${cert_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
${issuer_payload}    </array>
    <key>PayloadDisplayName</key>
    <string>IKEv2 VPN (${name})</string>
    <key>PayloadIdentifier</key>
    <string>com.ikev2vpn.config.${profile_uuid}</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${profile_uuid}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF
}

sign_mobileconfig() {
  local raw="$1"
  local dest="$2"
  local signer="$3"
  local key="$4"
  local chain="$5"
  local -a args
  args=(openssl smime -sign -in "$raw" -out "$dest" -signer "$signer" -inkey "$key" -outform der -nodetach)
  if [[ -n "$chain" && -f "$chain" ]]; then
    args+=(-certfile "$chain")
  fi
  "${args[@]}"
}
