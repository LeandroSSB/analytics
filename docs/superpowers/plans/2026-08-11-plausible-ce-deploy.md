# Plausible CE (fork) no megalan — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Self-host Plausible Community Edition (built from the fork) on `megalan`, served publicly at `https://plausible.leandrossb.com`, for analytics of Leandro's own sites.

**Architecture:** 3-service Docker stack (`plausible` app built from the repo Dockerfile with `MIX_ENV=ce`, PostgreSQL 16, ClickHouse 25.11) behind nginx + Cloudflare. DBs are internal-only (no host ports); the app publishes one high port (`127.0.0.1:14100`) that nginx reverse-proxies. TLS terminates at nginx via a Cloudflare Origin Cert (`ssl_stapling off` — the known 525 GOTCHA).

**Tech Stack:** Elixir/Phoenix release (OTP), PostgreSQL 16, ClickHouse 25.11, Docker Compose v2, nginx, Cloudflare (zone `leandrossb.com`, Full mode).

## Global Constraints

- **Edition:** `MIX_ENV=ce` only. Never `:prod` (EE) — `extra/lib/plausible/license.ex` calls `System.stop()` at boot without a purchased license key.
- **Build source:** the fork's own Dockerfile (`build: { context: ., args: { MIX_ENV: ce } }`), not the official `ghcr.io/plausible/community-edition` image.
- **DB-URL defaults are relied upon:** the fork's `config/runtime.exs` defaults `DATABASE_URL=postgres://postgres:postgres@plausible_db:5432/plausible_db` and `CLICKHOUSE_DATABASE_URL=http://plausible_events_db:8123/plausible_events_db`. Service names in compose MUST be exactly `plausible_db` and `plausible_events_db`. `POSTGRES_PASSWORD=postgres` and `CLICKHOUSE_SKIP_USER_SETUP=1` MUST stay as-is so the defaults resolve.
- **Only `BASE_URL` + `SECRET_KEY_BASE` are strictly required** in `.env.production`.
- **Do NOT set `ENABLE_EMAIL_VERIFICATION`:** on CE, `set_email_verification_status/1` sets `email_verified = not must_verify?`, so leaving it unset auto-verifies the registered admin (no email needed).
- **megalan SSH:** `ssh megalan` (non-interactive OK). **Sudo needs a password** — nginx site install, `/etc/nginx/ssl/` writes, and `nginx -s reload` require Leandro's sudo. Run those via interactive `sudo` (the executor is prompted).
- **Host port:** `14100` (web, bound to `127.0.0.1` only). Postgres + ClickHouse: **no host port** (internal). Avoids collision with `5432/45433/15432/15433/9000/8123` already in use on megalan.
- **TLS GOTCHA:** the nginx `:443` block MUST contain `ssl_stapling off;`. Without it nginx blocks the handshake waiting for OCSP from `ocsp.cloudflare.com` and Cloudflare returns 525.
- **Commits:** every repo-file task ends with a commit. `.env.production` is NEVER committed (gitignored).

**Spec:** `docs/superpowers/specs/2026-08-11-plausible-ce-deploy-design.md`

---

## File Structure

Repo-root artifacts (committed to the fork):
- `docker-compose.yml` — base stack: builds app from Dockerfile, postgres + clickhouse, volumes, healthchecks. No host ports, no env_file.
- `docker-compose.prod.yml` — prod override: publishes `127.0.0.1:14100:8000`, loads `.env.production`.
- `clickhouse/ipv4-only.xml`, `clickhouse/logs.xml`, `clickhouse/low-resources.xml`, `clickhouse/default-profile-low-resources-overrides.xml` — ClickHouse config (IPv4 bind, reduced logging, low-RAM profile). Mounted read-only by the events_db service.
- `.env.production.example` — committed template (no secrets).
- `deploy/nginx/plausible.leandrossb.com.conf` — nginx site (HTTP→HTTPS redirect, TLS, reverse-proxy, LiveView upgrade headers).
- `deploy/install-origin-cert.sh` — places the CF Origin Cert/key + installs the nginx site + reloads (needs sudo).
- `deploy/bootstrap-admin.exs` — Elixir release script: idempotently creates + verifies the admin user.
- `deploy/backup-pg.sh`, `deploy/backup-clickhouse.sh` — backup scripts for cron.
- `deploy/deploy.sh` — canonical up/rebuild wrapper.

