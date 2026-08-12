# Self-hosting Plausible CE (this fork) — ops reference

Builds **Plausible Community Edition** (`MIX_ENV=ce`) from this repo's Dockerfile
and runs it behind nginx + Cloudflare. This is the setup deployed on `megalan`
at `https://plausible.leandrossb.com`.

## Stack

| Service | Image | Role |
|---|---|---|
| `plausible` | **built from `./Dockerfile`** (`MIX_ENV=ce`) | the app (Elixir/Phoenix release) |
| `plausible_db` | `postgres:16-alpine` | Postgres (sites/users/goals/config) |
| `plausible_events_db` | `clickhouse/clickhouse-server:25.11.5.8-alpine` | ClickHouse (analytics events) |

DBs are internal-only (no host port). The app publishes only `127.0.0.1:14100:8000`;
nginx reverse-proxies `plausible.leandrossb.com` → `127.0.0.1:14100`.

## Required environment (`.env.production`, gitignored, chmod 600)

Only two are strictly required — DB URLs use the app's runtime defaults
(`plausible_db` / `plausible_events_db` service names):

```
BASE_URL=https://plausible.leandrossb.com
SECRET_KEY_BASE=<openssl rand -base64 48>
DISABLE_REGISTRATION=invite_only   # valid: true | false | invite_only (NOT "invite")
# ADMIN_USER_IDS=1                 # set after bootstrap, then restart → super-admin
```

Do **not** set `ENABLE_EMAIL_VERIFICATION` (CE auto-verifies registered users)
or `HTTPS_PORT` (TLS terminates at nginx; the app runs HTTP behind it).

## Deploy / update

```bash
# from the repo root on the host:
bash deploy/deploy.sh
# = docker compose -f docker-compose.yml -f docker-compose.prod.yml \
#                    --env-file .env.production up -d --build
```

Migrations (`createdb` → `interweave_migrate` → `run`) run on the app container's
start command, so they re-apply idempotently on every restart/update. To update:
sync the repo (`git pull` or `git archive HEAD | tar -x`) then `bash deploy/deploy.sh`.

## Bootstrap admin (no SMTP)

```bash
docker cp deploy/bootstrap-admin.exs plausible:/tmp/bootstrap-admin.exs
docker exec -e ADMIN_EMAIL=you@example.com -e ADMIN_NAME="Name" \
           -e ADMIN_PASSWORD='strong-password' \
  plausible /app/bin/plausible eval 'Code.eval_file("/tmp/bootstrap-admin.exs")'
# → prints "OK admin bootstrapped id=<N> ..."; set ADMIN_USER_IDS=<N> + restart
```

## TLS (Cloudflare Origin Cert + nginx)

Zone `leandrossb.com` is in **Full** mode. A wildcard Origin Cert (`*.leandrossb.com`,
2041) is reused (the same one marmoaria uses). Install with sudo:

```bash
sudo bash deploy/install-origin-cert.sh \
  /etc/nginx/ssl/marmoaria.leandrossb.com.crt \
  /etc/nginx/ssl/marmoaria.leandrossb.com.key
```

**Two hard-won nginx GOTCHAs** (both baked into `deploy/nginx/plausible.leandrossb.com.conf`):
1. `ssl_stapling off; ssl_stapling_verify off;` — with stapling on, nginx stalls the
   handshake on OCSP from `ocsp.cloudflare.com` and Cloudflare returns **525**.
2. Explicit **ECDHE cipher string** — the generic `ssl_ciphers HIGH:!aNULL:!MD5`
   also causes a **525** under OpenSSL 3 / Ubuntu crypto policy (CF's TLS client
   won't complete the handshake, even though `openssl s_client` succeeds locally).
   Use the same cipher list as the working `marmoaria.leandrossb.com` site.

## Backups

Daily, via leandro's crontab, to `${PLAUSIBLE_BACKUP_DIR:-/home/leandro/plausible-backup}`
(retention 7 days). On `megalan`, `/mnt/pool` and `/mnt/ssd` are root-owned, so the
default is the leandro-writable home; set `PLAUSIBLE_BACKUP_DIR` to override.

```bash
deploy/backup-pg.sh          # docker exec plausible_db pg_dump | gzip
deploy/backup-clickhouse.sh  # docker run alpine tar (volume snapshot) piped to host
```

Restore-test the Postgres dump before trusting it:
```bash
docker run --rm -d --name pg-restore -e POSTGRES_PASSWORD=x postgres:16-alpine
docker exec pg-restore psql -U postgres -c "CREATE DATABASE plausible_db;"
gunzip -c ~/plausible-backup/pg-*.sql.gz | docker exec -i pg-restore psql -U postgres -d plausible_db
docker exec pg-restore psql -U postgres -d plausible_db -c "select count(*) from users;"
docker rm -f pg-restore
```

## Healthcheck & validation

- `GET /api/health` → `{"postgres":"ok","sessions":"ok","clickhouse":"ok","sites_cache":"ok"}`
- Public: `https://plausible.leandrossb.com/api/health` → 200 (HTTP/2 via CF).
- Ingestion: `POST /api/event` with `{"name":"pageview","domain":"<yoursite>","url":"https://<yoursite>/"}` → `202`; the event appears in ClickHouse `events_v2` (column `hostname`, keyed by `site_id`) within the ~5s flush interval.

## Tracker snippet (embed on tracked sites)

```html
<script defer data-domain="chaminex.com"
  src="https://plausible.leandrossb.com/js/script.js"></script>
```
Prefer the SRI variant (`script.hash.js` with `integrity="sha384-..." crossorigin="anonymous"`)
— the UI shows the ready snippet. Re-fetch the snippet if you change tracker config
(outbound links, etc.): interpolated config changes the script body and invalidates the hash.

## CE vs EE

This is **CE only**. Never build `MIX_ENV=prod` (EE): `extra/lib/plausible/license.ex`
SHA256-checks `:license_key` at boot and calls `System.stop()` without a purchased key,
so the app refuses to start. CE (AGPLv3) covers personal-site analytics; EE-only are
funnels, ecommerce revenue, SSO, Sites API.
