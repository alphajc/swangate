#!/usr/bin/env bash
# Distribution, package, service, StrongSwan backend, and dataplane detection.
# shellcheck disable=SC2034  # Globals are shared across the sourced libraries.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

OS_RELEASE_FILE="${IKEV2_OS_RELEASE:-/etc/os-release}"
CRYPTO_FILE="${IKEV2_CRYPTO_FILE:-/proc/crypto}"
TUN_DEVICE="${IKEV2_TUN_DEVICE:-/dev/net/tun}"
PKG_REFRESHED=0

os_release_value() {
  local file="$1"
  local want="$2"
  local key value
  while IFS='=' read -r key value; do
    [[ "$key" == "$want" ]] || continue
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "$value"
    return 0
  done <"$file"
  return 0
}

# Sets DISTRO_ID, DISTRO_LIKE, DISTRO_VERSION_ID, DISTRO_NAME, DISTRO_FAMILY.
detect_distro() {
  local file="${1:-$OS_RELEASE_FILE}"
  local word
  [[ -r "$file" ]] || die "Cannot read ${file}. Unable to identify this Linux distribution."
  DISTRO_ID="$(os_release_value "$file" ID | tr '[:upper:]' '[:lower:]')"
  DISTRO_LIKE="$(os_release_value "$file" ID_LIKE | tr '[:upper:]' '[:lower:]')"
  DISTRO_VERSION_ID="$(os_release_value "$file" VERSION_ID)"
  DISTRO_NAME="$(os_release_value "$file" PRETTY_NAME)"
  DISTRO_NAME="${DISTRO_NAME:-${DISTRO_ID:-unknown}}"
  DISTRO_FAMILY=""

  case "$DISTRO_ID" in
    nixos)
      die "NixOS is not supported. Configure StrongSwan through services.strongswan in configuration.nix."
      ;;
    gentoo|funtoo|void|slackware|clear-linux-os|solus|guix|sle-micro|fedora-coreos|flatcar|bottlerocket|talos)
      die "${DISTRO_NAME} (ID=${DISTRO_ID}) is not supported."
      ;;
  esac

  for word in $DISTRO_ID $DISTRO_LIKE; do
    case "$word" in
      debian|ubuntu|linuxmint|pop|raspbian|kali|elementary|zorin|deepin|uos|devuan|neon)
        DISTRO_FAMILY=debian
        ;;
      rhel|centos|fedora|rocky|almalinux|ol|amzn|anolis|openeuler|opencloudos|tencentos|circle|eurolinux|navy|virtuozzo)
        DISTRO_FAMILY=rhel
        ;;
      suse|opensuse|opensuse-leap|opensuse-tumbleweed|opensuse-slowroll|sles|sled)
        DISTRO_FAMILY=suse
        ;;
      arch|manjaro|endeavouros|garuda|artix|archarm)
        DISTRO_FAMILY=arch
        ;;
      alpine|postmarketos)
        DISTRO_FAMILY=alpine
        ;;
    esac
    [[ -n "$DISTRO_FAMILY" ]] && break
  done

  if [[ -z "$DISTRO_FAMILY" ]]; then
    die "Unsupported Linux distribution: ${DISTRO_NAME} (ID=${DISTRO_ID:-unknown}, ID_LIKE=${DISTRO_LIKE:-none}). Supported families: Debian/Ubuntu, RHEL/Fedora, SUSE, Arch, Alpine."
  fi
  log "Detected ${DISTRO_NAME} (${DISTRO_FAMILY} family)."
}

# Sets PKG_MANAGER for DISTRO_FAMILY.
detect_pkg_manager() {
  case "$DISTRO_FAMILY" in
    debian)
      have_cmd apt-get && PKG_MANAGER=apt-get
      ;;
    rhel)
      if have_cmd dnf; then
        PKG_MANAGER=dnf
      elif have_cmd yum; then
        PKG_MANAGER=yum
      fi
      ;;
    suse)
      have_cmd zypper && PKG_MANAGER=zypper
      ;;
    arch)
      have_cmd pacman && PKG_MANAGER=pacman
      ;;
    alpine)
      have_cmd apk && PKG_MANAGER=apk
      ;;
  esac
  [[ -n "${PKG_MANAGER:-}" ]] || die "No package manager found for the ${DISTRO_FAMILY} family on ${DISTRO_NAME}."
}

