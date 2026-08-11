#!/usr/bin/env bash
# Canonical build/up command for Plausible on megalan. Run from ~/analytics.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  --env-file .env.production up -d --build
