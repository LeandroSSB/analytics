# Plausible CE (fork) no megalan — Design de Deploy

**Data:** 2026-08-11
**Status:** Aprovado (brainstorming), aguardando plano de implementação
**Repo:** `git@github.com:LeandroSSB/analytics.git` (fork de `plausible/analytics`, branch `master`)
**Alvo:** self-host público para analytics dos próprios sites do Leandro.

---

## 1. Contexto e objetivos

Hospedar o Plausible no servidor `megalan` para coletar analytics dos sites próprios (portfolio, marmoaria, vibedamente, etc.). Uso **pessoal, single-user, multi-site**. Não é multi-tenant, não há cobrança, não há convites de equipe por enquanto.

Objetivos explícitos:
- Funcionar end-to-end: tracker → ingestão → ClickHouse → dashboard.
- **Compreensão máxima** do código e funcionamento (manutenção/troubleshooting).
- **Build do próprio fork**, com vista a customizar o Elixir no futuro (evoluir/mudar código pra necessidades próprias).

## 2. Decisões (e porquê)

| Decisão | Escolha | Razão |
|---|---|---|
| Edição | **Plausible CE** (`MIX_ENV=ce`) | EE exige licença comprada: o módulo `extra/lib/plausible/license.ex` em `MIX_ENV=prod` faz hash SHA256 da env `:license_key` vs hash fixo e, sem match, `System.stop()` no boot — a app **recusa a subir**. O código EE é all-rights-reserved ("No rights are granted to use"), só está público pra transparência. CE é AGPLv3, sobe sem licença, tem tudo que sites pessoais precisam. |
| Build | **Do fork, no megalan** | Você quer rodar seu repo e customizar depois. O Dockerfile do repo já builda `MIX_ENV=ce` por default (`ARG MIX_ENV=ce`). Mesmo modelo do marmoaria. |
| Email | **Sem SMTP por agora** | `MAILER_ADAPTER` default = `Bamboo.Mua`. Sem creds SMTP a app sobe, só não envia (relatórios/convites/reset ficam pra depois). Admin criado via UI + verificação via console. |
| Domínio | **`plausible.leandrossb.com`** | Padrão dos subdomínios leandrossb (jellyfin, jellyseerr...). Atrás da Cloudflare (orange/proxied). |
| TLS | **Origin Cert CF + nginx** | Mesmo padrão testado do marmoaria. App em HTTP puro; TLS termina no nginx. |

### Features CE vs EE (referência)
CE **tem**: pageviews, visitantes únicos, fontes de tráfego, goals (por evento), eventos customizados, custom props, segments, exports CSV, API de stats/events, tempo real, Google Search Console (precisa OAuth), relatórios por email (precisa SMTP).
CE **não tem** (só EE, gated por licença): funis de conversão, receita de e-commerce, SSO/SAML, Sites API.

## 3. Topologia

```
Browser → Cloudflare (orange/proxied, zona leandrossb.com em modo Full)
        → nginx (megalan :443) — Origin Cert CF, ssl_stapling off
        → reverse-proxy HTTP → 127.0.0.1:14100
        → plausible-web container (:8000 interno)
              ├→ plausible-db      (PostgreSQL 18)   [rede interna, sem porta host]
              └→ plausible-events-db (ClickHouse 25.11) [rede interna, sem porta host]
```

- App fala **HTTP puro** pro nginx (TLS só no nginx). O `site_encrypt` (auto-HTTPS do CE) **não** é usado — ele brigaria com o nginx pelo :443. Não setar `HTTPS_PORT`.
- DBs ficam **só na rede interna do compose** — nenhuma porta publicada no host → zero colisão com as portas já em uso no megalan (`5432`, `45433`, `15432`, `15433`, `9000`, `8123`, etc.).
- Única porta host exposta: `14100` (web), reachable só pelo nginx.

## 4. Build & imagem

