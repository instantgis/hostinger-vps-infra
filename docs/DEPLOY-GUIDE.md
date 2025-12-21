# AutoLift Deployment Guide

Step-by-step guide for deploying AutoLift to a customer VPS.

## Which deployment method to use?

| Scenario | Use |
|----------|-----|
| **New customer VPS** (fresh install) | `autoliftdb/docker/deploy/deploy.sh` - deploys EVERYTHING |
| **Your home VPS** (already has Supabase) | This guide - deploys AutoLift layer only |

For **new customer deployments**, use `autoliftdb/docker/deploy/`:
```bash
cd C:\projects\autoliftdb\docker\deploy
./deploy.sh configs/daniels-company.com.env
```

That script handles Supabase + AutoLift + secrets + verification in one command.

---

## This Guide: Adding AutoLift to existing Supabase

Use this guide only when:
1. Supabase is already running on the VPS (deployed by `autoliftdb/docker/deploy/deploy.sh`)
2. You need to update or redeploy just the AutoLift layer

## Prerequisites

| Item | Where to get it |
|------|-----------------|
| SSH access | `root@<SERVER_IP>` |
| Supabase running | Verify with `docker ps | grep supabase` |
| `supabase_default` network exists | Created by Supabase stack |
| `.env` values | From `autoliftdb/docker/deploy/configs/<domain>.env` |

## Phase 1: Server Preparation

### 1.1 SSH into the server

```bash
ssh root@<SERVER_IP>
```

### 1.2 Update the system

```bash
apt update && apt upgrade -y
```

### 1.3 Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

Verify:
```bash
docker --version
docker compose version
```

### 1.4 Create deployment directory

```bash
mkdir -p /opt/autolift
cd /opt/autolift
```

## Phase 2: Deploy Key Setup

### 2.1 Generate SSH keypair on the server

```bash
ssh-keygen -t ed25519 -C "deploy@daniels-vps" -f ~/.ssh/deploy_key -N ""
```

### 2.2 Display the public key

```bash
cat ~/.ssh/deploy_key.pub
```

Copy the output (starts with `ssh-ed25519 ...`).

### 2.3 Add deploy key to GitHub

1. Go to: https://github.com/instantgis/hostinger-vps-infra/settings/keys
2. Click "Add deploy key"
3. Title: `daniels-vps` (or customer name)
4. Key: paste the public key
5. Leave "Allow write access" unchecked
6. Click "Add key"

### 2.4 Clone the repo

```bash
GIT_SSH_COMMAND="ssh -i ~/.ssh/deploy_key" git clone git@github.com:instantgis/hostinger-vps-infra.git /opt/autolift
cd /opt/autolift
git config core.sshCommand "ssh -i ~/.ssh/deploy_key"
```

## Phase 3: Configuration

### 3.1 Create .env file

**Option A: Using vaultKISS (recommended)**

The customer creates their app in vaultKISS, fills in their own secrets, then fetches them directly on their server. You never see their secrets.

On the customer's server:
```bash
# Fetch secrets directly from vaultKISS
curl -sf -H "Authorization: Bearer <APP_TOKEN>" \
  "https://vaultkiss.netlify.app/api/secrets?format=env" \
  > /opt/autolift/.env
```

Or with the helper script (if curl/jq available):
```bash
curl -sf -H "Authorization: Bearer <APP_TOKEN>" \
  "https://vaultkiss.netlify.app/api/secrets?format=env" \
  -o .env
```

The customer:
1. Logs into vaultKISS
2. Creates their app from the AutoLift template
3. Fills in their secrets (Supabase keys, etc.)
4. Gets their app token
5. Runs the curl command above on their server

**Option B: Manual**

If not using vaultKISS, on the server:
```bash
cp .env.example .env
nano .env
```

Fill in the values. Required variables from `.env.example`:

