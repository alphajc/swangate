#!/usr/bin/env bash
# Offline checks: command dispatch, distro and backend selection, dataplane
# fallback, config rendering, client certificates, Apple profile, and get.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export IKEV2_CONFIG_DIR="${tmp}/etc/ikev2-vpn"
export IKEV2_STATE_DIR="${tmp}/var/lib/ikev2-vpn"
export IKEV2_SKIP_SERVICE=1
export IKEV2_LETSENCRYPT_DIR="${tmp}/etc/letsencrypt"
IKEV2_HOME="$ROOT"
# shellcheck source=lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=lib/distro.sh
source "${ROOT}/lib/distro.sh"
# shellcheck source=lib/firewall.sh
source "${ROOT}/lib/firewall.sh"
# shellcheck source=lib/certs.sh
source "${ROOT}/lib/certs.sh"
# shellcheck source=lib/commands.sh
source "${ROOT}/lib/commands.sh"

pass=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
ok() {
  pass=$((pass + 1))
}
expect_fail() {
  local label="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    fail "${label} should have failed"
  fi
  ok
}
expect_eq() {
  [[ "$2" == "$3" ]] || fail "$1: expected '$3', got '$2'"
  ok
}

# Command dispatch.
if "$ROOT/ikev2" >/dev/null 2>&1; then fail "ikev2 without a command should fail"; fi
"$ROOT/ikev2" help | grep -q 'install' || fail "help lists install"
if "$ROOT/ikev2" bogus >/dev/null 2>&1; then fail "unknown command should fail"; fi
for sub in install issue revoke status; do
  "$ROOT/ikev2" "$sub" --help | grep -q "Usage: ikev2 ${sub}" || fail "${sub} --help"
done
expect_fail "install without ipv6" "$ROOT/ikev2" install --domain vpn.example.com
expect_fail "bad backend" "$ROOT/ikev2" install --domain vpn.example.com --ipv6 2001:db8::1 --backend nope
expect_fail "issue without name" "$ROOT/ikev2" issue
ok

# Validators.
expect_fail "bad domain" validate_domain 'not a domain'
expect_fail "bad client" validate_client_name '../alice'
expect_fail "ipv4 as ipv6" normalize_ipv6 '203.0.113.10'
expect_fail "huge v6 pool" normalize_network 'fd00:10:10::/48' ipv6
expect_eq "ipv6 normalize" "$(normalize_ipv6 '2001:0db8:0000::1')" "2001:db8::1"
expect_eq "dns v4" "$(dns_for_family '1.1.1.1,2606:4700:4700::1111,8.8.8.8' ipv4)" "1.1.1.1,8.8.8.8"
expect_eq "dns v6" "$(dns_for_family '1.1.1.1,2606:4700:4700::1111' ipv6)" "2606:4700:4700::1111"

# Distribution families.
os_release() {
  local file="${tmp}/os-release-$1"
  printf '%s\n' "${@:2}" >"$file"
  printf '%s\n' "$file"
}
family_of() {
  ( detect_distro "$1" >/dev/null && printf '%s\n' "$DISTRO_FAMILY" )
}
expect_eq ubuntu "$(family_of "$(os_release ubuntu 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"')")" debian
expect_eq debian "$(family_of "$(os_release debian 'ID=debian' 'VERSION_ID="12"')")" debian
expect_eq mint "$(family_of "$(os_release mint 'ID=linuxmint' 'ID_LIKE="ubuntu debian"')")" debian
expect_eq rocky "$(family_of "$(os_release rocky 'ID="rocky"' 'ID_LIKE="rhel centos fedora"' 'VERSION_ID="9.4"')")" rhel
expect_eq alma "$(family_of "$(os_release alma 'ID="almalinux"' 'ID_LIKE="rhel centos fedora"')")" rhel
expect_eq fedora "$(family_of "$(os_release fedora 'ID=fedora' 'VERSION_ID=40')")" rhel
expect_eq centos7 "$(family_of "$(os_release centos 'ID="centos"' 'ID_LIKE="rhel fedora"' 'VERSION_ID="7"')")" rhel
expect_eq amazon "$(family_of "$(os_release amzn 'ID="amzn"' 'ID_LIKE="fedora"')")" rhel
expect_eq leap "$(family_of "$(os_release leap 'ID="opensuse-leap"' 'ID_LIKE="suse opensuse"')")" suse
expect_eq sles "$(family_of "$(os_release sles 'ID="sles"')")" suse
expect_eq arch "$(family_of "$(os_release arch 'ID=arch')")" arch
expect_eq manjaro "$(family_of "$(os_release manjaro 'ID=manjaro' 'ID_LIKE=arch')")" arch
expect_eq alpine "$(family_of "$(os_release alpine 'ID=alpine' 'VERSION_ID=3.20.0')")" alpine
expect_fail nixos detect_distro "$(os_release nixos 'ID=nixos')"
expect_fail gentoo detect_distro "$(os_release gentoo 'ID=gentoo')"
expect_fail void detect_distro "$(os_release void 'ID="void"')"
expect_fail unknown detect_distro "$(os_release unknown 'ID=plan9')"
expect_fail missing detect_distro "${tmp}/does-not-exist"

