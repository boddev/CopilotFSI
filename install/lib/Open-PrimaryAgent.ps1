# Open-PrimaryAgent.ps1
# Post-install launcher: displays summary and opens the primary agent in Teams.
# Dot-source this file from the main installer script.

function Open-PrimaryAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$Environment,

        [hashtable]$AllTitleIds,

        [switch]$DryRun
    )

    # ── Locate the primary agent's .env file ──
    $primaryAgentPath = Join-Path $ProjectRoot "agents" "fsi-primary-agent"
    $envFileName = ".env.$Environment"
    $envFilePath = Join-Path $primaryAgentPath $envFileName

    if (-not (Test-Path $primaryAgentPath)) {
        Write-Host "  ❌ Primary agent directory not found: $primaryAgentPath" -ForegroundColor Red
        return
    }

    # ── Read TEAMS_APP_ID from .env file ──
    $teamsAppId = $null
    if (Test-Path $envFilePath) {
        $envContent = Get-Content $envFilePath -ErrorAction SilentlyContinue
        foreach ($line in $envContent) {
            if ($line -match '^\s*TEAMS_APP_ID\s*=\s*(.+)\s*$') {
                $teamsAppId = $Matches[1].Trim().Trim('"', "'")
                break
            }
        }
    }

    if (-not $teamsAppId) {
        Write-Host "  ⚠️  TEAMS_APP_ID not found in $envFilePath" -ForegroundColor Yellow
        Write-Host "  ⚠️  The primary agent may not have been provisioned yet." -ForegroundColor Yellow
        Write-Host "  ⚠️  Run provisioning first, then re-run this step." -ForegroundColor Yellow
        return
    }

    $deepLinkUrl = "https://teams.microsoft.com/l/app/$teamsAppId"

    # ── Compute summary statistics ──
    $totalAgents = if ($AllTitleIds) { $AllTitleIds.Count } else { 0 }
    $workerAgentCount = if ($AllTitleIds) {
        ($AllTitleIds.Keys | Where-Object { $_ -match '_TITLE_ID$' }).Count
    } else { 0 }

    # Count MCP server URLs from manifest files
    $mcpServerCount = 0
    $mcpAgentDir = Join-Path $ProjectRoot "agents" "mcp"
    if (Test-Path $mcpAgentDir) {
        $pluginFiles = Get-ChildItem -Path $mcpAgentDir -Recurse -Filter "ai-plugin-*.json" -ErrorAction SilentlyContinue
        $mcpServerCount = ($pluginFiles | Measure-Object).Count
    }

    # ── Display completion banner ──
    $boxWidth = 62
    $border = '═' * $boxWidth

    Write-Host ""
    Write-Host "╔$border╗"
    Write-Host "║            FSI Copilot — Installation Complete!              ║"
    Write-Host "╠$border╣"
    Write-Host "║                                                              ║"

    $line1 = "  ✅ $totalAgents agents provisioned successfully"
    Write-Host "║$($line1.PadRight($boxWidth))║" -ForegroundColor Green

    $line2 = "  ✅ $workerAgentCount worker_agents title IDs resolved"
    Write-Host "║$($line2.PadRight($boxWidth))║" -ForegroundColor Green

    $line3 = "  ✅ $mcpServerCount MCP server URLs configured"
    Write-Host "║$($line3.PadRight($boxWidth))║" -ForegroundColor Green

    Write-Host "║                                                              ║"

    $pName = "  Primary Agent: Financial Services Copilot"
    Write-Host "║$($pName.PadRight($boxWidth))║"

    $pId = "  App ID: $teamsAppId"
    if ($pId.Length -gt $boxWidth) { $pId = $pId.Substring(0, $boxWidth - 1) + '…' }
    Write-Host "║$($pId.PadRight($boxWidth))║"

    $pLink = "  Deep Link: $deepLinkUrl"
    if ($pLink.Length -gt $boxWidth) { $pLink = $pLink.Substring(0, $boxWidth - 1) + '…' }
    Write-Host "║$($pLink.PadRight($boxWidth))║"

    Write-Host "║                                                              ║"

    if (-not $DryRun) {
        $openMsg = "  Opening in browser..."
        Write-Host "║$($openMsg.PadRight($boxWidth))║" -ForegroundColor Cyan
    }
    else {
        $dryMsg = "  [DRY RUN] Would open in browser"
        Write-Host "║$($dryMsg.PadRight($boxWidth))║" -ForegroundColor Yellow
    }

    Write-Host "║                                                              ║"
    Write-Host "╚$border╝"

    # ── Display agent summary table ──
    if ($AllTitleIds -and $AllTitleIds.Count -gt 0) {
        Write-Host ""
        Write-Host "Agent                              Tier  Status  Title ID" -ForegroundColor Cyan
        Write-Host "─────────────────────────────────  ────  ──────  ────────" -ForegroundColor DarkGray

        # Build display rows from AllTitleIds
        $tierMap = @{
            'mcp-'         = 0
            'compliance-'  = 1
            'semantic-'    = 1
            'comparable-'  = 2
            'dcf-'         = 2
            'due-'         = 2
            'company-'     = 2
            'earnings-'    = 2
            'coverage-'    = 2
            'precedent-'   = 2
            'fsi-'         = 3
        }

        $rows = @()
        foreach ($key in ($AllTitleIds.Keys | Sort-Object)) {
            $titleId = $AllTitleIds[$key]
            # Derive agent name from key (e.g., MCP_FACTSET_TITLE_ID -> mcp-factset)
            $agentName = ($key -replace '_TITLE_ID$', '' -replace '_', '-').ToLower()

            # Determine tier
            $tier = '?'
            foreach ($prefix in $tierMap.Keys) {
                if ($agentName.StartsWith($prefix)) {
                    $tier = $tierMap[$prefix]
                    break
                }
            }

            # Truncate title ID for display
            $displayTitleId = if ($titleId.Length -gt 12) { $titleId.Substring(0, 12) + '…' } else { $titleId }

            $rows += [PSCustomObject]@{
                Agent   = $agentName
                Tier    = $tier
                Status  = '✅'
                TitleId = $displayTitleId
            }
        }

        # Sort by tier then name
        $rows = $rows | Sort-Object @{Expression = { $_.Tier }}, @{Expression = { $_.Agent }}

        foreach ($row in $rows) {
            $agentCol  = $row.Agent.PadRight(35)
            $tierCol   = "$($row.Tier)".PadRight(6)
            $statusCol = $row.Status.PadRight(8)
            $titleCol  = $row.TitleId

            Write-Host "$agentCol$tierCol$statusCol$titleCol"
        }

        Write-Host ""
    }

    # ── Open browser ──
    if (-not $DryRun) {
        try {
            Start-Process $deepLinkUrl
            Write-Host "  🚀 Browser launched successfully." -ForegroundColor Green
        }
        catch {
            Write-Host "  ⚠️  Could not open browser automatically." -ForegroundColor Yellow
            Write-Host "  ⚠️  Please navigate to: $deepLinkUrl" -ForegroundColor Yellow
        }
    }
}