- **Repo no megalan**: `~/analytics` (sync do fork via `git pull`/rsync, branch `master`). A deploys anteriores do fork (CLAUDE.md, graphify) já estão neste dir.
- **Dockerfile**: o do próprio repo, sem alteração. Ele já builda `MIX_ENV=ce`:
  - Stage `buildcontainer`: `hexpm/elixir:1.20.2-erlang-28.5.0.3-alpine`, instala deps, builda assets (`npm run deploy --prefix tracker`, `mix assets.deploy`, `mix phx.digest`), baixa geo DB (`mix download_country_database`), `mix release plausible`.
  - Stage final: `alpine:3.23`, uid 999, `ENTRYPOINT ["/entrypoint.sh"]`, `EXPOSE 8000`, `CMD ["run"]`.
- **Compose**: escrito por nós (repo não traz um), modelado no `plausible/community-edition`. 3 serviços + rede bridge nomeada.

### Estrutura do compose (resumo — detalhe no plano de impl)

```yaml
# docker-compose.yml (base) + docker-compose.prod.yml (override)
services:
  plausible-web:
    build: { context: ., args: { MIX_ENV: ce } }
    env_file: .env.production
    depends_on: [plausible-db, plausible-events-db]
    ports: ["127.0.0.1:14100:8000"]   # só nginx reacha
    command: sh -c "/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run"
    healthcheck: GET /api/health
    volumes: [plausible_uploads:/app/uploads]
  plausible-db:
    image: postgres:18
    env: POSTGRES_DB/USER/PASSWORD
    volumes: [plausible_pg:/var/lib/postgresql/data]
    # sem ports (interno)
  plausible-events-db:
    image: clickhouse/clickhouse-server:25.11.5.8-alpine
    env: CLICKHOUSE_DB/USER/PASSWORD, CLICKHOUSE_SKIP_USER_SETUP
    ulimit nofile 262144
    volumes: [plausible_ch:/var/lib/clickhouse]
    # sem ports (interno)
volumes: { plausible_pg, plausible_ch, plausible_uploads }
networks: default (bridge)
```

**Por que duas envs por repositório**: o CE usa Postgres **e** ClickHouse. O `ecto.create`/`createdb` cria o schema em ambos. O `interweave_migrate` (não `migrate` puro) intercala as migrações dos dois repos em ordem cronológica — isso existe porque migrações cross-repo dependem umas das outras (ver `lib/plausible_release.ex:27-60`).

## 5. Rede, portas, nginx, TLS

### Portas (host)
- `14100` → plausible-web (só `127.0.0.1`, só nginx reacha).
- Postgres / ClickHouse: **nenhuma porta no host** (internos).
- Evita colisão com: `5432`, `45433`, `15432`, `15433` (postgres existentes), `9000`, `8123` (clickhouse/booked).

### nginx
- Site em `/etc/nginx/sites-available/plausible.leandrossb.com` (+ symlink `sites-enabled/`).
- `:80` → redirect 301 `https://`; `:443 ssl http2` com `proxy_pass http://127.0.0.1:14100`.
- HSTS, `acme-challenge` só relevante se grey-cloud (não é o caso — usamos Origin Cert).
- **GOTCHA crítico (regressão silenciosa, já caída no marmoaria)**: o block `:443` **DEVE** ter `ssl_stapling off;` (+ ciphers/session explícitos). Sem isso o nginx trava o handshake esperando OCSP de `ocsp.cloudflare.com` e a CF devolve **525** (conexão chega ao nginx mas ele não loga nada). Reaproveitar o config/modelo do marmoaria (`~/marmoaria/deploy/`).

### TLS / Cloudflare
- Zona `leandrossb.com` em modo **Full** (CF→origem :443 TLS, não valida cert — aceita Origin Cert).
- Origin Cert CF (`*.leandrossb.com`, válido até 2041) em `/etc/nginx/ssl/plausible.leandrossb.com.{crt,key}`. Reemitir pelo dashboard CF → SSL/TLS → Origin Server, se precisar (a key **não** entra neste spec — guardrail de credential leakage).
- Artefatos: reusar `~/marmoaria/deploy/install-origin-cert.sh` como molde (adaptar domínio/porta).

## 6. Configuração — `.env.production` (chmod 600)

Lido do `config/runtime.exs` via `get_var_from_path_or_env` (suporta `/run/secrets` ou env). **Obrigatórios** (hard-fail sem eles):

