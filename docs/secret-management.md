# vaultKISS: Secret Management for VPS Deployments

## Current State: Manual .env Management

### How secrets get to the VPS today

1. **Master config lives in autoliftdb repo:**
   - File: `docker/deploy/configs/instantgis.cloud.env`
   - Contains everything: DOMAIN, SMTP, Supabase keys, JWT secrets, etc.
   - Generated once by `generate-secrets.sh`, then manually edited

2. **This repo provides a template:**
   - File: `.env.example` with `CHANGE_ME_*` placeholders
   - Committed to Git (no secrets)

3. **Manual deployment to VPS:**
   - SSH into VPS
   - Clone this repo to `/opt/hostinger-vps-infra`
   - Copy `.env.example` to `.env`
   - Manually fill in values from `instantgis.cloud.env` or password manager
   - Run `docker compose up -d`

4. **Problems with this approach:**
   - Error-prone: copy-paste mistakes, missed values
   - No audit trail: who changed what, when?
   - No rotation: changing a secret means SSH + manual edit
   - Scaling: each new VPS/customer requires repeating the process
   - Onboarding: customers can't self-service their secrets

---

## Proposed: vaultKISS

### Why build our own?

- **Doppler:** 364 issues, 49 unmerged PRs - maintenance concerns
- **Infisical:** Free tier limited to 5 identities, 3 projects
- **HashiCorp Vault:** Heavy, complex, overkill for simple VPS deployments
- **Goal:** Lean solution that fits on a single VPS with minimal dependencies

### The Stack

- **Framework:** SvelteKit (TypeScript, file-based routing, minimal boilerplate)
- **Hosting:** Netlify (free tier, first-class SvelteKit adapter)
- **Database:** Turso (SQLite at the edge, generous free tier)
- **Auth:** Simple password or Netlify Identity (free tier)

### Architecture: Server-Side Decryption Only

Key principle: **The MASTER_KEY never leaves the server.**

```
+------------------+     +------------------+     +------------------+
|   Web UI         |     |   Secrets API    |     |   Turso DB       |
|   (Next.js)      |---->|   (API Routes)   |---->|   (encrypted)    |
+------------------+     +------------------+     +------------------+
        |                        |
        v                        v
+------------------+     +------------------+
|   Admin adds     |     |   MASTER_KEY     |
|   secrets        |     |   (server only)  |
+------------------+     +------------------+
```

### Database Schema (Single DB, not one-per-app)

```sql
CREATE TABLE apps (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    token_hash TEXT NOT NULL,      -- bcrypt hash of app's API token
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE secrets (
    id TEXT PRIMARY KEY,
    app_id TEXT NOT NULL REFERENCES apps(id),
    key TEXT NOT NULL,             -- e.g., "SUPABASE_SERVICE_ROLE_KEY"
    encrypted_value TEXT NOT NULL, -- AES-256-GCM encrypted
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(app_id, key)
);
```

### How it integrates with deployment

#### Option A: Pull at container startup (recommended)

1. **Admin creates app in portal:** "instantgis-cloud-autolift"
2. **Admin adds secrets via Web UI:** fills in all the values from `.env.example`
3. **Portal generates app token:** stored in VPS as single env var
4. **docker-compose.yml uses entrypoint script:**

```yaml
api:
  image: adespaignet/autolift-api:latest
  environment:
    - SECRETS_APP_TOKEN=${SECRETS_APP_TOKEN}
    - SECRETS_API_URL=https://secrets.instantgis.cloud
  entrypoint: ["/scripts/fetch-secrets-and-run.sh"]
```

5. **Entrypoint script:**

```bash
#!/bin/sh
# Fetch secrets from portal, export as env vars, then exec the app
eval $(curl -s -H "Authorization: Bearer $SECRETS_APP_TOKEN" \
    "$SECRETS_API_URL/api/secrets" | jq -r 'to_entries | .[] | "export \(.key)=\(.value|@sh)"')
exec "$@"
```

**Pros:** Secrets never written to disk, automatic on every container restart
**Cons:** Requires network access at startup, adds startup latency

#### Option B: Generate .env file on demand

1. **Admin configures secrets in portal**
2. **Deployment script pulls and writes .env:**

```powershell
# In deployment script (PowerShell)
$token = $env:SECRETS_APP_TOKEN
$response = Invoke-RestMethod -Uri "https://secrets.instantgis.cloud/api/secrets" `
    -Headers @{ Authorization = "Bearer $token" }

