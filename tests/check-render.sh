#!/usr/bin/env bash
# Offline checks for config rendering, client certificates, and the Apple profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=lib/certs.sh
source "${ROOT}/lib/certs.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_fail() {
  local label="$1"
  shift
  if ( "$@"; ); then
    fail "${label} should have failed"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$ROOT/install.sh" --help >/dev/null
"$ROOT/issue-client.sh" --help >/dev/null
"$ROOT/revoke-client.sh" --help >/dev/null
assert_fail "missing install args" "$ROOT/install.sh"
assert_fail "bad domain" validate_domain 'not a domain'
assert_fail "bad client" validate_client_name '../alice'
assert_fail "ipv4 as ipv6" normalize_ipv6 '203.0.113.10'
assert_fail "huge v6 pool" normalize_network 'fd00:10:10::/48' ipv6
[[ "$(normalize_ipv6 '2001:0db8:0000::1')" == "2001:db8::1" ]] || fail "ipv6 normalize"
[[ "$(normalize_network '10.10.10.0/24' ipv4)" == "10.10.10.0/24" ]] || fail "v4 pool"

CA_KEY_PATH="${tmp}/private/vpn_client_ca.key"
CA_CRT_PATH="${tmp}/cacerts/vpn_client_ca.crt"
CA_STATE_DIR="${tmp}/ca"
OPENSSL_CNF="${tmp}/openssl.cnf"
CRL_PATH="${tmp}/crls/vpn_client_ca.crl"
IKEV2_SKIP_SERVICE=1
VPN_CA_COUNTRY="CN"
VPN_CA_ORG="IKEv2"
VPN_CA_CN="IKEv2 VPN Client CA"
VPN_DOMAIN="vpn.example.com"
VPN_POOL_V4="10.10.10.0/24"
VPN_POOL_V6="fd00:10:10::/64"
VPN_DNS="1.1.1.1,8.8.8.8,2606:4700:4700::1111"

create_client_ca
[[ "$(subject_for_rightca "$CA_CRT_PATH")" == "C=CN, O=IKEv2, CN=IKEv2 VPN Client CA" ]] \
  || fail "unexpected CA subject: $(subject_for_rightca "$CA_CRT_PATH")"

client_dir="${tmp}/clients/alice"
mkdir -p "$client_dir"
issue_client_cert alice "$client_dir"
openssl verify -CAfile "$CA_CRT_PATH" "${client_dir}/alice.crt" >/dev/null
openssl x509 -in "${client_dir}/alice.crt" -noout -text | grep -q "TLS Web Client Authentication" \
  || fail "client certificate is missing clientAuth"
revoke_certificate "${client_dir}/alice.crt"
openssl crl -in "$CRL_PATH" -noout -text | grep -q "Revoked Certificates" || fail "CRL is empty"

write_ipsec_conf "${tmp}/ipsec.conf"
write_ipsec_secrets "${tmp}/ipsec.secrets" ECDSA
grep -q 'rightauth=pubkey' "${tmp}/ipsec.conf" || fail "missing pubkey auth"
grep -q 'rightsourceip=10.10.10.0/24,fd00:10:10::/64' "${tmp}/ipsec.conf" || fail "missing pools"
grep -q 'esp=aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1' "${tmp}/ipsec.conf" || fail "missing esp"
grep -q 'leftcert=server.crt' "${tmp}/ipsec.conf" || fail "missing leaf cert"
grep -q 'uniqueids=never' "${tmp}/ipsec.conf" || fail "missing uniqueids"
if grep -Eq 'timeout=|eap-mschapv2|Alphajc|bangkok' "${tmp}/ipsec.conf" "${tmp}/ipsec.secrets"; then
  fail "generated config contains a removed setting or a personal value"
fi
if grep -q 'RSA' "${tmp}/ipsec.secrets"; then
  fail "ECDSA secrets include an RSA line"
fi
grep -q ': ECDSA server.key' "${tmp}/ipsec.secrets" || fail "missing ECDSA secret"

p12_pass="abc123def456"
openssl pkcs12 -export \
  -inkey "${client_dir}/alice.key" \
  -in "${client_dir}/alice.crt" \
  -certfile "$CA_CRT_PATH" \
  -out "${client_dir}/alice.p12" \
  -passout "pass:${p12_pass}"
p12_b64="$(base64 -w 0 "${client_dir}/alice.p12")"
write_mobileconfig_xml \
  "${tmp}/alice.mobileconfig" \
  alice \
  "$VPN_DOMAIN" \
  "$p12_pass" \
  "$p12_b64" \
  "11111111-1111-1111-1111-111111111111" \
  "22222222-2222-2222-2222-222222222222" \
  "33333333-3333-3333-3333-333333333333"
python3 - "${tmp}/alice.mobileconfig" <<'PY'
import sys
import xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
text = open(sys.argv[1], encoding="utf-8").read()
required = [
    "<key>IKEv2</key>",
    "<string>Certificate</string>",
    "<key>IPv6</key>",
    "<key>IPv4</key>",
    "<string>com.apple.security.pkcs12</string>",
    "<key>PayloadCertificateUUID</key>",
    "<key>RemoteIdentifier</key>",
    "<string>vpn.example.com</string>",
    "<string>alice</string>",
]
for item in required:
    if item not in text:
        raise SystemExit("missing %s" % item)
if text.count("<integer>1</integer>") != text.count("<key>PayloadVersion</key>"):
    raise SystemExit("boolean fields must use true/false tags")
if "<integer>0</integer>" in text:
    raise SystemExit("boolean fields must use true/false tags")
if text.count("<true/>") < 3 or text.count("<false/>") < 3:
    raise SystemExit("expected IPv4/IPv6 and IKEv2 boolean tags")
ET.fromstring(text)
PY
sign_mobileconfig \
  "${tmp}/alice.mobileconfig" \
  "${tmp}/alice.signed.mobileconfig" \
  "$CA_CRT_PATH" \
  "$CA_KEY_PATH" \
  ""
python3 - "${tmp}/alice.signed.mobileconfig" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if data.startswith(b"<?xml") or data[:1] != b"\x30":
    raise SystemExit("signed profile is not DER")
PY

python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
bad = []
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts or path.name == "README.md":
        continue
    data = path.read_bytes()
    if any(byte > 127 for byte in data):
        bad.append(str(path))
if bad:
    raise SystemExit("non-ASCII bytes in: %s" % ", ".join(bad))
PY

python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
needles = [
    "bang" + "kok." + "alphajc",
    "YourStrong" + "Password123",
    "240d:c000:" + "f0cf",
    "karen_" + "iphone",
]
bad = []
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts or path.name == "check-render.sh":
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for needle in needles:
        if needle in text:
            bad.append("%s (%s)" % (path, needle))
if bad:
    raise SystemExit("copied source values: %s" % ", ".join(bad))
PY

printf 'OK\n'