| Var | Valor | Nota |
|---|---|---|
| `BASE_URL` | `https://plausible.leandrossb.com` | `raise` se faltar; deve ter scheme http/https |
| `SECRET_KEY_BASE` | `<mix phx.gen.secret>` | `raise` se < 32 bytes |
| `DATABASE_URL` | `postgres://plausible:<pw>@plausible-db:5432/plausible_db` | Postgres |
| `CLICKHOUSE_DATABASE_URL` | `http://plausible-events-db:8123/plausible_events_db` | ClickHouse (read) |

**Importantes (CE):**

| Var | Valor | Nota |
|---|---|---|
| `LISTEN_IP` | `0.0.0.0` | default `127.0.0.1`; precisa `0.0.0.0` pra ser reachable no container |
| `PORT` / `HTTP_PORT` | `8000` | default 8000 |
| `HTTPS_PORT` | **não setar** | mantém app em HTTP atrás do nginx |
| `DISABLE_REGISTRATION` | `invite` (depois `true` opcional) | evita cadastros públicos aleatórios |
| `ADMIN_USER_IDS` | `<id do admin>` | setar após criar o admin → super-admin (acesso a /settings globais) |
| `MAILER_ADAPTER` | `Bamboo.Mua` (default) | sem `SMTP_*` → não envia, mas sobe |
| `MAILER_EMAIL` | `plausible@plausible.leandrossb.com` | remetente (só relevante quando tiver SMTP) |

**Opcionais (não setar agora — YAGNI):** `TOTP_VAULT_KEY` (2FA), `GOOGLE_CLIENT_ID/SECRET` (Search Console), `SENTRY_DSN`, `HONEYCOMB_*`, `PADDLE_*` (billing EE).

## 7. Dados, persistência e backups

- **Volumes nomeados** (fora do dir do repo, sobrevivem a `down`/rebuild):
  - `plausible_pg` — Postgres. Pequeno (config de sites/users/goals).
  - `plausible_ch` — ClickHouse. **Dominante em volume** (cresce com tráfego; eventos + sessões).
  - `plausible_uploads` — uploads do app (`/app/uploads`).
- **Disco (decisão inicial)**: volumes no default do Docker (LVM root, ~111 GB livres). Seus sites são baixo tráfego → suficiente. **Otimização futura documentada**: mover o volume ClickHouse p/ `/mnt/ssd` (240 GB, `noatime`) se queries ficarem lentas — **mesma troca-de-uma-linha** feita no Seafile (trocando o path do volume no env/compose). Não fazer agora.
- **Backups** (no plano de impl):
  - Postgres: `pg_dump` diário via cron (leandro), retenção ~7 dias, em `/mnt/pool` ou SSD.
  - ClickHouse: snapshot do volume (`docker run --rm -v plausible_ch:/data ... tar`) ou `BACKUP` nativo do CH 25.x. Frequência a definir (baixo tráfego → diário/semanal).

## 8. Init e primeiro acesso (sem email)

### Sequência de boot (serviço web)
O `command` do `plausible-web` encadeia:
```sh
/entrypoint.sh db createdb   # Plausible.Release.createdb  → cria DBs em PG + CH
/entrypoint.sh db migrate    # Plausible.Release.interweave_migrate → migrações intercaladas
/entrypoint.sh run           # plausible start (endpoint + oban + ingestion)
```
O app **não** migra sozinho no boot (só inicia os filhos Repo) — por isso o encadeamento.

### Criar admin sem SMTP
1. Subir a stack, deixar `plausible-web` healthy (`GET /api/health` = 200).
2. Registrar pela UI (`/register`) — cria `Plausible.Auth.User` com `email_verified: false` (o email de verificação não chega, sem SMTP).
3. No container, flipar verificação via release console:
   ```sh
   docker exec -it plausible-web /app/bin/plausible remote
   # dentro do console:
   alias Plausible.Repo; alias Plausible.Auth.User
   user = Repo.get_by!(User, email: "leandro@...")
   user |> Ecto.Changeset.change(email_verified: true) |> Repo.update!()
   ```
   *(changeset exato confirmado na impl; pode haver `User.verify/1` ou path equivalente — validar)*
