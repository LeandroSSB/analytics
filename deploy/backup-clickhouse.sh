#!/usr/bin/env bash
# Daily ClickHouse volume snapshot for Plausible. Cold snapshot (container keeps running).
# Override destination with PLAUSIBLE_BACKUP_DIR (defaults to a leandro-writable home path).
set -euo pipefail
DEST="${PLAUSIBLE_BACKUP_DIR:-/home/leandro/plausible-backup}"
install -d -m 0755 "$DEST"
STAMP="$(date +%F)"
# Pipe tar to the host redirect so the output file is owned by the leandro user
# running this script (the container runs as root to read the volume; writing the
# file from the host side keeps it user-owned so the retention find -delete works).
docker run --rm \
  -v plausible-ch:/data:ro \
  alpine tar cz -C /data . > "$DEST/ch-${STAMP}.tar.gz"
# Keep 7 days
find "$DEST" -name 'ch-*.tar.gz' -mtime +7 -delete
echo "clickhouse backup ok: $DEST/ch-${STAMP}.tar.gz"
