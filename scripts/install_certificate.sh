#!/usr/bin/env bash
#
# scripts/install_certificate.sh
#
# Install a Cloudflare Origin Certificate (or any cert/key pair) at
# /etc/ssl/matrixhub so the Hub container can mount it for TLS on :443.
#
# This is idempotent: if the destination already contains the same
# files, it just re-asserts permissions and prints the fingerprint.
#
# Usage (defaults match the README):
#   bash scripts/install_certificate.sh
#
# Override sources / destination via env:
#   CERT_SRC=./mycert.pem KEY_SRC=./mycert.key DEST_DIR=/etc/ssl/matrixhub \
#     bash scripts/install_certificate.sh

set -Eeuo pipefail

DEST_DIR="${DEST_DIR:-/etc/ssl/matrixhub}"
CERT_SRC="${CERT_SRC:-./cf-origin.pem}"
KEY_SRC="${KEY_SRC:-./cf-origin.key}"
CERT_DST="${DEST_DIR}/cf-origin.pem"
KEY_DST="${DEST_DIR}/cf-origin.key"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die "not root and 'sudo' not installed"
  SUDO="sudo"
fi

bold "▶ Installing TLS certificate to ${DEST_DIR}"

# --- 0. sources exist ---
[ -f "$CERT_SRC" ] || die "missing $CERT_SRC (override with CERT_SRC=...)"
[ -f "$KEY_SRC"  ] || die "missing $KEY_SRC  (override with KEY_SRC=...)"

# --- 1. validate the pair (if openssl is available) ---
if command -v openssl >/dev/null 2>&1; then
  CERT_MOD="$(openssl x509 -in "$CERT_SRC" -noout -modulus 2>/dev/null | openssl md5 || true)"
  KEY_MOD="$(openssl rsa -in "$KEY_SRC"  -noout -modulus 2>/dev/null | openssl md5 || true)"
  # rsa -modulus may print to stderr if it's an EC key; fall back gracefully.
  if [ -n "$CERT_MOD" ] && [ -n "$KEY_MOD" ] && [ "$CERT_MOD" != "$KEY_MOD" ]; then
    die "cert and key do NOT match (modulus mismatch). Refusing to install."
  fi
  ok "cert/key pair validated (modulus match)"
  if openssl x509 -in "$CERT_SRC" -noout -checkend 604800 >/dev/null 2>&1; then
    ok "cert is valid for at least 7 more days"
  else
    warn "cert expires within 7 days (or already has) — renew via Cloudflare → SSL/TLS → Origin Server"
  fi
else
  warn "openssl not available — skipping pair-validation"
fi

# --- 2. install ---
$SUDO mkdir -p "$DEST_DIR"
$SUDO install -m 0644 -o root -g root "$CERT_SRC" "$CERT_DST"
$SUDO install -m 0640 -o root -g root "$KEY_SRC"  "$KEY_DST"
ok "installed:"
$SUDO ls -l "$CERT_DST" "$KEY_DST" | sed 's/^/      /'

# --- 3. fingerprints ---
if command -v openssl >/dev/null 2>&1; then
  printf '\n  cert details:\n'
  $SUDO openssl x509 -in "$CERT_DST" -noout -subject -issuer -dates -fingerprint -sha256 \
    | sed 's/^/      /'
fi

bold "✓ Certificate installed"
info "The Hub container should mount $DEST_DIR read-only:"
info "  -v $DEST_DIR:/etc/ssl/matrixhub:ro"
info "and Gunicorn should be invoked with:"
info "  --certfile /etc/ssl/matrixhub/cf-origin.pem --keyfile /etc/ssl/matrixhub/cf-origin.key"