# Package manager per family.
pkg_manager_for() {
  (
    DISTRO_FAMILY="$1"
    DISTRO_NAME="test"
    PKG_MANAGER=""
    local present=" $2 "
    have_cmd() { [[ "$present" == *" $1 "* ]]; }
    detect_pkg_manager
    printf '%s\n' "$PKG_MANAGER"
  )
}
expect_eq apt "$(pkg_manager_for debian 'apt-get')" apt-get
expect_eq dnf "$(pkg_manager_for rhel 'dnf yum')" dnf
expect_eq yum "$(pkg_manager_for rhel 'yum')" yum
expect_eq zypper "$(pkg_manager_for suse 'zypper')" zypper
expect_eq pacman "$(pkg_manager_for arch 'pacman')" pacman
expect_eq apk "$(pkg_manager_for alpine 'apk')" apk
expect_fail "no dnf or yum" pkg_manager_for rhel ''
for fam in debian rhel suse arch alpine; do
  DISTRO_FAMILY="$fam"
  required_packages | grep -qx strongswan || fail "${fam} requires strongswan"
  required_packages | grep -Eqx 'python3?|python' || fail "${fam} requires python"
done
DISTRO_FAMILY=alpine
required_packages | grep -qx bash || fail "alpine requires bash"
ok

# StrongSwan backend selection with fake services.
backend_for() {
  (
    SERVICE_MANAGER=systemd
    local units="$1" enabled="$2" cmds="$3" want="${4:-auto}"
    svc_exists() { [[ " $units " == *" $1:"* ]]; }
    svc_definition() {
      local entry
      for entry in $units; do
        [[ "${entry%%:*}" == "$1" ]] || continue
        case "${entry#*:}" in
          starter) printf 'ExecStart=/usr/sbin/ipsec start --nofork\n' ;;
          swanctl) printf 'ExecStart=/usr/sbin/charon-systemd\nExecStartPost=/usr/sbin/swanctl --load-all\n' ;;
        esac
      done
    }
    svc_is_enabled() { [[ " $enabled " == *" $1 "* ]]; }
    have_cmd() { [[ " $cmds " == *" $1 "* ]]; }
    install_swanctl_fallback() { :; }
    select_backend "$want" >/dev/null
    printf '%s %s %s\n' "$VPN_BACKEND" "$VPN_SERVICE" "${OTHER_SWAN_SERVICE:-none}"
  )
}
expect_eq "ubuntu starter" "$(backend_for 'strongswan-starter:starter' '' 'ipsec')" "ipsec strongswan-starter none"
expect_eq "fedora both" "$(backend_for 'strongswan-starter:starter strongswan:swanctl' '' 'strongswan swanctl')" \
  "swanctl strongswan strongswan-starter"
expect_eq "enabled starter wins" \
  "$(backend_for 'strongswan-starter:starter strongswan:swanctl' 'strongswan-starter' 'ipsec swanctl')" \
  "ipsec strongswan-starter strongswan"