Server-side only (never committed):
- `~/analytics/.env.production` — real secrets (chmod 600).

---

## Task 1: Compose stack + ClickHouse configs + env template

**Files:**
- Create: `docker-compose.yml`
- Create: `docker-compose.prod.yml`
- Create: `clickhouse/ipv4-only.xml`, `clickhouse/logs.xml`, `clickhouse/low-resources.xml`, `clickhouse/default-profile-low-resources-overrides.xml`
- Create: `.env.production.example`
- Modify: `.gitignore`

**Interfaces:**
- Produces: the `plausible`, `plausible_db`, `plausible_events_db` services and the `plausible-pg` / `plausible-ch` / `plausible-ch-logs` / `plausible-data` volumes that later tasks depend on.

- [ ] **Step 1: Create `docker-compose.yml`**

Modelled on the official `plausible/community-edition` compose, with `build:` replacing `image:` and ClickHouse pinned to the fork's CI version.

```yaml
# container_name + explicit volume `name:` pin the names so deploy scripts,
# backup scripts, and `docker exec` work regardless of the compose project name
# (the project defaults to the dir name, which would otherwise prefix everything
# with `analytics-`). Matches the megalan convention (marmoaria-api, etc.).

services:
  plausible_db:
    image: postgres:16-alpine
    container_name: plausible_db
    restart: always
    volumes:
      - plausible-pg:/var/lib/postgresql/data
    environment:
      - POSTGRES_PASSWORD=postgres
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      start_period: 1m

  plausible_events_db:
    image: clickhouse/clickhouse-server:25.11.5.8-alpine
    container_name: plausible_events_db
    restart: always
    volumes:
      - plausible-ch:/var/lib/clickhouse
      - plausible-ch-logs:/var/log/clickhouse-server
      - ./clickhouse/logs.xml:/etc/clickhouse-server/config.d/logs.xml:ro
      - ./clickhouse/ipv4-only.xml:/etc/clickhouse-server/config.d/ipv4-only.xml:ro
      - ./clickhouse/low-resources.xml:/etc/clickhouse-server/config.d/low-resources.xml:ro
      - ./clickhouse/default-profile-low-resources-overrides.xml:/etc/clickhouse-server/users.d/default-profile-low-resources-overrides.xml:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    environment:
      - CLICKHOUSE_SKIP_USER_SETUP=1
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 -O - http://127.0.0.1:8123/ping || exit 1"]
      start_period: 1m

  plausible:
    build:
      context: .
      args:
        MIX_ENV: ce
    container_name: plausible
    restart: always
    command: sh -c "/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run"
    depends_on:
      plausible_db:
        condition: service_healthy
      plausible_events_db:
        condition: service_healthy
    volumes:
      - plausible-data:/var/lib/plausible
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    environment:
      - TMPDIR=/var/lib/plausible/tmp
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8000/api/health || exit 1"]
      start_period: 3m

volumes:
  plausible-pg:
    name: plausible-pg
  plausible-ch:
    name: plausible-ch
  plausible-ch-logs:
    name: plausible-ch-logs
  plausible-data:
    name: plausible-data
```

- [ ] **Step 2: Create `docker-compose.prod.yml` (override)**

```yaml
# Production override: publish the app on a localhost-only high port and load secrets.
services:
  plausible:
    ports:
      - "127.0.0.1:14100:8000"
    env_file:
      - .env.production
```

- [ ] **Step 3: Create `clickhouse/ipv4-only.xml`**

```xml
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
</clickhouse>
```

- [ ] **Step 4: Create `clickhouse/logs.xml`**