4. Logar pela UI. Pegar o `id` do user e setar `ADMIN_USER_IDS=<id>` no `.env.production`, restart → vira super-admin.
5. Setar `DISABLE_REGISTRATION=invite` no `.env.production` e restart — bloqueia novos cadastros públicos (só via convite). Não é automático; é um setting manual pós-setup.

### Adicionar o primeiro site
UI → "Add site" → domain (ex: `marmoaria.leandrossb.com`) → copiar o snippet do tracker → colar no `<head>` do site alvo. Eventos chegam em tempo real.

**SRI / integridade do script (segurança):** ao embedar o tracker nos sites, prefira a variante com hash (`script.hash.js`) em vez do `script.js` puro — ela carrega via Subresource Integrity, protegendo contra comprometimento do seu próprio domínio de analytics:
```html
<script defer
  src="https://plausible.leandrossb.com/js/script.hash.js"
  integrity="sha384-..." crossorigin="anonymous"></script>
```
O hash é gerado pelo Plausible no endpoint `/js/script.hash.js` (a UI mostra o snippet pronto com o `integrity` correto). Para scripts com config customizada (ex: `script.outbound-links.js`), valide se o SRI continua batendo após mudar a config do tracker no painel — config interpolada muda o conteúdo do script e invalida o hash.

## 9. Operação, saúde e updates

- **Healthcheck**: compose `healthcheck` no `plausible-web` = `GET /api/health` (`Api.SystemController.readiness`, verifica DB + ClickHouse). nginx idem.
- **Logs**: `docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f plausible-web`.
- **Update (rebuild após sync do fork)**:
  ```sh
  cd ~/analytics && git pull          # ou rsync do local
  docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.production up -d --build web
  # interweave_migrate roda no restart do web
  ```
- **Validar E2E pós-deploy**: `https://plausible.leandrossb.com/api/health` = 200, `db` ping ~ms, login admin 200 + cookie de sessão, enviar pageview de teste (`mix send_pageview` no container ou curl pro `/api/event`) e ver no dashboard.
- **Compreensão do código**: o grafo graphify (`graphify-out/`) já mapeia o backend (4793 nós). Pra achar onde mexer antes de customizar: `graphify query "..."` / `graphify path`. CLAUDE.md + memória persistente dão o resto do contexto.

## 10. Fora de escopo (YAGNI — confirmar se quiser)

- Google Search Console integration (OAuth creds).
- 2FA (`TOTP_VAULT_KEY`).
- Import histórico do Google Analytics.
- Sentry / Honeycomb / observabilidade externa (o app já tem OpenTelemetry/Prom_Ex internos).
- SMTP/relatórios por email (deferido).
- ClickHouse em SSD, cluster/replicação (single-node basta p/ volume pessoal).

## 11. Pontos a validar na implementação

1. Comando exato do changeset de `email_verified` (passo 3 do admin) — `User.verify/1` vs `Ecto.Changeset.change`.
2. Confirmar que `site_encrypt` não tenta provisionar cert com `BASE_URL=https` + sem `HTTPS_PORT` (esperado: não, pois sem porta HTTPS o endpoint é HTTP).
3. Versão exata da imagem ClickHouse a pinar (25.11.5.8-alpine = mesma do CI; confirmar disponibilidade).
4. Estratégia de backup do ClickHouse (snapshot de volume vs `BACKUP` nativo) — definir no plano.
5. Se `plausible_uploads` é usado em CE (o app cria `/app/uploads` no Dockerfile) — montar mesmo que vazio.

## 12. Sequência de deploy (alto nível — detalhada no plano)

1. Sync fork → `~/analytics` no megalan.
2. Escrever `docker-compose.yml` + `docker-compose.prod.yml` + `.env.production` (chmod 600).
3. `docker compose ... up -d --build` (build CE, createdb, migrate, run).
4. Aguardar healthy; criar admin (UI + console); setar `ADMIN_USER_IDS`; restart.
5. nginx site + Origin Cert CF (`ssl_stapling off`).
6. Validar E2E (`/api/health`, login, pageview de teste).
7. Cron de backup (pg_dump + snapshot CH).
8. Commit do compose/env-example no fork (`.env.production` **não** — gitignored).
