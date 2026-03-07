[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ReportPath = (Join-Path $PSScriptRoot "reports\validate-routing.json")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\TestHarness.ps1")

$repoRoot = Get-TestRepoRoot -ProjectRoot $ProjectRoot
$manifest = Get-AgentManifestData -RepoRoot $repoRoot
$cases = Get-Content -Path (Join-Path $PSScriptRoot "test-data\routing-cases.json") -Raw | ConvertFrom-Json
$records = @{}
foreach ($record in Get-AllDeclarativeAgentRecords -RepoRoot $repoRoot) {
    $records[$record.Entry.id] = $record
}

$primary = $records["fsi-primary-agent"]
$suite = "validate-routing"
$results = [System.Collections.Generic.List[object]]::new()

foreach ($case in $cases) {
    $targetEntry = @($manifest.agents | Where-Object { $_.id -eq $case.targetAgentId })[0]
    $targetRecord = $records[$case.targetAgentId]

    $results.Add((New-TestResult -Suite $suite -Name "$($case.id)-target-exists" -Passed ($null -ne $targetEntry -and $null -ne $targetRecord) -Message ((($null -ne $targetEntry) -and ($null -ne $targetRecord)) ? "Target agent exists in the manifest and on disk." : "Target agent is missing from the manifest or declarative manifests.") -Details @{ targetAgentId = $case.targetAgentId }))

    if ($null -eq $targetEntry -or $null -eq $targetRecord) {
        continue
    }

    $missingOrchestratorPhrases = Assert-ContainsAllPhrases -Content $primary.Json.instructions -Phrases @($case.orchestratorRequiredPhrases)
    $results.Add((New-TestResult -Suite $suite -Name "$($case.id)-orchestrator-contract" -Passed ($missingOrchestratorPhrases.Count -eq 0) -Message (($missingOrchestratorPhrases.Count -eq 0) ? "Primary orchestrator contains the expected routing guidance." : "Primary orchestrator is missing routing phrases.") -Details @{ missing = $missingOrchestratorPhrases; query = $case.query }))

    $missingTargetPhrases = Assert-ContainsAllPhrases -Content $targetRecord.Json.instructions -Phrases @($case.targetRequiredPhrases)
    $results.Add((New-TestResult -Suite $suite -Name "$($case.id)-target-contract" -Passed ($missingTargetPhrases.Count -eq 0) -Message (($missingTargetPhrases.Count -eq 0) ? "Target agent instructions cover the expected response contract." : "Target agent is missing required response phrases.") -Details @{ missing = $missingTargetPhrases; targetAgentId = $case.targetAgentId }))

    $hasTargetDependency = @($manifest.agents | Where-Object { $_.id -eq "fsi-primary-agent" }).workerAgentDeps -contains $targetEntry.titleIdPlaceholder
    $results.Add((New-TestResult -Suite $suite -Name "$($case.id)-primary-dependency" -Passed $hasTargetDependency -Message ($hasTargetDependency ? "FSI Primary is wired to the expected target agent." : "FSI Primary is not wired to the expected target agent.") -Details @{ targetPlaceholder = $targetEntry.titleIdPlaceholder }))

    $hasWebSearch = @($targetRecord.Json.capabilities | Where-Object { $_.name -eq "WebSearch" }).Count -gt 0
    $results.Add((New-TestResult -Suite $suite -Name "$($case.id)-target-websearch" -Passed $hasWebSearch -Message ($hasWebSearch ? "Target agent has WebSearch enabled for fallback use." : "Target agent is missing WebSearch capability.") -Details @{ targetAgentId = $case.targetAgentId }))
}

Save-TestReport -Suite $suite -Results $results -ReportPath $ReportPath

$failed = @($results | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) {
    $failedNames = $failed | ForEach-Object { $_.name }
    throw "Routing validation failed: $($failedNames -join ', ')"
}

Write-Host "Routing validation passed for $($cases.Count) query contracts."
