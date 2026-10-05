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
if "$ROOT/swangate" >/dev/null 2>&1; then fail "swangate without a command should fail"; fi
"$ROOT/swangate" help | grep -q 'install' || fail "help lists install"
"$ROOT/swangate" help | grep -q 'update' || fail "help lists update"
"$ROOT/swangate" update --help | grep -q 'reissue-clients' || fail "update help lists reissue"
if "$ROOT/swangate" bogus >/dev/null 2>&1; then fail "unknown command should fail"; fi
for sub in install issue revoke status; do
  "$ROOT/swangate" "$sub" --help | grep -q "Usage: swangate ${sub}" || fail "${sub} --help"
done
expect_fail "install without domain" "$ROOT/swangate" install --ipv6 2001:db8::1 </dev/null
expect_fail "bad backend" "$ROOT/swangate" install --domain vpn.example.com --ipv6 2001:db8::1 --backend nope
expect_fail "issue without name" "$ROOT/swangate" issue
VPN_DOMAIN=
VPN_EMAIL=
prompt_install_inputs 2>/dev/null <<'EOF'
vpn.example.com
admin@example.com
EOF
expect_eq "prompt domain" "$VPN_DOMAIN" "vpn.example.com"
expect_eq "prompt email" "$VPN_EMAIL" "admin@example.com"
VPN_DOMAIN=vpn.example.com
VPN_EMAIL=
prompt_install_inputs 2>/dev/null <<'EOF'

EOF
expect_eq "prompt keeps domain" "$VPN_DOMAIN" "vpn.example.com"
expect_eq "prompt skip email" "$VPN_EMAIL" ""
unset VPN_DOMAIN VPN_EMAIL
"$ROOT/swangate" install --help | grep -q 'prompted interactively' || fail "install help mentions interactive prompts"
ok

# Validators.
expect_fail "bad domain" validate_domain 'not a domain'
expect_fail "bad client" validate_client_name '../alice'
expect_fail "ipv4 as ipv6" normalize_ipv6 '203.0.113.10'
expect_fail "huge v6 pool" normalize_network 'fd00:10:10::/48' ipv6
expect_eq "ipv6 normalize" "$(normalize_ipv6 '2001:0db8:0000::1')" "2001:db8::1"
expect_eq "dns v4" "$(dns_for_family '1.1.1.1,2606:4700:4700::1111,8.8.8.8' ipv4)" "1.1.1.1,8.8.8.8"
expect_eq "dns v6" "$(dns_for_family '1.1.1.1,2606:4700:4700::1111' ipv6)" "2606:4700:4700::1111"
expect_eq "pick single" "$(printf 'eth0\t2001:db8::1\n' | pick_host_ipv6 '')" "2001:db8::1"
expect_eq "pick dns" "$(printf 'eth0\t2001:db8::1\neth0\t2001:db8::2\n' | pick_host_ipv6 '' 2001:db8::2)" "2001:db8::2"
expect_eq "pick global" "$(printf 'eth0\tfd00::1\neth0\t2001:218:2001:5000::1\n' | pick_host_ipv6 '')" "2001:218:2001:5000::1"
expect_eq "pick iface" "$(printf 'eth0\t2001:db8::1\neth1\t2001:db8::2\n' | pick_host_ipv6 eth1)" "2001:db8::2"
expect_fail "pick none" pick_host_ipv6 '' </dev/null
expect_fail "pick ambiguous" eval 'printf "eth0\t2001:db8::1\neth0\t2001:db8::2\n" | pick_host_ipv6 ""'
expect_eq "detect unique" "$(
  list_host_ipv6() { printf 'eth0\t2001:db8::1\n'; }
  domain_aaaa_addrs() { :; }
  VPN_DOMAIN=vpn.example.com
  detect_server_ipv6
)" "2001:db8::1"
detect_ambiguous() {
  (
    list_host_ipv6() { printf 'eth0\t2001:db8::1\neth0\t2001:db8::2\n'; }
    domain_aaaa_addrs() { :; }
    VPN_DOMAIN=vpn.example.com
    detect_server_ipv6
  )
}
expect_fail "detect ambiguous" detect_ambiguous

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
grep -q 'fragment_size = 576' "${tmp}/strongswan.d/zz-ikev2-vpn.conf" || fail "fragment_size"
write_libipsec_conf "${tmp}/strongswan.d" kernel
grep -q 'load = no' "${tmp}/strongswan.d/zz-ikev2-vpn.conf" || fail "kernel load"
grep -q 'fragment_size = 576' "${tmp}/strongswan.d/zz-ikev2-vpn.conf" || fail "fragment_size kept"
ok

