[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ReportPath = (Join-Path $PSScriptRoot "reports\validate-worker-wiring.json"),
    [switch]$RequireResolvedTitleIds
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\TestHarness.ps1")

$repoRoot = Get-TestRepoRoot -ProjectRoot $ProjectRoot
$manifest = Get-AgentManifestData -RepoRoot $repoRoot
$expectations = Get-Content -Path (Join-Path $PSScriptRoot "test-data\worker-dependencies.json") -Raw | ConvertFrom-Json
$records = @{}
foreach ($record in Get-AllDeclarativeAgentRecords -RepoRoot $repoRoot) {
    $records[$record.Entry.id] = $record
}

$resolvedTitleIds = @{}
foreach ($agent in $manifest.agents) {
    if (-not $agent.titleIdPlaceholder) {
        continue
    }

    $envFile = Join-Path $repoRoot (Join-Path $agent.path $agent.envFile)
    if (-not (Test-Path $envFile)) {
        continue
    }

    $titleLine = Select-String -Path $envFile -Pattern '^M365_TITLE_ID\s*=\s*(.+)$' | Select-Object -First 1
    if ($titleLine) {
        $resolvedTitleIds[$agent.titleIdPlaceholder] = $titleLine.Matches[0].Groups[1].Value.Trim()
    }
}

$validPlaceholders = @($manifest.agents | ForEach-Object { $_.titleIdPlaceholder })
$suite = "validate-worker-wiring"
$results = [System.Collections.Generic.List[object]]::new()

foreach ($expectation in $expectations) {
    $entry = @($manifest.agents | Where-Object { $_.id -eq $expectation.agentId })[0]
    $record = $records[$expectation.agentId]

    $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-manifest-entry" -Passed ($null -ne $entry -and $null -ne $record) -Message ((($null -ne $entry) -and ($null -ne $record)) ? "Agent exists for worker wiring validation." : "Agent manifest or declarative manifest is missing.") -Details @{ agentId = $expectation.agentId }))

    if ($null -eq $entry -or $null -eq $record) {
        continue
    }

    $expectedDeps = @($expectation.expectedManifestDeps)
    $actualDeps = @($entry.workerAgentDeps)
    $missingDeps = @($expectedDeps | Where-Object { $_ -notin $actualDeps })
    $extraDeps = @($actualDeps | Where-Object { $_ -notin $expectedDeps })
    $depsValid = ($missingDeps.Count -eq 0) -and ($extraDeps.Count -eq 0)
    $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-manifest-deps" -Passed $depsValid -Message ($depsValid ? "Manifest workerAgentDeps match the expected dependency contract." : "Manifest workerAgentDeps do not match the expected dependency contract.") -Details @{ expected = $expectedDeps; actual = $actualDeps; missing = $missingDeps; extra = $extraDeps }))

    $unknownDeps = @($expectedDeps | Where-Object { $_ -notin $validPlaceholders })
    $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-known-placeholders" -Passed ($unknownDeps.Count -eq 0) -Message (($unknownDeps.Count -eq 0) ? "Expected placeholders resolve to known manifest entries." : "One or more expected placeholders do not exist in the agent manifest.") -Details @{ unknown = $unknownDeps }))

    $workerCount = @($record.Json.worker_agents).Count
    $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-worker-count" -Passed ($workerCount -eq [int]$expectation.expectedWorkerCount) -Message (($workerCount -eq [int]$expectation.expectedWorkerCount) ? "Declarative worker_agents count matches expectations." : "Declarative worker_agents count does not match expectations.") -Details @{ expected = [int]$expectation.expectedWorkerCount; actual = $workerCount }))

    $workerIds = @($record.Json.worker_agents | ForEach-Object { $_.id })
    $dependencyCoverage = @(
        foreach ($expectedDep in $expectedDeps) {
            $placeholderToken = "{{$expectedDep}}"
            $resolvedId = if ($resolvedTitleIds.ContainsKey($expectedDep)) { $resolvedTitleIds[$expectedDep] } else { $null }
            $matchedIds = @($workerIds | Where-Object { $_ -eq $placeholderToken -or (($null -ne $resolvedId) -and $_ -eq $resolvedId) })

            [pscustomobject]@{
                dependency = $expectedDep
                placeholder = $placeholderToken
                resolvedId = $resolvedId
                matchedIds = $matchedIds
            }
        }
    )
    $missingDependencies = @($dependencyCoverage | Where-Object { $_.matchedIds.Count -eq 0 } | ForEach-Object { $_.dependency })
    $unexpectedWorkers = @(
        foreach ($workerId in $workerIds) {
            $matchingDeps = @($dependencyCoverage | Where-Object { $_.placeholder -eq $workerId -or (($null -ne $_.resolvedId) -and $_.resolvedId -eq $workerId) })
            if ($matchingDeps.Count -eq 0) {
                $workerId
            }
        }
    )
    $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-worker-id-membership" -Passed (($missingDependencies.Count -eq 0) -and ($unexpectedWorkers.Count -eq 0)) -Message (((($missingDependencies.Count -eq 0) -and ($unexpectedWorkers.Count -eq 0))) ? "Worker IDs align to the expected placeholder or resolved-ID contract." : "Worker IDs do not align to the expected placeholder or resolved-ID contract.") -Details @{ actual = $workerIds; missingDependencies = $missingDependencies; unexpectedWorkers = $unexpectedWorkers; expected = $dependencyCoverage }))

    $invalidWorkers = @(
        foreach ($workerId in $workerIds) {
            $validation = Test-WorkerId -Id $workerId -RequireResolvedTitleIds:$RequireResolvedTitleIds
            if (-not $validation.Passed) {
                [pscustomobject]@{ id = $workerId; reason = $validation.Reason }
            }
        }
    )
    $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-worker-id-format" -Passed ($invalidWorkers.Count -eq 0) -Message (($invalidWorkers.Count -eq 0) ? "Worker IDs have the expected format." : "One or more worker IDs have an unexpected format.") -Details @{ invalid = $invalidWorkers; requireResolvedTitleIds = $RequireResolvedTitleIds.IsPresent }))

    if ($RequireResolvedTitleIds) {
        $missingResolvedDeps = @($expectedDeps | Where-Object { -not $resolvedTitleIds.ContainsKey($_) })
        $placeholderWorkers = @($workerIds | Where-Object { $_ -match '^\{\{[A-Z0-9_]+\}\}$' })
        $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-resolved-dependencies" -Passed ($missingResolvedDeps.Count -eq 0) -Message (($missingResolvedDeps.Count -eq 0) ? "Resolved title IDs exist for every expected dependency." : "One or more expected dependencies do not have resolved title IDs in env files.") -Details @{ missing = $missingResolvedDeps }))
        $results.Add((New-TestResult -Suite $suite -Name "$($expectation.agentId)-no-placeholder-workers" -Passed ($placeholderWorkers.Count -eq 0) -Message (($placeholderWorkers.Count -eq 0) ? "Worker IDs are fully resolved in resolved-ID mode." : "One or more worker IDs are still placeholders in resolved-ID mode.") -Details @{ placeholders = $placeholderWorkers }))
    }
}

Save-TestReport -Suite $suite -Results $results -ReportPath $ReportPath

$failed = @($results | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) {
    $failedNames = $failed | ForEach-Object { $_.name }
    throw "Worker wiring validation failed: $($failedNames -join ', ')"
}

Write-Host "Worker wiring validation passed for $($expectations.Count) dependency contracts."
