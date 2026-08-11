#!/usr/bin/env bash
# Installs the Cloudflare Origin Cert for plausible.leandrossb.com + the nginx site.
# Requires sudo (Leandro's password). The cert/key are obtained from the Cloudflare
# dashboard: SSL/TLS → Origin Server → Create Certificate (*.leandrossb.com).
# Usage:
#   sudo bash deploy/install-origin-cert.sh <cert-file> <key-file>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <origin.crt> <origin.key>" >&2
  exit 1
fi

CERT="$1"; KEY="$2"
DOMAIN="plausible.leandrossb.com"
SSL_DIR="/etc/nginx/ssl"
SITE_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

for f in "$CERT" "$KEY"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

install -d -m 0755 "$SSL_DIR"
install -m 0644 "$CERT" "$SSL_DIR/$DOMAIN.crt"
install -m 0600 "$KEY" "$SSL_DIR/$DOMAIN.key"

install -m 0644 "$(dirname "$0")/nginx/$DOMAIN.conf" "$SITE_DIR/$DOMAIN.conf"
ln -sfn "$SITE_DIR/$DOMAIN.conf" "$ENABLED_DIR/$DOMAIN.conf"

nginx -t
systemctl reload nginx
echo "OK: $DOMAIN TLS installed and nginx reloaded."
