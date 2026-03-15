#Requires -Version 7.0
<#
.SYNOPSIS
    Removes all FSI Copilot agents from a Microsoft 365 tenant.
.DESCRIPTION
    Uses atk uninstall --mode env to remove agents from the M365 tenant,
    mirroring how Install-FSICopilot.ps1 provisions them with atk provision.
    Restores placeholder URLs and title IDs in agent manifests.
    Note: agents published into Microsoft 365 through teamsApp/extendToM365 can
    remain visible in the Microsoft 365 Agent Store / Agent Registry until an
    admin removes or deletes them from the Microsoft 365 admin center.
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
$successfulPaths = @()

# Collect ALL agent directories (manifest + any with m365agents.yml)
$allAgentDirs = @()

# Add manifest agents in reverse tier order
$tiers = @(3, 2, 1, 0)
foreach ($tierIndex in $tiers) {
    $tierAgents = $manifest.agents | Where-Object { [int]$_.tier -eq $tierIndex }
    if (-not $tierAgents) { continue }
    foreach ($agent in $tierAgents) {
        $allAgentDirs += @{
            Name = $agent.name
            Path = Join-Path $ProjectRoot $agent.path
            Tier = $tierIndex
            TierName = $manifest.tiers."$tierIndex".name
            Source = "manifest"
        }
    }
}

# Scan for orphaned agents (have m365agents.yml but not in manifest)
$manifestPaths = $manifest.agents | ForEach-Object { (Join-Path $ProjectRoot $_.path) }
$allYmlFiles = Get-ChildItem -Path (Join-Path $ProjectRoot "agents") -Filter "m365agents.yml" -Recurse -File -ErrorAction SilentlyContinue
foreach ($yml in $allYmlFiles) {
    $agentDir = $yml.Directory.FullName
    if ($agentDir -notin $manifestPaths) {
        $allAgentDirs += @{
            Name = "$(Split-Path $agentDir -Leaf) (orphan)"
            Path = $agentDir
            Tier = -1
            TierName = "Orphaned Agents"
            Source = "orphan"
        }
    }
}

