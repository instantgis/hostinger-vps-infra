# vaultKISS Install Script - Final Spec

## Overview

The install.sh script is ALREADY BUILT and ready to upload to vaultKISS storage.
File: `c:\projects\hostinger-vps-infra\install\install-generated.sh` (614 lines)

vaultKISS only needs to:
1. Store this file in Supabase Storage
2. Serve it via a new `/api/install` endpoint

## Customer Usage

```bash
curl -sf "https://vaultkiss.netlify.app/api/install?token=abc123" | bash -s abc123
```

The token appears TWICE:
1. `?token=abc123` - validates the request to GET the script from vaultKISS
2. `bash -s abc123` - passed to the script as $1, used by script to call /api/secrets

## What vaultKISS `/api/install` Endpoint Must Do

```
1. GET /api/install?token=abc123
2. Validate token (same logic as /api/secrets - lookup in apps table by token_hash)
3. Get template_name from the app record (e.g., "autolift-api")
4. Fetch file from Supabase Storage: install-scripts/{template_name}.sh
5. Return file contents with Content-Type: text/x-shellscript
```

NO secret injection. NO placeholders. Just serve the file as-is.

## How The Script Uses The Token

The script receives the token as $1 and calls /api/secrets ITSELF:

```bash
# Line 132-137 of install-generated.sh
SECRETS_RESPONSE=$(curl -sf -H "Authorization: Bearer $VAULTKISS_TOKEN" \
    "$VAULTKISS_URL/api/secrets?format=env" 2>&1) || {
    error "Failed to validate vaultKISS token"
    exit 1
}
```

The script then extracts values like DOMAIN, POSTGRES_PASSWORD, etc. from SECRETS_RESPONSE.

## vaultKISS Admin UI - Template Install Script Upload

Add a file upload field to the template edit page in vaultKISS:
- Field: "Install Script" (file input, accepts .sh)
- Storage path: `install-scripts/{template_name}.sh`
- The admin uploads `install-generated.sh` through vaultKISS UI
- vaultKISS handles the Supabase Storage upload internally

No manual Supabase Studio uploads needed.

## The Script Is Self-Contained

Everything is embedded in the script:
- docker-compose.yml for AutoLift stack (embedded as heredoc)
- Caddyfile template (embedded as heredoc)
- All logic for Docker install, directory creation, etc.

External downloads the script makes:
- Supabase files from official public supabase/supabase GitHub repo
- Docker images from Docker Hub (all public)
- Secrets from vaultKISS /api/secrets (using the token)

## Flow Diagram

```
Customer VPS                          vaultKISS
-----------                          ---------

curl /api/install?token=xxx  ------> Validate token
                                     Fetch from storage
                             <------ Return install.sh

bash -s xxx
  |
  +-- curl /api/secrets      ------> Return secrets as .env
  |                          <------
  +-- Install Docker
  +-- Create directories
  +-- Write docker-compose.yml (from heredoc)
  +-- Write Caddyfile (from heredoc, with $DOMAIN substituted)
  +-- Download Supabase files (from public GitHub)
  +-- docker compose up
  +-- Run db-init container
  +-- Health checks
  |
  DONE
```

## Summary

| Component | What It Does |
|-----------|--------------|
| `/api/install?token=xxx` | Validates token, returns install.sh from storage |
| `/api/secrets` | Already exists - script calls this to get secrets |
| install-generated.sh | The 614-line script to upload to storage |
| Token in URL | Authenticates request to get the script |
| Token as $1 | Script uses it to call /api/secrets |

