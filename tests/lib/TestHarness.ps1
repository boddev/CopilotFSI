Set-StrictMode -Version Latest

function Get-TestRepoRoot {
    param([string]$ProjectRoot)

    if ($ProjectRoot) {
        return (Resolve-Path $ProjectRoot).Path
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-AgentManifestData {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $manifestPath = Join-Path $RepoRoot "install\config\agent-manifest.json"
    return Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
}

function Get-DeclarativeAgentRecord {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$AgentEntry
    )

    $declarativePath = Join-Path $RepoRoot (Join-Path $AgentEntry.path "appPackage\declarativeAgent.json")
    if (-not (Test-Path $declarativePath)) {
        return $null
    }

    return [pscustomobject]@{
        Entry = $AgentEntry
        Path = $declarativePath
        Json = Get-Content -Path $declarativePath -Raw | ConvertFrom-Json
    }
}

function Get-AllDeclarativeAgentRecords {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $manifest = Get-AgentManifestData -RepoRoot $RepoRoot
    $records = foreach ($agent in @($manifest.agents)) {
        Get-DeclarativeAgentRecord -RepoRoot $RepoRoot -AgentEntry $agent
    }

    return @($records | Where-Object { $null -ne $_ })
}

function New-TestResult {
    param(
        [Parameter(Mandatory)][string]$Suite,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Details = @{}
    )

    return [pscustomobject]@{
        suite = $Suite
        name = $Name
        passed = $Passed
        message = $Message
        details = $Details
    }
}

function Save-TestReport {
    param(
        [Parameter(Mandatory)][string]$Suite,
        [Parameter(Mandatory)][array]$Results,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $reportDir = Split-Path -Parent $ReportPath
    if (-not (Test-Path $reportDir)) {
        $null = New-Item -Path $reportDir -ItemType Directory -Force
    }

    $report = [pscustomobject]@{
        suite = $Suite
        generatedAt = (Get-Date).ToString("o")
        total = $Results.Count
        failed = @($Results | Where-Object { -not $_.passed }).Count
        passed = @($Results | Where-Object { $_.passed }).Count
        success = (@($Results | Where-Object { -not $_.passed }).Count -eq 0)
        results = $Results
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $ReportPath
}

function Assert-ContainsAllPhrases {
    param(
        [Parameter(Mandatory)][string]$Content,
        [string[]]$Phrases
    )

    if (-not $Phrases -or $Phrases.Count -eq 0) {
        return ,@()
    }

    $missing = foreach ($phrase in $Phrases) {
        if (-not $Content.Contains($phrase, [System.StringComparison]::OrdinalIgnoreCase)) {
            $phrase
        }
    }

    return ,@($missing)
}

function Assert-ContainsNoneOfPhrases {
    param(
        [Parameter(Mandatory)][string]$Content,
        [string[]]$Phrases
    )

    if (-not $Phrases -or $Phrases.Count -eq 0) {
        return ,@()
    }

    $present = foreach ($phrase in $Phrases) {
        if ($Content.Contains($phrase, [System.StringComparison]::OrdinalIgnoreCase)) {
            $phrase
        }
    }

    return ,@($present)
}

function Test-WorkerId {
    param(
        [Parameter(Mandatory)][string]$Id,
        [switch]$RequireResolvedTitleIds
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return [pscustomobject]@{ Passed = $false; Reason = "Worker ID is blank." }
    }

    if ($Id -match '^\{\{[A-Z0-9_]+\}\}$') {
        if ($RequireResolvedTitleIds) {
            return [pscustomobject]@{ Passed = $false; Reason = "Worker ID is still a placeholder: $Id" }
        }

        return [pscustomobject]@{ Passed = $true; Reason = "Worker ID placeholder is acceptable in pre-deployment mode." }
    }

    if ($Id -match '^[A-Z]_[0-9a-fA-F-]{36}$') {
        return [pscustomobject]@{ Passed = $true; Reason = "Worker ID is resolved." }
    }

    return [pscustomobject]@{ Passed = $false; Reason = "Worker ID has an unexpected format: $Id" }
}
