# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a fork of [plausible/analytics](https://github.com/plausible/analytics) (privacy-first web analytics) currently tracking upstream with no local divergence. Built with Elixir + Phoenix, PostgreSQL + ClickHouse, and a React/Tailwind frontend.

## Common commands

### First-time setup (needs Docker for the two databases)
```bash
make postgres       # PostgreSQL container (plausible_db)
make clickhouse     # ClickHouse container (plausible_clickhouse)
make install        # deps + DB create/migrate + seeds + assets + tracker + geo DB
# then: make server   →  Phoenix on http://localhost:8000
```
Tool versions are pinned in `.tool-versions` (use asdf/mise): Erlang 28, Elixir 1.20, Node 24.
Seeded login: `user@plausible.test` / `plausible`, with a `dummy.site` site. Send a fake pageview with `mix send_pageview`.

### Tests
```bash
mix test                                  # default MIX_ENV=test = Enterprise Edition (EE)
mix test test/plausible/stats/clickhouse_test.exs              # single file
mix test test/plausible/ingestion_test.exs:42                   # single test by line
mix test --include slow --include minio --include migrations   # full (CI parity; minio needs `make minio`)
mix test --only migrations                                      # only tagged tests
MIX_ENV=ce_test mix test                   # Community Edition (CE) suite
mix test.e2e                              # Playwright E2E (run `mix e2e.setup` first)
```
- CI runs `mix test --include slow --include minio --include migrations --partitions 6 --max-failures 1 --warnings-as-errors` against both `test` (EE) and `ce_test` matrix envs.
- Tests **must live under `test/`** — `test_helper.exs` raises if any `*_test.exs` is found in `lib/`. Mirrors the source layout: `test/plausible/` ↔ `lib/plausible/`, `test/plausible_web/` ↔ `lib/plausible_web/`.
- `--partitions 6` + `MIX_TEST_PARTITION=N` shards the suite; `--warnings-as-errors` is enforced.

### Static checks (the "Static checks" CI job)
```bash
mix format                      # format (CI: mix format --check-formatted)
mix format --check-formatted    # CI gate
mix credo diff --from-git-merge-base origin/master   # lint only changed code
mix dialyzer                    # type checks (slow first run; PLT cached in priv/plts)
mix deps.unlock --check-unused
mix generate_countries_meta && git diff --exit-code -- assets/data/countries_meta.json
```
A `pre-commit` hook runs `mix format` (set up with `pip install --user pre-commit && pre-commit install`).

### Frontend (assets) — React/TS
```bash
npm --prefix assets ci
npm --prefix assets run test          # jest (TZ=UTC)
npm --prefix assets run lint          # eslint + stylelint
npm --prefix assets run typecheck     # tsc --noEmit
npm --prefix assets run format
```

### Tracker (tracker/) — standalone JS, MIT-licensed, served to client sites
```bash
npm --prefix tracker ci
npm --prefix tracker run deploy       # compile all variants → priv/tracker/js/ (node compile.js)
npm --prefix tracker test             # Playwright tests
npm --prefix tracker run lint
npm --prefix tracker run check-format
```

### Assets & release
```bash
mix assets.setup        # install tailwind + esbuild
mix assets.build        # dev build
mix assets.deploy       # minified + digest (also runs in Dockerfile)
mix release             # build the `plausible` OTP release (rel/)
```

### Database
- PostgreSQL migrations: `priv/repo/migrations/` (230+). `mix ecto.migrate`, `mix ecto.reset` (drop+setup+seed).
- ClickHouse schema lives under `priv/`. The `clean_clickhouse` mix task wipes analytics tables (used in the `test` alias).
- Both DBs are created/migrated together via `mix ecto.create` / `mix ecto.migrate` (Ecto manages both adapters).

## Architecture

### Two OTP app modules
- **`Plausible`** (`lib/plausible/`) — domain & business logic.
- **`PlausibleWeb`** (`lib/plausible_web/`) — Phoenix web layer: `controllers/`, `live/` (LiveViews), `plugs/`, `templates/`, `router.ex`.

