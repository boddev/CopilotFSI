[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ReportPath = (Join-Path $PSScriptRoot "reports\validate-agent-contracts.json")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\TestHarness.ps1")

$repoRoot = Get-TestRepoRoot -ProjectRoot $ProjectRoot
$contracts = Get-Content -Path (Join-Path $PSScriptRoot "test-data\agent-contracts.json") -Raw | ConvertFrom-Json
$records = @{}
foreach ($record in Get-AllDeclarativeAgentRecords -RepoRoot $repoRoot) {
    $records[$record.Entry.id] = $record
}

$suite = "validate-agent-contracts"
$results = [System.Collections.Generic.List[object]]::new()

foreach ($contract in $contracts) {
    $record = $records[$contract.agentId]
    $results.Add((New-TestResult -Suite $suite -Name "$($contract.agentId)-exists" -Passed ($null -ne $record) -Message (($null -ne $record) ? "Agent exists for contract validation." : "Agent manifest is missing for contract validation.") -Details @{ agentId = $contract.agentId }))

    if ($null -eq $record) {
        continue
    }

    $missingRequired = Assert-ContainsAllPhrases -Content $record.Json.instructions -Phrases @($contract.requiredPhrases)
    $results.Add((New-TestResult -Suite $suite -Name "$($contract.agentId)-required-phrases" -Passed ($missingRequired.Count -eq 0) -Message (($missingRequired.Count -eq 0) ? "All required behavior phrases are present." : "Agent is missing one or more required phrases.") -Details @{ missing = $missingRequired }))

    $presentForbidden = Assert-ContainsNoneOfPhrases -Content $record.Json.instructions -Phrases @($contract.forbiddenPhrases)
    $results.Add((New-TestResult -Suite $suite -Name "$($contract.agentId)-forbidden-phrases" -Passed ($presentForbidden.Count -eq 0) -Message (($presentForbidden.Count -eq 0) ? "No forbidden phrases were found." : "Agent still contains forbidden phrases.") -Details @{ present = $presentForbidden }))

    foreach ($capabilityName in @($contract.requiredCapabilities)) {
        $hasCapability = @($record.Json.capabilities | Where-Object { $_.name -eq $capabilityName }).Count -gt 0
        $results.Add((New-TestResult -Suite $suite -Name "$($contract.agentId)-capability-$capabilityName" -Passed $hasCapability -Message ($hasCapability ? "Required capability '$capabilityName' is present." : "Required capability '$capabilityName' is missing.") -Details @{ capability = $capabilityName }))
    }
}

Save-TestReport -Suite $suite -Results $results -ReportPath $ReportPath

$failed = @($results | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) {
    $failedNames = $failed | ForEach-Object { $_.name }
    throw "Agent contract validation failed: $($failedNames -join ', ')"
}

Write-Host "Agent contract validation passed for $($contracts.Count) agent contracts."
