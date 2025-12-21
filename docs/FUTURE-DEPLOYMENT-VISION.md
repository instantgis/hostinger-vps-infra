# Future Deployment Vision

A unified, automated deployment system for AutoLift.

## Current State (December 2025)

Two separate, incomplete systems:

| Location | What it does | Problem |
|----------|--------------|---------|
| `autoliftdb/docker/deploy/` | `deploy.sh` SSHes to VPS, deploys Supabase + AutoLift | Requires YOU to SSH in, push config |
| `hostinger-vps-infra/` | AutoLift docker-compose only | Doesn't include Supabase |

## Target State

One system where:
1. Customer gets a fresh VPS
2. Customer runs one command: `curl -sL https://example.com/install.sh | bash -s <TOKEN>`
3. Everything deploys automatically (Supabase + AutoLift)
4. Customer manages their secrets via vaultKISS

---

## Option 1: AutoLift Installer Script (Simplest)

**Like Coolify does it.** One curl command, everything installs.

### How it works

```bash
# Customer runs this on their fresh VPS:
curl -sL https://raw.githubusercontent.com/instantgis/autolift-installer/main/install.sh | bash -s <VAULTKISS_TOKEN>
```

The script:
1. Installs Docker if not present
2. Downloads unified docker-compose.yml (Supabase + AutoLift)
3. Fetches secrets from vaultKISS using the token
4. Writes .env files
5. Runs `docker compose up -d`
6. Runs health checks

### What needs to be built

| Component | Effort |
|-----------|--------|
| Merge Supabase + AutoLift into one docker-compose.yml | 3 hours |
| Create `install.sh` script | 2 hours |
| Test on fresh VPS | 1 hour |
| **Total** | ~6 hours |

### Pros

- No new infrastructure to maintain
- Customer self-service (you give them a token, they run the command)
- Works on any VPS provider
- vaultKISS handles secret updates

### Cons

- No web UI for you to monitor deployments
- No real-time logs streaming to your browser
- Manual SSH if something goes wrong

---

## Option 2: Coolify + vaultKISS Hybrid

**Coolify is essentially DeployKISS already built.** Instead of building from scratch, use Coolify for deployment orchestration and keep vaultKISS for customer-facing secret management.

### Architecture

```
kvm4 (instantgis.cloud) - YOUR CONTROL PLANE
├── /opt/autolift/supabase/     ← Your existing Supabase (stays as-is)
├── /opt/hostinger-vps-infra/   ← Your existing AutoLift (stays as-is)
│
├── Coolify container           ← NEW: runs alongside existing stack
│   │                              Access via https://coolify.instantgis.cloud
│   │
│   ├── SSH → Daniel's VPS
│   │   ├── daniel-supabase (one-click Supabase template)
│   │   └── daniel-autolift (your docker-compose)
│   │
│   ├── SSH → Bob's VPS
│   │   ├── bob-supabase
│   │   └── bob-autolift
│   │
│   └── SSH → future customers...
│
└── vaultKISS                   ← Customers manage their own secrets here
    ├── daniel-autolift-secrets
    ├── bob-autolift-secrets
    └── ...
```

### How Coolify + vaultKISS work together

```
Coolify Dashboard
│
│ You create "daniel-autolift" application
│ Set env var: VAULTKISS_TOKEN=abc123
│
▼ Container starts on Daniel's VPS
│
│ Entrypoint script runs:
│ 1. curl vaultkiss.instantgis.cloud/api/secrets?token=$VAULTKISS_TOKEN
│ 2. Write response to .env file
│ 3. Source .env
│ 4. Start application
│
▼
vaultKISS API returns Daniel's secrets (DB password, Stripe key, etc.)
│
▼
Daniel can update his secrets in vaultKISS UI anytime
Next container restart picks them up automatically
```

### What each system handles

| System | Responsibility |
|--------|---------------|
| **Coolify** | SSH access, deployment, container orchestration, one-click Supabase, restart/logs/monitoring |
| **vaultKISS** | Customer self-service secret management, secret versioning, access tokens |
| **Your docker-compose.yml** | AutoLift service definitions (paste into Coolify) |