# Sets SERVICE_MANAGER to systemd or openrc.
detect_service_manager() {
  if [[ -n "${IKEV2_SERVICE_MANAGER:-}" ]]; then
    SERVICE_MANAGER="$IKEV2_SERVICE_MANAGER"
  elif have_cmd systemctl && [[ -d /run/systemd/system ]]; then
    SERVICE_MANAGER=systemd
  elif have_cmd rc-service && have_cmd rc-update; then
    SERVICE_MANAGER=openrc
  else
    die "No supported service manager found. systemd or OpenRC is required."
  fi
}

pkg_refresh() {
  [[ "$PKG_REFRESHED" -eq 1 ]] && return 0
  log "Refreshing package metadata with ${PKG_MANAGER}."
  case "$PKG_MANAGER" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update
      ;;
    dnf|yum)
      "$PKG_MANAGER" -y makecache >/dev/null
      ;;
    zypper)
      zypper --non-interactive --gpg-auto-import-keys refresh >/dev/null
      ;;
    pacman)
      # Arch does not support partial upgrades, so sync and upgrade together.
      pacman -Syu --noconfirm
      ;;
    apk)
      apk update >/dev/null
      ;;
  esac
  PKG_REFRESHED=1
}

pkg_available() {
  local name="$1"
  case "$PKG_MANAGER" in
    apt-get)
      [[ -n "$(apt-cache policy "$name" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]]
      ;;
    dnf|yum)
      "$PKG_MANAGER" -q info "$name" >/dev/null 2>&1
      ;;
    zypper)
      zypper --non-interactive --quiet search --match-exact "$name" >/dev/null 2>&1
      ;;
    pacman)
      pacman -Si "$name" >/dev/null 2>&1 || pacman -Qi "$name" >/dev/null 2>&1
      ;;
    apk)
      [[ -n "$(apk search -x "$name" 2>/dev/null)" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

pkg_install() {
  [[ $# -gt 0 ]] || return 0
  log "Installing packages: $*"
  case "$PKG_MANAGER" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y "$@"
      ;;
    dnf|yum)
      "$PKG_MANAGER" install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install --auto-agree-with-licenses "$@"
      ;;
    pacman)
      pacman -S --needed --noconfirm "$@"
      ;;
    apk)
      apk add "$@"
      ;;
  esac
}

python_package() {
  case "$DISTRO_FAMILY" in
    arch) printf 'python\n' ;;
    *) printf 'python3\n' ;;
  esac
}

ensure_python() {
  have_cmd python3 && return 0
  detect_pkg_manager
  pkg_refresh
  pkg_install "$(python_package)" || die "Could not install python3."
  have_cmd python3 || die "python3 is still missing after installation."
}

required_packages() {
  case "$DISTRO_FAMILY" in
    debian) printf '%s\n' strongswan openssl iproute2 python3 ca-certificates ;;
    rhel) printf '%s\n' strongswan openssl iproute python3 ;;
    suse) printf '%s\n' strongswan openssl iproute2 python3 ;;
    arch) printf '%s\n' strongswan openssl iproute2 python ;;
    alpine) printf '%s\n' strongswan openssl iproute2 python3 bash ;;
  esac
}

optional_packages() {
  case "$DISTRO_FAMILY" in
    debian)
      printf '%s\n' strongswan-starter strongswan-pki libcharon-extra-plugins \
        libcharon-extauth-plugins libstrongswan-extra-plugins kmod procps
      ;;
    rhel)
      printf '%s\n' strongswan-libipsec kmod procps-ng util-linux
      ;;
    suse)
      printf '%s\n' strongswan-ipsec kmod procps
      ;;
    arch)
      printf '%s\n' kmod procps-ng
      ;;
    alpine)
      printf '%s\n' kmod procps
      ;;
  esac
}

# Packages that only matter when their command is missing.
command_package_pairs() {
  case "$DISTRO_FAMILY" in
    debian) printf '%s\n' certbot:certbot uuidgen:uuid-runtime ;;
    rhel) printf '%s\n' certbot:certbot uuidgen:util-linux ;;
    suse) printf '%s\n' certbot:python3-certbot certbot:certbot uuidgen:util-linux ;;
    arch) printf '%s\n' certbot:certbot uuidgen:util-linux ;;
    alpine) printf '%s\n' certbot:certbot uuidgen:util-linux-misc ;;
  esac
}

firewall_tool_pairs() {
  case "$DISTRO_FAMILY" in
    debian) printf '%s\n' iptables:iptables ip6tables:iptables ;;
    rhel) printf '%s\n' iptables:iptables-nft iptables:iptables ip6tables:iptables-nft ;;
    suse) printf '%s\n' iptables:iptables ip6tables:iptables ;;
    arch) printf '%s\n' iptables:iptables-nft iptables:iptables ip6tables:iptables-nft ;;
    alpine) printf '%s\n' iptables:iptables ip6tables:ip6tables ;;
  esac
}