expect_eq "forced ipsec" "$(backend_for 'strongswan-starter:starter strongswan:swanctl' '' 'ipsec swanctl' ipsec)" \
  "ipsec strongswan-starter strongswan"
expect_eq "arch swanctl only" "$(backend_for 'strongswan:swanctl' '' 'swanctl')" "swanctl strongswan none"
expect_fail "forced ipsec without starter" backend_for 'strongswan:swanctl' '' 'swanctl' ipsec
expect_fail "no service" backend_for '' '' ''

# Firewall selection.
firewall_for() {
  (
    local running="$1" cmds="$2" want="${3:-auto}"
    firewalld_running() { [[ "$running" == "yes" ]]; }
    have_cmd() { [[ " $cmds " == *" $1 "* ]]; }
    select_firewall "$want" >/dev/null
    printf '%s\n' "$VPN_FIREWALL"
  )
}
expect_eq "firewalld first" "$(firewall_for yes 'iptables ip6tables nft')" firewalld
expect_eq "iptables next" "$(firewall_for no 'iptables ip6tables nft')" iptables
expect_eq "nft last" "$(firewall_for no 'nft')" nftables
expect_eq "forced nft" "$(firewall_for no 'iptables ip6tables nft' nftables)" nftables
expect_fail "no firewall" firewall_for no ''
expect_fail "firewalld not running" firewall_for no 'iptables ip6tables' firewalld

# Dataplane: kernel XFRM or kernel-libipsec.
mkdir -p "${tmp}/plugins/ipsec/plugins"
: >"${tmp}/plugins/ipsec/plugins/libstrongswan-kernel-libipsec.so"
printf 'name         : authenc(hmac(sha256),cbc(aes))\n' >"${tmp}/crypto-ok"
printf 'name         : gcm(aes)\n' >"${tmp}/crypto-missing"
dataplane_for() {
  (
    CRYPTO_FILE="$1"
    IKEV2_PLUGIN_DIRS="$2"
    TUN_DEVICE=/dev/null
    kernel_xfrm_probe() { return 1; }
    select_dataplane "${3:-auto}" >/dev/null
    printf '%s\n' "$VPN_DATAPLANE"
  )
}
expect_eq "kernel crypto" "$(dataplane_for "${tmp}/crypto-ok" "${tmp}/plugins")" kernel
expect_eq "libipsec fallback" "$(dataplane_for "${tmp}/crypto-missing" "${tmp}/plugins")" libipsec
expect_eq "forced kernel" "$(dataplane_for "${tmp}/crypto-missing" "${tmp}/none" kernel)" kernel
expect_fail "no crypto and no plugin" dataplane_for "${tmp}/crypto-missing" "${tmp}/none"
write_libipsec_conf "${tmp}/strongswan.d" libipsec
grep -q 'load = yes' "${tmp}/strongswan.d/zz-ikev2-vpn.conf" || fail "libipsec load"
write_libipsec_conf "${tmp}/strongswan.d" kernel
grep -q 'load = no' "${tmp}/strongswan.d/zz-ikev2-vpn.conf" || fail "kernel load"
ok

# Firewall rules.
rules="$(iptables_rules kernel 10.10.10.0/24 fd00:10:10::/64 eth0)"
grep -q 'iptables filter FORWARD -m policy --pol ipsec --dir in -j ACCEPT' <<<"$rules" || fail "v4 policy"
grep -q 'ip6tables nat POSTROUTING -s fd00:10:10::/64 -o eth0 -j MASQUERADE' <<<"$rules" || fail "v6 nat"
grep -q 'ip6tables mangle FORWARD .*TCPMSS' <<<"$rules" || fail "v6 mss"
rules="$(iptables_rules libipsec 10.10.10.0/24 fd00:10:10::/64 eth0)"
grep -q 'iptables filter FORWARD -i ipsec0 -j ACCEPT' <<<"$rules" || fail "libipsec forward"
if grep -q -- '--pol ipsec' <<<"$rules"; then fail "libipsec must not use policy match"; fi
nft_text="$(nftables_ruleset kernel 10.10.10.0/24 fd00:10:10::/64 eth0)"
grep -q 'meta secpath exists accept' <<<"$nft_text" || fail "nft secpath"
grep -q 'ip6 saddr fd00:10:10::/64 oifname "eth0" masquerade' <<<"$nft_text" || fail "nft v6 nat"
grep -q 'udp dport { 500, 4500 } accept' <<<"$nft_text" || fail "nft ports"
grep -q 'maxseg size set rt mtu' <<<"$nft_text" || fail "nft mss"
if grep -q 'maxseg' <<<"$(nftables_ruleset kernel 10.10.10.0/24 fd00:10:10::/64 eth0 no)"; then
  fail "nft without mss"