$response.PSObject.Properties | ForEach-Object {
    "$($_.Name)=$($_.Value)"
} | Set-Content -Path "/opt/hostinger-vps-infra/.env"
```

3. **Then run:** `docker compose up -d`

**Pros:** Works exactly like current flow, just automated
**Cons:** Secrets written to disk (but that's already the case today)

#### Option C: SSH-less deployment via webhook

1. **Portal has "Deploy" button per app**
2. **VPS runs a small agent** that listens for deploy webhooks
3. **On webhook:** agent pulls secrets, writes .env, runs `docker compose up -d`
4. **No SSH required** for routine secret updates

### Customer self-service flow

For multi-tenant scenarios (customers managing their own VPS):

1. Customer signs up, gets assigned an "app" in the portal
2. Customer sees their `.env.example` template with empty fields
3. Customer fills in their values (SMTP, domain, etc.)
4. Customer gets a single `SECRETS_APP_TOKEN` to put on their VPS
5. Their VPS pulls secrets at startup - no manual .env editing

## Implementation Reference

### Project structure

```
vaultkiss/
  src/
    lib/
      server/
        db.ts             # Turso client
        crypto.ts         # AES-256-GCM encrypt/decrypt
    routes/
      +page.svelte        # Login page
      +layout.svelte      # Shared layout
      apps/
        +page.svelte      # List apps
        +page.server.ts   # Load apps from DB
        [appId]/
          +page.svelte    # Edit secrets for app
          +page.server.ts # Load/save secrets
      api/
        secrets/
          +server.ts      # Public API: GET secrets by token
  static/                 # Static assets
  svelte.config.js
  netlify.toml
```

### 1. Setup

```bash
# Create SvelteKit project
npx sv create vaultkiss
cd vaultkiss

# Add dependencies
npm install @libsql/client
npm install -D @sveltejs/adapter-netlify

# Setup Turso
turso auth login
turso db create vaultkiss
turso db tokens create vaultkiss

# Create .env (local dev) - also add these to Netlify env vars
TURSO_DATABASE_URL=libsql://vaultkiss-yourorg.turso.io
TURSO_AUTH_TOKEN=<token from above>
MASTER_KEY=<run: openssl rand -hex 32>
ADMIN_PASSWORD=<your admin password>
```

### 2. SvelteKit config for Netlify

```javascript
// svelte.config.js
import adapter from '@sveltejs/adapter-netlify';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

export default {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter()
  }
};
```

### 3. Database client

```typescript
// src/lib/server/db.ts
import { createClient } from '@libsql/client';
import { TURSO_DATABASE_URL, TURSO_AUTH_TOKEN } from '$env/static/private';

export const db = createClient({
  url: TURSO_DATABASE_URL,
  authToken: TURSO_AUTH_TOKEN,
});
```

### 4. Encryption utilities

```typescript
// src/lib/server/crypto.ts
import crypto from 'crypto';
import { MASTER_KEY } from '$env/static/private';

const ALGORITHM = 'aes-256-gcm';

export function encrypt(plaintext: string): string {
  const iv = crypto.randomBytes(16);
  const key = Buffer.from(MASTER_KEY, 'hex');
  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);

  let encrypted = cipher.update(plaintext, 'utf8', 'hex');
  encrypted += cipher.final('hex');
  const authTag = cipher.getAuthTag().toString('hex');

  return `${iv.toString('hex')}:${authTag}:${encrypted}`;
}

export function decrypt(ciphertext: string): string {
  const [ivHex, authTagHex, encrypted] = ciphertext.split(':');
  const key = Buffer.from(MASTER_KEY, 'hex');
  const iv = Buffer.from(ivHex, 'hex');
  const authTag = Buffer.from(authTagHex, 'hex');

  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(authTag);

  let decrypted = decipher.update(encrypted, 'hex', 'utf8');
  decrypted += decipher.final('utf8');
  return decrypted;
}

export function hashToken(token: string): string {
  return crypto.createHash('sha256').update(token).digest('hex');
}
```

### 5. Public API endpoint (for VPS to fetch secrets)

```typescript
// src/routes/api/secrets/+server.ts
import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { db } from '$lib/server/db';
import { decrypt, hashToken } from '$lib/server/crypto';

export const GET: RequestHandler = async ({ request }) => {
  const token = request.headers.get('authorization')?.replace('Bearer ', '');
  if (!token) {
    throw error(401, 'Unauthorized');
  }

  // Verify token and get app_id
  const app = await db.execute({
    sql: 'SELECT id FROM apps WHERE token_hash = ?',
    args: [hashToken(token)],
  });
  if (!app.rows.length) {
    throw error(401, 'Invalid token');
  }

  // Fetch and decrypt secrets
  const secrets = await db.execute({
    sql: 'SELECT key, encrypted_value FROM secrets WHERE app_id = ?',
    args: [app.rows[0].id],
  });

  const decrypted: Record<string, string> = {};
  for (const row of secrets.rows) {
    decrypted[row.key as string] = decrypt(row.encrypted_value as string);
  }

  return json(decrypted);
};
```

### 6. Admin UI: List apps

```svelte
<!-- src/routes/apps/+page.svelte -->
<script lang="ts">
  import type { PageData } from './$types';
  export let data: PageData;
