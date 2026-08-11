#!/usr/bin/env bash
# Daily ClickHouse volume snapshot for Plausible. Cold snapshot (container keeps running).
set -euo pipefail
DEST="/mnt/pool/plausible-backup"
install -d -m 0755 "$DEST"
STAMP="$(date +%F)"
docker run --rm \
  -v plausible-ch:/data:ro \
  -v "$DEST":/backup \
  alpine tar czf "/backup/ch-${STAMP}.tar.gz" -C /data .
# Keep 7 days
find "$DEST" -name 'ch-*.tar.gz' -mtime +7 -delete
echo "clickhouse backup ok: $DEST/ch-${STAMP}.tar.gz"