enable_epel() {
  local major
  [[ "$DISTRO_FAMILY" == "rhel" && "$DISTRO_ID" != "fedora" ]] || return 1
  if pkg_available epel-release; then
    pkg_install epel-release || return 1
  else
    major="${DISTRO_VERSION_ID%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm" || return 1
  fi
  "$PKG_MANAGER" -y makecache >/dev/null 2>&1 || true
  log "Enabled EPEL."
}

install_command_packages() {
  local pair cmd pkg done_cmd=""
  for pair in "$@"; do
    cmd="${pair%%:*}"
    pkg="${pair#*:}"
    [[ " $done_cmd " == *" $cmd "* ]] && continue
    if have_cmd "$cmd"; then
      done_cmd+=" $cmd"
      continue
    fi
    if pkg_available "$pkg" && pkg_install "$pkg" && have_cmd "$cmd"; then
      done_cmd+=" $cmd"
    fi
  done
}

# Installs everything the VPN needs. $1 is 1 when a host firewall tool is needed.
install_packages() {
  local need_fw="${1:-1}"
  local -a required=() optional=() missing=()
  local pkg
  pkg_refresh
  mapfile -t required < <(required_packages)
  for pkg in "${required[@]}"; do
    pkg_available "$pkg" || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -gt 0 ]] && enable_epel; then
    missing=()
    for pkg in "${required[@]}"; do
      pkg_available "$pkg" || missing+=("$pkg")
    done
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Required packages are not available from the configured repositories: ${missing[*]}"
  fi
  pkg_install "${required[@]}" || die "Failed to install required packages: ${required[*]}"

  for pkg in $(optional_packages); do
    pkg_available "$pkg" && optional+=("$pkg")
  done
  if [[ ${#optional[@]} -gt 0 ]]; then
    pkg_install "${optional[@]}" || warn "Some optional packages failed to install: ${optional[*]}"
  fi

  mapfile -t required < <(command_package_pairs)
  install_command_packages "${required[@]}"
  if [[ "$need_fw" == "1" ]]; then
    mapfile -t required < <(firewall_tool_pairs)
    install_command_packages "${required[@]}"
    if ! have_cmd iptables && ! have_cmd nft && pkg_available nftables; then
      pkg_install nftables || true
    fi
  fi
  require_cmd openssl ip python3
}

install_swanctl_fallback() {
  local -a extra=()
  local pkg
  [[ "$DISTRO_FAMILY" == "debian" ]] || return 0
  for pkg in charon-systemd strongswan-swanctl; do
    pkg_available "$pkg" && extra+=("$pkg")
  done
  [[ ${#extra[@]} -gt 0 ]] && pkg_install "${extra[@]}"
  return 0
}

resolve_certbot() {
  CERTBOT_BIN=""
  if have_cmd certbot; then
    CERTBOT_BIN="$(command -v certbot)"
  elif [[ -x /snap/bin/certbot ]]; then
    CERTBOT_BIN=/snap/bin/certbot
  elif have_cmd snap; then
    log "Installing certbot from snap."
    snap install --classic certbot && CERTBOT_BIN=/snap/bin/certbot
  fi
  [[ -n "$CERTBOT_BIN" ]] || die "certbot is not available. Install certbot, or rerun with --skip-certbot and an existing certificate."
}

svc_exists() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl cat "${name}.service" >/dev/null 2>&1 ;;
    openrc) [[ -x "/etc/init.d/${name}" ]] ;;
    *) return 1 ;;
  esac
}

svc_definition() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl cat "${name}.service" 2>/dev/null ;;
    openrc) cat "/etc/init.d/${name}" 2>/dev/null ;;
  esac
}

svc_is_enabled() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl is-enabled --quiet "$name" 2>/dev/null ;;
    openrc) rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx "$name" ;;
    *) return 1 ;;
  esac
}

svc_is_active() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl is-active --quiet "$name" ;;
    openrc) rc-service "$name" status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

svc_enable_restart() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl enable "$name" >/dev/null
      systemctl restart "$name"
      ;;
    openrc)
      rc-update add "$name" default >/dev/null 2>&1 || true
      rc-service "$name" restart
      ;;
  esac
}

svc_restart() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl restart "$name" ;;
    openrc) rc-service "$name" restart ;;
  esac
}

