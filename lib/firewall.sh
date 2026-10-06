#!/usr/bin/env bash
# Host firewall selection and rules for firewalld, iptables, and nftables.
# shellcheck disable=SC2034  # Globals are shared across the sourced libraries.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'This file is meant to be sourced.\n' >&2
  exit 1
fi

firewalld_running() {
  have_cmd firewall-cmd && [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]
}

# Sets VPN_FIREWALL. $1 is auto, firewalld, iptables, or nftables.
select_firewall() {
  local want="${1:-auto}"
  case "$want" in
    firewalld)
      firewalld_running || die "firewalld was requested, but it is not running."
      VPN_FIREWALL=firewalld
      ;;
    iptables)
      if ! have_cmd iptables || ! have_cmd ip6tables; then
        die "iptables was requested, but iptables or ip6tables is missing."
      fi
      VPN_FIREWALL=iptables
      ;;
    nftables)
      have_cmd nft || die "nftables was requested, but nft is missing."
      VPN_FIREWALL=nftables
      ;;
    auto)
      if firewalld_running; then
        VPN_FIREWALL=firewalld
      elif have_cmd iptables && have_cmd ip6tables; then
        VPN_FIREWALL=iptables
      elif have_cmd nft; then
        VPN_FIREWALL=nftables
      else
        die "No firewall tool found. Install firewalld, iptables, or nftables."
      fi
      ;;
    *)
      die "Unknown firewall: ${want}. Use auto, firewalld, iptables, or nftables."
      ;;
  esac
  log "Using ${VPN_FIREWALL} for firewall and NAT rules."
}

# One rule per line: binary table chain args...
# Filter rules are inserted at position 1, so they are listed in reverse of the
# desired chain order: INVALID ends up first, then established, then IPsec.
iptables_rules() {
  local dataplane="$1"
  local pool4="$2"
  local pool6="$3"
  local iface="$4"
  local bin pool
  for bin in iptables ip6tables; do
    # The Android built-in VPN sends plain ESP over IPv6 (no NAT-T there).
    printf '%s filter INPUT -p esp -j ACCEPT\n' "$bin"
    printf '%s filter INPUT -p udp --dport 4500 -j ACCEPT\n' "$bin"
    printf '%s filter INPUT -p udp --dport 500 -j ACCEPT\n' "$bin"
    printf '%s filter INPUT -m conntrack --ctstate INVALID -j DROP\n' "$bin"
    if [[ "$dataplane" == "libipsec" ]]; then
      printf '%s filter FORWARD -o ipsec0 -j ACCEPT\n' "$bin"
      printf '%s filter FORWARD -i ipsec0 -j ACCEPT\n' "$bin"
    else
      printf '%s filter FORWARD -m policy --pol ipsec --dir out -j ACCEPT\n' "$bin"
      printf '%s filter FORWARD -m policy --pol ipsec --dir in -j ACCEPT\n' "$bin"
    fi
    printf '%s filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n' "$bin"
    printf '%s filter FORWARD -m conntrack --ctstate INVALID -j DROP\n' "$bin"
    pool="$pool4"
    [[ "$bin" == "ip6tables" ]] && pool="$pool6"
    printf '%s nat POSTROUTING -s %s -o %s -m policy --dir out --pol none -j MASQUERADE\n' \
      "$bin" "$pool" "$iface"
    printf '%s mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\n' "$bin"
  done
}

apply_iptables() {
  local line bin table pool iface="$VPN_INTERFACE"
  local -a args
  # Drop the previous masquerade rule that also matched IPsec packets.
  for bin in iptables ip6tables; do
    pool="$VPN_POOL_V4"
    [[ "$bin" == "ip6tables" ]] && pool="$VPN_POOL_V6"
    "$bin" -t nat -D POSTROUTING -s "$pool" -o "$iface" -j MASQUERADE 2>/dev/null || true
  done
  while read -r line; do
    read -r -a args <<<"$line"
    bin="${args[0]}"
    table="${args[1]}"
    args=("${args[@]:2}")
    "$bin" -t "$table" -C "${args[@]}" 2>/dev/null && continue
    if [[ "$line" == *conntrack* ]]; then
      "$bin" -t "$table" -I "${args[0]}" 1 "${args[@]:1}" 2>/dev/null \
        || warn "${bin}: conntrack match unavailable. Skipping state rules."
    elif [[ "$table" == "filter" ]]; then
      "$bin" -t "$table" -I "${args[0]}" 1 "${args[@]:1}"
    elif [[ "$line" == *TCPMSS* ]]; then
      "$bin" -t "$table" -A "${args[@]}" 2>/dev/null \
        || warn "${bin}: this kernel lacks TCPMSS. Skipping MSS clamping; large TCP packets may stall."
    else
      "$bin" -t "$table" -A "${args[@]}"
    fi
  done < <(iptables_rules "$VPN_DATAPLANE" "$VPN_POOL_V4" "$VPN_POOL_V6" "$VPN_INTERFACE")
}