# Firewall rules.
rules="$(iptables_rules kernel 10.10.10.0/24 fd00:10:10::/64 eth0)"
grep -q 'iptables filter FORWARD -m policy --pol ipsec --dir in -j ACCEPT' <<<"$rules" || fail "v4 policy"
grep -q 'ip6tables nat POSTROUTING -s fd00:10:10::/64 -o eth0 -m policy --dir out --pol none -j MASQUERADE' <<<"$rules" || fail "v6 nat"
grep -q 'iptables filter INPUT -m conntrack --ctstate INVALID -j DROP' <<<"$rules" || fail "v4 invalid"
grep -q 'iptables filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' <<<"$rules" || fail "v4 established"
grep -q 'ip6tables mangle FORWARD .*TCPMSS' <<<"$rules" || fail "v6 mss"
rules="$(iptables_rules libipsec 10.10.10.0/24 fd00:10:10::/64 eth0)"
grep -q 'iptables filter FORWARD -i ipsec0 -j ACCEPT' <<<"$rules" || fail "libipsec forward"
if grep -q -- '--pol ipsec' <<<"$rules"; then fail "libipsec must not use policy match"; fi
nft_text="$(nftables_ruleset kernel 10.10.10.0/24 fd00:10:10::/64 eth0)"
grep -q 'meta secpath exists accept' <<<"$nft_text" || fail "nft secpath"
grep -q 'ip6 saddr fd00:10:10::/64 oifname "eth0" rt ipsec missing masquerade' <<<"$nft_text" || fail "nft v6 nat"
grep -q 'ct state invalid drop' <<<"$nft_text" || fail "nft invalid"
grep -q 'ct state { established, related } accept' <<<"$nft_text" || fail "nft established"
grep -q 'udp dport { 500, 4500 } accept' <<<"$nft_text" || fail "nft ports"
grep -q 'maxseg size set rt mtu' <<<"$nft_text" || fail "nft mss"
if grep -q 'maxseg' <<<"$(nftables_ruleset kernel 10.10.10.0/24 fd00:10:10::/64 eth0 no)"; then
  fail "nft without mss"
fi
grep -q 'iifname "ipsec0" accept' <<<"$(nftables_ruleset libipsec 10.10.10.0/24 fd00:10:10::/64 eth0)" \
  || fail "nft libipsec"
if have_cmd nft; then
  sudo nft -c -f - <<<"$nft_text" >/dev/null || fail "nft ruleset rejected"
  sudo nft -c -f - <<<"$(nftables_ruleset libipsec 10.10.10.0/24 fd00:10:10::/64 eth0)" >/dev/null \
    || fail "nft libipsec ruleset rejected"
  ok
fi

