# `hostinger-vps-infra` Repo – Specification (Draft)

Purpose: describe what the **`C:\projects\hostinger-vps-infra`** repo should contain so it can fully own the Hostinger VPS stack for **instantgis.cloud** while reusing patterns from this repo.

## 1. Scope

Home VPS on `instantgis.cloud`, running:
- AutoLift stack (this repo)
  - `api.instantgis.cloud` ? AutoLift API
  - `booking.instantgis.cloud` ? booking frontend
  - `rules.instantgis.cloud` ? rules admin
- Audio guide stack (`C:\projects\casela-audiofence`)
  - `sag.instantgis.cloud` ? SAG Angular app (audiofence-frontend)
  - `triplit.instantgis.cloud` ? Triplit server
  - `triplit-console.instantgis.cloud` ? Triplit console UI
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
  - `sag.instantgis.cloud` ? `audiofence-frontend:80`
  - `triplit.instantgis.cloud` ? `triplit-server:80`
  - `triplit-console.instantgis.cloud` ? `triplit-console:80`
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
- The canonical mapping of `{{DOMAIN}}` ? `instantgis.cloud` for:
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
  - TRIPLIT_JWT_SECRET is configured in this repo's .env on the VPS (see autoliftdb/docs/infrastructure/TRIPLIT-DEPLOYMENT.md for JWT secret and token generation details).

Image names/tags for SAG and Triplit can initially be hard-coded in `docker-compose.yml` and later moved into `env/sag.env` if you prefer more configurability.

Once these phases are complete, this doc can be mirrored into the `hostinger-vps-infra` repo itself as its `README.md`.

## 7. WebSocket support assumptions

- Triplit server requires **long-lived WebSocket connections plus durable storage**.
- Prior experiments (see `TRIPLIT-SELF-HOST-NOTES.md` and the Triplit repo docs) showed that Netlify cannot satisfy this combination; hence the move to Hostinger VPS + Docker.
- Hostinger KVM VPS with Caddy as reverse proxy is assumed to support WebSockets normally:
  - `triplit.instantgis.cloud` ? `reverse_proxy triplit-server:PORT` must allow WebSocket upgrades to pass through.
  - `triplit-console.instantgis.cloud` ? `reverse_proxy triplit-console:80` serves the console SPA that talks to that WebSocket endpoint.
- When implementing this repo, ensure there is a documented smoke test (console or CLI) for `wss://triplit.instantgis.cloud` so regressions are caught early.

## 8. Deployment & environment flow for `instantgis.cloud`

### 8.1 Application images (code repo ? Docker Hub ? VPS)

**Source repo:** `autoliftdb`.

On every push to `main` that touches the relevant folders, these GitHub Actions run:

- `.github/workflows/build-api-image.yml` ? builds & pushes `adespaignet/autolift-api`.
- `.github/workflows/build-frontend-vps.yml` ? builds & pushes `adespaignet/autolift-booking`.
- `.github/workflows/build-rules-admin.yml` ? builds & pushes `adespaignet/autolift-rules-admin`.

On the Hostinger VPS, the `watchtower` service in `docker-compose.yml` watches these images:

- When a new `latest` (or SHA) tag appears on Docker Hub, Watchtower pulls the image and restarts the corresponding container.
- Result: for normal API / frontend / rules-admin changes you simply `git push origin main` in **autoliftdb** and wait for Watchtower to roll the containers. No manual `docker compose` on the VPS is required.

### 8.2 Infra repo (this repo) ? VPS

**Source repo:** `hostinger-vps-infra` (this repo).

This repo owns the *topology* for the Hostinger VPS:

- `docker-compose.yml` – which services run and which images they use.
- `caddy/Caddyfile` – how subdomains map to containers.
- `.env` on the server – runtime secrets and URLs for the AutoLift stack.

Typical lifecycle on the VPS:

1. Clone this repo once, e.g. to `/opt/hostinger-vps-infra`.
2. Copy `.env.example` ? `.env` **on the VPS only** and fill in the real values.
3. Start/refresh the stack:
   - `docker compose pull`   # optional: pull newer base images
   - `docker compose up -d`  # (re)create containers with the current config

You only need to update this repo (and re-run `docker compose up -d`) when you change **infrastructure**, e.g.:

- Add/remove services (SAG/Triplit, extra tools).
- Change domains, ports, or networks.
- Change how env vars are wired into containers.