```xml
<clickhouse>
    <logger>
        <level>warning</level>
        <console>true</console>
    </logger>

    <query_log replace="1">
        <database>system</database>
        <table>query_log</table>
        <flush_interval_milliseconds>7500</flush_interval_milliseconds>
        <engine>
            ENGINE = MergeTree
            PARTITION BY event_date
            ORDER BY (event_time)
            TTL event_date + interval 30 day
            SETTINGS ttl_only_drop_parts=1
        </engine>
    </query_log>

    <!-- Stops unnecessary logging -->
    <metric_log remove="remove" />
    <asynchronous_metric_log remove="remove" />
    <query_thread_log remove="remove" />
    <text_log remove="remove" />
    <trace_log remove="remove" />
    <session_log remove="remove" />
    <part_log remove="remove" />
</clickhouse>
```

- [ ] **Step 5: Create `clickhouse/low-resources.xml`**

```xml
<clickhouse>
    <!-- https://clickhouse.com/docs/en/operations/server-configuration-parameters/settings#mark_cache_size -->
    <mark_cache_size>524288000</mark_cache_size>
</clickhouse>
```

- [ ] **Step 6: Create `clickhouse/default-profile-low-resources-overrides.xml`**

```xml
<!-- https://clickhouse.com/docs/en/operations/tips#using-less-than-16gb-of-ram -->
<clickhouse>
    <profiles>
        <default>
            <!-- https://clickhouse.com/docs/en/operations/settings/settings#max_threads -->
            <max_threads>1</max_threads>
            <!-- https://clickhouse.com/docs/en/operations/settings/settings#max_block_size -->
            <max_block_size>8192</max_block_size>
            <!-- https://clickhouse.com/docs/en/operations/settings/settings#max_download_threads -->
            <max_download_threads>1</max_download_threads>
            <!--
            https://clickhouse.com/docs/en/operations/settings/settings#input_format_parallel_parsing -->
            <input_format_parallel_parsing>0</input_format_parallel_parsing>
            <!--
            https://clickhouse.com/docs/en/operations/settings/settings#output_format_parallel_formatting -->
            <output_format_parallel_formatting>0</output_format_parallel_formatting>
        </default>
    </profiles>
</clickhouse>
```

- [ ] **Step 7: Create `.env.production.example`**

```dotenv
# ---- Plausible CE — production env (megalan) ----
# Copy to .env.production (chmod 600) and fill in. Never commit .env.production.

# REQUIRED
BASE_URL=https://plausible.leandrossb.com
# Generate with: openssl rand -base64 48
SECRET_KEY_BASE=

# Recommended
# Block public self-registration after the admin is created:
DISABLE_REGISTRATION=invite
# Set to the admin's numeric DB id AFTER bootstrap (Task 6), then restart:
# ADMIN_USER_IDS=1

# DO NOT set ENABLE_EMAIL_VERIFICATION — leaving it unset makes CE auto-verify
# registered users (the admin), so login works without SMTP.

# DATABASE_URL / CLICKHOUSE_DATABASE_URL intentionally unset: the app's runtime
# defaults point at the plausible_db / plausible_events_db service names.

# --- Email (deferred). Set when SMTP is available to enable reports/resets: ---
# MAILER_ADAPTER=Bamboo.Mua
# MAILER_EMAIL=plausible@plausible.leandrossb.com
# SMTP_HOST_ADDR=...
# SMTP_HOST_PORT=587
# SMTP_USER_NAME=...
# SMTP_USER_PWD=...
# SMTP_HOST_SSL_ENABLED=true
```

- [ ] **Step 8: Add `.env.production` to `.gitignore`**

Append after the existing `.env` line:

```diff
 .env

+# Plausible self-host production env (contains SECRET_KEY_BASE — never commit)
+.env.production
+.env.*.local
+
 # Geolocation databases
```

- [ ] **Step 9: Validate the compose syntax**

Run: `docker compose -f docker-compose.yml -f docker-compose.prod.yml config --quiet`
Expected: no output, exit 0. (Run locally; Docker need not be running for `config`.)

- [ ] **Step 10: Commit**

```bash
git add docker-compose.yml docker-compose.prod.yml clickhouse/ .env.production.example .gitignore
git commit -m "deploy: add self-host compose + clickhouse config + env template"
```

---

## Task 2: nginx site config + Origin Cert installer

**Files:**
- Create: `deploy/nginx/plausible.leandrossb.com.conf`
- Create: `deploy/install-origin-cert.sh`