# Kernel settings. BBR and conntrack are optional and passed in explicitly.
sysctl_text="$(sysctl_settings eth0 no no)"
grep -q 'net.ipv4.ip_forward = 1' <<<"$sysctl_text" || fail "sysctl forward"
grep -q 'net.ipv4.conf.all.rp_filter = 0' <<<"$sysctl_text" || fail "sysctl rp_filter"
grep -q 'net.ipv4.conf.eth0.rp_filter = 0' <<<"$sysctl_text" || fail "sysctl iface rp_filter"
grep -q 'net.ipv4.conf.all.src_valid_mark = 1' <<<"$sysctl_text" || fail "sysctl src_valid_mark"
grep -q 'net.ipv6.conf.all.accept_ra = 2' <<<"$sysctl_text" || fail "sysctl accept_ra"
grep -q 'net.ipv6.conf.eth0.accept_ra = 2' <<<"$sysctl_text" || fail "sysctl iface accept_ra"
grep -q 'net.ipv6.conf.eth0.forwarding = 1' <<<"$sysctl_text" || fail "sysctl iface forwarding"
grep -q 'net.ipv4.conf.all.send_redirects = 0' <<<"$sysctl_text" || fail "sysctl send_redirects"
grep -q 'net.ipv6.conf.all.accept_redirects = 0' <<<"$sysctl_text" || fail "sysctl v6 redirects"
grep -q 'net.ipv4.tcp_mtu_probing = 1' <<<"$sysctl_text" || fail "sysctl mtu probing"
if grep -q 'tcp_congestion_control' <<<"$sysctl_text"; then fail "bbr omitted unless requested"; fi
if grep -q 'nf_conntrack_max' <<<"$sysctl_text"; then fail "conntrack omitted unless requested"; fi
sysctl_extra="$(sysctl_settings 'eth0.10' yes yes)"
grep -q 'net.ipv4.conf.eth0/10.rp_filter = 0' <<<"$sysctl_extra" || fail "vlan sysctl path"
grep -q 'net.ipv6.conf.eth0/10.accept_ra = 2' <<<"$sysctl_extra" || fail "vlan accept_ra"
grep -q 'net.core.default_qdisc = fq' <<<"$sysctl_extra" || fail "bbr qdisc"
grep -q 'net.ipv4.tcp_congestion_control = bbr' <<<"$sysctl_extra" || fail "bbr"
grep -q 'net.netfilter.nf_conntrack_max = 262144' <<<"$sysctl_extra" || fail "conntrack max"
grep -q 'net.netfilter.nf_conntrack_udp_timeout_stream = 300' <<<"$sysctl_extra" || fail "udp timeout"
ok

moddir="${tmp}/modprobe.d"
mkdir -p "$moddir"
printf 'install esp4 /bin/false\ninstall esp6 /usr/bin/false\n' >"${moddir}/disable-esp.conf"
printf 'install e1000 /sbin/modprobe --ignore-install e1000\n' >"${moddir}/other.conf"
esp_warn="$(IKEV2_MODPROBE_DIRS="$moddir" warn_blocked_esp_modules 2>&1 || true)"
grep -q 'esp4 is disabled' <<<"$esp_warn" || fail "esp4 warning"
grep -q 'esp6 is disabled' <<<"$esp_warn" || fail "esp6 warning"
if grep -q 'e1000' <<<"$esp_warn"; then fail "unrelated modprobe line warned"; fi
esp_ok="$(IKEV2_MODPROBE_DIRS="${tmp}/no-such-modprobe" warn_blocked_esp_modules 2>&1 || true)"
[[ -z "$esp_ok" ]] || fail "missing modprobe dir should be quiet"
ok

# StrongSwan configuration for both backends.
VPN_DOMAIN="vpn.example.com"
VPN_CA_SUBJECT="C=CN, O=IKEv2, CN=IKEv2 VPN Client CA"
VPN_POOL_V4="10.10.10.0/24"
VPN_POOL_V6="fd00:10:10::/64"
VPN_DNS="1.1.1.1,8.8.8.8,2606:4700:4700::1111"
set_swan_paths ipsec /etc
expect_eq "ipsec path" "$SWAN_CONF" /etc/ipsec.conf
expect_eq "ipsec cacerts" "$CA_PUBLISHED_CRT" /etc/ipsec.d/cacerts/vpn_client_ca.crt
expect_eq "ipsec chain outside cacerts" "$SERVER_CHAIN" "${IKEV2_CONFIG_DIR}/server-chain.pem"
set_swan_paths swanctl /etc/strongswan
expect_eq "fedora swanctl path" "$SWAN_CONF" /etc/strongswan/swanctl/conf.d/ikev2-vpn.conf
expect_eq "fedora crl" "$CRL_PATH" /etc/strongswan/swanctl/x509crl/vpn_client_ca.crl
expect_eq "fedora strongswan.d" "$STRONGSWAN_D" /etc/strongswan/strongswan.d
expect_eq "swanctl chain outside x509ca" "$SERVER_CHAIN" "${IKEV2_CONFIG_DIR}/server-chain.pem"

