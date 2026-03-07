# Invoke-AgentProvisioning.ps1
# Orchestrates tiered provisioning of all FSI Copilot agents.
# Dot-source this file from the main installer script.
# Depends on: Resolve-TitleIds.ps1 (Read-TitleIds, Set-TitleIds, Remove-UnresolvedWorkerAgents)

function Test-AgentReady {
    param(
        [Parameter(Mandatory)][object]$AgentEntry,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [hashtable]$AvailableTitleIds = @{}
    )

    $reasons = @()
    $agentPath = Join-Path $ProjectRoot $AgentEntry.path

    # Check 1: Unresolved {{MCP_HOST}} in plugin files
    # Scans ALL ai-plugin-*.json files because ATK's zipAppPackage includes
    # everything in appPackage/. Unreferenced files with {{MCP_HOST}} would
    # still cause validateAppPackage to fail. Instruction-based agents should
    # have no ai-plugin-*.json files in their appPackage directory.
    $pluginDir = Join-Path $agentPath "appPackage"
    $pluginFiles = Get-ChildItem -Path $pluginDir -Filter "ai-plugin-*.json" -ErrorAction SilentlyContinue
    foreach ($pf in $pluginFiles) {
        $content = Get-Content $pf.FullName -Raw
        if ($content -match '\{\{MCP_HOST\}\}') {
            $reasons += "unconfigured MCP URL in $($pf.Name)"
            break
        }
    }

    # Check 2: Missing worker agent dependencies
    $deps = $AgentEntry.workerAgentDeps
    if ($deps -and $deps.Count -gt 0) {
        foreach ($dep in $deps) {
            if (-not $AvailableTitleIds.ContainsKey($dep)) {
                $reasons += "missing dependency $dep"
            }
        }
    }

    return @{ Ready = ($reasons.Count -eq 0); Reasons = $reasons }
}

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

        $result = & atk provision --env $Environment --interactive false 2>&1
        $output = ($result | Out-String).Trim()

        if ($LASTEXITCODE -ne 0) {
            throw "Provisioning failed (exit code $LASTEXITCODE) for ${AgentPath}:`n$output"
        }

        Write-Host "  ✅ Provisioned: $(Split-Path $AgentPath -Leaf)" -ForegroundColor Green
    }
    catch {
        Write-Host "  ❌ Failed: $(Split-Path $AgentPath -Leaf)" -ForegroundColor Red
        Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
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
                    $result = & atk provision --env $Env --interactive false 2>&1
                    $output = ($result | Out-String).Trim()
                    if ($LASTEXITCODE -ne 0) {
                        throw "Exit code $LASTEXITCODE`n$output"
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
    if (-not $manifest.tiers -or -not $manifest.agents) {
        throw "Invalid agent manifest: missing 'tiers' or 'agents' property"
    }

    # ── State tracking ──
    $allTitleIds = @{}
    $allSucceeded = @()
    $allFailed = @()
    $allSkipped = @()
    $tierResults = @{}

    # ── Process each tier ──
    $maxTier = ($manifest.agents | ForEach-Object { [int]$_.tier } | Measure-Object -Maximum).Maximum
    foreach ($tierIndex in 0..$maxTier) {
        $tierKey = "$tierIndex"
        $tierMeta = $manifest.tiers.$tierKey

        if (-not $tierMeta) {
            Write-Host "`n  ⚠️  Tier $tierIndex not found in manifest — skipping." -ForegroundColor Yellow
            continue
        }

        $tierLabel = "Tier ${tierIndex}: $($tierMeta.name)"

        # Get agents for this tier from the agents array
        $tierAgents = @($manifest.agents | Where-Object { [int]$_.tier -eq $tierIndex })

        if ($tierAgents.Count -eq 0) {
            Write-Host "`n  ⚠️  No agents defined for $tierLabel — skipping." -ForegroundColor Yellow
            continue
        }

        Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "  $tierLabel" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

        # Build agent list with resolved paths
        $agents = @()
        $manifestAgentsForTier = @()
        foreach ($agentEntry in $tierAgents) {
            $agentPath = Join-Path $ProjectRoot $agentEntry.path
            if (-not (Test-Path $agentPath)) {
                Write-Host "  ⚠️  Agent path not found: $agentPath — skipping." -ForegroundColor Yellow
                continue
            }
            $agents += @{
                name = $agentEntry.name
                path = $agentPath
            }
            $manifestAgentsForTier += $agentEntry
        }

        $isSequential = -not $tierMeta.parallel

        if ($isSequential) {
            # ── Sequential tier: per-agent readiness → inject → provision → collect ──
            # Readiness is checked per-agent (not upfront) because earlier agents in
            # the tier produce title IDs that later agents depend on
            # (e.g., coverage-report provisions first, then fsi-primary sees its title ID).
            foreach ($i in 0..($agents.Count - 1)) {
                $agent = $agents[$i]
                $manifestAgent = $manifestAgentsForTier[$i]

                # Check readiness with current title IDs (includes IDs from earlier agents in this tier)
                $check = Test-AgentReady -AgentEntry $manifestAgent -ProjectRoot $ProjectRoot -AvailableTitleIds $allTitleIds
                if (-not $check.Ready) {
                    Write-Host "  ⏭️  Skipping: $($agent.name) — $($check.Reasons -join '; ')" -ForegroundColor DarkGray
                    $allSkipped += $agent.name
                    continue
                }

                # Inject all available title IDs into this agent
                if ($allTitleIds.Count -gt 0) {
                    Write-Host "  Injecting $($allTitleIds.Count) title ID(s) into $($agent.name)..." -ForegroundColor DarkGray
                    if (-not $DryRun) {
                        try {
                            $null = Set-TitleIds -TitleIds $allTitleIds -TargetAgents @($manifestAgent) -ProjectRoot $ProjectRoot -DryRun:$DryRun
                        }
                        catch {
                            Write-Host "  ⚠️  Failed to inject title IDs: $_" -ForegroundColor Yellow
                        }
                    }
                    else {
                        Write-Host "  [DRY RUN] Would inject title IDs into $($agent.name)" -ForegroundColor Yellow
                    }
                }

                # Remove any unresolved worker_agent placeholders (optional deps)
                try {
                    $null = Remove-UnresolvedWorkerAgents -TargetAgents @($manifestAgent) -ProjectRoot $ProjectRoot -DryRun:$DryRun
                }
                catch {
                    Write-Host "  ⚠️  Failed to clean unresolved worker agents: $_" -ForegroundColor Yellow
                }

                # Provision this single agent
                $singleResult = Invoke-TierProvisioning -Agents @($agent) -TierLabel $tierLabel `
                    -Environment $Environment -Sequential -DryRun:$DryRun

                $allSucceeded += $singleResult.Succeeded
                $allFailed += $singleResult.Failed

                # If this agent failed, stop the sequential tier — later agents depend on it
                if ($singleResult.Failed.Count -gt 0) {
                    break
                }

                # Collect title ID immediately so the next agent in this tier can use it
                if (-not $DryRun -and $agent.name -in $singleResult.Succeeded) {
                    try {
                        $envTitleIds = Read-TitleIds -Agents @($manifestAgent) -ProjectRoot $ProjectRoot
                        foreach ($key in $envTitleIds.Keys) {
                            $allTitleIds[$key] = $envTitleIds[$key]
                        }
                        Write-Host "  📋 Collected $($envTitleIds.Count) title ID(s) from $($agent.name)" -ForegroundColor DarkGray
                    }
                    catch {
                        Write-Host "  ⚠️  Could not read title IDs: $_" -ForegroundColor Yellow
                    }
                }
            }

            $tierResults[$tierIndex] = @{
                Succeeded = @($allSucceeded | Where-Object { $_ -in ($agents | ForEach-Object { $_.name }) })
                Failed    = @($allFailed | Where-Object { $_ -in ($agents | ForEach-Object { $_.name }) })
                Errors    = @{}
            }
            $result = $tierResults[$tierIndex]
        }
        else {
            # ── Parallel tier: filter upfront → batch inject → provision → collect ──
            $readyAgents = @()
            $readyManifestAgents = @()
            $tierSkipped = @()

            for ($i = 0; $i -lt $agents.Count; $i++) {
                $check = Test-AgentReady -AgentEntry $manifestAgentsForTier[$i] -ProjectRoot $ProjectRoot -AvailableTitleIds $allTitleIds
                if ($check.Ready) {
                    $readyAgents += $agents[$i]
                    $readyManifestAgents += $manifestAgentsForTier[$i]
                } else {
                    $tierSkipped += @{ Name = $agents[$i].name; Reasons = $check.Reasons }
                }
            }

            foreach ($skip in $tierSkipped) {
                Write-Host "  ⏭️  Skipping: $($skip.Name) — $($skip.Reasons -join '; ')" -ForegroundColor DarkGray
                $allSkipped += $skip.Name
            }

            # Replace arrays with filtered versions
            $agents = $readyAgents
            $manifestAgentsForTier = $readyManifestAgents

            if ($agents.Count -eq 0) {
                Write-Host "  ⚠️  All agents for $tierLabel were skipped or missing — skipping tier." -ForegroundColor Yellow
                continue
            }

            # Inject title IDs from previous tiers (tiers 1+)
            if ($tierIndex -gt 0 -and $allTitleIds.Count -gt 0) {
                Write-Host "  Injecting $($allTitleIds.Count) title ID(s) from previous tiers..." -ForegroundColor DarkGray
                if (-not $DryRun) {
                    try {
                        $null = Set-TitleIds -TitleIds $allTitleIds -TargetAgents $manifestAgentsForTier -ProjectRoot $ProjectRoot -DryRun:$DryRun
                    }
                    catch {
                        Write-Host "  ⚠️  Failed to inject title IDs: $_" -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "  [DRY RUN] Would inject title IDs into $($agents.Count) agent(s)" -ForegroundColor Yellow
                }
            }

            # Remove any unresolved worker_agent placeholders (optional deps)
            try {
                $null = Remove-UnresolvedWorkerAgents -TargetAgents $manifestAgentsForTier -ProjectRoot $ProjectRoot -DryRun:$DryRun
            }
            catch {
                Write-Host "  ⚠️  Failed to clean unresolved worker agents: $_" -ForegroundColor Yellow
            }

            $result = Invoke-TierProvisioning -Agents $agents -TierLabel $tierLabel `
                -Environment $Environment -DryRun:$DryRun

            $tierResults[$tierIndex] = $result
            $allSucceeded += $result.Succeeded
            $allFailed += $result.Failed

            # Collect title IDs from provisioned agents
            if (-not $DryRun) {
                $succeededManifestAgents = @($manifestAgentsForTier | Where-Object { $_.name -in $result.Succeeded })
                if ($succeededManifestAgents.Count -gt 0) {
                    try {
                        $envTitleIds = Read-TitleIds -Agents $succeededManifestAgents -ProjectRoot $ProjectRoot
                        foreach ($key in $envTitleIds.Keys) {
                            $allTitleIds[$key] = $envTitleIds[$key]
                        }
                        Write-Host "  📋 Collected $($envTitleIds.Count) title ID(s) from $($succeededManifestAgents.Count) agent(s)" -ForegroundColor DarkGray
                    }
                    catch {
                        Write-Host "  ⚠️  Could not read title IDs: $_" -ForegroundColor Yellow
                    }
                }
            }
        }

        # Abort remaining tiers if any agent failed — downstream dependencies will be broken
        if ($result.Failed.Count -gt 0) {
            $failedNames = $result.Failed -join ', '
            Write-Host ""
            Write-Host "  ❌ ABORTING: $($result.Failed.Count) agent(s) failed in $tierLabel" -ForegroundColor Red
            Write-Host "  ❌ Failed: $failedNames" -ForegroundColor Red
            if ($tierIndex -lt $maxTier) {
                Write-Host "  ❌ Skipping remaining tiers — downstream agents depend on these." -ForegroundColor Red
            }
            break
        }
    }

    # ── Final summary ──
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Provisioning Summary" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  ✅ Succeeded: $($allSucceeded.Count)" -ForegroundColor Green
    if ($allSkipped.Count -gt 0) {
        Write-Host "  ⏭️  Skipped:   $($allSkipped.Count) (unconfigured)" -ForegroundColor DarkGray
        foreach ($name in $allSkipped) {
            Write-Host "     - $name" -ForegroundColor DarkGray
        }
    }
    if ($allFailed.Count -gt 0) {
        Write-Host "  ❌ Failed:    $($allFailed.Count)" -ForegroundColor Red
        foreach ($name in $allFailed) {
            Write-Host "     - $name" -ForegroundColor Red
        }
    }
    Write-Host "  📋 Title IDs: $($allTitleIds.Count)" -ForegroundColor DarkGray
    Write-Host ""

    return @{
        TitleIds  = $allTitleIds
        Succeeded = $allSucceeded
        Failed    = $allFailed
        Skipped   = $allSkipped
    }
}
