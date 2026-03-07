[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ReportDir = (Join-Path $PSScriptRoot "reports"),
    [switch]$RequireResolvedTitleIds
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\TestHarness.ps1")

$repoRoot = Get-TestRepoRoot -ProjectRoot $ProjectRoot
$enginePath = (Get-Process -Id $PID).Path
$suiteRoot = $PSScriptRoot

if (-not (Test-Path $ReportDir)) {
    $null = New-Item -Path $ReportDir -ItemType Directory -Force
}

$suites = @(
    @{ Name = "validate-manifests"; Path = (Join-Path $suiteRoot "validate-manifests.ps1"); Args = @() },
    @{ Name = "validate-routing"; Path = (Join-Path $suiteRoot "validate-routing.ps1"); Args = @() },
    @{ Name = "validate-agent-contracts"; Path = (Join-Path $suiteRoot "validate-agent-contracts.ps1"); Args = @() },
    @{ Name = "validate-worker-wiring"; Path = (Join-Path $suiteRoot "validate-worker-wiring.ps1"); Args = @(if ($RequireResolvedTitleIds) { "-RequireResolvedTitleIds" } else { $null }) }
)

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($suite in $suites) {
    $reportPath = Join-Path $ReportDir "$($suite.Name).json"
    $suiteArgs = @("-NoProfile", "-File", $suite.Path, "-ProjectRoot", $repoRoot, "-ReportPath", $reportPath)
    $suiteArgs += @($suite.Args | Where-Object { $null -ne $_ })

    Write-Host "Running $($suite.Name)..." -ForegroundColor Cyan
    $output = & $enginePath @suiteArgs 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if (-not (Test-Path $reportPath)) {
        throw "Test suite '$($suite.Name)' did not generate a report at $reportPath.`n$output"
    }

    $report = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
    $summary.Add([pscustomobject]@{
        name = $suite.Name
        success = [bool]$report.success
        failed = [int]$report.failed
        passed = [int]$report.passed
        report = $reportPath
        exitCode = $exitCode
    })

    if ($exitCode -eq 0) {
        Write-Host "  PASS $($suite.Name)" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL $($suite.Name)" -ForegroundColor Red
        Write-Host ($output.Trim()) -ForegroundColor DarkGray
    }
}

$summaryObject = [pscustomobject]@{
    generatedAt = (Get-Date).ToString("o")
    projectRoot = $repoRoot
    requireResolvedTitleIds = $RequireResolvedTitleIds.IsPresent
    suites = $summary
    success = (@($summary | Where-Object { -not $_.success }).Count -eq 0)
}

$summaryPath = Join-Path $ReportDir "summary.json"
$summaryObject | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath

Write-Host ""
Write-Host "Test summary:" -ForegroundColor Cyan
foreach ($item in $summary) {
    $status = if ($item.success) { "PASS" } else { "FAIL" }
    $color = if ($item.success) { "Green" } else { "Red" }
    Write-Host ("  {0} {1} (passed: {2}, failed: {3})" -f $status, $item.name, $item.passed, $item.failed) -ForegroundColor $color
}
Write-Host "Summary report: $summaryPath"

if (-not $summaryObject.success) {
    throw "One or more validation suites failed."
}
