#!/usr/bin/env bash
# Daily PostgreSQL backup for Plausible. Run as leandro via cron (group docker).
# Override destination with PLAUSIBLE_BACKUP_DIR (e.g. /mnt/pool/plausible-backup
# if you've created + chowned it; defaults to a leandro-writable home path).
set -euo pipefail
DEST="${PLAUSIBLE_BACKUP_DIR:-/home/leandro/plausible-backup}"
install -d -m 0755 "$DEST"
STAMP="$(date +%F)"
docker exec plausible_db pg_dump -U postgres -d plausible_db \
  | gzip > "$DEST/pg-${STAMP}.sql.gz"
# Keep 7 days
find "$DEST" -name 'pg-*.sql.gz' -mtime +7 -delete
echo "pg backup ok: $DEST/pg-${STAMP}.sql.gz"