</script>

<h1>Apps</h1>

<ul>
  {#each data.apps as app}
    <li>
      <a href="/apps/{app.id}">{app.name}</a>
    </li>
  {/each}
</ul>

<a href="/apps/new">Create New App</a>
```

```typescript
// src/routes/apps/+page.server.ts
import type { PageServerLoad } from './$types';
import { db } from '$lib/server/db';

export const load: PageServerLoad = async () => {
  const result = await db.execute('SELECT id, name FROM apps ORDER BY name');
  return {
    apps: result.rows as { id: string; name: string }[],
  };
};
```

### 7. Admin UI: Edit secrets

```svelte
<!-- src/routes/apps/[appId]/+page.svelte -->
<script lang="ts">
  import type { PageData } from './$types';
  export let data: PageData;
</script>

<h1>Secrets for {data.app.name}</h1>

<form method="POST">
  {#each Object.entries(data.secrets) as [key, value]}
    <div>
      <label for={key}>{key}</label>
      <input type="password" name={key} id={key} value={value} />
    </div>
  {/each}

  <div>
    <input type="text" name="new_key" placeholder="New key" />
    <input type="password" name="new_value" placeholder="New value" />
  </div>

  <button type="submit">Save</button>
</form>

<h2>App Token</h2>
<code>{data.app.token || 'Generate a new token'}</code>
```

### 8. Netlify config

```toml
# netlify.toml
[build]
  command = "npm run build"
  publish = "build"
```

---

## Security Considerations

1. **MASTER_KEY management:**
   - Generate: `openssl rand -hex 32`
   - Store in Netlify env vars (production) and password manager (backup)
   - If lost, all secrets are unrecoverable
   - Consider backing up to a second secure location

2. **App tokens:**
   - Generate per-app: `openssl rand -base64 32`
   - Store only the hash in the database
   - Revoke by deleting the app or regenerating token

3. **Transport security:**
   - All API calls over HTTPS
   - Secrets decrypted server-side, sent over TLS to the requesting service

4. **Audit trail (future enhancement):**
   - Add `audit_log` table: who accessed what, when
   - Useful for compliance and debugging

---

## Summary

| Component | Technology | Cost |
|-----------|------------|------|
| Framework | SvelteKit (TypeScript) | Free |
| Hosting | Netlify | Free |
| Database | Turso (single DB) | Free tier: 9GB |
| Auth | Static admin password | Free |
| Encryption | AES-256-GCM, server-side | - |

**Migration path from current state:**
1. Build the portal MVP
2. Import existing `instantgis.cloud.env` values into portal
3. Generate app token, add `SECRETS_APP_TOKEN` to VPS
4. Update docker-compose to use entrypoint script
5. Remove `.env` file from VPS (secrets now pulled at runtime)
6. New deployments use portal from day one

---

## Implementation Guide (for AI assistants)

This section contains everything needed to implement vaultKISS from scratch.

### Context

vaultKISS is a lightweight secrets manager that:
- Replaces manual `.env` file editing for VPS deployments
- Stores secrets encrypted in Turso (SQLite edge database)
- Provides a web UI for admins to manage secrets per app
- Exposes an API endpoint for VPS containers to fetch secrets at runtime
- Uses server-side decryption only (MASTER_KEY never leaves the server)

### Prerequisites

- Node.js 18+
- Turso CLI installed (`curl -sSfL https://get.tur.so/install.sh | bash`)
- Netlify account (free tier)
- Turso account (free tier)

### Database Schema (run in Turso shell: `turso db shell vaultkiss`)

```sql
CREATE TABLE apps (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    name TEXT NOT NULL UNIQUE,
    token_hash TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE secrets (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    encrypted_value TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    UNIQUE(app_id, key)
);

CREATE INDEX idx_secrets_app_id ON secrets(app_id);
```

### Files to Create (in order)

```
vaultkiss/
  .env                          # Local dev secrets (gitignored)
  .env.example                  # Template for env vars
  .gitignore
  package.json
  svelte.config.js
  vite.config.ts
  tsconfig.json
  netlify.toml
  src/
    app.html                    # HTML shell
    app.css                     # Global styles (minimal)
    lib/
      server/
        db.ts                   # Turso client singleton
        crypto.ts               # encrypt, decrypt, hashToken functions
        auth.ts                 # Admin password check
      types.ts                  # Shared TypeScript types
    routes/
      +layout.svelte            # Shared layout with nav
      +layout.server.ts         # Auth check for all routes
      +page.svelte              # Login page (if not authed) or redirect
      +page.server.ts           # Login form action
      apps/
        +page.svelte            # List all apps
        +page.server.ts         # Load apps, create app action
        [appId]/
          +page.svelte          # View/edit secrets for one app
          +page.server.ts       # Load secrets, save secrets action, regenerate token
      api/
        secrets/
          +server.ts            # GET /api/secrets - public endpoint for VPS
```

### Implementation Steps

1. **Scaffold project:**
   ```bash
   npx sv create vaultkiss --template minimal --types ts
   cd vaultkiss
   npm install @libsql/client
   npm install -D @sveltejs/adapter-netlify
   ```

2. **Configure for Netlify:** Update `svelte.config.js` to use Netlify adapter.

3. **Create `.env.example`:**
   ```
   TURSO_DATABASE_URL=libsql://vaultkiss-yourorg.turso.io
   TURSO_AUTH_TOKEN=
   MASTER_KEY=
   ADMIN_PASSWORD=
   ```

4. **Implement `src/lib/server/db.ts`:** Export Turso client singleton.

5. **Implement `src/lib/server/crypto.ts`:**
   - `encrypt(plaintext: string): string` - AES-256-GCM, returns `iv:authTag:ciphertext`
   - `decrypt(ciphertext: string): string` - reverses encryption
   - `hashToken(token: string): string` - SHA-256 hash for token storage

6. **Implement `src/lib/server/auth.ts`:**
   - Simple session using cookies
   - Check `ADMIN_PASSWORD` env var
   - Set httpOnly cookie on successful login

7. **Implement `src/lib/types.ts`:**
   ```typescript
   export interface App {
     id: string;
     name: string;
     created_at: string;
   }

   export interface Secret {
     id: string;
     app_id: string;
     key: string;
     value: string; // decrypted
   }
   ```

8. **Implement routes in order:**
   - `+layout.server.ts`: Check auth cookie, expose `isAuthenticated` to all pages
   - `+page.svelte` / `+page.server.ts`: Login form, redirect to /apps if authed
   - `apps/+page.svelte` / `+page.server.ts`: List apps, "New App" form
   - `apps/[appId]/+page.svelte` / `+page.server.ts`: Show secrets, edit form, show app token

9. **Implement `/api/secrets/+server.ts`:**
   - Accept `Authorization: Bearer <token>` header
   - Hash token, look up app
   - Return decrypted secrets as JSON object
   - No admin auth required (token IS the auth)

10. **Test locally:**
    ```bash
    npm run dev
    ```
    - Login with ADMIN_PASSWORD
    - Create an app, note the generated token
    - Add some secrets
    - Test API: `curl -H "Authorization: Bearer <token>" http://localhost:5173/api/secrets`

11. **Deploy to Netlify:**
    - Push to GitHub
    - Connect repo in Netlify
    - Add env vars in Netlify UI
    - Deploy

### Key Decisions Already Made

- **Single database:** All apps in one Turso DB, not one DB per app
- **Server-side decryption only:** MASTER_KEY never sent to client or VPS
- **Token auth for API:** Each app gets a unique token, hashed in DB
- **Password auth for admin UI:** Simple password, cookie session
- **No framework for UI:** Just SvelteKit built-in features, no component library

### Testing the VPS Integration

Once deployed, test from the VPS:

```bash
# Fetch secrets
curl -s -H "Authorization: Bearer YOUR_APP_TOKEN" \
  https://your-vaultkiss.netlify.app/api/secrets

# Should return JSON like:
# {"SUPABASE_URL":"http://kong:8000","SUPABASE_SERVICE_ROLE_KEY":"..."}
```

### Entrypoint script for docker containers

```bash
#!/bin/sh
# fetch-secrets-and-run.sh
set -e

# Fetch secrets and export as env vars
eval $(curl -sf -H "Authorization: Bearer $VAULTKISS_TOKEN" \
  "$VAULTKISS_URL/api/secrets" | jq -r 'to_entries | .[] | "export \(.key)=\(.value|@sh)"')

# Run the original command
exec "$@"
```

Add to docker-compose.yml:
```yaml
api:
  image: your-image
  environment:
    - VAULTKISS_TOKEN=${VAULTKISS_TOKEN}
    - VAULTKISS_URL=https://your-vaultkiss.netlify.app
  entrypoint: ["/scripts/fetch-secrets-and-run.sh"]
  command: ["node", "server.js"]
```