#!/usr/bin/env bash
set -euo pipefail

# Paths on the host (unchanged from your plan)
DEST_DIR="/etc/ssl/matrixhub"
CERT_SRC="${CERT_SRC:-./cf-origin.pem}"
KEY_SRC="${KEY_SRC:-./cf-origin.key}"

# 1) sanity: make sure the files exist in the current dir (or override via env)
[ -f "$CERT_SRC" ] || { echo "Missing $CERT_SRC"; exit 1; }
[ -f "$KEY_SRC" ]  || { echo "Missing $KEY_SRC";  exit 1; }

# 2) install
sudo mkdir -p "$DEST_DIR"
sudo cp "$CERT_SRC" "$DEST_DIR/cf-origin.pem"
sudo cp "$KEY_SRC"  "$DEST_DIR/cf-origin.key"

# 3) permissions: readable by the container's non-root user
#    (644 is the least invasive; tighten later if you run TLS as root inside the container)
sudo chmod 644 "$DEST_DIR/cf-origin.pem" "$DEST_DIR/cf-origin.key"
sudo chown root:root "$DEST_DIR/cf-origin.pem" "$DEST_DIR/cf-origin.key"

echo "Installed to $DEST_DIR:"
ls -l "$DEST_DIR"/cf-origin.*