**Interfaces:**
- Produces: the nginx site consumed by Task 7; the cert installer that Task 7 runs (needs Leandro's sudo).

- [ ] **Step 1: Create `deploy/nginx/plausible.leandrossb.com.conf`**

```nginx
# Plausible CE — reverse-proxied behind Cloudflare (zone leandrossb.com, Full mode).
# TLS terminates here with a Cloudflare Origin Cert. ssl_stapling MUST be off.

server {
    listen 80;
    listen [::]:80;
    server_name plausible.leandrossb.com;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name plausible.leandrossb.com;

    ssl_certificate     /etc/nginx/ssl/plausible.leandrossb.com.crt;
    ssl_certificate_key /etc/nginx/ssl/plausible.leandrossb.com.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # CRITICAL (GOTCHA): with stapling on, nginx blocks the TLS handshake waiting
    # for OCSP from ocsp.cloudflare.com and Cloudflare returns 525. Keep OFF.
    ssl_stapling off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    # Event ingestion payloads are small; LiveView websocket upgrades are used by the dashboard.
    client_max_body_size 10m;

    location / {
        proxy_pass http://127.0.0.1:14100;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        # LiveView / WebSocket upgrade
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 90;
    }
}
```

> Note on client IP: behind Cloudflare, `$proxy_add_x_forwarded_for` chains the real client IP (first hop) ahead of the CF edge IP. Plausible's `PlausibleWeb.RemoteIP` plug reads the leftmost value, so visitor IPs are accurate without `set_real_ip_from`. If accuracy drifts, add the CF IP ranges with `real_ip_header CF-Connecting-IP`.

- [ ] **Step 2: Create `deploy/install-origin-cert.sh`**

```bash
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
```

- [ ] **Step 3: Make the script executable and commit**

```bash
chmod +x deploy/install-origin-cert.sh
git add deploy/nginx/plausible.leandrossb.com.conf deploy/install-origin-cert.sh
git commit -m "deploy: add nginx site + Origin Cert installer for plausible.leandrossb.com"
```

---

## Task 3: Bootstrap-admin script + backup scripts + deploy wrapper

**Files:**
- Create: `deploy/bootstrap-admin.exs`
- Create: `deploy/backup-pg.sh`
- Create: `deploy/backup-clickhouse.sh`
- Create: `deploy/deploy.sh`

**Interfaces:**
- Produces: `bootstrap-admin.exs` (run by Task 6 inside the container via `bin/plausible eval`); backup scripts (wired to cron in Task 9); `deploy.sh` (the canonical rebuild command used by every later ops step).

- [ ] **Step 1: Create `deploy/bootstrap-admin.exs`**

Idempotent: creates the admin if missing, then forces `email_verified: true`. Uses the verified API `User.new/1` (registration changeset) + `User.changeset/2`.

```elixir
# Run inside the plausible container, e.g.:
#   docker cp deploy/bootstrap-admin.exs plausible:/tmp/bootstrap-admin.exs
#   docker exec plausible /app/bin/plausible eval /tmp/bootstrap-admin.exs
# Env: ADMIN_EMAIL (required), ADMIN_NAME (default "Admin"), ADMIN_PASSWORD (required)
alias Plausible.Repo
alias Plausible.Auth.User

email = System.fetch_env!("ADMIN_EMAIL")
name  = System.get_env("ADMIN_NAME", "Admin")
pass  = System.fetch_env!("ADMIN_PASSWORD")

user =
  case Repo.get_by(User, email: email) do
    nil ->
      %User{}
      |> User.new(%{"name" => name, "email" => email, "password" => pass})
      |> Repo.insert!()
    existing ->
      existing
  end

user =
  user
  |> User.changeset(%{email_verified: true})
  |> Repo.update!()

IO.puts("OK admin bootstrapped id=#{user.id} email=#{user.email} email_verified=#{user.email_verified}")
```

- [ ] **Step 2: Create `deploy/backup-pg.sh`**

```bash
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
```

- [ ] **Step 3: Create `deploy/backup-clickhouse.sh`**

```bash
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
```

- [ ] **Step 4: Create `deploy/deploy.sh`**

```bash
#!/usr/bin/env bash
# Canonical build/up command for Plausible on megalan. Run from ~/analytics.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  --env-file .env.production up -d --build
```

- [ ] **Step 5: Make scripts executable and commit**

```bash
chmod +x deploy/backup-pg.sh deploy/backup-clickhouse.sh deploy/deploy.sh
git add deploy/bootstrap-admin.exs deploy/backup-pg.sh deploy/backup-clickhouse.sh deploy/deploy.sh
git commit -m "deploy: add admin bootstrap + backup scripts + deploy wrapper"
```

---

## Task 4: Sync fork to megalan + write `.env.production`

**Files:** server-side only (`~/analytics/.env.production`, never committed).

**Interfaces:** Consumes Tasks 1–3 artifacts (pushed to the fork). Produces the secrets the build in Task 5 reads.

- [ ] **Step 1: Push the deploy artifacts to the fork**

Run locally:
```bash
git push origin master
```
Expected: the three commit hashes from Tasks 1–3 push to `github.com:LeandroSSB/analytics`.

- [ ] **Step 2: Ensure `~/analytics` exists and is up to date on megalan**

```bash
ssh megalan 'if [ -d ~/analytics ]; then cd ~/analytics && git pull; else git clone git@github.com:LeandroSSB/analytics.git ~/analytics && cd ~/analytics; fi && git log --oneline -1'
```
Expected: latest commit matches the push from Step 1.

> If megalan cannot pull the private repo by SSH (no deploy key), rsync instead from local:
> `rsync -az --delete --exclude=node_modules --exclude=.git --exclude=_build --exclude=deps --exclude=priv/static --exclude=.env.production -e ssh ./ megalan:~/analytics/`

- [ ] **Step 3: Generate `SECRET_KEY_BASE`**

```bash
ssh megalan 'openssl rand -base64 48'
```
Expected: a 64-char base64 string. Copy it.

- [ ] **Step 4: Write `~/analytics/.env.production` (chmod 600)**

Replace `<SECRET>` with the value from Step 3.

```bash
ssh megalan 'cat > ~/analytics/.env.production && chmod 600 ~/analytics/.env.production' <<'EOF'
BASE_URL=https://plausible.leandrossb.com
SECRET_KEY_BASE=<SECRET>
DISABLE_REGISTRATION=invite
EOF
```
Expected: no output; `ssh megalan 'ls -l ~/analytics/.env.production'` shows `-rw------- 1 leandro leandro`.

- [ ] **Step 5: Sanity-check the file**

```bash
ssh megalan 'grep -cE "^BASE_URL=|^SECRET_KEY_BASE=" ~/analytics/.env.production'
```
Expected: `2`.

---

## Task 5: Build + first boot (local-only, no nginx yet)

**Goal:** get the stack running on megalan and answering `/api/health` on `127.0.0.1:14100`. Not yet public.

- [ ] **Step 1: Start the build (this compiles all Elixir deps + the release — expect 10–20 min, high RAM)**

```bash
ssh megalan 'cd ~/analytics && bash deploy/deploy.sh 2>&1 | tail -40'
```
> The first build is heavy. Run when megalan load is low (other stacks — pecunium/streaming-rd/marmoaria — should be idle). Watch memory; the Elixir compile can spike. If the build OOMs, free build cache first: `docker builder prune -af`.

Expected (tail): `Container plausible-plausible-1  Started` (or similar), no build errors. The `command` then runs `db createdb` → `db migrate` → `run`.

- [ ] **Step 2: Wait for the app to become healthy**

```bash
ssh megalan 'cd ~/analytics && for i in $(seq 1 30); do docker compose -f docker-compose.yml -f docker-compose.prod.yml ps --format json plausible | grep -q "\"Health\":\"healthy\"" && echo HEALTHY && break; sleep 10; done; docker compose -f docker-compose.yml -f docker-compose.prod.yml ps'
```
Expected: eventually `HEALTHY` and all three services `(healthy)`.

- [ ] **Step 3: Verify the readiness endpoint returns 200**

```bash
ssh megalan 'curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:14100/api/health'
```
Expected: `200`. (If 502/000, the app hasn't bound :8000 yet — check logs in Step 4.)

- [ ] **Step 4: Inspect boot logs for problems**

```bash
ssh megalan 'cd ~/analytics && docker compose -f docker-compose.yml -f docker-compose.prod.yml logs --tail=80 plausible'
```
Expected: lines showing `createdb`, `interweave_migrate` (no errors), then Phoenix listening on `8000`. **Confirm absence of**: license errors (impossible in CE), `site_encrypt` cert-provisioning attempts, ClickHouse/Postgres connection errors. If `site_encrypt` tries to fetch a cert, that is a config regression — ensure `HTTPS_PORT` is not set in `.env.production` (it isn't, per Task 4).

- [ ] **Step 5: Verify migrations ran (sanity)**

```bash
ssh megalan 'docker exec plausible_db psql -U postgres -d plausible_db -c "select count(*) from schema_migrations;"'
```
Expected: a number > 200 (233+ migrations exist; the count reflects applied ones).

- [ ] **Step 6: Checkpoint (no file change)**

The stack is running locally. Commit nothing; this is a runtime state. Proceed to Task 6.

---

## Task 6: Bootstrap the admin user (no email)

**Goal:** create the super-admin account. Exploits the CE auto-verify behavior (`email_verified = not must_verify?` with no `ENABLE_EMAIL_VERIFICATION`).

- [ ] **Step 1: Copy the bootstrap script into the container**

```bash
ssh megalan 'docker cp ~/analytics/deploy/bootstrap-admin.exs plausible:/tmp/bootstrap-admin.exs'
```
Expected: no output. (Container names are pinned by `container_name:` in the compose — they are exactly `plausible`, `plausible_db`, `plausible_events_db`. Verify with `docker ps --format "{{.Names}}"` if unsure.)

- [ ] **Step 2: Run the bootstrap (substitute real email + a strong password)**

```bash
ssh megalan 'docker exec \
  -e ADMIN_EMAIL=leandro@REDACTED.example \
  -e ADMIN_NAME=Leandro \
  -e ADMIN_PASSWORD=REDACTED-STRONG-PASSWORD \
  plausible /app/bin/plausible eval /tmp/bootstrap-admin.exs'
```
Expected: `OK admin bootstrapped id=1 email=... email_verified=true`. Note the `id`.

- [ ] **Step 3: Confirm the user is queryable + verified**

```bash
ssh megalan 'docker exec plausible_db psql -U postgres -d plausible_db -c "select id, email, email_verified from users;"'
```
Expected: one row, `email_verified = t`.

- [ ] **Step 4: Promote to super-admin via `ADMIN_USER_IDS`**

Using the `id` from Step 2, append to `.env.production`:

```bash
ssh megalan 'echo "ADMIN_USER_IDS=<ID>" >> ~/analytics/.env.production'
```
Then restart the app service (migrations are already applied — this re-runs them idempotently, fast):

```bash
ssh megalan 'cd ~/analytics && docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.production up -d plausible'
```

- [ ] **Step 5: Verify login works over a local SSH tunnel**

Open a tunnel and log in via browser:
```bash
ssh -L 14100:127.0.0.1:14100 megalan -N
```
Then browse to `http://localhost:14100/login` and sign in with the admin email + password.
Expected: dashboard loads (empty — no sites yet). Close the tunnel when done.

---

## Task 7: nginx site + Cloudflare DNS + TLS → public

**Goal:** serve `https://plausible.leandrossb.com`. Needs Leandro's sudo for nginx/cert steps.

- [ ] **Step 1: Create the Cloudflare DNS record**

In the Cloudflare dashboard for `leandrossb.com`: add an **A** record `plausible` → `192.168.0.210` (megalan LAN IP — Cloudflare proxies it via the tunnel/public IP), **Proxied (orange)**. (If the megalan public IP is used directly, use the current dynamic IP — but proxied + LAN IP is the resilient choice, matching marmoaria's CF setup.)

> Alternatively use a CNAME to an existing `*.leandrossb.com` record. The key is: **orange-cloud (proxied)**.

- [ ] **Step 2: Obtain the Cloudflare Origin Certificate**

Cloudflare dashboard → `leandrossb.com` → SSL/TLS → Origin Server → Create Certificate → RSA (2048), hostnames `*.leandrossb.com,leandrossb.com`, validity 15 years. Copy the **Origin Certificate** and **Private Key** to two local files (`plausible.crt`, `plausible.key`). (The key never enters the repo.)

- [ ] **Step 3: Ensure the zone SSL mode is Full**

Cloudflare dashboard → SSL/TLS → Overview → mode **Full** (not Flexible, not Full Strict — the Origin Cert is not publicly trusted, Full doesn't validate it).

- [ ] **Step 4: Install the cert + nginx site (needs Leandro's sudo)**

Copy the two cert files to megalan, then run the installer:
```bash
scp plausible.crt plausible.key megalan:/tmp/
ssh megalan 'sudo bash ~/analytics/deploy/install-origin-cert.sh /tmp/plausible.crt /tmp/plausible.key'
```
Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful` then `OK: plausible.leandrossb.com TLS installed and nginx reloaded.`

> If `sudo` prompts for a password non-interactively and fails, run that one command in an interactive shell (`ssh -t megalan`) so Leandro can type the password.

- [ ] **Step 5: Verify end-to-end over the public hostname**

```bash
curl -fsS -o /dev/null -w "%{http_code}\n" https://plausible.leandrossb.com/api/health
```
Expected: `200`. If `525`: confirm `ssl_stapling off;` is present in the installed `/etc/nginx/sites-available/plausible.leandrossb.com.conf` (the GOTCHA). If `521/522`: Cloudflare cannot reach megalan — check the port-forward/NAT/public-IP reachability (the same path the other `*.leandrossb.com` services use).

---

## Task 8: End-to-end validation — ingest a real pageview

**Goal:** prove the full pipeline (tracker → ingestion → ClickHouse → dashboard) works.

- [ ] **Step 1: Create the first site**

Log in at `https://plausible.leandrossb.com` → "Add site" → domain e.g. `dummy.test` (or a real owned domain). The UI shows the tracker snippet.

- [ ] **Step 2: Send a test pageview directly to the events API**

Substitute the site domain. This mimics what the tracker does:
```bash
curl -fsS -X POST https://plausible.leandrossb.com/api/event \
  -H "Content-Type: application/json" \
  -d '{"name":"pageview","url":"https://dummy.test/","domain":"dummy.test"}'
```
Expected: HTTP `202 Accepted`.

- [ ] **Step 3: Confirm the event landed in ClickHouse**

```bash
ssh megalan 'docker exec plausible_events_db clickhouse-client -d plausible_events_db -q "select count() from events_v2;"'
```
Expected: `1` (or more).

- [ ] **Step 4: See it in the dashboard**

Refresh the site's dashboard in the UI. Expected: "Current visitors: 1" and a pageview for `/` within seconds.

- [ ] **Step 5: (Real tracker) embed on an owned site**

On a real site (e.g. `marmoaria.leandrossb.com`), add to `<head>`:
```html
<script defer data-domain="marmoaria.leandrossb.com"
  src="https://plausible.leandrossb.com/js/script.js"></script>
```
For SRI, prefer the hash variant (the UI provides the snippet with a correct `integrity` attribute): use `script.hash.js` and keep the `integrity="sha384-..." crossorigin="anonymous"` attributes verbatim. Re-fetch the snippet if you change tracker config (outbound links, etc.) — config interpolation changes the script and invalidates the hash.

- [ ] **Step 6: Checkpoint**

The deployment is functionally complete. Commit nothing (runtime state).

---

## Task 9: Backups (cron) + ops documentation

**Files:**
- Modify: `README.md` (append a self-host section) — optional
- Cron entries (leandro crontab on megalan)

- [ ] **Step 1: Dry-run both backup scripts once**

```bash
ssh megalan 'bash ~/analytics/deploy/backup-pg.sh && bash ~/analytics/deploy/backup-clickhouse.sh && ls -lh /mnt/pool/plausible-backup/'
```
Expected: `pg-YYYY-MM-DD.sql.gz` and `ch-YYYY-MM-DD.tar.gz` appear, non-zero size.

- [ ] **Step 2: Install daily cron (leandro, 03:17 and 03:37 — off-the-hour)**

```bash
ssh megalan '(crontab -l 2>/dev/null; echo "17 3 * * * /home/leandro/analytics/deploy/backup-pg.sh >> /home/leandro/plausible-backup-pg.log 2>&1"; echo "37 3 * * * /home/leandro/analytics/deploy/backup-clickhouse.sh >> /home/leandro/plausible-backup-ch.log 2>&1") | crontab -'
ssh megalan 'crontab -l | grep plausible'
```
Expected: the two cron lines printed.

- [ ] **Step 3: Restore-test the Postgres backup (into a throwaway container)**

```bash
ssh megalan 'docker run --rm -d --name pg-restore-test -e POSTGRES_PASSWORD=x postgres:16-alpine'
ssh megalan 'gunzip -c /mnt/pool/plausible-backup/pg-*.sql.gz | docker exec -i pg-restore-test psql -U postgres'
ssh megalan 'docker exec pg-restore-test psql -U postgres -d plausible_db -c "select count(*) from users;"'
ssh megalan 'docker rm -f pg-restore-test'
```
Expected: the restore runs (errors for the `plausible_db` database not existing on first connect are fine if the dump includes `CREATE DATABASE`; otherwise connect to a pre-created db). Confirm `users` row count matches. This proves backups are restorable.

- [ ] **Step 4: Document ops in the repo README (append)**

Append to `README.md`:

```markdown
## Self-hosting this fork (megalan, CE)

Builds Plausible **Community Edition** (`MIX_ENV=ce`) from this repo's Dockerfile.

- **Stack:** `plausible` (app, built) + `plausible_db` (Postgres 16) + `plausible_events_db` (ClickHouse 25.11).
- **Required env** (`.env.production`, gitignored): `BASE_URL`, `SECRET_KEY_BASE`. DB URLs use the app's runtime defaults.
- **Deploy:** `bash deploy/deploy.sh` (= `docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.production up -d --build`).
- **Admin (no SMTP):** `deploy/bootstrap-admin.exs` (CE auto-verifies when `ENABLE_EMAIL_VERIFICATION` is unset).
- **Public:** nginx reverse-proxy `plausible.leandrossb.com` → `127.0.0.1:14100`, TLS via Cloudflare Origin Cert (`ssl_stapling off`).
- **Backups:** `deploy/backup-pg.sh`, `deploy/backup-clickhouse.sh` (cron, daily → `/mnt/pool/plausible-backup`).
- **Update:** `git pull && bash deploy/deploy.sh` (migrations re-run idempotently on restart).
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: self-host (megalan, CE) section in README"
git push origin master
```

---

## Done criteria

- [ ] `https://plausible.leandrossb.com/api/health` → 200.
- [ ] Admin can log in; `ADMIN_USER_IDS` set; public self-registration blocked.
- [ ] A test pageview appears in the dashboard and in `events_v2`.
- [ ] Real site tracked with the SRI (`script.hash.js`) snippet.
- [ ] Daily pg + ClickHouse backups run via cron; restore tested once.
- [ ] All deploy artifacts committed to the fork; `.env.production` is NOT committed.

## Validate-during-impl (from spec §11) — resolution

1. **`email_verified` changeset:** resolved — `User.new/1` creates; `User.changeset/2` flips `email_verified`. On CE with no `ENABLE_EMAIL_VERIFICATION`, `set_email_verification_status/1` already sets it true, so Task 6 even without the explicit flip works.
2. **`site_encrypt` with `BASE_URL=https` + no `HTTPS_PORT`:** resolved — Task 5 Step 4 verifies no cert-provisioning in logs; the app stays HTTP behind nginx.
3. **ClickHouse image:** pinned `clickhouse/clickhouse-server:25.11.5.8-alpine` (fork CI version).
4. **Backup strategy:** resolved — Task 9 (pg_dump + volume tar snapshot, 7-day retention, restore-tested).
5. **`plausible_uploads` / volume:** resolved — using the official `plausible-data:/var/lib/plausible` volume (the app's `DEFAULT_DATA_DIR`); the fork Dockerfile's `/app/uploads` is superseded by the release's data dir.
```