fi
grep -q 'iifname "ipsec0" accept' <<<"$(nftables_ruleset libipsec 10.10.10.0/24 fd00:10:10::/64 eth0)" \
  || fail "nft libipsec"
if have_cmd nft && nft -c -f - <<<"$nft_text" >/dev/null 2>&1; then
  ok
fi

# StrongSwan configuration for both backends.
VPN_DOMAIN="vpn.example.com"
VPN_CA_SUBJECT="C=CN, O=IKEv2, CN=IKEv2 VPN Client CA"
VPN_POOL_V4="10.10.10.0/24"
VPN_POOL_V6="fd00:10:10::/64"
VPN_DNS="1.1.1.1,8.8.8.8,2606:4700:4700::1111"
set_swan_paths ipsec /etc
expect_eq "ipsec path" "$SWAN_CONF" /etc/ipsec.conf
expect_eq "ipsec cacerts" "$CA_PUBLISHED_CRT" /etc/ipsec.d/cacerts/vpn_client_ca.crt
set_swan_paths swanctl /etc/strongswan
expect_eq "fedora swanctl path" "$SWAN_CONF" /etc/strongswan/swanctl/conf.d/ikev2-vpn.conf
expect_eq "fedora crl" "$CRL_PATH" /etc/strongswan/swanctl/x509crl/vpn_client_ca.crl
expect_eq "fedora strongswan.d" "$STRONGSWAN_D" /etc/strongswan/strongswan.d

write_ipsec_conf "${tmp}/ipsec.conf"
SERVER_KEY=/etc/ipsec.d/private/server.key
write_ipsec_secrets "${tmp}/ipsec.secrets" ECDSA
grep -q 'rightauth=pubkey' "${tmp}/ipsec.conf" || fail "missing pubkey auth"
grep -q 'rightsourceip=10.10.10.0/24,fd00:10:10::/64' "${tmp}/ipsec.conf" || fail "missing pools"
grep -q 'esp=aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1' "${tmp}/ipsec.conf" || fail "missing esp"
grep -q 'leftcert=server.crt' "${tmp}/ipsec.conf" || fail "missing leaf cert"
if grep -Eq 'timeout=|eap-mschapv2' "${tmp}/ipsec.conf"; then fail "removed setting in ipsec.conf"; fi
if grep -q 'RSA' "${tmp}/ipsec.secrets"; then fail "ECDSA secrets include RSA"; fi

write_swanctl_conf "${tmp}/swanctl.conf"
sw="$(cat "${tmp}/swanctl.conf")"
grep -q 'auth = pubkey' <<<"$sw" || fail "swanctl pubkey"
grep -q 'cacerts = vpn_client_ca.crt' <<<"$sw" || fail "swanctl cacerts"
grep -q 'local_ts = 0.0.0.0/0,::/0' <<<"$sw" || fail "swanctl full tunnel"
grep -q 'esp_proposals = aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1,default' <<<"$sw" \
  || fail "swanctl esp"
grep -q 'addrs = fd00:10:10::/64' <<<"$sw" || fail "swanctl v6 pool"
grep -q 'dns = 2606:4700:4700::1111' <<<"$sw" || fail "swanctl v6 dns"
grep -q 'dns = 1.1.1.1,8.8.8.8' <<<"$sw" || fail "swanctl v4 dns"
[[ "$(grep -c '{' <<<"$sw")" == "$(grep -c '}' <<<"$sw")" ]] || fail "swanctl braces"
ensure_swanctl_include "${tmp}/sw/swanctl.conf"
ensure_swanctl_include "${tmp}/sw/swanctl.conf"
expect_eq "include once" "$(grep -c 'include conf.d' "${tmp}/sw/swanctl.conf")" 1
ok