| Variable | Where to get it |
|----------|-----------------|
| `SUPABASE_URL` | `http://kong:8000` (internal Docker network) |
| `SUPABASE_SERVICE_ROLE_KEY` | Customer's Supabase: Settings > API |
| `SUPABASE_ANON_KEY` | Customer's Supabase: Settings > API |
| `PUBLIC_SUPABASE_URL` | `https://supabase.<DOMAIN>` |
| `API_BASE_URL` | `https://api.<DOMAIN>` |
| `QR_TOKEN_SECRET` | Generate: `openssl rand -hex 32` |
| `WEBHOOK_SECRET` | Generate: `openssl rand -hex 32` |
| `MATOBA_HOST` | Customer's SMTP server |
| `MATOBA_PORT` | Usually `465` for SSL |
| `MATOBA_SECURE` | `true` for SSL |
| `MATOBA_USER` | SMTP username |
| `MATOBA_PASSWORD` | SMTP password |

**Note:** `.env.example` also contains `TRIPLIT_*` variables - ignore these for customer deployments. They're only for your personal VPS with `--profile triplit`.

### 3.2 Generate Caddyfile

The Caddyfile has 3 placeholders:

| Placeholder | What it is | Where to get it |
|-------------|------------|-----------------|
| `{{DOMAIN}}` | Customer's domain | e.g., `daniels-company.com` |
| `{{DASHBOARD_USERNAME}}` | HTTP Basic Auth user for Studio | Generated when setting up customer's Supabase |
| `{{DASHBOARD_PASSWORD_HASH}}` | Bcrypt hash for Studio auth | Same password, hashed for Caddy |

The username/password protect `studio.<DOMAIN>` so random people can't access Supabase Studio. Use the same credentials as the customer's Supabase dashboard.

On your local machine:

```powershell
$domain = "daniels-company.com"
$dashUser = "supabase"  # from customer's Supabase DASHBOARD_USERNAME
$dashPass = "generated-password"  # from customer's Supabase DASHBOARD_PASSWORD

# Generate bcrypt hash (Caddy requires this format)
$dashPassHash = docker run --rm caddy:2-alpine caddy hash-password --plaintext $dashPass

(Get-Content caddy/Caddyfile.core) `
    -replace '\{\{DOMAIN\}\}', $domain `
    -replace '\{\{DASHBOARD_USERNAME\}\}', $dashUser `
    -replace '\{\{DASHBOARD_PASSWORD_HASH\}\}', $dashPassHash |
    Set-Content Caddyfile
```

Then copy to server:
```powershell
scp Caddyfile root@<SERVER_IP>:/opt/autolift/
```

## Phase 4: DNS Configuration

Customer needs to add these DNS records (A records pointing to server IP):

| Subdomain | Type | Value |
|-----------|------|-------|
| `api` | A | `<SERVER_IP>` |
| `booking` | A | `<SERVER_IP>` |
| `rules` | A | `<SERVER_IP>` |
| `supabase` | A | `<SERVER_IP>` |
| `studio` | A | `<SERVER_IP>` |
| `@` (root) | A | `<SERVER_IP>` |

DNS propagation can take up to 24 hours, but usually 5-15 minutes.

Verify DNS:
```bash
nslookup api.<DOMAIN>
```

## Phase 5: Start the Stack

### 5.1 Pull images

```bash
cd /opt/autolift
docker compose pull
```

### 5.2 Start containers

```bash
docker compose up -d
```

### 5.3 Check status

```bash
docker compose ps
docker compose logs -f
```

All containers should show "healthy" or "running".

## Phase 6: Verification

### 6.1 Test endpoints

```bash
curl -I https://api.<DOMAIN>/health
curl -I https://booking.<DOMAIN>
curl -I https://rules.<DOMAIN>
```

### 6.2 Check Caddy logs (for SSL issues)

```bash
docker compose logs caddy
```

First request triggers Let's Encrypt certificate issuance. Wait ~30 seconds.

## Troubleshooting

### Container won't start
```bash
docker compose logs <service-name>
```

### SSL certificate issues
- Ensure DNS is pointing to server IP
- Check port 80 and 443 are open
- Caddy needs both ports for ACME challenge

### Can't connect to Supabase
- Verify Supabase is running: `docker ps | grep supabase`
- Check network: `docker network ls`
- Ensure `supabase_default` network exists

## Post-Deployment

1. Share credentials with customer securely
2. Document the deployment in your records
3. Set up monitoring (optional)
4. Schedule regular backups (optional)