write_ipsec_conf "${tmp}/ipsec.conf"
SERVER_KEY=/etc/ipsec.d/private/server.key
write_ipsec_secrets "${tmp}/ipsec.secrets" ECDSA
grep -q 'rightauth=pubkey' "${tmp}/ipsec.conf" || fail "missing pubkey auth"
grep -q 'rightsourceip=10.10.10.0/24,fd00:10:10::/64' "${tmp}/ipsec.conf" || fail "missing pools"
grep -q 'esp=aes256-sha256-modp2048,aes128-sha256-modp2048,aes256gcm16-modp2048,aes128gcm16-modp2048,aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1' "${tmp}/ipsec.conf" || fail "missing esp"
grep -q 'dpddelay=30s' "${tmp}/ipsec.conf" || fail "dpd delay"
grep -q 'dpdtimeout=120s' "${tmp}/ipsec.conf" || fail "dpd timeout"
grep -q 'ikelifetime=24h' "${tmp}/ipsec.conf" || fail "ike lifetime"
grep -q 'lifetime=8h' "${tmp}/ipsec.conf" || fail "child lifetime"
grep -q 'leftcert=server.crt' "${tmp}/ipsec.conf" || fail "missing leaf cert"
grep -q 'fragmentation=yes' "${tmp}/ipsec.conf" || fail "ipsec IKE fragmentation enabled"
grep -q 'mobike=no' "${tmp}/ipsec.conf" || fail "ipsec mobike disabled"
if grep -Eq '(^|[^a-z])timeout=|eap-mschapv2' "${tmp}/ipsec.conf"; then fail "removed setting in ipsec.conf"; fi
if grep -q 'RSA' "${tmp}/ipsec.secrets"; then fail "ECDSA secrets include RSA"; fi

write_swanctl_conf "${tmp}/swanctl.conf"
sw="$(cat "${tmp}/swanctl.conf")"
grep -q 'auth = pubkey' <<<"$sw" || fail "swanctl pubkey"
grep -q 'cacerts = vpn_client_ca.crt' <<<"$sw" || fail "swanctl cacerts"
grep -q 'fragmentation = yes' <<<"$sw" || fail "swanctl IKE fragmentation enabled"
grep -q 'mobike = no' <<<"$sw" || fail "swanctl mobike disabled"
grep -q 'local_ts = 0.0.0.0/0,::/0' <<<"$sw" || fail "swanctl full tunnel"
grep -q 'esp_proposals = aes256-sha256-modp2048,aes128-sha256-modp2048,aes256gcm16-modp2048,aes128gcm16-modp2048,aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1' <<<"$sw" \
  || fail "swanctl esp"
grep -q 'proposals = aes256-sha256-modp2048,aes128-sha256-modp2048,aes256-sha1-modp2048$' <<<"$sw" \
  || fail "swanctl ike proposals"
if grep -q ',default' <<<"$sw"; then fail "swanctl must not include default proposals"; fi
grep -q 'dpd_delay = 30s' <<<"$sw" || fail "swanctl dpd"
grep -q 'dpd_timeout = 120s' <<<"$sw" || fail "swanctl dpd timeout"
grep -q 'rekey_time = 24h' <<<"$sw" || fail "swanctl ike rekey"
grep -q 'life_time = 8h' <<<"$sw" || fail "swanctl child lifetime"
grep -q 'rekey_time = 7h' <<<"$sw" || fail "swanctl child rekey"
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
# Fake LE intermediate first, then sign the server leaf with it so issuer CN
# matches chain.pem (mirrors Let's Encrypt YE2/E7 + leaf).
live="${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}"
mkdir -p "$live"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/CN=Fake LE Intermediate" -keyout "${tmp}/int.key" -out "${live}/chain.pem" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -subj "/CN=${VPN_DOMAIN}" -keyout "$SERVER_KEY" -out "${tmp}/server.csr" >/dev/null 2>&1
openssl x509 -req -in "${tmp}/server.csr" -CA "${live}/chain.pem" -CAkey "${tmp}/int.key" \
  -CAcreateserial -days 30 -out "$SERVER_CRT" >/dev/null 2>&1
