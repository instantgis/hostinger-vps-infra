#!/bin/bash
# AutoLift Installer Script
# Usage: curl -sL https://raw.githubusercontent.com/.../install.sh | bash -s <VAULTKISS_TOKEN> [--dry-run]
#
# This script:
# 1. Validates the vaultKISS token BEFORE touching anything
# 2. Installs Docker if not present
# 3. Downloads Supabase + AutoLift docker-compose files
# 4. Fetches secrets from vaultKISS
# 5. Generates config files
# 6. Starts the full stack
# 7. Runs health checks
#
# Safety features:
# - Refuses to run on blocked VPS IPs (existing production)
# - Refuses to run if /opt/stacks/autolift already exists
# - Validates token before making any changes
# - Dry-run mode to preview actions

set -e

#=============================================================================
# CONFIGURATION
#=============================================================================
VAULTKISS_URL="https://vaultkiss.netlify.app"
STACKS_DIR="/opt/stacks"
SUPABASE_DIR="$STACKS_DIR/supabase"
AUTOLIFT_DIR="$STACKS_DIR/autolift"

# GitHub raw URLs for Supabase files (public repo)
SUPABASE_GITHUB="https://raw.githubusercontent.com/supabase/supabase/master/docker"
# Note: AutoLift docker-compose.yml and Caddyfile are embedded below (no private repo access needed)

# BLOCKED VPS IPs - These are production servers, never touch them
BLOCKED_IPS="31.97.128.161"  # kvm4 instantgis.cloud

#=============================================================================
# COLORS AND LOGGING
#=============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Log file with timestamp - created in /tmp until STACKS_DIR exists
LOG_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/tmp/autolift-install-${LOG_TIMESTAMP}.log"