# Remove agents using atk uninstall --mode env (mirrors how install provisions)
# Fallback chain: --mode env → --mode title-id → --mode manifest-id
$currentTierLabel = ""
foreach ($agent in $allAgentDirs) {
    $tierLabel = "Tier $($agent.Tier) : $($agent.TierName)"
    if ($agent.Tier -eq -1) { $tierLabel = "Orphaned Agents (not in manifest)" }

    if ($tierLabel -ne $currentTierLabel) {
        $currentTierLabel = $tierLabel
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "  $tierLabel" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    }

    $agentPath = $agent.Path
    $agentName = $agent.Name

    if (-not (Test-Path $agentPath)) {
        Write-Host "  ⏭️  $agentName — directory not found, skipping" -ForegroundColor DarkGray
        continue
    }

    # Check if this agent was ever provisioned (has env folder or m365agents.yml)
    $hasProject = (Test-Path (Join-Path $agentPath "m365agents.yml"))
    if (-not $hasProject) {
        Write-Host "  ⏭️  $agentName — no m365agents.yml found, skipping" -ForegroundColor DarkGray
        continue
    }

    # Pre-read title ID and manifest ID from .env file for fallback uninstall
    $titleId    = $null
    $manifestId = $null
    $envFile    = Join-Path $agentPath "env" ".env.$Environment"
    if (Test-Path $envFile) {
        $envContent = Get-Content -Path $envFile -ErrorAction SilentlyContinue
        foreach ($line in $envContent) {
            if ($line -match '^\s*M365_TITLE_ID\s*=\s*(.+)$')  { $titleId    = $Matches[1].Trim() }
            if ($line -match '^\s*TEAMS_APP_ID\s*=\s*(.+)$')    { $manifestId = $Matches[1].Trim() }
        }
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would remove: $agentName" -ForegroundColor Yellow
        if ($titleId)    { Write-Host "             Title ID:    $titleId" -ForegroundColor DarkGray }
        if ($manifestId) { Write-Host "             Manifest ID: $manifestId" -ForegroundColor DarkGray }
        $removedCount++
    }
    else {
        $removed = $false

        # Attempt 1: --mode env (standard, mirrors how atk provision works)
        try {
            $result = & atk uninstall --mode env --env $Environment --folder $agentPath --options 'm365-app,app-registration' --interactive false 2>&1
            $output = ($result | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Removed: $agentName" -ForegroundColor Green
                $removedCount++
                $successfulPaths += $agentPath
                $removed = $true
            }
        }
        catch { }

        # Attempt 2: --mode title-id (catches ghost agents that persist after env cleanup)
        if (-not $removed -and $titleId) {
            try {
                Write-Host "  ⚠️  env-mode failed for $agentName, retrying with title-id ($titleId)..." -ForegroundColor Yellow
                $result = & atk uninstall --mode title-id --title-id $titleId --interactive false 2>&1
                $output = ($result | Out-String).Trim()
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✅ Removed (title-id): $agentName" -ForegroundColor Green
                    $removedCount++
                    $successfulPaths += $agentPath
                    $removed = $true
                }
            }
            catch { }
        }

        # Attempt 3: --mode manifest-id (last resort using the Teams App GUID)
        if (-not $removed -and $manifestId) {
            try {
                Write-Host "  ⚠️  title-id failed for $agentName, retrying with manifest-id ($manifestId)..." -ForegroundColor Yellow
                $result = & atk uninstall --mode manifest-id --manifest-id $manifestId --options 'm365-app,app-registration' --interactive false 2>&1
                $output = ($result | Out-String).Trim()
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✅ Removed (manifest-id): $agentName" -ForegroundColor Green
                    $removedCount++
                    $successfulPaths += $agentPath
                    $removed = $true
                }
            }
            catch { }
        }

        if (-not $removed) {
            Write-Host "  ❌ Failed to remove: $agentName — all uninstall methods exhausted" -ForegroundColor Red
            if (-not $titleId -and -not $manifestId) {
                Write-Host "       No .env.$Environment file found with M365_TITLE_ID or TEAMS_APP_ID" -ForegroundColor DarkGray
            }
            $failedCount++
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

# Delete .env files ONLY for successfully removed agents (preserve others for retry)
if ($DryRun) {
    $allEnvFilesCleanup = Get-ChildItem -Path (Join-Path $ProjectRoot "agents") -Filter ".env.$Environment" -Recurse -File -ErrorAction SilentlyContinue
    foreach ($ef in $allEnvFilesCleanup) {
        Write-Host "  [DRY RUN] Would delete: $($ef.FullName)" -ForegroundColor Yellow
        $envFilesDeleted++
    }
}
else {
    foreach ($agentDir in $successfulPaths) {
        $envFile = Join-Path $agentDir "env" ".env.$Environment"
        if (Test-Path $envFile) {
            Remove-Item -Path $envFile -Force
            Write-Verbose "Deleted $envFile"
            $envFilesDeleted++
        }
    }
}

# Delete build directories from agent appPackage folders
$buildDirs = Get-ChildItem -Path (Join-Path $ProjectRoot "agents") -Filter "build" -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Parent.Name -eq 'appPackage' }
foreach ($bd in $buildDirs) {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would delete: $($bd.FullName)" -ForegroundColor Yellow
    }
    else {
        Remove-Item -Path $bd.FullName -Recurse -Force
        Write-Verbose "Deleted $($bd.FullName)"
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
    Write-Host "  Note: published agents can still appear in Agent Store until removed from Microsoft 365 admin center > Agents > All agents." -ForegroundColor Yellow
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
    Write-Host "  ℹ️  If agents still appear in Agent Store / Built for your org, remove or delete them in Microsoft 365 admin center > Agents > All agents." -ForegroundColor Yellow
}

Write-Host ""
