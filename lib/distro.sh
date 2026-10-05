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

# Some cloud images disable ESP with "install esp4 /bin/false". Warn instead of failing quietly.
warn_blocked_esp_modules() {
  local dir conf mod
  local -a dirs=(/etc/modprobe.d /run/modprobe.d /usr/local/lib/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d)
  local install_re='^[[:space:]]*install[[:space:]]+'
  local false_re='/(usr/)?bin/false([[:space:]]|$)'
  if [[ -n "${IKEV2_MODPROBE_DIRS:-}" ]]; then
    read -r -a dirs <<<"$IKEV2_MODPROBE_DIRS"
  fi
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for conf in "$dir"/*.conf; do
      [[ -f "$conf" ]] || continue
      for mod in esp4 esp6; do
        if grep -Eq "${install_re}${mod}[[:space:]]+${false_re}" "$conf"; then
          warn "Kernel module ${mod} is disabled in ${conf}. IPsec data packets will fail until that line is removed."
        fi
      done
    done
  done
}

load_kernel_modules() {
  local -a modules=(esp4 esp6 xfrm_user xfrm_algo af_key authenc cryptd aes sha256 sha512 gcm cbc tun
    ip6table_nat iptable_nat nf_nat ip6table_mangle iptable_mangle xt_policy xt_TCPMSS
    nf_conntrack xt_conntrack tcp_bbr)
  local -a loaded=()
  local mod
  warn_blocked_esp_modules
  if ! have_cmd modprobe; then
    warn "modprobe is not available. Skipping kernel module loading."
    return 0
  fi
  for mod in "${modules[@]}"; do
    if modprobe "$mod" 2>/dev/null; then
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
  ip xfrm state add src 192.0.2.1 dst 192.0.2.2 proto esp spi "$spi" reqid 4242 mode tunnel \
    enc 'cbc(aes)' "0x${key}" auth-trunc 'hmac(sha256)' "0x${key}" 128 >/dev/null 2>&1 || return 1
  ip xfrm state delete src 192.0.2.1 dst 192.0.2.2 proto esp spi "$spi" >/dev/null 2>&1 || true
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
    plugins {
        kernel-libipsec {
            load = ${load}
        }
    }
}
EOF
  chmod 644 "${strongswan_d}/zz-ikev2-vpn.conf"
}
