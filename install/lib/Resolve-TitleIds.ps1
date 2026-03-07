function Read-TitleIds {
    <#
    .SYNOPSIS
        Reads M365_TITLE_ID values from each agent's env/.env.prod file.
    .DESCRIPTION
        For each agent in the manifest, locates the env/.env.prod file under the agent's
        directory and extracts the M365_TITLE_ID value. Returns a hashtable mapping
        each agent's titleIdPlaceholder name to the resolved title ID.
    .PARAMETER Agents
        Array of agent objects from agent-manifest.json. Each object must have at least
        'path' and 'titleIdPlaceholder' properties.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .OUTPUTS
        System.Collections.Hashtable — maps placeholder names to title ID values.
        Example: @{ "SEMANTIC_NORMALIZATION_AGENT_TITLE_ID" = "P_abc123" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Agents,

        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $titleIds = @{}

    foreach ($agent in $Agents) {
        $agentPath = $agent.path
        $placeholder = $agent.titleIdPlaceholder

        if (-not $placeholder) {
            Write-Verbose "Agent at '$agentPath' has no titleIdPlaceholder — skipping."
            continue
        }

        $envFile = Join-Path $ProjectRoot (Join-Path $agentPath "env/.env.prod")

        if (-not (Test-Path $envFile)) {
            Write-Warning "No env/.env.prod found for agent '$placeholder' at: $envFile"
            continue
        }

        try {
            $titleId = $null
            $lines = Get-Content -Path $envFile

            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                # Skip comments and blank lines
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

                if ($trimmed -match '^M365_TITLE_ID\s*=\s*(.+)$') {
                    $titleId = $Matches[1].Trim()
                    break
                }
            }

            if ($titleId) {
                $titleIds[$placeholder] = $titleId
                Write-Verbose "Read $placeholder = $titleId from $envFile"
            }
            else {
                Write-Warning "M365_TITLE_ID not found in $envFile"
            }
        }
        catch {
            Write-Error "Failed to read env file '$envFile': $_"
        }
    }

    return $titleIds
}

function Set-TitleIds {
    <#
    .SYNOPSIS
        Injects resolved title IDs into declarativeAgent.json files, replacing placeholders.
    .DESCRIPTION
        For each target agent, reads its declarativeAgent.json and replaces
        {{PLACEHOLDER_NAME}} references with the actual title ID values.
    .PARAMETER TitleIds
        Hashtable mapping placeholder names to resolved title ID values.
        Example: @{ "SEMANTIC_NORMALIZATION_AGENT_TITLE_ID" = "P_abc123" }
    .PARAMETER TargetAgents
        Array of agent objects (from agent-manifest.json) whose declarativeAgent.json
        files should have placeholders replaced. Each must have a 'path' property.
        All available title IDs are replaced, not just those in workerAgentDeps.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .PARAMETER DryRun
        If specified, logs replacements without modifying files.
    .OUTPUTS
        System.Int32 — count of placeholders replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$TitleIds,

        [Parameter(Mandatory)]
        [array]$TargetAgents,

        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [switch]$DryRun
    )

    $replacementCount = 0

    foreach ($agent in $TargetAgents) {
        $agentPath = $agent.path
        $declAgentFile = Join-Path $ProjectRoot (Join-Path $agentPath "appPackage\declarativeAgent.json")

        if (-not (Test-Path $declAgentFile)) {
            Write-Warning "declarativeAgent.json not found at: $declAgentFile"
            continue
        }

        try {
            $content = Get-Content -Path $declAgentFile -Raw
            $modified = $false

            # Replace all available title IDs (required + optional) in the file
            foreach ($placeholder in $TitleIds.Keys) {
                $token = "{{$placeholder}}"

                if ($content -notmatch [regex]::Escape($token)) {
                    continue
                }

                $resolvedId = $TitleIds[$placeholder]

                if ($DryRun) {
                    Write-Host "[DryRun] Would replace $token → $resolvedId in $declAgentFile"
                }
                else {
                    $content = $content -replace [regex]::Escape($token), $resolvedId
                    $modified = $true
                    Write-Verbose "Replaced $token → $resolvedId in $declAgentFile"
                }

                $replacementCount++
            }

            if ($modified -and -not $DryRun) {
                Set-Content -Path $declAgentFile -Value $content -Encoding UTF8 -NoNewline
                Write-Verbose "Saved $declAgentFile"
            }
        }
        catch {
            Write-Error "Failed to process '$declAgentFile': $_"
        }
    }

    Write-Verbose "Total placeholders replaced: $replacementCount"
    return $replacementCount
}

