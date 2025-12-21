# Build the final install.sh by embedding docker-compose.yml and Caddyfile.core
# Run this before uploading to vaultKISS storage
#
# Usage: .\build-installer.ps1
# Output: install/install-generated.sh (ready for vaultKISS upload)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installDir = $PSScriptRoot

# Source files
$templateFile = Join-Path $installDir "install-template.sh"
$composeFile = Join-Path $repoRoot "docker-compose.yml"
$caddyFile = Join-Path (Join-Path $repoRoot "caddy") "Caddyfile.core"
$outputFile = Join-Path $installDir "install-generated.sh"

# Check files exist
if (-not (Test-Path $templateFile)) { throw "Template not found: $templateFile" }
if (-not (Test-Path $composeFile)) { throw "docker-compose.yml not found: $composeFile" }
if (-not (Test-Path $caddyFile)) { throw "Caddyfile.core not found: $caddyFile" }

Write-Host "Building installer..." -ForegroundColor Cyan
Write-Host "  Template:  $templateFile"
Write-Host "  Compose:   $composeFile"
Write-Host "  Caddyfile: $caddyFile"
Write-Host "  Output:    $outputFile"

# Read source files
$template = Get-Content $templateFile -Raw
$compose = Get-Content $composeFile -Raw
$caddy = Get-Content $caddyFile -Raw

# Convert Caddyfile {{VAR}} placeholders to ${VAR} for bash expansion
$caddy = $caddy -replace '\{\{(\w+)\}\}', '${$1}'

# Escape any $ in docker-compose.yml that aren't meant for bash
# Actually docker-compose ${VAR} should stay as-is (they're for docker, not bash)
# The heredoc uses 'COMPOSE_EOF' (quoted) so no expansion happens

# Replace placeholders in template
$output = $template -replace '\{\{DOCKER_COMPOSE_CONTENT\}\}', $compose
$output = $output -replace '\{\{CADDYFILE_CONTENT\}\}', $caddy

# Write output with Unix line endings (LF)
$output = $output -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($outputFile, $output)

Write-Host ""
Write-Host "Generated: $outputFile" -ForegroundColor Green
Write-Host "Lines: $((Get-Content $outputFile).Count)"
Write-Host ""
Write-Host "Next: Upload install-generated.sh to vaultKISS storage as 'autolift-api.sh'"

