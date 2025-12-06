# `hostinger-vps-infra` Repo – Specification (Draft)

Purpose: describe what the **`C:\projects\hostinger-vps-infra`** repo should contain so it can fully own the Hostinger VPS stack for **instantgis.cloud** while reusing patterns from this repo.

## 1. Scope

Home VPS on `instantgis.cloud`, running:
- AutoLift stack (this repo)
  - `api.instantgis.cloud` → AutoLift API
  - `booking.instantgis.cloud` → booking frontend
  - `rules.instantgis.cloud` → rules admin
- Audio guide stack (`C:\projects\casela-audiofence`)
  - `sag.instantgis.cloud` → SAG Angular app (audiofence-frontend)
  - `triplit.instantgis.cloud` → Triplit server
  - `triplit-console.instantgis.cloud` → Triplit console UI
- Supabase stack (from separate Supabase Docker repo)
  - `supabase.instantgis.cloud`, `studio.instantgis.cloud`, root `instantgis.cloud` healthcheck

The **infra repo** should be the single place where the *deployed* Docker Compose and Caddy config for this VPS live.

## 2. Proposed repo layout

```text
hostinger-vps-infra/
  README.md                 # High-level description + usage
  docker-compose.yml        # Full stack for instantgis.cloud
  caddy/
    Caddyfile               # All instantgis.cloud subdomains
  env/
    autolift-api.env        # Values consumed by api + booking + rules-admin
    supabase.env            # Values consumed by Supabase stack (from templates)
    sag.env                 # Values consumed by audiofence-frontend + Triplit
  scripts/
    ai-mcp-tools.ps1        # PowerShell module (Invoke-SagBuild, ...)
  docs/
    STACK-OVERVIEW.md       # Diagram + narrative
```

Notes:
- The infra repo is **single-domain**: everything is for `instantgis.cloud` only.
- Supabase Docker itself still lives in its own repo; here we only keep the **env file** used when bringing up Supabase.

## 3. docker-compose.yml – contents (conceptual)

`docker-compose.yml` in `hostinger-vps-infra` should define at least:
- `caddy` – reverse proxy, ports 80/443, mounts `caddy/Caddyfile`, joins `supabase_default`.
- `api` – from `adespaignet/autolift-api:...`, env from `env/autolift-api.env`.
- `booking` – from `adespaignet/autolift-booking:...`.
- `rules-admin` – from `adespaignet/autolift-rules-admin:...`.
- `audiofence-frontend` – from SAG image (to be defined), env from `env/sag.env`.
- `triplit-server` – from Triplit server image, env from `env/sag.env`.
- `triplit-console` – from Triplit console image.
- `watchtower` – same pattern as `docker/autolift-api/docker-compose.yml`.

The external `supabase_default` network should be preserved so `api` can talk to Supabase via `kong:8000`.

## 4. Caddyfile – contents (conceptual)

`caddy/Caddyfile` in `hostinger-vps-infra` should:
- Reuse **headers and CORS** patterns from `docker/autolift-api/Caddyfile`.
- Replace `saggini.cloud` with `instantgis.cloud` and add:
  - `sag.instantgis.cloud` → `audiofence-frontend:80`
  - `triplit.instantgis.cloud` → `triplit-server:80`
  - `triplit-console.instantgis.cloud` → `triplit-console:80`
- Keep Supabase blocks equivalent to what is generated from `docker/deploy/templates/Caddyfile.template` + `configs/instantgis.cloud.env`.

## 5. What to hoist from this repo

From **`docker/autolift-api/docker-compose.yml`**:
- Service definitions and restart policies for:
  - `caddy`, `api`, `booking`, `rules-admin`, `watchtower`.
- The `supabase_default` external network definition.

From **`docker/autolift-api/Caddyfile`**:
- Security headers and gzip/zstd config.
- API + Supabase + Studio vhost structure.

From **`docker/deploy/templates/*.template` + `configs/instantgis.cloud.env`**:
- The canonical mapping of `{{DOMAIN}}` → `instantgis.cloud` for:
  - `api`, `booking`, `rules`, `supabase`, `studio`, root domain healthcheck.
- The exact env variable names used in `supabase.env` and `autolift-api.env`.

These should be **copied and adapted** into `hostinger-vps-infra`, with comments pointing back to their origin for now.

## 6. Migration plan and roles

### 6.1 Source-of-truth evolution

- **Target end-state:** `hostinger-vps-infra` is the **only source of truth** for Caddy + Docker Compose for the Hostinger VPS.
- **Current state:** `docker/deploy` is effectively upstream for:
  - `output/instantgis.cloud/Caddyfile`
  - `output/instantgis.cloud/autolift-api.env`
  - `output/instantgis.cloud/supabase.env`

### 6.2 Phased approach

1. **Phase 1 – Bootstrap infra repo**
   - Copy/adapt the current working config (equivalent to `output/instantgis.cloud/*`) into `hostinger-vps-infra`:
     - `docker-compose.yml` for AutoLift + SAG/Triplit.
     - `caddy/Caddyfile` for all `*.instantgis.cloud` subdomains.
     - `env/*.env` matching what `docker/deploy` currently generates.
   - Keep `docker/deploy` intact but treat it as **reference**.

2. **Phase 2 – Switch deployment to infra repo**
   - Update deployment scripts/PowerShell (e.g. `Invoke-HostingerStackDeploy`) so the VPS is updated **only** from `hostinger-vps-infra`.
   - Verify everything on the VPS works from this repo alone.

3. **Phase 3 – Deprecate `docker/deploy` for home VPS**
   - Mark `docker/deploy` as legacy for `instantgis.cloud` in docs.
   - Optionally remove or archive `configs/instantgis.cloud.env` and its outputs, leaving the templates as historical reference only.

### 6.3 Supabase and Triplit roles

- Supabase:
  - You have a clone of the **official Supabase Docker** stack on this machine, used primarily as a reference/POC for local Docker Desktop deployments.
  - `git status` currently shows at least one local change (`docker-compose.yml`), reflecting those POC experiments.
  - `hostinger-vps-infra` will not re-host the entire Supabase Compose file; it will track only the **env file(s)** and the **Caddy routing** that point to the running Supabase stack (`supabase_default` network, `supabase.instantgis.cloud`, `studio.instantgis.cloud`).

- Triplit:
  - Triplit server/console Docker definitions live in their own repo(s) or folders.
  - `hostinger-vps-infra` is responsible for wiring them into the VPS stack (services in `docker-compose.yml` and routes in `caddy/Caddyfile`).

Image names/tags for SAG and Triplit can initially be hard-coded in `docker-compose.yml` and later moved into `env/sag.env` if you prefer more configurability.

Once these phases are complete, this doc can be mirrored into the `hostinger-vps-infra` repo itself as its `README.md`.

## 7. WebSocket support assumptions

- Triplit server requires **long-lived WebSocket connections plus durable storage**.
- Prior experiments (see `TRIPLIT-SELF-HOST-NOTES.md` and the Triplit repo docs) showed that Netlify cannot satisfy this combination; hence the move to Hostinger VPS + Docker.
- Hostinger KVM VPS with Caddy as reverse proxy is assumed to support WebSockets normally:
  - `triplit.instantgis.cloud` → `reverse_proxy triplit-server:PORT` must allow WebSocket upgrades to pass through.
  - `triplit-console.instantgis.cloud` → `reverse_proxy triplit-console:80` serves the console SPA that talks to that WebSocket endpoint.
- When implementing this repo, ensure there is a documented smoke test (console or CLI) for `wss://triplit.instantgis.cloud` so regressions are caught early.