Day-to-day application deploys still flow through `autoliftdb` ? Docker Hub ? Watchtower as described above.

### 8.3 Secrets & environment files

There are three relevant layers:

1. **Master deployment config (big picture, includes Supabase)**

   - File: `docker/deploy/configs/instantgis.cloud.env` in the **autoliftdb** repo.
   - Content: everything for this domain – VPS_HOST, DOMAIN, SMTP settings, Supabase secrets, JWT keys, QR/Webhook secrets, Logflare tokens, etc.
   - Role: this is the "one file to rule them all" used by `docker/deploy/deploy.sh` together with the `*.template` files to generate:
     - `output/instantgis.cloud/Caddyfile`
     - `output/instantgis.cloud/supabase.env`
     - `output/instantgis.cloud/autolift-api.env`

2. **Runtime env for AutoLift stack (this repo, on the VPS)**

   - In this repo we keep a **non-secret** shape file: `.env.example`.
   - On the VPS, in the same folder as `docker-compose.yml`, you create a real `.env` file with:
     - `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`
     - `PUBLIC_SUPABASE_URL`, `API_BASE_URL`
     - `QR_TOKEN_SECRET`, `WEBHOOK_SECRET`
     - `EMAIL_PROVIDER`, `MATOBA_*` SMTP settings
     - `SENTRY_DSN` (optional)
   - This `.env` is effectively the same information that `autolift-api.env.template` would produce when combined with `instantgis.cloud.env`, but we store it **only on the VPS**, not in Git.

3. **Supabase stack env (separate Supabase Docker repo)**

   - Supabase uses its own `supabase.env` (previously generated from `supabase.env.template` + `instantgis.cloud.env`).
   - That env file also lives on the VPS and is not committed here; this repo only assumes there is an external `supabase_default` network and that `kong:8000` is reachable from the `api` service.

#### Where does `configs/instantgis.cloud.env` fit now?

- We **do not** copy `docker/deploy/configs/instantgis.cloud.env` into this repo, even though it is private, because it contains the full set of production secrets.
- Instead:
  - Treat `instantgis.cloud.env` as your master config, stored in **autoliftdb** and in your password manager or other secure storage.
  - Use it (plus the `docker/deploy` scripts) whenever you need to regenerate `supabase.env` or the values that go into this repo's `.env`.
  - Keep this repo focused on **topology + non-secret examples**, with real secrets supplied only via `.env` on the VPS.

This separation keeps `hostinger-vps-infra` easy to reason about ("what runs where") while avoiding a second copy of your full production secret bundle.

## 9. Mapping `instantgis.cloud.env` -> `.env` (AutoLift stack)

For the **home VPS on `instantgis.cloud`**, the master config file lives in the
`autoliftdb` repo at:

- `docker/deploy/configs/instantgis.cloud.env`

This file was originally generated by `generate-secrets.sh` and then edited with
customer-specific values (SMTP, domain, etc.). The `.env` file in this repo is
what the AutoLift API + frontends actually read at runtime.

When you are filling `.env` for this repo (on kvm4), use the following mapping:

| `.env` key                  | Source in `instantgis.cloud.env` | Notes |
|----------------------------|-----------------------------------|-------|
| `SUPABASE_URL`             | _fixed_                          | Use `http://kong:8000` (internal Supabase URL on `supabase_default` network). |
| `SUPABASE_SERVICE_ROLE_KEY`| `SERVICE_ROLE_KEY`               | Copy value verbatim. |
| `SUPABASE_ANON_KEY`        | `ANON_KEY`                       | Copy value verbatim. |
| `PUBLIC_SUPABASE_URL`      | `DOMAIN`                         | Use `https://supabase.{DOMAIN}` ? for `instantgis.cloud`: `https://supabase.instantgis.cloud`. |
| `API_BASE_URL`             | `DOMAIN`                         | Use `https://api.{DOMAIN}` ? for `instantgis.cloud`: `https://api.instantgis.cloud`. |
| `QR_TOKEN_SECRET`          | `QR_TOKEN_SECRET`                | Copy value verbatim. |
| `WEBHOOK_SECRET`           | `WEBHOOK_SECRET`                 | Copy value verbatim. |
| `EMAIL_PROVIDER`           | _fixed_                          | For Matoba SMTP keep `matoba`. |
| `MATOBA_HOST`              | `SMTP_HOST`                      | Copy value verbatim. |
| `MATOBA_PORT`              | `SMTP_PORT`                      | Copy value verbatim. |
| `MATOBA_SECURE`            | `SMTP_SECURE`                    | Copy value verbatim (`true`/`false`). |
| `MATOBA_USER`              | `SMTP_USER`                      | Copy value verbatim. |
| `MATOBA_PASSWORD`          | `SMTP_PASS`                      | Copy value verbatim. |
| `SENTRY_DSN`               | `SENTRY_DSN`                     | Optional; copy value or leave empty to disable. |