# Logging functions - output to both terminal and log file
log()   { echo -e "${GREEN}[INSTALL]${NC} $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
dry()   { echo -e "${BLUE}[DRY-RUN]${NC} Would: $1" | tee -a "$LOG_FILE"; }

# Also capture stderr to log file
exec 2> >(tee -a "$LOG_FILE" >&2)

# Start log
echo "========================================" >> "$LOG_FILE"
echo "AutoLift Install Log" >> "$LOG_FILE"
echo "Started: $(date)" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

#=============================================================================
# ARGUMENT PARSING
#=============================================================================
VAULTKISS_TOKEN=""
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            if [ -z "$VAULTKISS_TOKEN" ]; then
                VAULTKISS_TOKEN="$arg"
            fi
            ;;
    esac
done

#=============================================================================
# USAGE
#=============================================================================
if [ -z "$VAULTKISS_TOKEN" ]; then
    echo "AutoLift Installer"
    echo ""
    echo "Usage:"
    echo "  curl -sL <url>/install.sh | bash -s <VAULTKISS_TOKEN>"
    echo "  curl -sL <url>/install.sh | bash -s <VAULTKISS_TOKEN> --dry-run"
    echo ""
    echo "Options:"
    echo "  <VAULTKISS_TOKEN>  Your app token from vaultKISS"
    echo "  --dry-run          Show what would happen without making changes"
    echo ""
    echo "Get your token:"
    echo "  1. Log into vaultKISS"
    echo "  2. Create an app from the AutoLift template"
    echo "  3. Fill in your secrets"
    echo "  4. Copy your app token"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "============================================"
    echo "  DRY RUN MODE - No changes will be made"
    echo "============================================"
    echo ""
fi

#=============================================================================
# SAFETY CHECK 1: Blocked VPS IPs
#=============================================================================
log "Checking VPS identity..."

# Get all IP addresses on this machine
MY_IPS=$(hostname -I 2>/dev/null || ip addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "unknown")

for blocked in $BLOCKED_IPS; do
    if echo "$MY_IPS" | grep -q "$blocked"; then
        error "BLOCKED: This installer refuses to run on $blocked"
        error "This VPS has an existing production deployment."
        error "Use the manual deployment process instead."
        exit 1
    fi
done
log "VPS identity OK (not a blocked production server)"

#=============================================================================
# SAFETY CHECK 2: Already installed
#=============================================================================
if [ -d "$AUTOLIFT_DIR" ] || [ -d "$SUPABASE_DIR" ]; then
    error "BLOCKED: $STACKS_DIR/autolift or $STACKS_DIR/supabase already exists"
    error "This installer is for fresh VPS deployments only."
    error "If you want to reinstall, remove $STACKS_DIR/autolift and $STACKS_DIR/supabase first."
    exit 1
fi
log "Install directory check OK ($STACKS_DIR/autolift and $STACKS_DIR/supabase do not exist)"

#=============================================================================
# SAFETY CHECK 3: Validate vaultKISS token BEFORE touching anything
#=============================================================================
log "Validating vaultKISS token..."

SECRETS_RESPONSE=$(curl -sf -H "Authorization: Bearer $VAULTKISS_TOKEN" \
    "$VAULTKISS_URL/api/secrets?format=env" 2>&1) || {
    error "Failed to validate vaultKISS token"
    error "Check that your token is correct and vaultKISS is accessible"
    exit 1
}

# Check response has expected content (DOMAIN= should be present)
if ! echo "$SECRETS_RESPONSE" | grep -q "DOMAIN="; then
    error "Invalid response from vaultKISS"
    error "The token may be invalid or the app has no secrets configured"
    exit 1
fi

# Extract domain for later use
DOMAIN=$(echo "$SECRETS_RESPONSE" | grep "^DOMAIN=" | cut -d'=' -f2)
if [ -z "$DOMAIN" ]; then
    error "DOMAIN not found in vaultKISS secrets"
    error "Make sure your vaultKISS app has DOMAIN configured"
    exit 1
fi

log "Token valid! Deploying to: $DOMAIN"

#=============================================================================
# ALL SAFETY CHECKS PASSED - Now we can start making changes
#=============================================================================
echo ""
log "All safety checks passed. Starting installation..."
echo ""

#=============================================================================
# STEP 1: Install Docker (or upgrade if Compose v2 missing)
#=============================================================================
install_docker() {
    if [ "$DRY_RUN" = true ]; then
        dry "Install Docker via get.docker.com"
    else
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        log "Docker installed: $(docker --version)"
    fi
}

if command -v docker &> /dev/null; then
    # Docker exists - check if it has Compose v2
    if docker compose version &> /dev/null; then
        log "Docker already installed: $(docker --version)"
        log "Docker Compose available: $(docker compose version --short)"
    else
        # Old Docker without Compose v2 - reinstall
        warn "Docker found but missing Compose v2. Reinstalling..."
        install_docker
    fi
else
    # No Docker at all
    install_docker
fi

#=============================================================================
# STEP 2: Create installation directory
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "Create directory: $SUPABASE_DIR"
    dry "Create directory: $AUTOLIFT_DIR"
else
    log "Creating directories..."
    mkdir -p "$SUPABASE_DIR"
    mkdir -p "$AUTOLIFT_DIR"
fi

#=============================================================================
# STEP 3: Write secrets from vaultKISS
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "Write secrets to $SUPABASE_DIR/.env"
    dry "Write secrets to $AUTOLIFT_DIR/.env"
    echo ""
    echo "Secrets that would be written:"
    echo "$SECRETS_RESPONSE" | grep "^[A-Z]" | cut -d'=' -f1 | head -20
    echo "... (truncated)"
else
    log "Writing secrets..."
    echo "$SECRETS_RESPONSE" > "$SUPABASE_DIR/.env"
    echo "$SECRETS_RESPONSE" > "$AUTOLIFT_DIR/.env"
    log "Secrets written to .env files"
fi

#=============================================================================
# STEP 4: Download Supabase files from official repo
#=============================================================================
download_file() {
    local url="$1"
    local dest="$2"
    if [ "$DRY_RUN" = true ]; then
        dry "Download $url"
    else
        curl -sf "$url" -o "$dest" || {
            error "Failed to download: $url"
        }
    fi
}

if [ "$DRY_RUN" = true ]; then
    dry "Download Supabase docker-compose.yml and config files"
else
    log "Downloading Supabase files from official repo..."

    # Create directory structure
    mkdir -p "$SUPABASE_DIR/volumes/api"
    mkdir -p "$SUPABASE_DIR/volumes/db/init"
    mkdir -p "$SUPABASE_DIR/volumes/logs"
    mkdir -p "$SUPABASE_DIR/volumes/pooler"
    mkdir -p "$SUPABASE_DIR/volumes/functions/hello"
    mkdir -p "$SUPABASE_DIR/volumes/functions/main"

    # Docker compose
    download_file "$SUPABASE_GITHUB/docker-compose.yml" "$SUPABASE_DIR/docker-compose.yml"

    # Kong API gateway config
    download_file "$SUPABASE_GITHUB/volumes/api/kong.yml" "$SUPABASE_DIR/volumes/api/kong.yml"

    # Logging config
    download_file "$SUPABASE_GITHUB/volumes/logs/vector.yml" "$SUPABASE_DIR/volumes/logs/vector.yml"

    # Connection pooler config
    download_file "$SUPABASE_GITHUB/volumes/pooler/pooler.exs" "$SUPABASE_DIR/volumes/pooler/pooler.exs"

    # Supabase internal DB init scripts
    download_file "$SUPABASE_GITHUB/volumes/db/_supabase.sql" "$SUPABASE_DIR/volumes/db/_supabase.sql"
    download_file "$SUPABASE_GITHUB/volumes/db/jwt.sql" "$SUPABASE_DIR/volumes/db/jwt.sql"
    download_file "$SUPABASE_GITHUB/volumes/db/logs.sql" "$SUPABASE_DIR/volumes/db/logs.sql"
    download_file "$SUPABASE_GITHUB/volumes/db/pooler.sql" "$SUPABASE_DIR/volumes/db/pooler.sql"
    download_file "$SUPABASE_GITHUB/volumes/db/realtime.sql" "$SUPABASE_DIR/volumes/db/realtime.sql"
    download_file "$SUPABASE_GITHUB/volumes/db/roles.sql" "$SUPABASE_DIR/volumes/db/roles.sql"
    download_file "$SUPABASE_GITHUB/volumes/db/webhooks.sql" "$SUPABASE_DIR/volumes/db/webhooks.sql"

    # Edge functions (examples)
    download_file "$SUPABASE_GITHUB/volumes/functions/hello/index.ts" "$SUPABASE_DIR/volumes/functions/hello/index.ts"
    download_file "$SUPABASE_GITHUB/volumes/functions/main/index.ts" "$SUPABASE_DIR/volumes/functions/main/index.ts"

    log "Supabase files downloaded"
fi

# STEP 5: AutoLift init scripts are in adespaignet/autolift-db-init Docker image
# (not downloaded here - the db-init container runs after Supabase starts)

#=============================================================================
# STEP 6: Write AutoLift docker-compose.yml (embedded by build-installer.ps1)
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "Write embedded docker-compose.yml to $AUTOLIFT_DIR/"
else
    log "Writing AutoLift docker-compose.yml..."
    cat > "$AUTOLIFT_DIR/docker-compose.yml" << 'COMPOSE_EOF'
# AutoLift API Stack
# Caddy (reverse proxy + auto-SSL) + Fastify API + Watchtower (auto-deploy)
#
# Deployment Flow:
#   1. Push to main -> GitHub Actions builds image -> Docker Hub
#   2. Watchtower detects new image -> pulls and restarts API container
#
# Prerequisites:
#   - Supabase stack running (docker/supabase) - creates supabase_default network
#   - Caddyfile in same directory with reverse proxy config
#   - .env file with credentials (see .env.example)
#
# Profiles:
#   - Default (no profile): AutoLift core services only
#   - triplit: Adds Triplit server + console (optional, for dev VPS)
#
# Usage:
#   docker compose up -d                      # AutoLift only (customer VPS)
#   docker compose --profile triplit up -d    # AutoLift + Triplit (your VPS)

services:
  # Caddy - Reverse proxy with automatic HTTPS
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - caddy_data:/data
      - caddy_config:/config
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    networks:
      - default
      - supabase_default
    depends_on:
      - api

  # AutoLift Fastify API
  api:
    image: adespaignet/autolift-api:latest
    restart: unless-stopped
    expose:
      - "3000"
    networks:
      - default
      - supabase_default
    environment:
      - NODE_ENV=production
      - PORT=3000
      # Supabase connection (via supabase_default network -> kong:8000)
      - API_SUPABASE_URL=${SUPABASE_URL}
      - API_SUPABASE_SERVICE_KEY=${SUPABASE_SERVICE_ROLE_KEY}
      - API_SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
      # QR Token secret
      - QR_TOKEN_SECRET=${QR_TOKEN_SECRET}
      # Webhook authentication (for Supabase database triggers like order-paid)
      - WEBHOOK_SECRET=${WEBHOOK_SECRET}
      # Email configuration
      - EMAIL_PROVIDER=${EMAIL_PROVIDER:-matoba}
      - MATOBA_HOST=${MATOBA_HOST}
      - MATOBA_PORT=${MATOBA_PORT}
      - MATOBA_SECURE=${MATOBA_SECURE}
      - MATOBA_USER=${MATOBA_USER}
      - MATOBA_PASSWORD=${MATOBA_PASSWORD}
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/health"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 10s
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Frontend - Angular app for VPS demo site
  booking:
    image: adespaignet/autolift-booking:latest
    restart: unless-stopped
    expose:
      - "80"
    networks:
      - default
    environment:
      # Runtime config injection - used by docker-entrypoint.sh to generate env-config.js
      # These are PUBLIC URLs (browser requests), not internal Docker network URLs
      - SUPABASE_URL=${PUBLIC_SUPABASE_URL}
      - SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
      - API_BASE_URL=${API_BASE_URL}
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Rules Admin - React app for GoRules management
  rules-admin:
    image: adespaignet/autolift-rules-admin:latest
    restart: unless-stopped
    expose:
      - "80"
    networks:
      - default
    environment:
      # Runtime config injection - used by docker-entrypoint.sh to generate env-config.js
      # These are PUBLIC URLs (browser requests), not internal Docker network URLs
      - SUPABASE_URL=${PUBLIC_SUPABASE_URL}
      - SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Triplit Server - Real-time sync database (for casela-audiofence)
  # Optional: only runs with --profile triplit
  triplit-server:
    image: aspencloud/triplit-server:latest
    restart: unless-stopped
    profiles:
      - triplit
    expose:
      - "8080"
    networks:
      - default
    environment:
      - JWT_SECRET=${TRIPLIT_JWT_SECRET}
      - EXTERNAL_JWT_SECRET=${TRIPLIT_EXTERNAL_JWT_SECRET}
      - LOCAL_DATABASE_URL=/data/triplit.db
    volumes:
      - triplit_data:/data
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/healthcheck"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 10s
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Triplit Console - Admin UI for Triplit (custom build)
  # Optional: only runs with --profile triplit
  # See docs/infrastructure/TRIPLIT-DEPLOYMENT.md for build instructions
  triplit-console:
    image: adespaignet/triplit-console:latest
    restart: unless-stopped
    profiles:
      - triplit
    expose:
      - "80"
    networks:
      - default
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Watchtower - Auto-pull new images from Docker Hub
  watchtower:
    image: containrrr/watchtower:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - DOCKER_API_VERSION=1.44           # Match VPS Docker version
      - WATCHTOWER_CLEANUP=true           # Remove old images
      - WATCHTOWER_POLL_INTERVAL=300      # Check every 5 minutes
      - WATCHTOWER_LABEL_ENABLE=true      # Only update labeled containers
    command: --interval 300

volumes:
  caddy_data:
  caddy_config:
  triplit_data:

networks:
  supabase_default:
    external: true


COMPOSE_EOF
    log "docker-compose.yml written"
fi

#=============================================================================
# STEP 7: Generate Caddyfile (template embedded by build-installer.ps1)
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "Write Caddyfile with domain and auth placeholders replaced"
else
    log "Generating Caddyfile..."

    # Extract values from secrets
    DASHBOARD_USERNAME=$(echo "$SECRETS_RESPONSE" | grep "^DASHBOARD_USERNAME=" | cut -d'=' -f2)
    DASHBOARD_PASSWORD=$(echo "$SECRETS_RESPONSE" | grep "^DASHBOARD_PASSWORD=" | cut -d'=' -f2)

    # Generate password hash using Caddy
    log "Generating password hash..."
    DASHBOARD_PASSWORD_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$DASHBOARD_PASSWORD")

    # Write Caddyfile - variables like ${DOMAIN} are expanded by bash
    # The template below is embedded by build-installer.ps1 from caddy/Caddyfile.core
    cat > "$AUTOLIFT_DIR/Caddyfile" << CADDY_EOF
# Caddy reverse proxy configuration for AutoLift
# Core services - always deployed
# Domain: ${DOMAIN}

# API subdomain - Fastify API
api.${DOMAIN} {
    encode gzip zstd
    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        Access-Control-Allow-Origin "*"
        Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
        Access-Control-Allow-Headers "Authorization, Content-Type, apikey, X-Client-Info, X-Requested-With, sentry-trace, baggage, Range, Accept-Profile, Content-Profile, Prefer, Content-Length"
        Access-Control-Expose-Headers "Content-Range, Range-Unit"
    }
    @supabase path /rest/* /auth/* /storage/* /realtime/* /functions/* /analytics/* /pg/*
    redir @supabase https://supabase.${DOMAIN}{uri} 308
    reverse_proxy api:3000
}

# Supabase public API (Kong gateway)
supabase.${DOMAIN} {
    encode gzip zstd
    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        Access-Control-Allow-Origin "*"
        Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
        Access-Control-Allow-Headers "Authorization, Content-Type, apikey, X-Client-Info, X-Requested-With, sentry-trace, baggage, Range, Accept-Profile, Content-Profile, Prefer, Content-Length, x-supabase-api-version"
        Access-Control-Expose-Headers "Content-Range, Range-Unit, X-Supabase-Api-Version"
    }
    reverse_proxy kong:8000
}

# Supabase Studio - protected with basic auth
studio.${DOMAIN} {
    basic_auth {
        ${DASHBOARD_USERNAME} ${DASHBOARD_PASSWORD_HASH}
    }
    reverse_proxy supabase-studio:3000
    encode gzip zstd
    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
    }
}

# Frontend - Angular booking app
booking.${DOMAIN} {
    reverse_proxy booking:80
    encode gzip zstd
    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
    }
}

# Rules Admin - React app for GoRules management
rules.${DOMAIN} {
    reverse_proxy rules-admin:80
    encode gzip zstd
    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
    }
}

# Root domain health check
${DOMAIN} {
    respond "AutoLift infra via hostinger-vps-infra" 200
}


CADDY_EOF
    log "Caddyfile generated"
fi

#=============================================================================
# STEP 8: Start Supabase stack
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "cd $SUPABASE_DIR && docker compose up -d"
else
    log "Starting Supabase stack (14 containers)..."
    cd "$SUPABASE_DIR"
    docker compose up -d

    log "Waiting for Supabase to be healthy..."
    sleep 30  # Give containers time to start

    # Check if Kong is responding
    for i in {1..10}; do
        if curl -sf "http://localhost:8000/rest/v1/" > /dev/null 2>&1; then
            log "Supabase Kong is responding"
            break
        fi
        if [ $i -eq 10 ]; then
            warn "Kong not responding yet, continuing anyway..."
        fi
        sleep 5
    done
fi

#=============================================================================
# STEP 8b: Initialize AutoLift database (idempotent)
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "Run adespaignet/autolift-db-init container to initialize database"
else
    log "Initializing AutoLift database..."

    # Build DATABASE_URL from secrets
    DB_HOST=$(echo "$SECRETS_RESPONSE" | grep "^POSTGRES_HOST=" | cut -d'=' -f2)
    DB_PORT=$(echo "$SECRETS_RESPONSE" | grep "^POSTGRES_PORT=" | cut -d'=' -f2)
    DB_NAME=$(echo "$SECRETS_RESPONSE" | grep "^POSTGRES_DB=" | cut -d'=' -f2)
    DB_PASSWORD=$(echo "$SECRETS_RESPONSE" | grep "^POSTGRES_PASSWORD=" | cut -d'=' -f2)

    # Default values if not set
    DB_HOST=${DB_HOST:-localhost}
    DB_PORT=${DB_PORT:-5432}
    DB_NAME=${DB_NAME:-postgres}

    DATABASE_URL="postgresql://postgres:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

    # Run the db-init container (idempotent - skips if already initialized)
    docker run --rm \
        --network supabase_default \
        -e DATABASE_URL="$DATABASE_URL" \
        adespaignet/autolift-db-init:latest

    log "Database initialization complete"
fi

#=============================================================================
# STEP 9: Start AutoLift stack
#=============================================================================
if [ "$DRY_RUN" = true ]; then
    dry "cd $AUTOLIFT_DIR && docker compose up -d"
else
    log "Starting AutoLift stack..."
    cd "$AUTOLIFT_DIR"
    docker compose up -d

    log "Waiting for services to start..."
    sleep 10
fi

#=============================================================================
# STEP 10: Health checks
#=============================================================================
echo ""
log "Running health checks..."

check_endpoint() {
    local name="$1"
    local url="$2"
    local expected="${3:-200}"

    if [ "$DRY_RUN" = true ]; then
        dry "Check $name: $url"
        return
    fi

    status=$(curl -sf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [ "$status" = "$expected" ]; then
        log "$name: OK ($url)"
    else
        warn "$name: FAILED - got $status, expected $expected ($url)"
    fi
}

check_endpoint "API Health" "https://api.$DOMAIN/health"
check_endpoint "Booking App" "https://booking.$DOMAIN"
check_endpoint "Rules Admin" "https://rules.$DOMAIN"
check_endpoint "Supabase Studio" "https://studio.$DOMAIN"
check_endpoint "Supabase API" "https://supabase.$DOMAIN"

#=============================================================================
# DONE
#=============================================================================
echo ""
echo "============================================"
if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN COMPLETE"
    echo "  No changes were made"
    echo ""
    echo "  Log file: $LOG_FILE"
else
    echo "  INSTALLATION COMPLETE"
    echo ""
    echo "  Your AutoLift stack is now running at:"
    echo ""
    echo "  Booking App:    https://booking.$DOMAIN"
    echo "  Rules Admin:    https://rules.$DOMAIN"
    echo "  API:            https://api.$DOMAIN"
    echo "  Supabase:       https://supabase.$DOMAIN"
    echo "  Studio:         https://studio.$DOMAIN"
    echo ""
    echo "  Supabase stack: $SUPABASE_DIR"
    echo "  AutoLift stack: $AUTOLIFT_DIR"
    echo ""
    # Move log file to autolift directory
    FINAL_LOG="$AUTOLIFT_DIR/install-${LOG_TIMESTAMP}.log"
    mv "$LOG_FILE" "$FINAL_LOG"
    echo "  Log file: $FINAL_LOG"
fi
echo "============================================"
echo ""

# Log completion
echo "Completed: $(date)" >> "${FINAL_LOG:-$LOG_FILE}"