svc_disable_stop() {
  local name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl disable --now "$name" >/dev/null 2>&1 || true ;;
    openrc)
      rc-service "$name" stop >/dev/null 2>&1 || true
      rc-update del "$name" default >/dev/null 2>&1 || true
      ;;
  esac
}

# Prints starter, swanctl, or unknown for a StrongSwan service definition.
service_kind() {
  local text
  text="$(svc_definition "$1")"
  if grep -Eq 'charon-systemd|swanctl' <<<"$text"; then
    printf 'swanctl\n'
  elif grep -Eq 'starter|ipsec' <<<"$text"; then
    printf 'starter\n'
  else
    printf 'unknown\n'
  fi
}

ipsec_command() {
  if have_cmd ipsec; then
    printf 'ipsec\n'
  elif have_cmd strongswan; then
    printf 'strongswan\n'
  fi
}

detect_swan_etc() {
  if [[ -n "${IKEV2_SWAN_ETC:-}" ]]; then
    printf '%s\n' "$IKEV2_SWAN_ETC"
  elif [[ -d /etc/strongswan ]] && { [[ -e /etc/strongswan/strongswan.conf ]] \
    || [[ -d /etc/strongswan/swanctl ]] || [[ -d /etc/strongswan/ipsec.d ]]; }; then
    printf '/etc/strongswan\n'
  else
    printf '/etc\n'
  fi
}

# Sets STARTER_SERVICE and SWANCTL_SERVICE from installed service definitions.
scan_swan_services() {
  local name kind
  STARTER_SERVICE=""
  SWANCTL_SERVICE=""
  for name in strongswan-starter strongswan strongswan-swanctl ipsec charon; do
    svc_exists "$name" || continue
    kind="$(service_kind "$name")"
    if [[ "$kind" == "starter" && -z "$STARTER_SERVICE" ]]; then
      STARTER_SERVICE="$name"
    elif [[ "$kind" == "swanctl" && -z "$SWANCTL_SERVICE" ]]; then
      SWANCTL_SERVICE="$name"
    fi
  done
}

# Sets VPN_BACKEND, VPN_SERVICE, and OTHER_SWAN_SERVICE. $1 is auto, ipsec, or swanctl.
select_backend() {
  local want="${1:-auto}"
  local ipsec_cmd
  scan_swan_services
  ipsec_cmd="$(ipsec_command)"
  if [[ -z "$STARTER_SERVICE" && -z "$SWANCTL_SERVICE" && "$want" != "ipsec" ]]; then
    install_swanctl_fallback
    scan_swan_services
  fi
  local starter_ok=0 swanctl_ok=0
  [[ -n "$STARTER_SERVICE" && -n "$ipsec_cmd" ]] && starter_ok=1
  [[ -n "$SWANCTL_SERVICE" ]] && have_cmd swanctl && swanctl_ok=1

  case "$want" in
    ipsec)
      [[ "$starter_ok" -eq 1 ]] || die "The ipsec.conf backend was requested, but no StrongSwan starter service and ipsec command were found."
      VPN_BACKEND=ipsec
      ;;
    swanctl)
      [[ "$swanctl_ok" -eq 1 ]] || die "The swanctl backend was requested, but no swanctl service and swanctl command were found."
      VPN_BACKEND=swanctl
      ;;
    auto)
      if [[ "$starter_ok" -eq 1 ]] && svc_is_enabled "$STARTER_SERVICE"; then
        VPN_BACKEND=ipsec
      elif [[ "$swanctl_ok" -eq 1 ]]; then
        VPN_BACKEND=swanctl
      elif [[ "$starter_ok" -eq 1 ]]; then
        VPN_BACKEND=ipsec
      else
        die "StrongSwan is installed, but neither the ipsec starter nor swanctl service is usable."
      fi
      ;;
    *)
      die "Unknown backend: ${want}. Use auto, ipsec, or swanctl."
      ;;
  esac

  if [[ "$VPN_BACKEND" == "ipsec" ]]; then
    VPN_SERVICE="$STARTER_SERVICE"
    OTHER_SWAN_SERVICE="$SWANCTL_SERVICE"
  else
    VPN_SERVICE="$SWANCTL_SERVICE"
    OTHER_SWAN_SERVICE="$STARTER_SERVICE"
  fi
  [[ "$OTHER_SWAN_SERVICE" == "$VPN_SERVICE" ]] && OTHER_SWAN_SERVICE=""
  log "Using the ${VPN_BACKEND} backend through service ${VPN_SERVICE}."
}

