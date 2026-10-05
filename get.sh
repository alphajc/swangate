#!/usr/bin/env bash
# Download and install the swangate command, then run the given subcommand.
#   curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash -s -- install --domain ...
set -euo pipefail

IKEV2_REPO="${IKEV2_REPO:-alphajc/swangate}"
IKEV2_REF="${IKEV2_REF:-main}"
IKEV2_TARBALL_URL="${IKEV2_TARBALL_URL:-https://codeload.github.com/${IKEV2_REPO}/tar.gz/${IKEV2_REF}}"
IKEV2_PREFIX="${IKEV2_PREFIX:-/usr/local/lib/swangate}"
IKEV2_BIN="${IKEV2_BIN:-/usr/local/bin/swangate}"

say() {
  printf '[swangate] %s\n' "$*"
}

fail() {
  printf '[swangate] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Linux" ]] || fail "swangate only runs on Linux."

target_parent="$(dirname "$IKEV2_PREFIX")"
bin_dir="$(dirname "$IKEV2_BIN")"
mkdir -p "$target_parent" "$bin_dir" 2>/dev/null || true
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && { [[ ! -w "$target_parent" ]] || [[ ! -w "$bin_dir" ]]; }; then
  fail "Run as root, for example: curl -fsSL https://raw.githubusercontent.com/${IKEV2_REPO}/${IKEV2_REF}/get.sh | sudo bash -s -- install ..."
fi

command -v tar >/dev/null 2>&1 || fail "tar is required."
command -v gzip >/dev/null 2>&1 || fail "gzip is required."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "Downloading ${IKEV2_TARBALL_URL}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 -o "${work}/swangate.tar.gz" "$IKEV2_TARBALL_URL" || fail "Download failed."
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "${work}/swangate.tar.gz" "$IKEV2_TARBALL_URL" || fail "Download failed."
else
  fail "curl or wget is required."
fi

mkdir -p "${work}/src"
tar -xzf "${work}/swangate.tar.gz" -C "${work}/src" || fail "The downloaded archive is not a valid tarball."
src="$(find "${work}/src" -maxdepth 2 -type f -name swangate | head -n 1)"
[[ -n "$src" ]] || fail "The archive does not contain the swangate command."
src="$(dirname "$src")"
[[ -f "${src}/lib/commands.sh" ]] || fail "The archive is missing lib/commands.sh."

rm -rf "${IKEV2_PREFIX}.new"
install -d -m 755 "${IKEV2_PREFIX}.new/lib"
install -m 755 "${src}/swangate" "${IKEV2_PREFIX}.new/swangate"
install -m 644 "${src}"/lib/*.sh "${IKEV2_PREFIX}.new/lib/"
rm -rf "$IKEV2_PREFIX"
mv "${IKEV2_PREFIX}.new" "$IKEV2_PREFIX"
install -d -m 755 "$(dirname "$IKEV2_BIN")"
ln -sfn "${IKEV2_PREFIX}/swangate" "$IKEV2_BIN"
say "Installed ${IKEV2_BIN}"

if [[ $# -eq 0 ]]; then
  cat <<'EOF'
Next step:
  sudo swangate install --domain vpn.example.com --email admin@example.com
EOF
  exit 0
fi

rm -rf "$work"
trap - EXIT
exec "$IKEV2_BIN" "$@"
