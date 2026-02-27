# Invoke-AgentProvisioning.ps1
# Orchestrates tiered provisioning of all FSI Copilot agents.
# Dot-source this file from the main installer script.
# Depends on: Resolve-TitleIds.ps1 (Read-TitleIds, Set-TitleIds)

function Invoke-SingleAgentProvision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AgentPath,

        [string]$Environment = "prod",

        [switch]$DryRun
    )

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would provision: $AgentPath" -ForegroundColor Yellow
        return
    }

    $originalLocation = Get-Location
    try {
        Set-Location $AgentPath

        $result = & atk provision --env $Environment --nonInteractive 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Provisioning failed for ${AgentPath}: $result"
        }

        Write-Host "  ✅ Provisioned: $(Split-Path $AgentPath -Leaf)" -ForegroundColor Green
    }
    catch {
        Write-Host "  ❌ Failed: $(Split-Path $AgentPath -Leaf) — $_" -ForegroundColor Red
        throw
    }
    finally {
        Set-Location $originalLocation
    }
}

function Show-TierProgress {
    [CmdletBinding()]
    param(
        [string]$TierLabel,
        [int]$Completed,
        [int]$Total,
        [string[]]$SucceededNames,
        [string[]]$PendingNames,
        [string[]]$FailedNames
    )

    $barLength = 4
    $filledCount = if ($Total -gt 0) { [math]::Floor(($Completed / $Total) * $barLength) } else { 0 }
    $emptyCount = $barLength - $filledCount
    $bar = ('█' * $filledCount) + ('▒' * $emptyCount)

    $boxWidth = 58
    $border = '═' * $boxWidth

    Write-Host ""
    Write-Host "╔$border╗"
    Write-Host "║          FSI Copilot — Agent Provisioning                ║"
    Write-Host "╠$border╣"
    Write-Host "║                                                          ║"

    $headerText = "  $TierLabel"
    $counter = "[$Completed/$Total] $bar"
    $padLen = $boxWidth - $headerText.Length - $counter.Length
    if ($padLen -lt 1) { $padLen = 1 }
    Write-Host "║$headerText$(' ' * $padLen)$counter║"

    foreach ($name in $SucceededNames) {
        $line = "    ✅ $name"
        $pad = $boxWidth - $line.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host -NoNewline "║"
        Write-Host -NoNewline $line -ForegroundColor Green
        Write-Host "$(' ' * $pad)║"
    }

    foreach ($name in $FailedNames) {
        $line = "    ❌ $name"
        $pad = $boxWidth - $line.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host -NoNewline "║"
        Write-Host -NoNewline $line -ForegroundColor Red
        Write-Host "$(' ' * $pad)║"
    }

    foreach ($name in $PendingNames) {
        $line = "    ⏳ $name"
        $pad = $boxWidth - $line.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host -NoNewline "║"
        Write-Host -NoNewline $line -ForegroundColor Yellow
        Write-Host "$(' ' * $pad)║"
    }

    Write-Host "║                                                          ║"
    Write-Host "╚$border╝"
}