### Why this is better than building DeployKISS

| Aspect | Build DeployKISS | Use Coolify |
|--------|------------------|-------------|
| Effort | ~26 hours | ~2 hours (install + configure) |
| Supabase deployment | Need to merge compose files | One-click built-in template |
| Real-time logs | Build from scratch | Built-in |
| Rollbacks | Build from scratch | Built-in |
| SSL/HTTPS | Configure manually | Automatic Let's Encrypt |
| Maintenance | You maintain it | Community maintains it |

### What you DON'T need to do with Coolify

- Merge Supabase + AutoLift into one docker-compose.yml (they're separate apps in Coolify)
- Build SSH execution backend
- Build WebSocket streaming
- Build terminal UI
- Build deployment history

### Coolify Requirements

From Coolify docs (https://coolify.io/docs/get-started/installation):

| Requirement | Minimum |
|-------------|---------|
| CPU | 2 cores |
| RAM | 2 GB |
| Storage | 30 GB free |
| OS | Debian, Ubuntu, RHEL, Alpine, Raspberry Pi OS 64-bit |

**What Coolify installs:**
- Docker Engine 24+ (if not present)
- Coolify container (Laravel app)
- PostgreSQL container (metadata storage)
- Redis container
- Traefik or Caddy (proxy)

**Data stored at:** `/data/coolify/`

### Installation

```bash
# One command to install Coolify
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Then access at `http://YOUR_IP:8000` (or set up DNS for `https://coolify.instantgis.cloud`).

### Coolify features

- Web UI for deployments
- SSH into any server (just add IP + key)
- Real-time terminal output in browser
- Docker Compose support
- One-click Supabase (280+ one-click services)
- Automatic SSL via Let's Encrypt
- Environment variable management per app
- Deployment history
- Team access with roles
- API for automation
- GitHub/GitLab push-to-deploy

---

## Option 3: Build DeployKISS (Custom)

If you want a web UI with real-time streaming but don't want Coolify's overhead:

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  DeployKISS UI                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │  New Deployment                                 │    │
│  │  ─────────────────                              │    │
│  │  Customer: Daniel's Auto Shop                   │    │
│  │  Domain:   daniels-auto.com                     │    │
│  │  VPS IP:   [185.xxx.xxx.xxx]                    │    │
│  │  SSH Key:  [paste or upload]                    │    │
│  │                                                 │    │
│  │  [Deploy Now]                                   │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Terminal Output                          [Live]│    │
│  │  ─────────────────────────────────────────────  │    │
│  │  > Connecting to 185.xxx.xxx.xxx...             │    │
│  │  > Installing Docker...                         │    │
│  │  > Pulling docker-compose.yml...                │    │
│  │  > Fetching secrets from vaultKISS...           │    │
│  │  > Starting Supabase stack...                   │    │
│  │  > Starting AutoLift stack...                   │    │
│  │  > Running health checks...                     │    │
│  │  > SUCCESS: All services healthy                │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
         │
         │ WebSocket (real-time streaming)
         ▼
┌─────────────────────────────────────────────────────────┐
│  DeployKISS Backend (Node.js/Fastify)                   │
│                                                         │
│  - Receives deploy request                              │
│  - Opens SSH connection (ssh2 library)                  │
│  - Executes deployment steps                            │
│  - Fetches secrets from vaultKISS                       │
│  - Streams output back via WebSocket                    │
│  - Stores deployment history in database                │
└─────────────────────────────────────────────────────────┘
         │
         │ SSH connection
         ▼
┌─────────────────────────────────────────────────────────┐
│  Customer VPS                                           │
│                                                         │
│  Commands executed remotely:                            │
│  1. apt update && apt install -y docker.io docker-compose│
│  2. mkdir -p /opt/autolift && cd /opt/autolift          │
│  3. curl -o docker-compose.yml <github-raw-url>         │
│  4. curl -o .env <vaultkiss-api-url>                    │
│  5. docker compose up -d                                │
│  6. docker ps (verify)                                  │
└─────────────────────────────────────────────────────────┘
```

## Components Needed

### 1. Unified docker-compose.yml

Merge Supabase + AutoLift into one file. Two approaches:

**Option A: Single file (simpler)**
```yaml
# One big docker-compose.yml with all ~20 services
services:
  # Supabase services (13)
  supabase-db:
  supabase-kong:
  supabase-auth:
  # ... etc
  
  # AutoLift services (7)
  caddy:
  api:
  booking:
  # ... etc
```

**Option B: Compose include (cleaner)**
```yaml
# docker-compose.yml
include:
  - supabase/docker-compose.yml

services:
  caddy:
  api:
  # ... AutoLift services only
```

### 2. vaultKISS Integration

Already exists. Each customer gets an app in vaultKISS:
- `autolift-daniels-auto-com`
- Contains all secrets (Supabase keys, SMTP, JWT, etc.)
- API endpoint: `GET /api/apps/:id/download?token=xxx`

### 3. DeployKISS Backend

New service or addition to existing backend:

```typescript
// Simplified example
import { Client } from 'ssh2';

async function deploy(config: DeployConfig, onOutput: (line: string) => void) {
  const ssh = new Client();
  
  ssh.on('ready', async () => {
    // Step 1: Install Docker
    await exec(ssh, 'apt update && apt install -y docker.io', onOutput);
    
    // Step 2: Create directory
    await exec(ssh, 'mkdir -p /opt/autolift', onOutput);
    
    // Step 3: Pull compose file
    await exec(ssh, `curl -o /opt/autolift/docker-compose.yml ${COMPOSE_URL}`, onOutput);
    
    // Step 4: Fetch secrets from vaultKISS
    const envContent = await fetchFromVaultKISS(config.vaultkissAppId, config.vaultkissToken);
    await writeFile(ssh, '/opt/autolift/.env', envContent);
    
    // Step 5: Start everything
    await exec(ssh, 'cd /opt/autolift && docker compose up -d', onOutput);
    
    // Step 6: Verify
    await exec(ssh, 'docker ps', onOutput);
  });
  
  ssh.connect({
    host: config.vpsIp,
    username: 'root',
    privateKey: config.sshKey
  });
}
```

### 4. DeployKISS Frontend

Simple React/Angular UI:
- Form: IP, SSH key, customer selection
- WebSocket connection for real-time output
- Terminal-like display component
- Deployment history list

## Effort Estimate

| Task | Hours |
|------|-------|
| Merge docker-compose.yml (Supabase + AutoLift) | 3 |
| Create deployment script (tested locally) | 2 |
| Backend: SSH execution + WebSocket streaming | 8 |
| Frontend: Deploy form + terminal display | 6 |
| vaultKISS: "New deployment" wizard | 4 |
| Testing on fresh VPS | 3 |
| **Total** | ~26 hours (~3-4 days) |

## Related Reading

| Tool | Database | Notes |
|------|----------|-------|
| **Coolify** (https://coolify.io) | PostgreSQL + Redis containers | No SQLite option |
| **Dokploy** (https://dokploy.com) | PostgreSQL + Redis containers | Same architecture as Coolify, no SQLite option |
| CapRover (https://caprover.com) | - | Older, less active development |
| Kamal (https://kamal-deploy.org) | - | CLI-only, from 37signals |

Both Coolify and Dokploy require PostgreSQL + Redis for their internal metadata storage.
Neither offers a SQLite option.

## Decision Summary

| Option | Effort | What you get |
|--------|--------|--------------|
| **Option 1: Installer script** | ~6 hours | Customer self-service via `curl \| bash`, vaultKISS for secrets, NO extra DB overhead |
| **Option 2: Coolify or Dokploy** | ~2 hours | Web UI but requires PostgreSQL + Redis containers for their own metadata |
| Option 3: Build DeployKISS | ~26 hours | Custom web UI with full control |