function Remove-UnresolvedWorkerAgents {
    <#
    .SYNOPSIS
        Strips unresolved {{...}} entries from worker_agents arrays in declarativeAgent.json files.
    .DESCRIPTION
        After title ID injection, some optional worker_agents may still contain {{PLACEHOLDER}}
        tokens (e.g., optional MCP connectors that weren't provisioned). This function removes
        those entries so the agent can still be provisioned with its required dependencies.
    .PARAMETER TargetAgents
        Array of agent objects from agent-manifest.json whose declarativeAgent.json files
        should be cleaned.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .PARAMETER DryRun
        If specified, logs removals without modifying files.
    .OUTPUTS
        System.Int32 — count of unresolved entries removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$TargetAgents,

        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [switch]$DryRun
    )

    $removedCount = 0

    foreach ($agent in $TargetAgents) {
        $agentPath = $agent.path
        $declAgentFile = Join-Path $ProjectRoot (Join-Path $agentPath "appPackage\declarativeAgent.json")

        if (-not (Test-Path $declAgentFile)) {
            continue
        }

        try {
            $json = Get-Content -Path $declAgentFile -Raw | ConvertFrom-Json

            if (-not $json.worker_agents -or $json.worker_agents.Count -eq 0) {
                continue
            }

            $originalCount = $json.worker_agents.Count
            $resolved = @($json.worker_agents | Where-Object { $_.id -notmatch '\{\{.*\}\}' })

            if ($resolved.Count -eq $originalCount) {
                continue
            }

            $unresolvedCount = $originalCount - $resolved.Count
            $removedCount += $unresolvedCount

            if ($DryRun) {
                Write-Host "[DryRun] Would remove $unresolvedCount unresolved worker_agent(s) from $declAgentFile"
            }
            else {
                $json.worker_agents = $resolved
                $output = $json | ConvertTo-Json -Depth 10
                Set-Content -Path $declAgentFile -Value $output -Encoding UTF8 -NoNewline
                Write-Verbose "Removed $unresolvedCount unresolved worker_agent(s) from $declAgentFile"
            }
        }
        catch {
            Write-Error "Failed to process '$declAgentFile': $_"
        }
    }

    Write-Verbose "Total unresolved worker_agents removed: $removedCount"
    return $removedCount
}

function Restore-TitleIdPlaceholders {
    <#
    .SYNOPSIS
        Restores manifest-driven title ID placeholders in declarativeAgent.json files.
    .DESCRIPTION
        Reads agent-manifest.json and rebuilds each declarative agent's worker_agents
        array from the manifest's workerAgentDeps placeholders. This keeps install and
        uninstall deterministic even if declarativeAgent.json currently contains stale
        or previously injected title IDs.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .PARAMETER ConfigPath
        Path to the agent-manifest.json configuration file.
    .PARAMETER DryRun
        If specified, logs planned changes without modifying files.
    .OUTPUTS
        System.Int32 — count of declarative agent files reset to placeholder wiring.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [switch]$DryRun
    )

    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Agent manifest not found: $ConfigPath"
        return
    }

    try {
        $manifest = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse agent manifest: $_"
        return
    }

    $restoredCount = 0

    foreach ($agent in $manifest.agents) {
        $workerAgentDeps = @($agent.workerAgentDeps)
        if ($workerAgentDeps.Count -eq 0) {
            continue
        }

        $declAgentFile = Join-Path $ProjectRoot (Join-Path $agent.path "appPackage\declarativeAgent.json")
        if (-not (Test-Path $declAgentFile)) {
            Write-Warning "declarativeAgent.json not found at: $declAgentFile"
            continue
        }

        try {
            $json = Get-Content -Path $declAgentFile -Raw | ConvertFrom-Json
            $expectedIds = @($workerAgentDeps | ForEach-Object { "{{$($_)}}" })
            $currentIds = @($json.worker_agents | ForEach-Object { $_.id })

            if (($currentIds -join '|') -eq ($expectedIds -join '|')) {
                continue
            }

            if ($DryRun) {
                Write-Host "[DryRun] Would reset worker_agents placeholders in $declAgentFile"
                $restoredCount++
                continue
            }

            $expectedWorkers = @($expectedIds | ForEach-Object { [pscustomobject]@{ id = $_ } })
            if ($json.PSObject.Properties.Name -contains 'worker_agents') {
                $json.worker_agents = $expectedWorkers
            }
            else {
                $json | Add-Member -NotePropertyName worker_agents -NotePropertyValue $expectedWorkers
            }

            $output = $json | ConvertTo-Json -Depth 10
            Set-Content -Path $declAgentFile -Value $output -Encoding UTF8 -NoNewline
            Write-Verbose "Reset worker_agents placeholders in $declAgentFile"
            $restoredCount++
        }
        catch {
            Write-Error "Failed to restore placeholders in '$declAgentFile': $_"
        }
    }

    return $restoredCount
}