# End to end: install-time CA, then issue, revoke, reissue, and status.
swan="${tmp}/swan"
set_swan_paths swanctl "$swan"
VPN_CA_COUNTRY=CN
VPN_CA_ORG=IKEv2
VPN_CA_CN="IKEv2 VPN Client CA"
create_client_ca >/dev/null
create_client_ca >/dev/null
publish_client_ca
openssl verify -CAfile "$CA_CRT_PATH" "$CA_PUBLISHED_CRT" >/dev/null || fail "published CA"
mkdir -p "$CERT_DIR" "$KEY_DIR" "$CACERT_DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/CN=${VPN_DOMAIN}" -keyout "$SERVER_KEY" -out "$SERVER_CRT" >/dev/null 2>&1
expect_eq "server key type" "$(detect_key_type "$SERVER_KEY")" ECDSA
VPN_IPV6=2001:db8::1
VPN_INTERFACE=eth0
VPN_CLIENTS_DIR="${tmp}/clients"
VPN_BACKEND=swanctl
VPN_SWAN_ETC="$swan"
VPN_SERVICE=strongswan
VPN_SERVICE_MANAGER=systemd
VPN_FIREWALL=nftables
VPN_DATAPLANE=libipsec
VPN_DISTRO_FAMILY=rhel
VPN_DISTRO_ID=rocky
save_config
require_root() { :; }
svc_is_active() { return 1; }
swan_listing() { printf 'ikev2-cert: IKEv2\n'; }

cmd_issue alice >"${tmp}/issue.out"
grep -q "PKCS#12 password:" "${tmp}/issue.out" || fail "issue prints password"
for f in alice.crt alice.key alice.p12 alice.mobileconfig ca.crt connection.txt; do
  [[ -f "${VPN_CLIENTS_DIR}/alice/${f}" ]] || fail "missing ${f}"
done
[[ ! -e "${VPN_CLIENTS_DIR}/alice/alice.csr" ]] || fail "CSR left behind"
openssl verify -CAfile "$CA_CRT_PATH" "${VPN_CLIENTS_DIR}/alice/alice.crt" >/dev/null || fail "client cert chain"
openssl x509 -in "${VPN_CLIENTS_DIR}/alice/alice.crt" -noout -text | grep -q "TLS Web Client Authentication" \
  || fail "clientAuth EKU"
openssl x509 -in "${VPN_CLIENTS_DIR}/alice/alice.crt" -noout -ext subjectAltName | grep -q "DNS:alice" \
  || fail "client SAN carries the IKE identity"
p12_pass="$(awk -F': ' '/PKCS#12 password/ {print $2}' "${VPN_CLIENTS_DIR}/alice/connection.txt")"
openssl pkcs12 -in "${VPN_CLIENTS_DIR}/alice/alice.p12" -passin "pass:${p12_pass}" -noout || fail "p12 password"
python3 - "${VPN_CLIENTS_DIR}/alice/alice.mobileconfig" <<'PY' || fail "signed profile"
import sys
data = open(sys.argv[1], "rb").read()
if data[:1] != b"\x30":
    raise SystemExit("not DER")
for needle in (b"<key>IKEv2</key>", b"<string>Certificate</string>", b"<key>IPv6</key>", b"vpn.example.com"):
    if needle not in data:
        raise SystemExit("missing %r" % needle)