rm -f "${tmp}/server.csr"
expect_eq "server key type" "$(detect_key_type "$SERVER_KEY")" ECDSA
# sync_server_cert must keep the LE chain out of StrongSwan's CA dir and remove
# the legacy intermediate.crt that caused IKE_AUTH CERT CERT fragmentation.
cp "$SERVER_CRT" "${live}/cert.pem"
cp "$SERVER_KEY" "${live}/privkey.pem"
: >"${CACERT_DIR}/intermediate.crt"
sync_server_cert >/dev/null
[[ -f "$SERVER_CHAIN" ]] || fail "server chain missing at ${SERVER_CHAIN}"
[[ ! -e "${CACERT_DIR}/intermediate.crt" ]] || fail "legacy intermediate.crt must be removed"
openssl x509 -in "$SERVER_CHAIN" -noout -subject | grep -q 'Fake LE Intermediate' \
  || fail "chain not copied outside cacerts"
case "$SERVER_CHAIN" in
  */server-chain.pem) ;;
  *) fail "unexpected SERVER_CHAIN path: ${SERVER_CHAIN}" ;;
esac
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
for needle in (
    b"<key>IKEv2</key>",
    b"<string>Certificate</string>",
    b"<key>CertificateType</key>",
    b"<string>ECDSA256</string>",
    b"<key>IKESecurityAssociationParameters</key>",
    b"<key>ChildSecurityAssociationParameters</key>",
    b"<key>ServerCertificateIssuerCommonName</key>",
    b"<string>Fake LE Intermediate</string>",
    b"<key>ServerCertificateCommonName</key>",
    b"<string>com.apple.security.pkcs1</string>",
    b"server-issuer.crt",
    b"<key>IPv6</key>",
    b"vpn.example.com",
):
    if needle not in data:
        raise SystemExit("missing %r" % needle)
if b"<key>IKESAParameters</key>" in data or b"<key>ChildSAParameters</key>" in data:
    raise SystemExit("legacy SA parameter key names must not be used")
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

# update --skip-self re-applies install from saved config and can reissue clients.
rm -f "${tmp}/update-install.args" "${tmp}/update-issue.log"
cmd_install() {
  printf '%s\0' "$@" >"${tmp}/update-install.args"
  log "mock install"
}
cmd_issue() {
  printf '%s\n' "$*" >>"${tmp}/update-issue.log"
}
update_out="$(cmd_update --skip-self --reissue-clients 2>&1)"
grep -q 'Re-applying VPN configuration' <<<"$update_out" || fail "update logs re-apply"
python3 - "${tmp}/update-install.args" <<'PY' || fail "update install args"
import sys
args = open(sys.argv[1], "rb").read().split(b"\0")
args = [a.decode() for a in args if a]
need = {
    "--domain": "vpn.example.com",
    "--ipv6": "2001:db8::1",
    "--interface": "eth0",
    "--backend": "swanctl",
    "--firewall": "nftables",
    "--dataplane": "libipsec",
    "--clients-dir": None,
    "--skip-certbot": None,
}
it = iter(args)
for a in it:
    if a in need and need[a] is not None:
        val = next(it, None)
        if val != need[a]:
            raise SystemExit("expected %s %s, got %s" % (a, need[a], val))
        del need[a]
    elif a in need:
        del need[a]
if need:
    raise SystemExit("missing %s" % sorted(need))
PY
grep -qx -- '--force alice' "${tmp}/update-issue.log" || fail "update reissues alice"
grep -qx -- '--force bob' "${tmp}/update-issue.log" || fail "update reissues bob"
[[ "$(grep -c -- '--force' "${tmp}/update-issue.log")" == 2 ]] || fail "update must not reissue revoked-only names"
# Restore real command implementations shadowed by the mocks above.
# shellcheck source=lib/commands.sh
source "${ROOT}/lib/commands.sh"
ok

