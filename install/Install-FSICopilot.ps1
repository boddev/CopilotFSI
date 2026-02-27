#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the FSI Copilot agent suite to a Microsoft 365 tenant.
.DESCRIPTION
    Interactive installer that provisions 20 declarative agents for financial services
    including skill agents, MCP data connector agents, and the primary orchestrator.
    Supports MCP server selection, 4-tier dependency-ordered provisioning, and automatic
    worker_agents title ID resolution.
.PARAMETER DryRun
    Simulates the installation without provisioning any agents.
.PARAMETER Environment
    The atk environment name to use (default: "prod").
.PARAMETER SkipPrerequisites
    Skip prerequisite checks.
.PARAMETER AutoInstallPrereqs
    Automatically install missing prerequisites.
.PARAMETER NonInteractive
    Use default MCP selections (SEC EDGAR + Alpha Vantage only).
.EXAMPLE
    .\Install-FSICopilot.ps1
    .\Install-FSICopilot.ps1 -DryRun
    .\Install-FSICopilot.ps1 -Environment dev -AutoInstallPrereqs
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Environment = "prod",
    [switch]$SkipPrerequisites,
    [switch]$AutoInstallPrereqs,
    [switch]$NonInteractive
)

# ─────────────────────────────────────────────────────────────────────
# 1. Setup
# ─────────────────────────────────────────────────────────────────────
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath  = Join-Path $PSScriptRoot "config"
$LibPath     = Join-Path $PSScriptRoot "lib"

# Dot-source all modules
. "$LibPath\Test-Prerequisites.ps1"
. "$LibPath\Show-McpSelector.ps1"
. "$LibPath\Set-McpServerUrls.ps1"
. "$LibPath\Resolve-TitleIds.ps1"
. "$LibPath\Invoke-AgentProvisioning.ps1"
. "$LibPath\Open-PrimaryAgent.ps1"

$InstallerVersion = "1.0"
$startTime = Get-Date

# ─────────────────────────────────────────────────────────────────────
# Welcome Banner
# ─────────────────────────────────────────────────────────────────────
function Show-WelcomeBanner {
    Write-Host ""
    Write-Host " ╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host " ║                                                                   ║" -ForegroundColor Cyan
    Write-Host " ║     ███████╗███████╗██╗     ██████╗ ██████╗ ██████╗ ██╗██╗      ║" -ForegroundColor Cyan
    Write-Host " ║     ██╔════╝██╔════╝██║    ██╔════╝██╔═══██╗██╔══██╗██║██║      ║" -ForegroundColor Cyan
    Write-Host " ║     █████╗  ███████╗██║    ██║     ██║   ██║██████╔╝██║██║      ║" -ForegroundColor Cyan
    Write-Host " ║     ██╔══╝  ╚════██║██║    ██║     ██║   ██║██╔═══╝ ██║██║      ║" -ForegroundColor Cyan
    Write-Host " ║     ██║     ███████║██║    ╚██████╗╚██████╔╝██║     ██║███████╗ ║" -ForegroundColor Cyan
    Write-Host " ║     ╚═╝     ╚══════╝╚═╝     ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝ ║" -ForegroundColor Cyan
    Write-Host " ║                                                                   ║" -ForegroundColor Cyan
    Write-Host " ║          Financial Services Copilot for Microsoft 365             ║" -ForegroundColor Cyan
    Write-Host " ║                        Installer v$InstallerVersion                              ║" -ForegroundColor Cyan
    Write-Host " ║                                                                   ║" -ForegroundColor Cyan
    Write-Host " ╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($DryRun) {
        Write-Host "  ⚠️  DRY RUN MODE — no changes will be made" -ForegroundColor Yellow
        Write-Host ""
    }
}

Show-WelcomeBanner

# ─────────────────────────────────────────────────────────────────────
# Step 1: Prerequisites Check
# ─────────────────────────────────────────────────────────────────────
Write-Host "`n📋 Step 1: Prerequisites Check" -ForegroundColor Cyan
Write-Host ("═" * 50)