nftables_ruleset() {
  local dataplane="$1"
  local pool4="$2"
  local pool6="$3"
  local iface="$4"
  local mss="${5:-yes}"
  local forward_match mss_rule=""
  [[ "$mss" == "yes" ]] && mss_rule=$'\n        tcp flags syn tcp option maxseg size set rt mtu'
  if [[ "$dataplane" == "libipsec" ]]; then
    forward_match=$'        iifname "ipsec0" accept\n        oifname "ipsec0" accept'
  else
    forward_match=$'        meta secpath exists accept\n        rt ipsec exists accept'
  fi
  # "rt ipsec missing" is the nft 1.0 equivalent of iptables policy --pol none.
  cat <<EOF
# ${MANAGED_MARK}
table inet ikev2_vpn {}
delete table inet ikev2_vpn
table inet ikev2_vpn {
    chain input {
        type filter hook input priority -5; policy accept;
        ct state invalid drop
        udp dport { 500, 4500 } accept
        meta l4proto esp accept
    }
    chain forward {
        type filter hook forward priority -5; policy accept;${mss_rule}
        ct state invalid drop
        ct state { established, related } accept
${forward_match}
    }
}
table ip ikev2_vpn_nat {}
delete table ip ikev2_vpn_nat
table ip ikev2_vpn_nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr ${pool4} oifname "${iface}" rt ipsec missing masquerade
    }
}
table ip6 ikev2_vpn_nat {}
delete table ip6 ikev2_vpn_nat
table ip6 ikev2_vpn_nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip6 saddr ${pool6} oifname "${iface}" rt ipsec missing masquerade
    }
}
EOF
}

apply_nftables() {
  local file="${CONFIG_DIR}/nftables.conf"
  mkdir -p "$CONFIG_DIR"
  nftables_ruleset "$VPN_DATAPLANE" "$VPN_POOL_V4" "$VPN_POOL_V6" "$VPN_INTERFACE" yes >"$file"
  chmod 644 "$file"
  if ! nft -f "$file" 2>/dev/null; then
    nftables_ruleset "$VPN_DATAPLANE" "$VPN_POOL_V4" "$VPN_POOL_V6" "$VPN_INTERFACE" no >"$file"
    nft -f "$file"
    warn "nftables: this kernel rejected MSS clamping. Skipping it; large TCP packets may stall."
  fi
}

firewalld_zone() {
  local zone
  zone="$(firewall-cmd --get-zone-of-interface="$VPN_INTERFACE" 2>/dev/null || true)"
  [[ -n "$zone" ]] || zone="$(firewall-cmd --get-default-zone)"
  printf '%s\n' "$zone"
}

# Adds one permanent direct rule when it is not already present.
firewalld_direct_add() {
  if firewall-cmd --permanent --direct --query-rule "$@" >/dev/null 2>&1; then
    return 0
  fi
  firewall-cmd --permanent --direct --add-rule "$@" >/dev/null 2>&1
}