# Apple profile XML before signing. ECDSA server leaf => ECDSA client cert.
expect_eq "apple client cert type" "$(apple_certificate_type "${VPN_CLIENTS_DIR}/alice/alice.crt")" ECDSA256
expect_eq "apple server ecdsa type" "$(apple_certificate_type "$SERVER_CRT")" ECDSA256
expect_eq "server subject cn" "$(cert_common_name "$SERVER_CRT" subject)" "$VPN_DOMAIN"
expect_eq "server issuer cn" "$(cert_common_name "$SERVER_CRT" issuer)" "Fake LE Intermediate"
expect_eq "ec curve for ECDSA256" "$(ec_curve_for_apple_type ECDSA256)" prime256v1
expect_eq "ec curve for ECDSA384" "$(ec_curve_for_apple_type ECDSA384)" secp384r1
expect_eq "ec curve for ECDSA521" "$(ec_curve_for_apple_type ECDSA521)" secp521r1
issuer_der_b64="$(apple_issuer_der_b64 "$SERVER_CRT" "${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}/chain.pem")"
[[ -n "$issuer_der_b64" ]] || fail "apple_issuer_der_b64 empty"
# Wrong intermediate CN must not be selected when the leaf issuer is YE2-like.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/CN=Wrong Intermediate" -keyout "${tmp}/wrong.key" -out "${tmp}/wrong-chain.pem" >/dev/null 2>&1
if apple_issuer_der_b64 "$SERVER_CRT" "${tmp}/wrong-chain.pem" >/dev/null 2>&1; then
  fail "apple_issuer_der_b64 must reject mismatched issuer CN"
fi
ok
# P-384 server leaf => ECDSA384 client (not hard-coded P-256).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -days 30 \
  -subj "/CN=P384 Issuer" -keyout "${tmp}/p384-iss.key" -out "${tmp}/p384-iss.crt" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes \
  -subj "/CN=${VPN_DOMAIN}" -keyout "${tmp}/p384-server.key" -out "${tmp}/p384-server.csr" >/dev/null 2>&1
openssl x509 -req -in "${tmp}/p384-server.csr" -CA "${tmp}/p384-iss.crt" -CAkey "${tmp}/p384-iss.key" \
  -CAcreateserial -days 30 -out "${tmp}/p384-server.crt" >/dev/null 2>&1
mkdir -p "${tmp}/p384client"
SERVER_CRT="${tmp}/p384-server.crt" issue_client_cert p384client "${tmp}/p384client"
expect_eq "p384 client type" "$(apple_certificate_type "${tmp}/p384client/p384client.crt")" ECDSA384
# Restore ECDSA256 server path used by later checks.
set_swan_paths swanctl "$swan"
issuer_der_b64="$(apple_issuer_der_b64 "$SERVER_CRT" "${LETSENCRYPT_DIR}/live/${VPN_DOMAIN}/chain.pem")"
write_mobileconfig_xml "${tmp}/p.mobileconfig" alice "$VPN_DOMAIN" pass "QUJD" \
  11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222 33333333-3333-3333-3333-333333333333 \
  ECDSA256 "Fake LE Intermediate" "$VPN_DOMAIN" "$issuer_der_b64" 44444444-4444-4444-4444-444444444444
python3 - "${tmp}/p.mobileconfig" <<'PY' || fail "profile xml"
import sys
import xml.etree.ElementTree as ET
text = open(sys.argv[1], encoding="utf-8").read()
ET.fromstring(text)
if text.count("<integer>1</integer>") != text.count("<key>PayloadVersion</key>"):
    raise SystemExit("boolean fields must use true/false tags")
if "<integer>0</integer>" in text:
    raise SystemExit("boolean fields must use true/false tags")