ESP_MODPROBE_OVERRIDE="${IKEV2_ESP_MODPROBE_OVERRIDE:-/etc/modprobe.d/00-ikev2-vpn-esp.conf}"

# Prints "module file" for each esp4/esp6 that a modprobe.d file disables with
# "install espN /bin/false", which some cloud images ship.
blocked_esp_modules() {
  local dir conf mod
  local -a dirs=(/etc/modprobe.d /run/modprobe.d /usr/local/lib/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d)
  local install_re='^[[:space:]]*install[[:space:]]+'
  local false_re='/(usr/)?bin/(false|true)([[:space:]]|$)'
  if [[ -n "${IKEV2_MODPROBE_DIRS:-}" ]]; then
    read -r -a dirs <<<"$IKEV2_MODPROBE_DIRS"
  fi
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for conf in "$dir"/*.conf; do
      [[ -f "$conf" ]] || continue
      for mod in esp4 esp6; do
        if grep -Eq "${install_re}${mod}[[:space:]]+${false_re}" "$conf"; then
          printf '%s %s\n' "$mod" "$conf"
        fi
      done
    done
  done
}

esp_modprobe_override() {
  local modprobe_bin="$1"
  printf '# %s\n' "$MANAGED_MARK"
  # shellcheck disable=SC2016  # $CMDLINE_OPTS is expanded by modprobe.
  printf 'install %s %s --ignore-install %s $CMDLINE_OPTS\n' esp4 "$modprobe_bin" esp4 esp6 "$modprobe_bin" esp6
}

# libkmod uses the first install command it reads for a module, and reads
# modprobe.d files sorted by name, so the override must sort before the
# image's own file.
unblock_esp_modules() {
  local blocked mod conf modprobe_bin
  blocked="$(blocked_esp_modules)"
  [[ -n "$blocked" ]] || return 0
  while read -r mod conf; do
    [[ "$conf" == "$ESP_MODPROBE_OVERRIDE" ]] && continue
    warn "Kernel module ${mod} is disabled in ${conf}. Overriding it in ${ESP_MODPROBE_OVERRIDE}."
  done <<<"$blocked"
  modprobe_bin="$(command -v modprobe 2>/dev/null || printf '/sbin/modprobe')"
  mkdir -p "$(dirname "$ESP_MODPROBE_OVERRIDE")"
  esp_modprobe_override "$modprobe_bin" >"$ESP_MODPROBE_OVERRIDE"
  chmod 644 "$ESP_MODPROBE_OVERRIDE"
}

kernel_module_list() {
  printf '%s\n' esp4 esp6 xfrm_user xfrm_algo xfrm4_tunnel xfrm6_tunnel af_key authenc echainiv seqiv \
    cryptd hmac aes aes_generic sha256 sha256_generic sha512 gcm cbc tun \
    ip6table_nat iptable_nat nf_nat ip6table_mangle iptable_mangle xt_policy xt_TCPMSS \
    nf_conntrack xt_conntrack tcp_bbr
}

# Packages that carry ESP and crypto modules some cloud kernels leave out.
kernel_extra_packages() {
  local release
  release="$(uname -r)"
  case "$DISTRO_FAMILY" in
    debian) printf '%s\n' "linux-modules-extra-${release}" ;;
    rhel) printf '%s\n' "kernel-modules-extra-${release}" kernel-modules-extra ;;
    suse) printf '%s\n' kernel-default-extra ;;
  esac
}

install_kernel_extra_modules() {
  local pkg
  for pkg in $(kernel_extra_packages); do
    if pkg_available "$pkg"; then
      pkg_install "$pkg" && return 0
    fi
  done
  return 1
}

load_kernel_modules() {
  local -a modules=() loaded=()
  local mod
  mapfile -t modules < <(kernel_module_list)
  unblock_esp_modules
  if ! have_cmd modprobe; then
    warn "modprobe is not available. Skipping kernel module loading."
    return 0
  fi
  for mod in "${modules[@]}"; do
    if modprobe "$mod" 2>/dev/null; then
      loaded+=("$mod")
    elif [[ "$mod" == esp4 || "$mod" == esp6 ]] && modprobe --ignore-install "$mod" 2>/dev/null; then
      loaded+=("$mod")
    fi
  done
  mkdir -p /etc/modules-load.d
  {
    printf '# %s\n' "$MANAGED_MARK"
    printf '%s\n' "${loaded[@]}"
  } >/etc/modules-load.d/ikev2-vpn.conf
  if [[ -f /etc/modules ]]; then
    for mod in "${loaded[@]}"; do
      grep -qxF "$mod" /etc/modules || printf '%s\n' "$mod" >>/etc/modules
    done
  fi
  log "Loaded kernel modules: ${loaded[*]:-none}"
}

kernel_xfrm_probe() {
  local key spi
  have_cmd ip || return 1
  key="$(openssl rand -hex 32)"
  spi="0x$(openssl rand -hex 4)"
  # IPv6 outer addresses, so the probe also needs esp6: the VPN runs over IPv6.
  ip xfrm state add src 2001:db8::1 dst 2001:db8::2 proto esp spi "$spi" reqid 4242 mode tunnel \
    enc 'cbc(aes)' "0x${key}" auth-trunc 'hmac(sha256)' "0x${key}" 128 >/dev/null 2>&1 || return 1
  ip xfrm state delete src 2001:db8::1 dst 2001:db8::2 proto esp spi "$spi" >/dev/null 2>&1 || true
  return 0
}

kernel_has_cbc_hmac() {
  if [[ -r "$CRYPTO_FILE" ]] && grep -q 'authenc(hmac(sha256),cbc(aes))' "$CRYPTO_FILE"; then
    return 0
  fi
  kernel_xfrm_probe
}

find_libipsec_plugin() {
  local dir
  for dir in ${IKEV2_PLUGIN_DIRS:-/usr/lib /usr/lib64 /usr/libexec}; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 5 -name 'libstrongswan-kernel-libipsec.so' -print -quit 2>/dev/null
  done | head -n 1
}

# Sets VPN_DATAPLANE to kernel or libipsec. $1 is auto, kernel, or libipsec.
select_dataplane() {
  local want="${1:-auto}"
  local plugin
  case "$want" in
    kernel)
      VPN_DATAPLANE=kernel
      ;;
    libipsec|auto)
      if [[ "$want" == "auto" ]] && kernel_has_cbc_hmac; then
        VPN_DATAPLANE=kernel
      else
        plugin="$(find_libipsec_plugin)"
        if [[ -z "$plugin" ]]; then
          die "The kernel cannot use AES-CBC with HMAC-SHA256 for ESP, which iOS requires, and the StrongSwan kernel-libipsec plugin is not installed."
        fi
        [[ -c "$TUN_DEVICE" ]] || die "kernel-libipsec needs ${TUN_DEVICE}, which is missing. Enable TUN for this server."
        VPN_DATAPLANE=libipsec
      fi
      ;;
    *)
      die "Unknown dataplane: ${want}. Use auto, kernel, or libipsec."
      ;;
  esac
  if [[ "$VPN_DATAPLANE" == "libipsec" ]]; then
    log "The kernel lacks AES-CBC with HMAC-SHA256 for ESP. Using the userspace kernel-libipsec plugin."
  else
    log "Using kernel IPsec (XFRM)."
  fi
}

# Loads the ESP and crypto modules, and installs the distribution's extra
# kernel modules package when the running kernel still cannot do
# AES-CBC + HMAC-SHA256 ESP. $1 is the requested dataplane.
prepare_kernel_dataplane() {
  local want="${1:-auto}"
  load_kernel_modules
  [[ "$want" == "libipsec" ]] && return 0
  kernel_has_cbc_hmac && return 0
  log "The kernel cannot do AES-CBC with HMAC-SHA256 for ESP yet. Trying the extra kernel modules package."
  if install_kernel_extra_modules; then
    load_kernel_modules
  fi
}

STRONGSWAN_SRC_VERSION="5.9.14"
STRONGSWAN_SRC_SHA256="728027ddda4cb34c67c4cec97d3ddb8c274edfbabdaeecf7e74693b54fc33678"
STRONGSWAN_SRC_URL="${IKEV2_STRONGSWAN_SRC_URL:-https://download.strongswan.org/strongswan-${STRONGSWAN_SRC_VERSION}.tar.bz2}"
# kernel-libipsec gained raw (non-UDP-encapsulated) ESP in this release.
STRONGSWAN_RAW_ESP_VERSION="5.9.11"

# True when version $1 is at least $2.
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

# Prints the installed StrongSwan version, for example 5.9.8, or nothing.
strongswan_version() {
  local out="" cmd
  if [[ -n "${IKEV2_STRONGSWAN_VERSION:-}" ]]; then
    printf '%s\n' "$IKEV2_STRONGSWAN_VERSION"
    return 0
  fi
  if have_cmd swanctl; then
    out="$(swanctl --version 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]]; then
    cmd="$(ipsec_command)"
    [[ -n "$cmd" ]] && out="$("$cmd" --version 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]] && have_cmd dpkg-query; then
    out="$(dpkg-query -W -f='${Version}\n' strongswan 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]] && have_cmd rpm; then
    out="$(rpm -q --qf '%{VERSION}\n' strongswan 2>/dev/null || true)"
  fi
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"$out" | head -n 1 || true
}

strongswan_has_raw_esp() {
  local version="${1:-}"
  [[ -n "$version" ]] && version_ge "$version" "$STRONGSWAN_RAW_ESP_VERSION"
}

strongswan_build_packages() {
  case "$DISTRO_FAMILY" in
    debian)
      printf '%s\n' build-essential pkg-config bison flex bzip2 curl \
        libssl-dev libgmp-dev libsystemd-dev
      ;;
  esac
}

# Debian-family layout: binaries in /usr/sbin, charon and plugins in
# /usr/lib/ipsec, config in /etc. Matching it lets the distribution's
# strongswan-starter and strongswan (charon-systemd) units keep working, so
# upstream's units go to the throwaway directory $1.
strongswan_configure_args() {
  local unit_dir="$1"
  printf '%s\n' --prefix=/usr --sysconfdir=/etc --libexecdir=/usr/lib --libdir=/usr/lib \
    --with-ipsecdir=/usr/lib/ipsec "--with-systemdsystemunitdir=${unit_dir}" \
    --enable-openssl --enable-gmp --enable-kernel-netlink --enable-kernel-libipsec \
    --enable-socket-default --enable-stroke --enable-swanctl --enable-vici --enable-systemd \
    --enable-attr --enable-resolve --enable-updown --enable-revocation --enable-constraints \
    --enable-pkcs1 --enable-pkcs8 --enable-pkcs12 --enable-pem --enable-x509 --enable-pubkey
}

STRONGSWAN_PLUGIN_DIR="${IKEV2_STRONGSWAN_PLUGIN_DIR:-/usr/lib/ipsec/plugins}"

# Plugins left from the packaged release would be loaded into the newer
# daemon with a mismatched ABI, so move them aside before installing.
stash_packaged_plugins() {
  local dest
  [[ -d "$STRONGSWAN_PLUGIN_DIR" ]] || return 0
  dest="${STATE_DIR}/packaged-plugins.$(date +%Y%m%d%H%M%S)"
  mkdir -p "$STATE_DIR"
  mv "$STRONGSWAN_PLUGIN_DIR" "$dest"
  log "Moved the packaged StrongSwan plugins to ${dest}."
}

# Debian confines charon with AppArmor; raw ESP needs a raw socket.
allow_charon_raw_socket() {
  local dir="${IKEV2_APPARMOR_DIR:-/etc/apparmor.d}"
  local profile="${dir}/usr.lib.ipsec.charon"
  local local_rules="${dir}/local/usr.lib.ipsec.charon"
  [[ -f "$profile" ]] || return 0
  mkdir -p "$(dirname "$local_rules")"
  touch "$local_rules"
  if ! grep -q 'ikev2-vpn raw ESP' "$local_rules"; then
    printf '%s\n' '# ikev2-vpn raw ESP for kernel-libipsec' 'capability net_raw,' 'network inet6 raw,' \
      'network inet raw,' >>"$local_rules"
  fi
  if have_cmd apparmor_parser && [[ -d /sys/kernel/security/apparmor ]]; then
    apparmor_parser -r "$profile" >/dev/null 2>&1 || warn "Could not reload the AppArmor profile ${profile}."
  fi
}

# Keeps apt from replacing the source-built daemon with the older package.
hold_strongswan_packages() {
  local -a pkgs=()
  have_cmd dpkg-query && have_cmd apt-mark || return 0
  mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
    'strongswan*' 'libstrongswan*' 'libcharon*' 'charon*' 2>/dev/null | awk '$1 ~ /^.i/ {print $2}')
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  apt-mark hold "${pkgs[@]}" >/dev/null
  log "Held packages so upgrades keep StrongSwan ${STRONGSWAN_SRC_VERSION}: ${pkgs[*]}"
}

build_strongswan_from_source() {
  local work src jobs
  local -a args=()
  [[ "$DISTRO_FAMILY" == "debian" ]] \
    || die "StrongSwan $(strongswan_version) cannot receive raw ESP with kernel-libipsec, and building ${STRONGSWAN_SRC_VERSION} from source is only supported on Debian and Ubuntu. Install StrongSwan ${STRONGSWAN_RAW_ESP_VERSION} or newer, or a kernel with AES-CBC and HMAC-SHA256."
  log "Building StrongSwan ${STRONGSWAN_SRC_VERSION} from source for raw ESP in kernel-libipsec."
  pkg_refresh
  # shellcheck disable=SC2046
  pkg_install $(strongswan_build_packages) || die "Failed to install StrongSwan build dependencies."
  work="$(mktemp -d)"
  src="${work}/strongswan-${STRONGSWAN_SRC_VERSION}"
  if ! curl -fsSL --retry 3 -o "${work}/strongswan.tar.bz2" "$STRONGSWAN_SRC_URL"; then
    rm -rf "$work"
    die "Could not download ${STRONGSWAN_SRC_URL}."
  fi
  if ! sha256sum "${work}/strongswan.tar.bz2" | grep -q "^${STRONGSWAN_SRC_SHA256} "; then
    rm -rf "$work"
    die "Checksum mismatch for ${STRONGSWAN_SRC_URL}."
  fi
  tar -xjf "${work}/strongswan.tar.bz2" -C "$work" || { rm -rf "$work"; die "Could not unpack the StrongSwan source."; }
  mapfile -t args < <(strongswan_configure_args "${work}/systemd-units")
  jobs="$(nproc 2>/dev/null || printf '1')"
  if ! (cd "$src" && ./configure "${args[@]}" >"${work}/configure.log" 2>&1 \
    && make -j"$jobs" >"${work}/make.log" 2>&1); then
    mkdir -p "$STATE_DIR"
    cp "${work}"/*.log "$STATE_DIR"/ 2>/dev/null || true
    rm -rf "$work"
    die "Building StrongSwan ${STRONGSWAN_SRC_VERSION} failed. Logs are in ${STATE_DIR}."
  fi
  stash_packaged_plugins
  if ! (cd "$src" && make install >"${work}/install.log" 2>&1); then
    mkdir -p "$STATE_DIR"
    cp "${work}"/*.log "$STATE_DIR"/ 2>/dev/null || true
    rm -rf "$work"
    die "Building StrongSwan ${STRONGSWAN_SRC_VERSION} failed. Logs are in ${STATE_DIR}."
  fi
  rm -rf "$work"
  have_cmd ldconfig && ldconfig
  hold_strongswan_packages
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$STRONGSWAN_SRC_VERSION" >"${STATE_DIR}/strongswan-source-version"
  log "Installed StrongSwan ${STRONGSWAN_SRC_VERSION}."
}

# Android's built-in VPN sends plain ESP over IPv6. kernel-libipsec needs
# StrongSwan 5.9.11 or newer to receive it.
ensure_libipsec_raw_esp() {
  local version
  [[ "$VPN_DATAPLANE" == "libipsec" ]] || return 0
  allow_charon_raw_socket
  version="$(strongswan_version)"
  if strongswan_has_raw_esp "$version"; then
    log "StrongSwan ${version} supports raw ESP in kernel-libipsec."
    return 0
  fi
  warn "StrongSwan ${version:-unknown} predates ${STRONGSWAN_RAW_ESP_VERSION}; kernel-libipsec cannot receive the plain ESP that Android's built-in VPN sends."
  if [[ "${IKEV2_SKIP_SWAN_BUILD:-0}" == "1" ]]; then
    warn "IKEV2_SKIP_SWAN_BUILD=1: not building StrongSwan ${STRONGSWAN_SRC_VERSION}."
    return 0
  fi
  build_strongswan_from_source
}

# Package-owned plugin files stay untouched; this file sorts after them and wins.
write_libipsec_conf() {
  local strongswan_d="$1"
  local dataplane="$2"
  local load=no
  [[ "$dataplane" == "libipsec" ]] && load=yes
  mkdir -p "$strongswan_d"
  cat >"${strongswan_d}/zz-ikev2-vpn.conf" <<EOF
# ${MANAGED_MARK}
charon {
    # Prefer small IKEv2 fragments (RFC 7383). Default IPv6 size (~1280) yields
    # ~1220-byte UDP payloads that mobile networks often drop toward the phone.
    fragment_size = 576
    plugins {
        kernel-libipsec {
            load = ${load}
            # Android's built-in VPN negotiates plain ESP over IPv6.
            raw_esp = yes
        }
    }
}
EOF
  chmod 644 "${strongswan_d}/zz-ikev2-vpn.conf"
}