apply_firewalld() {
  local zone fam pool
  zone="$(firewalld_zone)"
  firewall-cmd --permanent --zone="$zone" --add-port=500/udp --add-port=4500/udp >/dev/null
  firewall-cmd --permanent --zone="$zone" --add-service=ipsec >/dev/null 2>&1 || true
  # Older installs masqueraded every pool packet, including ones already in IPsec.
  firewall-cmd --permanent --zone="$zone" \
    --remove-rich-rule="rule family=ipv4 source address=${VPN_POOL_V4} masquerade" >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone="$zone" \
    --remove-rich-rule="rule family=ipv6 source address=${VPN_POOL_V6} masquerade" >/dev/null 2>&1 || true
  for fam in ipv4 ipv6; do
    pool="$VPN_POOL_V4"
    [[ "$fam" == "ipv6" ]] && pool="$VPN_POOL_V6"
    firewalld_direct_add "$fam" filter INPUT 0 -m conntrack --ctstate INVALID -j DROP \
      || warn "firewalld refused the ${fam} INVALID drop on INPUT."
    firewalld_direct_add "$fam" filter FORWARD 0 -m conntrack --ctstate INVALID -j DROP \
      || warn "firewalld refused the ${fam} INVALID drop on FORWARD."
    firewalld_direct_add "$fam" filter FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
      || warn "firewalld refused the ${fam} established rule."
    firewalld_direct_add "$fam" nat POSTROUTING 0 -s "$pool" -o "$VPN_INTERFACE" \
      -m policy --dir out --pol none -j MASQUERADE \
      || warn "firewalld refused the ${fam} policy-aware masquerade rule."
  done
  firewall-cmd --permanent --zone="$zone" --add-forward >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=trusted --add-source="$VPN_POOL_V4" >/dev/null
  firewall-cmd --permanent --zone=trusted --add-source="$VPN_POOL_V6" >/dev/null
  if [[ "$VPN_DATAPLANE" == "libipsec" ]]; then
    firewall-cmd --permanent --zone=trusted --add-interface=ipsec0 >/dev/null 2>&1 || true
  fi
  for fam in ipv4 ipv6; do
    if ! firewall-cmd --permanent --direct --query-rule "$fam" mangle FORWARD 0 \
      -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
      firewall-cmd --permanent --direct --add-rule "$fam" mangle FORWARD 0 \
        -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || warn "firewalld refused the ${fam} MSS clamp rule. Large TCP packets may stall."
    fi
  done
  firewall-cmd --reload >/dev/null
  log "firewalld rules saved in zone ${zone}."
}

firewall_apply() {
  case "$VPN_FIREWALL" in
    firewalld) apply_firewalld ;;
    iptables) apply_iptables ;;
    nftables) apply_nftables ;;
    *) die "Unknown firewall in configuration: ${VPN_FIREWALL}" ;;
  esac
}

# Reapplies iptables or nftables rules at boot. firewalld keeps its own permanent rules.
install_firewall_boot_hook() {
  local bin="$1"
  local unit=/etc/systemd/system/ikev2-vpn-firewall.service
  local openrc_hook=/etc/local.d/ikev2-vpn.start
  if [[ "$VPN_FIREWALL" == "firewalld" ]]; then
    if [[ "$SERVICE_MANAGER" == "systemd" && -f "$unit" ]]; then
      systemctl disable ikev2-vpn-firewall.service >/dev/null 2>&1 || true
      rm -f "$unit"
      systemctl daemon-reload
    fi
    rm -f "$openrc_hook"
    return 0
  fi
  case "$SERVICE_MANAGER" in
    systemd)
      cat >"$unit" <<EOF
# ${MANAGED_MARK}
[Unit]
Description=IKEv2 VPN firewall and NAT rules
Wants=network-pre.target
After=network-pre.target iptables.service ip6tables.service nftables.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${bin} firewall-apply

[Install]
WantedBy=multi-user.target
EOF
      chmod 644 "$unit"
      systemctl daemon-reload
      systemctl enable ikev2-vpn-firewall.service >/dev/null
      ;;
    openrc)
      mkdir -p /etc/local.d
      cat >"$openrc_hook" <<EOF
#!/bin/sh
# ${MANAGED_MARK}
${bin} firewall-apply
EOF
      chmod 755 "$openrc_hook"
      rc-update add local default >/dev/null 2>&1 || true
      ;;
  esac
}

# Opens 80/tcp for the certbot HTTP challenge until firewall_http_close runs.
firewall_http_open() {
  HTTP_OPENED=""
  case "$VPN_FIREWALL" in
    firewalld)
      if ! firewall-cmd --query-port=80/tcp >/dev/null 2>&1; then
        firewall-cmd --add-port=80/tcp >/dev/null && HTTP_OPENED=firewalld
      fi
      ;;
    iptables)
      if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
        ip6tables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
        HTTP_OPENED=iptables
      fi
      ;;
    nftables)
      nft -f - <<'EOF' && HTTP_OPENED=nftables
table inet ikev2_vpn_http {
    chain input {
        type filter hook input priority -10; policy accept;
        tcp dport 80 accept
    }
}
EOF
      ;;
  esac
}

firewall_http_close() {
  case "${HTTP_OPENED:-}" in
    firewalld)
      firewall-cmd --remove-port=80/tcp >/dev/null 2>&1 || true
      ;;
    iptables)
      iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
      ip6tables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
      ;;
    nftables)
      nft delete table inet ikev2_vpn_http 2>/dev/null || true
      ;;
  esac
  HTTP_OPENED=""
}