for needle in (
    "<key>CertificateType</key>",
    "<string>ECDSA256</string>",
    "<key>IKESecurityAssociationParameters</key>",
    "<key>ChildSecurityAssociationParameters</key>",
    "<key>ServerCertificateIssuerCommonName</key>",
    "<string>Fake LE Intermediate</string>",
    "<key>ServerCertificateCommonName</key>",
    "<string>com.apple.security.pkcs1</string>",
    "server-issuer.crt",
    "<key>UseConfigurationAttributeInternalIPSubnet</key>",
    "<key>Proxies</key>",
    "<key>OnDemandEnabled</key>",
    "<key>DisableMOBIKE</key>",
    "<key>DisableRedirect</key>",
    "<true/>",
):
    if needle not in text:
        raise SystemExit("missing %r" % needle)
if "<key>DisableMOBIKE</key>\n                <false/>" in text:
    raise SystemExit("DisableMOBIKE must be true when server disables MOBIKE")
if "<key>IKESAParameters</key>" in text or "<key>ChildSAParameters</key>" in text:
    raise SystemExit("legacy SA parameter key names must not be used")
PY

# get.sh installs from a tarball and runs the subcommand.
mkdir -p "${tmp}/tarsrc/swangate-main"
cp -R "$ROOT/swangate" "$ROOT/lib" "$ROOT/get.sh" "${tmp}/tarsrc/swangate-main/"
tar -czf "${tmp}/swangate.tar.gz" -C "${tmp}/tarsrc" swangate-main
IKEV2_TARBALL_URL="file://${tmp}/swangate.tar.gz" IKEV2_PREFIX="${tmp}/prefix/swangate" IKEV2_BIN="${tmp}/bin/swangate" \
  bash "$ROOT/get.sh" help >"${tmp}/get.out"
grep -q 'Usage: swangate' "${tmp}/get.out" || fail "get.sh runs the subcommand"
[[ -x "${tmp}/bin/swangate" && -f "${tmp}/prefix/swangate/lib/commands.sh" ]] || fail "get.sh install layout"
"${tmp}/bin/swangate" status --help >/dev/null || fail "installed command runs through the symlink"
IKEV2_TARBALL_URL="file://${tmp}/swangate.tar.gz" IKEV2_PREFIX="${tmp}/prefix/swangate" IKEV2_BIN="${tmp}/bin/swangate" \
  bash "$ROOT/get.sh" >"${tmp}/get2.out"
grep -q 'sudo swangate install' "${tmp}/get2.out" || fail "get.sh without arguments prints install"
grep -q 'sudo swangate update' "${tmp}/get2.out" || fail "get.sh without arguments prints update"
printf 'not a tarball' >"${tmp}/bad.tar.gz"
if IKEV2_TARBALL_URL="file://${tmp}/bad.tar.gz" IKEV2_PREFIX="${tmp}/prefix2/swangate" IKEV2_BIN="${tmp}/bin2/swangate" \
  bash "$ROOT/get.sh" help >/dev/null 2>&1; then
  fail "get.sh must reject a broken archive"
fi
# get.sh update must inject --skip-self so the just-installed tree is not downloaded twice.
IKEV2_TARBALL_URL="file://${tmp}/swangate.tar.gz" IKEV2_PREFIX="${tmp}/prefix3/swangate" IKEV2_BIN="${tmp}/bin3/swangate" \
  bash "$ROOT/get.sh" update --help >"${tmp}/get-update.out"
grep -q 'Download the latest swangate' "${tmp}/get-update.out" || fail "get.sh update reaches update help"
grep -q '\-\-skip-self' "${tmp}/get-update.out" || fail "update help documents --skip-self"
# fetch_and_install_release installs from a tarball URL into a fresh prefix.
IKEV2_PREFIX="${tmp}/prefix4/swangate"
IKEV2_BIN="${tmp}/bin4/swangate"
IKEV2_TARBALL_URL="file://${tmp}/swangate.tar.gz"
fetch_and_install_release main >/dev/null
[[ -x "${IKEV2_BIN}" && -f "${IKEV2_PREFIX}/lib/commands.sh" ]] || fail "fetch_and_install_release layout"
grep -q 'cmd_update' "${IKEV2_PREFIX}/lib/commands.sh" || fail "fetched tree includes update"
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
