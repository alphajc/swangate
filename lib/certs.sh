#!/usr/bin/env bash
# Certificate, StrongSwan config, and Apple profile helpers.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

CA_KEY_PATH="/etc/ipsec.d/private/vpn_client_ca.key"
CA_CRT_PATH="/etc/ipsec.d/cacerts/vpn_client_ca.crt"
CA_STATE_DIR="/var/lib/ikev2-vpn/ca"
OPENSSL_CNF="/var/lib/ikev2-vpn/openssl.cnf"
SERVER_CRT="/etc/ipsec.d/certs/server.crt"
SERVER_KEY="/etc/ipsec.d/private/server.key"
SERVER_CHAIN="/etc/ipsec.d/cacerts/intermediate.crt"
CRL_PATH="/etc/ipsec.d/crls/vpn_client_ca.crl"
MANAGED_MARK="managed-by: ikev2-vpn-installer"

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

create_client_ca() {
  local subj
  mkdir -p "$(dirname "$CA_KEY_PATH")" "$(dirname "$CA_CRT_PATH")"
  if [[ ! -f "$CA_CRT_PATH" || ! -f "$CA_KEY_PATH" ]]; then
    subj="/C=${VPN_CA_COUNTRY}/O=${VPN_CA_ORG}/CN=${VPN_CA_CN}"
    log "Creating client CA: ${subj}"
    local old_umask
    old_umask="$(umask)"
    umask 077
    openssl req -x509 -new -nodes -newkey rsa:2048 \
      -keyout "$CA_KEY_PATH" \
      -out "$CA_CRT_PATH" \
      -days 3650 \
      -subj "$subj" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash"
    chmod 600 "$CA_KEY_PATH"
    chmod 644 "$CA_CRT_PATH"
    umask "$old_umask"
  else
    log "Client CA already exists. Leaving the existing key and certificate in place."
  fi
  # shellcheck disable=SC1090
  eval "$(ca_subject_fields "$CA_CRT_PATH")"
  init_ca_db "$CA_STATE_DIR"
  write_openssl_cnf "$OPENSSL_CNF" "$CA_STATE_DIR" "$CA_CRT_PATH" "$CA_KEY_PATH"
  rm -f "$(dirname "$CA_CRT_PATH")/vpn_client_ca.srl"
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
    dpddelay=300s

conn ikev2-cert
    auto=add
    type=tunnel
    compress=no
    fragmentation=yes
    forceencaps=yes
    ike=aes256-sha256-modp2048,aes128-sha256-modp2048,aes256-sha1-modp2048
    esp=aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1
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

sync_server_cert() {
  local live="/etc/letsencrypt/live/${VPN_DOMAIN}"
  local cert_hash key_hash
  [[ -f "${live}/cert.pem" ]] || die "Missing ${live}/cert.pem. Obtain a Let's Encrypt certificate first."
  [[ -f "${live}/privkey.pem" ]] || die "Missing ${live}/privkey.pem."
  [[ -f "${live}/chain.pem" ]] || die "Missing ${live}/chain.pem."
  mkdir -p /etc/ipsec.d/certs /etc/ipsec.d/private /etc/ipsec.d/cacerts
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
}

strongswan_unit() {
  if systemctl cat strongswan-starter.service >/dev/null 2>&1; then
    printf 'strongswan-starter\n'
  elif systemctl cat strongswan.service >/dev/null 2>&1; then
    printf 'strongswan\n'
  else
    die "Neither strongswan-starter.service nor strongswan.service is installed."
  fi
}

restart_strongswan() {
  local unit
  unit="$(strongswan_unit)"
  systemctl enable "$unit"
  systemctl restart "$unit"
  systemctl is-active --quiet "$unit" || die "Service ${unit} is not active."
  log "Restarted ${unit}."
}

issue_client_cert() {
  local name="$1"
  local work_dir="$2"
  local key crt csr old_umask
  old_umask="$(umask)"
  key="${work_dir}/${name}.key"
  csr="${work_dir}/${name}.csr"
  crt="${work_dir}/${name}.crt"
  umask 077
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$key" \
    -out "$csr" \
    -subj "/C=${VPN_CA_COUNTRY}/O=${VPN_CA_ORG}/CN=${name}"
  chmod 600 "$key"
  openssl ca -config "$OPENSSL_CNF" -batch -notext \
    -in "$csr" \
    -out "$crt" \
    -days 3650 >/dev/null
  chmod 644 "$crt"
  umask "$old_umask"
}

revoke_certificate() {
  local crt="$1"
  local output rc
  [[ -f "$crt" ]] || die "Certificate not found: ${crt}"
  [[ -f "$OPENSSL_CNF" ]] || die "Missing ${OPENSSL_CNF}. Run install.sh first."
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
}

publish_crl() {
  local crl_tmp unit
  [[ -f "$OPENSSL_CNF" ]] || die "Missing ${OPENSSL_CNF}. Run install.sh first."
  mkdir -p "$(dirname "$CRL_PATH")"
  crl_tmp="$(mktemp)"
  openssl ca -config "$OPENSSL_CNF" -gencrl -out "$crl_tmp" -batch >/dev/null
  install -m 644 "$crl_tmp" "$CRL_PATH"
  rm -f "$crl_tmp"
  if [[ "${IKEV2_SKIP_SERVICE:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl cat strongswan-starter.service >/dev/null 2>&1 || systemctl cat strongswan.service >/dev/null 2>&1; then
      unit="$(strongswan_unit)"
      if command -v ipsec >/dev/null 2>&1; then
        ipsec rereadcrls >/dev/null 2>&1 || true
      fi
      systemctl restart "$unit"
    fi
  fi
  log "Published CRL at ${CRL_PATH}"
}

write_mobileconfig_xml() {
  local dest="$1"
  local name="$2"
  local domain="$3"
  local p12_pass="$4"
  local p12_b64="$5"
  local cert_uuid="$6"
  local vpn_uuid="$7"
  local profile_uuid="$8"
  cat >"$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>Password</key>
            <string>${p12_pass}</string>
            <key>PayloadCertificateFileName</key>
            <string>${name}.p12</string>
            <key>PayloadContent</key>
            <data>${p12_b64}</data>
            <key>PayloadDescription</key>
            <string>Client certificate for IKEv2</string>
            <key>PayloadDisplayName</key>
            <string>IKEv2 client certificate (${name})</string>
            <key>PayloadIdentifier</key>
            <string>com.ikev2vpn.cert.${cert_uuid}</string>
            <key>PayloadType</key>
            <string>com.apple.security.pkcs12</string>
            <key>PayloadUUID</key>
            <string>${cert_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        <dict>
            <key>IKEv2</key>
            <dict>
                <key>AuthenticationMethod</key>
                <string>Certificate</string>
                <key>PayloadCertificateUUID</key>
                <string>${cert_uuid}</string>
                <key>RemoteAddress</key>
                <string>${domain}</string>
                <key>RemoteIdentifier</key>
                <string>${domain}</string>
                <key>LocalIdentifier</key>
                <string>${name}</string>
                <key>DeadPeerDetectionRate</key>
                <string>Medium</string>
                <key>DisableMOBIKE</key>
                <false/>
                <key>DisableRedirect</key>
                <false/>
                <key>EnableCertificateRevocationCheck</key>
                <false/>
                <key>EnablePFS</key>
                <true/>
                <key>IKESAParameters</key>
                <dict>
                    <key>EncryptionAlgorithm</key>
                    <string>AES-256</string>
                    <key>IntegrityAlgorithm</key>
                    <string>SHA2-256</string>
                    <key>DiffieHellmanGroup</key>
                    <integer>14</integer>
                </dict>
                <key>ChildSAParameters</key>
                <dict>
                    <key>EncryptionAlgorithm</key>
                    <string>AES-256</string>
                    <key>IntegrityAlgorithm</key>
                    <string>SHA2-256</string>
                    <key>DiffieHellmanGroup</key>
                    <integer>14</integer>
                </dict>
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
            <key>PayloadIdentifier</key>
            <string>com.ikev2vpn.profile.${vpn_uuid}</string>
            <key>PayloadType</key>
            <string>com.apple.vpn.managed</string>
            <key>PayloadUUID</key>
            <string>${vpn_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>UserDefinedName</key>
            <string>IKEv2 - ${domain}</string>
            <key>VPNType</key>
            <string>IKEv2</string>
        </dict>
    </array>
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
