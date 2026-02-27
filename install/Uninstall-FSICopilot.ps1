#Requires -Version 7.0
<#
.SYNOPSIS
    Removes all FSI Copilot agents from a Microsoft 365 tenant.
.DESCRIPTION
    Reads provisioned agent IDs from .env files and removes them from the
    M365 tenant. Restores placeholder URLs and title IDs in agent manifests.
.PARAMETER Environment
    The atk environment to uninstall from (default: "prod").
.PARAMETER DryRun
    Show what would be removed without actually removing anything.
.PARAMETER KeepConfig
    Don't restore placeholder URLs (keep the configured MCP server URLs).
.EXAMPLE
    .\Uninstall-FSICopilot.ps1
    .\Uninstall-FSICopilot.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Environment = "prod",
    [switch]$DryRun,
    [switch]$KeepConfig
)

$ErrorActionPreference = "Stop"

# ── Resolve paths ──
$InstallRoot = $PSScriptRoot
$ProjectRoot = Split-Path $InstallRoot -Parent
$LibPath     = Join-Path $InstallRoot "lib"
$ConfigPath  = Join-Path $InstallRoot "config"

# ── Dot-source lib modules ──
. "$LibPath\Resolve-TitleIds.ps1"

$ManifestPath    = Join-Path $ConfigPath "agent-manifest.json"
$McpProvidersPath = Join-Path $ConfigPath "mcp-providers.json"

# ── Load configuration ──
if (-not (Test-Path $ManifestPath)) {
    Write-Error "Agent manifest not found: $ManifestPath"
    exit 1
}

$manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

# ── Confirm with user ──
if (-not $DryRun) {
    Write-Host ""
    Write-Host "⚠️  This will remove ALL FSI Copilot agents from your M365 tenant." -ForegroundColor Yellow
    Write-Host "    Environment: $Environment" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "    Are you sure? (y/N)"
    if ($confirm -notin @('y', 'Y', 'yes', 'Yes', 'YES')) {
        Write-Host "Cancelled." -ForegroundColor DarkGray
        exit 0
    }
    Write-Host ""
}

# ── Remove agents (reverse tier order: 3→0) ──
$removedCount = 0
$failedCount  = 0
$envFilesDeleted = 0

$tiers = @(3, 2, 1, 0)

foreach ($tierIndex in $tiers) {
    $tierAgents = $manifest.agents | Where-Object { [int]$_.tier -eq $tierIndex }
    if (-not $tierAgents -or $tierAgents.Count -eq 0) { continue }

    $tierName = $manifest.tiers."$tierIndex".name
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Tier $tierIndex : $tierName" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    foreach ($agent in $tierAgents) {
        $agentPath  = Join-Path $ProjectRoot $agent.path
        $envFile    = Join-Path $agentPath ".env.$Environment"
        $agentName  = $agent.name

        # Read TEAMS_APP_ID from the env file
        $appId = $null
        if (Test-Path $envFile) {
            $lines = Get-Content -Path $envFile
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
                if ($trimmed -match '^TEAMS_APP_ID\s*=\s*(.+)$') {
                    $appId = $Matches[1].Trim()
                    break
                }
            }
        }

        if (-not $appId) {
            Write-Host "  ⏭️  $agentName — no TEAMS_APP_ID found, skipping removal" -ForegroundColor DarkGray
            continue
        }

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would remove: $agentName (TEAMS_APP_ID=$appId)" -ForegroundColor Yellow
            $removedCount++
        }
        else {
            try {
                $originalLocation = Get-Location
                Set-Location $agentPath

                $result = & atk teamsapp remove --teams-app-id $appId 2>&1

                if ($LASTEXITCODE -ne 0) {
                    throw "atk teamsapp remove failed: $result"
                }

                Write-Host "  ✅ Removed: $agentName" -ForegroundColor Green
                $removedCount++
            }
            catch {
                Write-Host "  ❌ Failed to remove: $agentName — $_" -ForegroundColor Red
                $failedCount++
            }
            finally {
                Set-Location $originalLocation
            }
        }
    }
}