### Three repositories (dual-database design)
- **`Plausible.Repo`** — PostgreSQL. General app data (sites, users, teams, billing, goals, settings). Uses `Plausible.Audit.Repo`.
- **`Plausible.ClickhouseRepo`** — ClickHouse, **read-only** (`read_only: true`). All analytics queries.
- **`Plausible.IngestRepo`** — ClickHouse, **write-centric**. Event ingestion inserts. Knows about clustered/replicated tables (`clustered_table?`, `replica_count`).
ClickHouse is reached via `ecto_ch` / `Ecto.Adapters.ClickHouse`. The `:plausible` app lists `ecto_repos: [Plausible.Repo, Plausible.IngestRepo]`.

### Event ingestion (write path)
`POST /api/event` → `PlausibleWeb.Api.ExternalController` → `Plausible.Ingestion.Request` → buffers/persists to ClickHouse.
- `lib/plausible/ingestion/` — `request.ex` (parse+validate), `counters/` (per-domain internal metrics via `SummingMergeTree`, flushed every 10s), `persistor/` (embedded / embedded_with_relay / remote strategies), `write_buffer.ex`.
- The tracker JS (`priv/tracker/js`) sends events here; site-specific config is interpolated into the script by `TrackerPlug` + `PlausibleWeb.Tracker`.

### Stats query engine (read path)
- **`Plausible.Stats.Query`** (`lib/plausible/stats/query.ex`) is the central struct for every analytics query (time range, dimensions, filters, metrics, pagination, imports).
- `ApiQueryParser` / `ParsedQueryParams` / `QueryBuilder` build a `Query` from API/dashboard params; `QueryRunner` executes it against `ClickhouseRepo`. Results may merge **imported** (Google Analytics, `stats/imported/`), **legacy**, and **consolidated** views.
- SQL is assembled in `lib/plausible/stats/sql/` (`expression.ex`, `where_builder.ex`, `query_builder.ex`, `fragments.ex`).
- The internal stats API lives at `scope "/api"` → `Api.StatsController` (`POST /:domain/query`, exports, current visitors, funnels, exploration).
- External/public API (Stats API + Events API) is OpenAPI-spec'd via `open_api_spex` (`/api/plugins/spec/openapi`).

