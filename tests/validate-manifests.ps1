[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ReportPath = (Join-Path $PSScriptRoot "reports\validate-manifests.json")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\TestHarness.ps1")

$repoRoot = Get-TestRepoRoot -ProjectRoot $ProjectRoot
$records = Get-AllDeclarativeAgentRecords -RepoRoot $repoRoot
$results = [System.Collections.Generic.List[object]]::new()
$suite = "validate-manifests"

foreach ($record in $records) {
    $name = $record.Entry.id
    $json = $record.Json

    $requiredProps = @("name", "description", "instructions", "capabilities")
    $missingProps = @(
        foreach ($prop in $requiredProps) {
        if (-not ($json.PSObject.Properties.Name -contains $prop)) {
            $prop
        }
    }
    )

    $results.Add((New-TestResult -Suite $suite -Name "$name-required-properties" -Passed ($missingProps.Count -eq 0) -Message (($missingProps.Count -eq 0) ? "Required manifest properties are present." : "Missing properties: $($missingProps -join ', ').") -Details @{ path = $record.Path; missing = $missingProps }))

    $instructionsLength = $json.instructions.Length
    $results.Add((New-TestResult -Suite $suite -Name "$name-instructions-length" -Passed ($instructionsLength -le 8000) -Message (($instructionsLength -le 8000) ? "Instruction length is within schema limits." : "Instruction length exceeds 8000 characters.") -Details @{ path = $record.Path; length = $instructionsLength }))

    $hasEmptyActions = ($json.PSObject.Properties.Name -contains "actions") -and (@($json.actions).Count -eq 0)
    $results.Add((New-TestResult -Suite $suite -Name "$name-empty-actions" -Passed (-not $hasEmptyActions) -Message ((-not $hasEmptyActions) ? "No empty actions array is present." : "actions property exists but is empty.") -Details @{ path = $record.Path }))

    $hasConversationStarters = ($json.PSObject.Properties.Name -contains "conversation_starters") -and (@($json.conversation_starters).Count -gt 0)
    $results.Add((New-TestResult -Suite $suite -Name "$name-conversation-starters" -Passed $hasConversationStarters -Message ($hasConversationStarters ? "Conversation starters are present." : "conversation_starters is missing or empty.") -Details @{ path = $record.Path }))

    $webSearchCapability = @($json.capabilities | Where-Object { $_.name -eq "WebSearch" })
    if ($webSearchCapability.Count -gt 0) {
        $sites = @($webSearchCapability[0].sites)
        $siteCountValid = ($sites.Count -ge 1) -and ($sites.Count -le 4)
        $siteUrlsValid = @($sites | Where-Object { -not $_.url }).Count -eq 0

        $results.Add((New-TestResult -Suite $suite -Name "$name-websearch-site-count" -Passed $siteCountValid -Message ($siteCountValid ? "WebSearch site list is within schema limits." : "WebSearch site count must be between 1 and 4.") -Details @{ path = $record.Path; siteCount = $sites.Count }))

        $results.Add((New-TestResult -Suite $suite -Name "$name-websearch-site-urls" -Passed $siteUrlsValid -Message ($siteUrlsValid ? "WebSearch site entries all contain URLs." : "One or more WebSearch site entries are missing a URL.") -Details @{ path = $record.Path }))
    }

    if ([int]$record.Entry.tier -ge 2) {
        $hasWorkers = @($json.worker_agents).Count -gt 0
        $results.Add((New-TestResult -Suite $suite -Name "$name-worker-agents" -Passed $hasWorkers -Message ($hasWorkers ? "Worker agents are configured." : "Tier 2+ agent is missing worker_agents.") -Details @{ path = $record.Path; workerCount = @($json.worker_agents).Count }))
    }
}

Save-TestReport -Suite $suite -Results $results -ReportPath $ReportPath

$failed = @($results | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) {
    $failedNames = $failed | ForEach-Object { $_.name }
    throw "Manifest validation failed: $($failedNames -join ', ')"
}

Write-Host "Manifest validation passed for $($records.Count) declarative agent manifests."