# ── Cleanup ──
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  Cleanup" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# Restore title ID placeholders in declarativeAgent.json files
if (-not $DryRun) {
    Write-Host "  Restoring title ID placeholders..." -ForegroundColor DarkGray
    Restore-TitleIdPlaceholders -ProjectRoot $ProjectRoot -ConfigPath $ManifestPath
    Write-Host "  ✅ Title ID placeholders restored" -ForegroundColor Green
}
else {
    Write-Host "  [DRY RUN] Would restore title ID placeholders in declarativeAgent.json files" -ForegroundColor Yellow
}

# Restore {{MCP_HOST}} placeholder URLs in plugin files
if (-not $KeepConfig) {
    if (Test-Path $McpProvidersPath) {
        $providersConfig = Get-Content -Path $McpProvidersPath -Raw | ConvertFrom-Json

        foreach ($provider in $providersConfig.providers) {
            $urlPattern = $provider.urlPattern
            if (-not $urlPattern) { $urlPattern = "/mcp/$($provider.id)" }
            $placeholderUrl = "https://{{MCP_HOST}}$urlPattern"

            if (-not $provider.pluginFiles -or $provider.pluginFiles.Count -eq 0) { continue }

            foreach ($relativeFile in $provider.pluginFiles) {
                $filePath = Join-Path $ProjectRoot $relativeFile
                if (-not (Test-Path $filePath)) { continue }

                try {
                    $content = Get-Content -Path $filePath -Raw

                    # Match any non-placeholder URL that ends with the provider's urlPattern
                    # Skip if already a placeholder
                    if ($content -match [regex]::Escape($placeholderUrl)) { continue }

                    # Replace any URL ending with the urlPattern back to placeholder
                    $escapedPattern = [regex]::Escape($urlPattern)
                    $urlRegex = 'https?://[^\s"]+?' + $escapedPattern
                    if ($content -match $urlRegex) {
                        if ($DryRun) {
                            Write-Host "  [DRY RUN] Would restore placeholder URL in $relativeFile" -ForegroundColor Yellow
                        }
                        else {
                            $content = $content -replace $urlRegex, $placeholderUrl
                            Set-Content -Path $filePath -Value $content -Encoding UTF8 -NoNewline
                            Write-Verbose "  Restored placeholder URL in $relativeFile"
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to restore placeholder in '$relativeFile': $_"
                }
            }
        }

        if (-not $DryRun) {
            Write-Host "  ✅ MCP server URL placeholders restored" -ForegroundColor Green
        }
    }
}
else {
    Write-Host "  ⏭️  Skipping URL placeholder restoration (--KeepConfig)" -ForegroundColor DarkGray
}

# Delete .env files from agent directories
foreach ($agent in $manifest.agents) {
    $envFile = Join-Path $ProjectRoot (Join-Path $agent.path ".env.$Environment")
    if (Test-Path $envFile) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would delete: $envFile" -ForegroundColor Yellow
        }
        else {
            Remove-Item -Path $envFile -Force
            Write-Verbose "Deleted $envFile"
        }
        $envFilesDeleted++
    }
}

# Delete .env.install from project root
$envInstallPath = Join-Path $ProjectRoot ".env.install"
if (Test-Path $envInstallPath) {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would delete: $envInstallPath" -ForegroundColor Yellow
    }
    else {
        Remove-Item -Path $envInstallPath -Force
        Write-Verbose "Deleted $envInstallPath"
    }
    $envFilesDeleted++
}

if (-not $DryRun) {
    Write-Host "  ✅ Deleted $envFilesDeleted .env file(s)" -ForegroundColor Green
}

# ── Summary ──
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  Uninstall Summary" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "  [DRY RUN] No changes were made." -ForegroundColor Yellow
    Write-Host "  Would remove: $removedCount agent(s)" -ForegroundColor Yellow
    Write-Host "  Would delete: $envFilesDeleted .env file(s)" -ForegroundColor Yellow
}
else {
    Write-Host "  ✅ Removed:  $removedCount agent(s)" -ForegroundColor Green
    if ($failedCount -gt 0) {
        Write-Host "  ❌ Failed:   $failedCount agent(s)" -ForegroundColor Red
    }
    Write-Host "  🗑️  Deleted:  $envFilesDeleted .env file(s)" -ForegroundColor Green
    if (-not $KeepConfig) {
        Write-Host "  🔗 Restored: MCP server URL placeholders" -ForegroundColor Green
    }
    Write-Host "  📋 Restored: Title ID placeholders" -ForegroundColor Green
}

Write-Host ""