### EE vs CE (Community Edition) split — the most important convention
The same source tree builds **two products**: Plausible Analytics (EE) and Plausible CE. This is controlled at **compile time**, not runtime:
- **`lib/plausible.ex`** defines macros: `ee?()` / `ce?()`, and `on_ee do ... end` / `on_ce do ... end`. They use `:erlang.phash2(1,1)` to defeat the type checker so both branches compile, then the dead branch is dropped.
- **Mix envs**: `dev`/`test`/`e2e_test` = EE; `ce`/`ce_dev`/`ce_test` = CE; `prod` = EE; `load` = load testing. `elixirc_paths` excludes `extra/lib` entirely in `:ce*` envs (so EE modules don't exist in CE builds).
- **EE-only code lives in `extra/lib/`** (mirrors `lib/`): SSO/SAML, funnels, customer support, HelpScout, consolidated views, some stats/ingestion/plugins code. When adding a premium feature, put it in `extra/lib/` and gate call-sites with `on_ee do ... end`.
- CE features excluded: marketing funnels, ecommerce revenue goals, SSO, Sites API. Tests tag EE-only behavior with `@tag :ee_only` and CE-only with `@tag :ce_build_only` (see `test/test_helper.exs`).

### Domain areas under `lib/plausible/`
`ingestion/` (write path), `stats/` (read path / query engine), `site/` (site mgmt, shared links, tracker config, reports), `teams/` (multi-tenant: teams → memberships → invitations → billing; replaces older single-owner model), `billing/` (Paddle subscriptions), `auth/` (passwords, 2FA/TOTP, SSO SAML via `simple_saml`), `audit/`, `plugins/`, `funnel/` (EE), `segments/`, `google/` (Search Console + GA import), `imported/` (historical import adapters).

### Background jobs & observability
- **Oban** for queued jobs (`lib/workers/`, `lib/plausible/workers/`); errors reported via `lib/oban_error_reporter.ex`.
- **OpenTelemetry** is wired throughout (ecto, phoenix, oban, cowboy, req) — keep spans instrumented when adding hot paths.
- **Prom_ex / Peep** expose Prometheus metrics; **Sentry** for error reporting (`sentry_filter.ex`).
- **Feature flags** via `fun_with_flags` (UI at `/flags`, persistent in Postgres) — gate new behavior behind a flag.

### Multi-target tracker compilation
`tracker/src/plausible.js` is one source compiled into many variants (web snippet, npm package, legacy `.compat`/`.exclusive` extensions) by `tracker/compile.js` + rollup + `@swc/core`. `COMPILE` globals toggle features per variant (`tracker/compiler/variants.json`); dead branches are tree-shaken. Output lands in `priv/tracker/js/`. Over 1000 variants compile in ~3s. The `tracker_script_version` in `tracker/package.json` busts CDN cache. See `tracker/ARCHITECTURE.md`.

### Frontend entrypoints
esbuild bundles from `assets/js/`: `app.js` (main app), `dashboard.tsx` (stats dashboard, React + react-query + chart.js + d3), `embed.host.js` / `embed.content.js` (iframe-resizer for shared/embedded dashboards). Tailwind v4 compiles `assets/css/app.css`.

### Config & release
- `config/` is split per env (`config.exs` base, `dev.exs`, `prod.exs`, `runtime.exs` for env-var-driven prod config, `ce*.exs`, `test.exs`, `e2e_test.exs`, `load.exs`).
- The Dockerfile builds `MIX_ENV=ce` by default (the self-hostable image); EE images build with `MIX_ENV=prod`. `rel/overlays` + `import_extra_config.exs` inject EE config into the release. Runs as uid 999, listens on `:8000`.
- `lib/plausible_release.ex` handles release tasks (DB migrations on boot, geo DB download, etc.); `rel/docker-entrypoint.sh` is the container entrypoint.

## graphify knowledge graph

A code knowledge graph of the backend core (`lib/` + `extra/`, 4793 nodes / 7263 edges / 493 communities) lives in `graphify-out/` (gitignored). Built with free AST extraction — **0 LLM tokens**.

**Use it before re-deriving architecture from scratch.** When asked how something connects, what calls what, or to trace a path across modules, query the graph instead of grepping:
```bash
graphify query "How does an event flow from HTTP to ClickHouse?"
graphify path "Ingestion.Event" "ClickhouseRepo"      # shortest path between concepts
graphify explain "Plausible.Stats.Query"               # plain-language node summary
open graphify-out/graph.html                            # interactive visualization
```
The full audit (god nodes, surprising connections, per-community cohesion) is in `graphify-out/GRAPH_REPORT.md`.

Refresh after code changes (incremental, AST-only, no tokens):
```bash
/graphify . --update          # re-extract only new/changed files
```
Frontend (`assets/js`, `tracker/src`) is **not** in the graph — build a separate one with `/graphify assets/js` or rebuild the whole source with `/graphify lib extra assets/js tracker/src`. Docs/markdown are excluded (would need an LLM/Gemini key for semantic extraction).

## Conventions
- **Format**: `mix format` (formatter uses `Phoenix.LiveView.HTMLFormatter` plugin; `assert_matches/1` is a local no-parens macro). Don't fight the formatter.
- **Mocks**: `Mox` (`Plausible.HTTPClient.Mock`, `Plausible.DnsLookup.Mock`) — define mocks in `test/test_helper.exs`, set with `Mox.expect` / `Plausible.Mock` helpers. `ex_machina` factory in `test/support/factory.ex`. Ecto SQL Sandbox in `:manual` mode (checkout per test via `conn_case`/`data_case`).
- **When you change the query schema**, regenerate the TS types: `npm --prefix assets run generate-types` (from `priv/json-schemas/query-api-schema.json`), then `npm --prefix assets run typecheck`.
- The `CHANGELOG.md` is large and upstream-maintained; the tracker has its own `npm_package/CHANGELOG.md`.