function Invoke-TierProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Agents,

        [Parameter(Mandatory)]
        [string]$TierLabel,

        [string]$Environment = "prod",

        [switch]$Sequential,

        [switch]$DryRun
    )

    $succeeded = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $failed    = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $errors    = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
    $total     = $Agents.Count

    if ($total -eq 0) {
        Write-Host "  No agents in this tier — skipping." -ForegroundColor DarkGray
        return @{ Succeeded = @(); Failed = @(); Errors = @{} }
    }

    $agentNames = $Agents | ForEach-Object { $_.name }

    if ($Sequential -or $DryRun) {
        # Sequential provisioning (tier 3 or dry run)
        foreach ($agent in $Agents) {
            $name = $agent.name
            $path = $agent.path
            try {
                Invoke-SingleAgentProvision -AgentPath $path -Environment $Environment -DryRun:$DryRun
                $succeeded.Add($name)
            }
            catch {
                $failed.Add($name)
                $errors[$name] = $_.Exception.Message
            }

            $completedNames = @($succeeded.ToArray())
            $failedNames = @($failed.ToArray())
            $pendingNames = $agentNames | Where-Object { $_ -notin $completedNames -and $_ -notin $failedNames }
            Show-TierProgress -TierLabel $TierLabel `
                -Completed ($completedNames.Count + $failedNames.Count) -Total $total `
                -SucceededNames $completedNames -PendingNames $pendingNames -FailedNames $failedNames
        }
    }
    else {
        # Parallel provisioning (tiers 0-2) using Start-Job for PS 5.1+ compat
        $jobs = @{}
        foreach ($agent in $Agents) {
            $name = $agent.name
            $path = $agent.path
            $job = Start-Job -ScriptBlock {
                param($AgentPath, $Env)
                $originalLocation = Get-Location
                try {
                    Set-Location $AgentPath
                    $result = & atk provision --env $Env --nonInteractive 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Provisioning failed: $result"
                    }
                    return @{ Success = $true; Name = (Split-Path $AgentPath -Leaf) }
                }
                catch {
                    return @{ Success = $false; Name = (Split-Path $AgentPath -Leaf); Error = $_.Exception.Message }
                }
                finally {
                    Set-Location $originalLocation
                }
            } -ArgumentList $path, $Environment

            $jobs[$name] = $job
        }

        # Poll for completion
        while ($jobs.Values | Where-Object { $_.State -eq 'Running' }) {
            Start-Sleep -Seconds 3

            foreach ($entry in @($jobs.GetEnumerator())) {
                $name = $entry.Key
                $job = $entry.Value

                if ($job.State -ne 'Running' -and $name -notin $succeeded.ToArray() -and $name -notin $failed.ToArray()) {
                    $output = Receive-Job -Job $job
                    if ($output.Success) {
                        $succeeded.Add($name)
                        Write-Host "  ✅ Provisioned: $name" -ForegroundColor Green
                    }
                    else {
                        $failed.Add($name)
                        $errors[$name] = $output.Error
                        Write-Host "  ❌ Failed: $name — $($output.Error)" -ForegroundColor Red
                    }
                    Remove-Job -Job $job -Force
                }
            }

            $completedNames = @($succeeded.ToArray())
            $failedNames = @($failed.ToArray())
            $pendingNames = $agentNames | Where-Object { $_ -notin $completedNames -and $_ -notin $failedNames }
            Show-TierProgress -TierLabel $TierLabel `
                -Completed ($completedNames.Count + $failedNames.Count) -Total $total `
                -SucceededNames $completedNames -PendingNames $pendingNames -FailedNames $failedNames
        }

        # Collect any remaining completed jobs
        foreach ($entry in @($jobs.GetEnumerator())) {
            $name = $entry.Key
            $job = $entry.Value
            if ($name -notin $succeeded.ToArray() -and $name -notin $failed.ToArray()) {
                $output = Receive-Job -Job $job -ErrorAction SilentlyContinue
                if ($output.Success) {
                    $succeeded.Add($name)
                    Write-Host "  ✅ Provisioned: $name" -ForegroundColor Green
                }
                else {
                    $failed.Add($name)
                    $errMsg = if ($output.Error) { $output.Error } else { "Unknown error" }
                    $errors[$name] = $errMsg
                    Write-Host "  ❌ Failed: $name — $errMsg" -ForegroundColor Red
                }
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return @{
        Succeeded = @($succeeded.ToArray())
        Failed    = @($failed.ToArray())
        Errors    = @($errors.GetEnumerator() | ForEach-Object { @{ $_.Key = $_.Value } })
    }
}

function Invoke-AgentProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$Environment = "prod",

        [switch]$DryRun
    )

    # ── Load manifest ──
    if (-not (Test-Path $ConfigPath)) {
        throw "Agent manifest not found: $ConfigPath"
    }

    $manifest = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # Validate manifest structure
    if (-not $manifest.tiers) {
        throw "Invalid agent manifest: missing 'tiers' property"
    }

    # ── State tracking ──
    $allTitleIds = @{}
    $allSucceeded = @()
    $allFailed = @()
    $tierResults = @{}

    $tierLabels = @{
        0 = "Tier 0: MCP Data Connector Agents"
        1 = "Tier 1: Utility Agents"
        2 = "Tier 2: Skill Agents"
        3 = "Tier 3: Orchestrator Agents"
    }

    # ── Process each tier ──
    foreach ($tierIndex in 0..3) {
        $tierKey = "$tierIndex"
        $tierConfig = $manifest.tiers | Where-Object { [int]$_.tier -eq $tierIndex }

        if (-not $tierConfig) {
            Write-Host "`n  ⚠️  Tier $tierIndex not found in manifest — skipping." -ForegroundColor Yellow
            continue
        }

        $tierLabel = if ($tierLabels.ContainsKey($tierIndex)) { $tierLabels[$tierIndex] } else { "Tier $tierIndex" }

        Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "  $tierLabel" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

        # Build agent list with resolved paths
        $agents = @()
        foreach ($agentEntry in $tierConfig.agents) {
            $agentPath = Join-Path $ProjectRoot $agentEntry.path
            if (-not (Test-Path $agentPath)) {
                Write-Host "  ⚠️  Agent path not found: $agentPath — skipping." -ForegroundColor Yellow
                continue
            }
            $agents += @{
                name = $agentEntry.name
                path = $agentPath
                title_id_key = $agentEntry.title_id_key
            }
        }

        # Inject title IDs from previous tiers (tiers 1+)
        if ($tierIndex -gt 0 -and $allTitleIds.Count -gt 0) {
            Write-Host "  Injecting $($allTitleIds.Count) title ID(s) from previous tiers..." -ForegroundColor DarkGray
            if (-not $DryRun) {
                foreach ($agent in $agents) {
                    try {
                        Set-TitleIds -AgentPath $agent.path -TitleIds $allTitleIds
                    }
                    catch {
                        Write-Host "  ⚠️  Failed to inject title IDs into $($agent.name): $_" -ForegroundColor Yellow
                    }
                }
            }
            else {
                Write-Host "  [DRY RUN] Would inject title IDs into $($agents.Count) agent(s)" -ForegroundColor Yellow
            }
        }

        # Provision the tier
        $isSequential = ($tierIndex -eq 3)
        $result = Invoke-TierProvisioning -Agents $agents -TierLabel $tierLabel `
            -Environment $Environment -Sequential:$isSequential -DryRun:$DryRun

        $tierResults[$tierIndex] = $result
        $allSucceeded += $result.Succeeded
        $allFailed += $result.Failed

        # Collect title IDs from provisioned agents
        if (-not $DryRun) {
            foreach ($agent in $agents) {
                if ($agent.name -in $result.Succeeded) {
                    try {
                        $envTitleIds = Read-TitleIds -AgentPath $agent.path -Environment $Environment
                        foreach ($key in $envTitleIds.Keys) {
                            $allTitleIds[$key] = $envTitleIds[$key]
                        }
                        Write-Host "  📋 Collected title ID for $($agent.name)" -ForegroundColor DarkGray
                    }
                    catch {
                        Write-Host "  ⚠️  Could not read title ID for $($agent.name): $_" -ForegroundColor Yellow
                    }
                }
            }
        }

        # Warn about dependency impact if agents failed
        if ($result.Failed.Count -gt 0 -and $tierIndex -lt 3) {
            $failedNames = $result.Failed -join ', '
            Write-Host ""
            Write-Host "  ⚠️  WARNING: $($result.Failed.Count) agent(s) failed in $tierLabel" -ForegroundColor Yellow
            Write-Host "  ⚠️  Failed: $failedNames" -ForegroundColor Yellow
            Write-Host "  ⚠️  Agents in later tiers that depend on these as worker_agents may not function correctly." -ForegroundColor Yellow
        }
    }

    # ── Final summary ──
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Provisioning Summary" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  ✅ Succeeded: $($allSucceeded.Count)" -ForegroundColor Green
    if ($allFailed.Count -gt 0) {
        Write-Host "  ❌ Failed:    $($allFailed.Count)" -ForegroundColor Red
        foreach ($name in $allFailed) {
            Write-Host "     - $name" -ForegroundColor Red
        }
    }
    Write-Host "  📋 Title IDs: $($allTitleIds.Count)" -ForegroundColor DarkGray
    Write-Host ""

    return $allTitleIds
}