if (-not $SkipPrerequisites) {
    try {
        $prereqs = Test-FSIPrerequisites -AutoInstall:$AutoInstallPrereqs
        if (-not $prereqs.AllPassed) {
            Write-Host "`n  ❌ Prerequisites check failed. Please resolve the issues above." -ForegroundColor Red
            exit 1
        }
        Write-Host "  ✅ All prerequisites passed" -ForegroundColor Green
    }
    catch {
        Write-Host "  ❌ Prerequisites check error: $_" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "  ⏭️  Skipped (--SkipPrerequisites)" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────────────
# Step 2: M365 Tenant Authentication
# ─────────────────────────────────────────────────────────────────────
Write-Host "`n📋 Step 2: M365 Tenant Authentication" -ForegroundColor Cyan
Write-Host ("═" * 50)

try {
    $authCheck = & atk auth list 2>&1
    $authText = ($authCheck | Out-String).Trim()

    if ($authText -match "No account" -or $authText -match "not logged in") {
        Write-Host "  Launching M365 login..." -ForegroundColor Yellow
        if (-not $DryRun) {
            & atk auth login
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ❌ Authentication failed." -ForegroundColor Red
                exit 1
            }
        }
        else {
            Write-Host "  [DRY RUN] Would launch atk auth login" -ForegroundColor Yellow
        }
    }
    Write-Host "  ✅ Authenticated to M365 tenant" -ForegroundColor Green
}
catch {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would authenticate to M365 tenant (atk not available)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  ❌ Authentication error: $_" -ForegroundColor Red
        Write-Host "  Please ensure the M365 Agents Toolkit CLI (atk) is installed." -ForegroundColor Yellow
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────
# Step 3: MCP Server Selection
# ─────────────────────────────────────────────────────────────────────
Write-Host "`n📋 Step 3: MCP Server Selection" -ForegroundColor Cyan
Write-Host ("═" * 50)

$mcpConfigPath = Join-Path $ConfigPath "mcp-providers.json"

try {
    if ($NonInteractive) {
        $selectedProviders = @{
            "sec-edgar"      = "https://data.sec.gov"
            "alpha-vantage"  = "https://www.alphavantage.co"
        }
        Write-Host "  Using default providers (non-interactive mode):" -ForegroundColor Yellow
        foreach ($key in $selectedProviders.Keys) {
            Write-Host "    • $key → $($selectedProviders[$key])" -ForegroundColor White
        }
    }
    else {
        $selectedProviders = Show-McpSelector -ConfigPath $mcpConfigPath
    }
    Write-Host "  ✅ $($selectedProviders.Count) MCP provider(s) selected" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ MCP server selection failed: $_" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────────
# Step 4: URL Configuration
# ─────────────────────────────────────────────────────────────────────
Write-Host "`n📋 Step 4: URL Configuration" -ForegroundColor Cyan
Write-Host ("═" * 50)

try {
    $modifiedCount = Set-McpServerUrls -ProviderUrls $selectedProviders `
        -ConfigPath $mcpConfigPath `
        -ProjectRoot $ProjectRoot `
        -DryRun:$DryRun

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would modify $modifiedCount file(s)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  ✅ URL configuration complete (modified $modifiedCount files)" -ForegroundColor Green
    }
}
catch {
    Write-Host "  ❌ URL configuration failed: $_" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────────
# Step 5: Agent Provisioning (4-tier)
# ─────────────────────────────────────────────────────────────────────
Write-Host "`n📋 Step 5: Agent Provisioning" -ForegroundColor Cyan
Write-Host ("═" * 50)

$manifestPath = Join-Path $ConfigPath "agent-manifest.json"

try {
    $allTitleIds = Invoke-AgentProvisioning `
        -ConfigPath $manifestPath `
        -ProjectRoot $ProjectRoot `
        -Environment $Environment `
        -DryRun:$DryRun

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would provision all agents across 4 tiers" -ForegroundColor Yellow
    }
    else {
        Write-Host "  ✅ Agent provisioning complete ($($allTitleIds.Count) agents)" -ForegroundColor Green
    }
}
catch {
    Write-Host "  ❌ Agent provisioning failed: $_" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────────
# Step 6: Installation Complete — Launch
# ─────────────────────────────────────────────────────────────────────
Write-Host "`n📋 Step 6: Installation Complete!" -ForegroundColor Cyan
Write-Host ("═" * 50)

$elapsed = (Get-Date) - $startTime
$elapsedFormatted = "{0:mm\:ss}" -f $elapsed

try {
    Open-PrimaryAgent -ProjectRoot $ProjectRoot `
        -Environment $Environment `
        -AllTitleIds $allTitleIds `
        -DryRun:$DryRun
}
catch {
    Write-Host "  ⚠️  Could not launch primary agent: $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  ⏱️  Total install time: $elapsedFormatted" -ForegroundColor DarkGray
Write-Host ""