In other words:

- **All crypto and JWT-related values** (`ANON_KEY`, `SERVICE_ROLE_KEY`,
  `QR_TOKEN_SECRET`, `WEBHOOK_SECRET`) must be copied directly from the
  existing `instantgis.cloud.env` file and **never regenerated** for this
  environment.
- **SMTP and Sentry settings** are copied from the same file so that email and
  error tracking continue to work exactly as before.
- The default values in `.env.example` already match `DOMAIN=instantgis.cloud`;
  for a different domain you would adjust the `PUBLIC_SUPABASE_URL` and
  `API_BASE_URL` patterns accordingly.

When in doubt, open both files side by side (`instantgis.cloud.env` and `.env`)
and use this table as a checklist: every non-`CHANGE_ME_*` value in `.env` must
come from this mapping.



## 10. Triplit Deployment (December 2025)

### 10.1 Deployed services

| Service | URL | Image | Port |
|---------|-----|-------|------|
| Triplit Server | https://triplit.instantgis.cloud | `aspencloud/triplit-server:latest` | 8080 |
| Triplit Console | https://triplit-console.instantgis.cloud | `adespaignet/triplit-console:latest` | 80 |

### 10.2 Docker Compose configuration

`yaml
triplit-server:
  image: aspencloud/triplit-server:latest
  environment:
    - JWT_SECRET=${TRIPLIT_JWT_SECRET}
    - EXTERNAL_JWT_SECRET=${TRIPLIT_EXTERNAL_JWT_SECRET}
    - LOCAL_DATABASE_URL=/data/triplit.db
  volumes:
    - triplit_data:/data
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://localhost:8080/healthcheck"]
  labels:
    - "com.centurylinklabs.watchtower.enable=true"

triplit-console:
  image: adespaignet/triplit-console:latest
  labels:
    - "com.centurylinklabs.watchtower.enable=true"
`

### 10.3 JWT configuration

| Env Var | Purpose | Source |
|---------|---------|--------|
| `TRIPLIT_JWT_SECRET` | Internal tokens (console, CLI, service) | Generate random secret |
| `TRIPLIT_EXTERNAL_JWT_SECRET` | Verify Supabase JWTs | Copy from Supabase Settings > API > JWT Secret |

### 10.4 DNS records (Hostinger hPanel)

| Name | Type | Value |
|------|------|-------|
| `triplit` | A | 31.97.128.161 |
| `triplit-console` | A | 31.97.128.161 |

### 10.5 Console connection

1. Open https://triplit-console.instantgis.cloud
2. Click "Connect to a new server"
3. Enter service token (signed with TRIPLIT_JWT_SECRET)
4. Server URL: `https://triplit.instantgis.cloud`
5. Connection saved in browser localStorage

### 10.6 Generate service token

`javascript
// Node.js one-liner to generate service token
const crypto = require('crypto');
const secret = process.env.TRIPLIT_JWT_SECRET;
const header = { alg: 'HS256', typ: 'JWT' };
const payload = { 'x-triplit-token-type': 'secret', 'x-triplit-project-id': 'local' };
const base64url = (s) => Buffer.from(s).toString('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');
const h = base64url(JSON.stringify(header));
const p = base64url(JSON.stringify(payload));
const sig = crypto.createHmac('sha256', secret).update(h+'.'+p).digest('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');
console.log(h + '.' + p + '.' + sig);
`

### 10.7 Console image build

The console image is built from the `instantgis/triplit` fork via GitHub Actions:

- Workflow: `.github/workflows/build-and-push-console.yml`
- Pushes to: `adespaignet/triplit-console:latest`
- Dockerfile builds dependencies in correct order: logger ? types ? db ? client ? react ? console
