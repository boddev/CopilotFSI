function Read-TitleIds {
    <#
    .SYNOPSIS
        Reads TEAMS_APP_TITLE_ID values from each agent's .env.prod file.
    .DESCRIPTION
        For each agent in the manifest, locates the .env.prod file under the agent's
        directory and extracts the TEAMS_APP_TITLE_ID value. Returns a hashtable mapping
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

        $envFile = Join-Path $ProjectRoot (Join-Path $agentPath ".env.prod")

        if (-not (Test-Path $envFile)) {
            Write-Warning "No .env.prod found for agent '$placeholder' at: $envFile"
            continue
        }

        try {
            $titleId = $null
            $lines = Get-Content -Path $envFile

            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                # Skip comments and blank lines
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

                if ($trimmed -match '^TEAMS_APP_TITLE_ID\s*=\s*(.+)$') {
                    $titleId = $Matches[1].Trim()
                    break
                }
            }

            if ($titleId) {
                $titleIds[$placeholder] = $titleId
                Write-Verbose "Read $placeholder = $titleId from $envFile"
            }
            else {
                Write-Warning "TEAMS_APP_TITLE_ID not found in $envFile"
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
        files should have placeholders replaced. Each must have 'path' and
        'workerAgentDeps' properties.
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

        $deps = $agent.workerAgentDeps
        if (-not $deps -or $deps.Count -eq 0) {
            Write-Verbose "No workerAgentDeps for agent at '$agentPath' — skipping."
            continue
        }

        try {
            $content = Get-Content -Path $declAgentFile -Raw
            $modified = $false

            foreach ($depPlaceholder in $deps) {
                $token = "{{$depPlaceholder}}"

                if ($content -notmatch [regex]::Escape($token)) {
                    Write-Verbose "  Placeholder $token not found in $declAgentFile — skipping."
                    continue
                }

                if (-not $TitleIds.ContainsKey($depPlaceholder)) {
                    Write-Warning "No title ID resolved for placeholder '$depPlaceholder' — cannot replace in $declAgentFile"
                    continue
                }

                $resolvedId = $TitleIds[$depPlaceholder]

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

function Restore-TitleIdPlaceholders {
    <#
    .SYNOPSIS
        Restores title ID placeholders in declarativeAgent.json files (for uninstall).
    .DESCRIPTION
        Reads agent-manifest.json to discover all titleIdPlaceholder names, then scans
        each declarativeAgent.json for resolved title IDs (P_xxxxxxxx format) within
        worker_agents blocks and replaces them with the original {{PLACEHOLDER_NAME}}.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .PARAMETER ConfigPath
        Path to the agent-manifest.json configuration file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$ConfigPath
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

    # Build a lookup: read current title IDs from .env.prod files
    # so we know which concrete ID maps to which placeholder
    $idToPlaceholder = @{}

    foreach ($agent in $manifest.agents) {
        $placeholder = $agent.titleIdPlaceholder
        if (-not $placeholder) { continue }

        $envFile = Join-Path $ProjectRoot (Join-Path $agent.path ".env.prod")
        if (-not (Test-Path $envFile)) { continue }

        try {
            $lines = Get-Content -Path $envFile
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
                if ($trimmed -match '^TEAMS_APP_TITLE_ID\s*=\s*(.+)$') {
                    $titleId = $Matches[1].Trim()
                    $idToPlaceholder[$titleId] = $placeholder
                    Write-Verbose "Mapped $titleId → {{$placeholder}}"
                    break
                }
            }
        }
        catch {
            Write-Warning "Could not read $envFile : $_"
        }
    }

    if ($idToPlaceholder.Count -eq 0) {
        Write-Warning "No title ID mappings found — nothing to restore."
        return
    }

    # Scan all declarativeAgent.json files for injected title IDs
    $declFiles = Get-ChildItem -Path $ProjectRoot -Filter "declarativeAgent.json" -Recurse -File

    foreach ($file in $declFiles) {
        try {
            $content = Get-Content -Path $file.FullName -Raw
            $modified = $false

            foreach ($titleId in $idToPlaceholder.Keys) {
                if ($content -match [regex]::Escape($titleId)) {
                    $placeholder = $idToPlaceholder[$titleId]
                    $content = $content -replace [regex]::Escape($titleId), "{{$placeholder}}"
                    $modified = $true
                    Write-Verbose "Restored $titleId → {{$placeholder}} in $($file.FullName)"
                }
            }

            if ($modified) {
                Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
                Write-Verbose "Saved $($file.FullName)"
            }
        }
        catch {
            Write-Error "Failed to restore placeholders in '$($file.FullName)': $_"
        }
    }
}