PY
expect_fail "duplicate issue" cmd_issue alice
cmd_revoke alice >/dev/null
openssl crl -in "$CRL_PATH" -noout -text | grep -q "Revoked Certificates" || fail "CRL is empty"
[[ -f "${VPN_CLIENTS_DIR}/alice/REVOKED" ]] || fail "revoked marker"
cmd_issue --force alice >/dev/null
[[ ! -f "${VPN_CLIENTS_DIR}/alice/REVOKED" ]] || fail "reissue clears marker"
cmd_issue bob >/dev/null
status_out="$(cmd_status)"
grep -q 'StrongSwan:      swanctl (strongswan) inactive' <<<"$status_out" || fail "status backend"
grep -q 'Dataplane:       libipsec' <<<"$status_out" || fail "status dataplane"
grep -q 'Connection:      ikev2-cert loaded' <<<"$status_out" || fail "status connection"
grep -Eq 'alice +revoked' <<<"$status_out" || fail "status shows revoked alice"
grep -Eq 'alice +valid' <<<"$status_out" || fail "status shows reissued alice"
grep -Eq 'bob +valid' <<<"$status_out" || fail "status shows bob"
ok

# Apple profile XML before signing.
write_mobileconfig_xml "${tmp}/p.mobileconfig" alice "$VPN_DOMAIN" pass "QUJD" \
  11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222 33333333-3333-3333-3333-333333333333
python3 - "${tmp}/p.mobileconfig" <<'PY' || fail "profile xml"
import sys
import xml.etree.ElementTree as ET
text = open(sys.argv[1], encoding="utf-8").read()
ET.fromstring(text)
if text.count("<integer>1</integer>") != text.count("<key>PayloadVersion</key>"):
    raise SystemExit("boolean fields must use true/false tags")
if "<integer>0</integer>" in text:
    raise SystemExit("boolean fields must use true/false tags")
PY

# get.sh installs from a tarball and runs the subcommand.
mkdir -p "${tmp}/tarsrc/ikev2-main"
cp -R "$ROOT/ikev2" "$ROOT/lib" "$ROOT/get.sh" "${tmp}/tarsrc/ikev2-main/"
tar -czf "${tmp}/ikev2.tar.gz" -C "${tmp}/tarsrc" ikev2-main
IKEV2_TARBALL_URL="file://${tmp}/ikev2.tar.gz" IKEV2_PREFIX="${tmp}/prefix/ikev2" IKEV2_BIN="${tmp}/bin/ikev2" \
  bash "$ROOT/get.sh" help >"${tmp}/get.out"
grep -q 'Usage: ikev2' "${tmp}/get.out" || fail "get.sh runs the subcommand"
[[ -x "${tmp}/bin/ikev2" && -f "${tmp}/prefix/ikev2/lib/commands.sh" ]] || fail "get.sh install layout"
"${tmp}/bin/ikev2" status --help >/dev/null || fail "installed command runs through the symlink"
IKEV2_TARBALL_URL="file://${tmp}/ikev2.tar.gz" IKEV2_PREFIX="${tmp}/prefix/ikev2" IKEV2_BIN="${tmp}/bin/ikev2" \
  bash "$ROOT/get.sh" >"${tmp}/get2.out"
grep -q 'sudo ikev2 install' "${tmp}/get2.out" || fail "get.sh without arguments prints the next step"
printf 'not a tarball' >"${tmp}/bad.tar.gz"
if IKEV2_TARBALL_URL="file://${tmp}/bad.tar.gz" IKEV2_PREFIX="${tmp}/prefix2/ikev2" IKEV2_BIN="${tmp}/bin2/ikev2" \
  bash "$ROOT/get.sh" help >/dev/null 2>&1; then
  fail "get.sh must reject a broken archive"
fi
ok

# Repository hygiene.
python3 - "$ROOT" <<'PY' || fail "hygiene"
import pathlib, sys
root = pathlib.Path(sys.argv[1])
needles = ["bang" + "kok." + "alphajc", "YourStrong" + "Password123", "240d:c000:" + "f0cf", "karen_" + "iphone"]
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts:
        continue
    data = path.read_bytes()
    if path.name != "README.md" and any(b > 127 for b in data):
        raise SystemExit("non-ASCII bytes in %s" % path)
    text = data.decode("utf-8", "replace")
    for needle in needles:
        if needle in text:
            raise SystemExit("copied source value in %s" % path)
PY

printf 'OK (%d checks)\n' "$pass"
