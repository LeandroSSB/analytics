#!/usr/bin/env bash
# Daily PostgreSQL backup for Plausible. Run as leandro via cron (group docker).
set -euo pipefail
DEST="/mnt/pool/plausible-backup"
install -d -m 0755 "$DEST"
STAMP="$(date +%F)"
docker exec plausible_db pg_dump -U postgres -d plausible_db \
  | gzip > "$DEST/pg-${STAMP}.sql.gz"
# Keep 7 days
find "$DEST" -name 'pg-*.sql.gz' -mtime +7 -delete
echo "pg backup ok: $DEST/pg-${STAMP}.sql.gz"
