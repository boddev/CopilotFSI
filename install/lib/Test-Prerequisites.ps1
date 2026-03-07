# Test-Prerequisites.ps1
# Prerequisites checker for FSI Copilot agent deployment.
# Dot-source this file from the main installer script.

function Test-FSIPrerequisites {
    [CmdletBinding()]
    param(
        [switch]$AutoInstall
    )

    $results = @()
    $nodeVersion = $null
    $atkVersion = $null

    # ── 1. PowerShell version (>= 7.0) ──
    try {
        $psVer = $PSVersionTable.PSVersion
        if ($psVer.Major -ge 7) {
            $results += [PSCustomObject]@{ Name = 'PowerShell'; Status = 'Pass'; Version = "$psVer"; Message = "PowerShell $psVer" }
        } else {
            $results += [PSCustomObject]@{ Name = 'PowerShell'; Status = 'Fail'; Version = "$psVer"; Message = "PowerShell $psVer found — version 7.0+ is required. Install from https://aka.ms/powershell" }
        }
    } catch {
        $results += [PSCustomObject]@{ Name = 'PowerShell'; Status = 'Fail'; Version = $null; Message = "Unable to determine PowerShell version: $_" }
    }

    # ── 2. Node.js (>= 18.0) ──
    try {
        $nodeOut = & node --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "node exited with code $LASTEXITCODE" }
        $nodeVersionRaw = ($nodeOut | Out-String).Trim().TrimStart('v')
        $nodeParsed = [version]$nodeVersionRaw
        $nodeVersion = $nodeVersionRaw
        if ($nodeParsed.Major -ge 18) {
            $results += [PSCustomObject]@{ Name = 'Node.js'; Status = 'Pass'; Version = $nodeVersionRaw; Message = "Node.js $nodeVersionRaw" }
        } else {
            $results += [PSCustomObject]@{ Name = 'Node.js'; Status = 'Fail'; Version = $nodeVersionRaw; Message = "Node.js $nodeVersionRaw found — version 18.0+ is required. Download from https://nodejs.org" }
        }
    } catch {
        $results += [PSCustomObject]@{ Name = 'Node.js'; Status = 'Fail'; Version = $null; Message = "Node.js not found. Download from https://nodejs.org" }
    }

    # ── 3. npm ──
    try {
        $npmOut = & npm --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "npm exited with code $LASTEXITCODE" }
        $npmVersion = ($npmOut | Out-String).Trim()
        $results += [PSCustomObject]@{ Name = 'npm'; Status = 'Pass'; Version = $npmVersion; Message = "npm $npmVersion" }
    } catch {
        $results += [PSCustomObject]@{ Name = 'npm'; Status = 'Fail'; Version = $null; Message = "npm not found — it should be included with Node.js. Reinstall Node.js from https://nodejs.org" }
    }

    # ── 4. M365 Agents Toolkit CLI (atk) ──
    try {
        $atkOut = & atk --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "atk exited with code $LASTEXITCODE" }
        $atkVersion = ($atkOut | Out-String).Trim()
        $results += [PSCustomObject]@{ Name = 'M365 Agents Toolkit CLI'; Status = 'Pass'; Version = $atkVersion; Message = "M365 Agents Toolkit CLI $atkVersion" }
    } catch {
        if ($AutoInstall) {
            Write-Host '  Installing M365 Agents Toolkit CLI (atk)...' -ForegroundColor Yellow
            try {
                # Use Start-Process to avoid PowerShell treating npm stderr warnings as errors
                $npmPrefix = (& npm config get prefix 2>$null | Out-String).Trim()
                $proc = Start-Process -FilePath 'npm' `
                    -ArgumentList 'install', '-g', '@microsoft/m365agentstoolkit-cli' `
                    -NoNewWindow -Wait -PassThru
                if ($proc.ExitCode -ne 0) {
                    throw "npm install exited with code $($proc.ExitCode)"
                }

                # Ensure npm global bin directory is on PATH for this session
                if ($npmPrefix -and ($env:PATH -notlike "*$npmPrefix*")) {
                    $env:PATH = "$npmPrefix;$env:PATH"
                }

                $atkOut2 = & atk --version 2>&1
                if ($LASTEXITCODE -ne 0) { throw "atk installed but not found on PATH: $($atkOut2 | Out-String)" }
                $atkVersion = ($atkOut2 | Out-String).Trim()
                $results += [PSCustomObject]@{ Name = 'M365 Agents Toolkit CLI'; Status = 'Pass'; Version = $atkVersion; Message = "M365 Agents Toolkit CLI $atkVersion (auto-installed)" }
            } catch {
                $results += [PSCustomObject]@{ Name = 'M365 Agents Toolkit CLI'; Status = 'Fail'; Version = $null; Message = "Auto-install failed: $_. Run manually: npm install -g @microsoft/m365agentstoolkit-cli" }
            }
        } else {
            $results += [PSCustomObject]@{ Name = 'M365 Agents Toolkit CLI'; Status = 'Warn'; Version = $null; Message = "atk not found. Install with: npm install -g @microsoft/m365agentstoolkit-cli" }
        }
    }

    # ── 5. M365 Authentication ──
    try {
        $authOut = & atk auth list 2>&1
        $authText = ($authOut | Out-String).Trim()
        if ($authText -match 'logged in' -or $authText -match 'account') {
            $results += [PSCustomObject]@{ Name = 'M365 Auth'; Status = 'Pass'; Version = $null; Message = 'M365 Auth — logged in' }
        } else {
            $results += [PSCustomObject]@{ Name = 'M365 Auth'; Status = 'Warn'; Version = $null; Message = 'M365 Auth — not logged in (will prompt during install)' }
        }
    } catch {
        $results += [PSCustomObject]@{ Name = 'M365 Auth'; Status = 'Warn'; Version = $null; Message = 'M365 Auth — not logged in (will prompt during install)' }
    }

    # ── Display formatted results ──
    $boxWidth = 48
    $border = '═' * $boxWidth
    Write-Host "╔$border╗"
    Write-Host "║$(' ' * 5)FSI Copilot — Prerequisites Check$(' ' * ($boxWidth - 39))║"
    Write-Host "╠$border╣"

    foreach ($r in $results) {
        switch ($r.Status) {
            'Pass' {
                $icon = '✅'
                $color = 'Green'
            }
            'Fail' {
                $icon = '❌'
                $color = 'Red'
            }
            'Warn' {
                $icon = '⚠️ '
                $color = 'Yellow'
            }
        }
        $text = " $icon $($r.Message)"
        $pad = $boxWidth - $text.Length
        if ($pad -lt 0) { $pad = 0 }
        # Truncate long messages to fit the box
        if ($text.Length -gt $boxWidth) {
            $text = $text.Substring(0, $boxWidth - 1) + '…'
            $pad = 0
        }
        Write-Host -NoNewline '║'
        Write-Host -NoNewline $text -ForegroundColor $color
        Write-Host "$(' ' * $pad)║"
    }

    Write-Host "╚$border╝"

    $allPassed = ($results | Where-Object { $_.Status -eq 'Fail' }).Count -eq 0

    return [PSCustomObject]@{
        AllPassed   = $allPassed
        Results     = $results
        NodeVersion = $nodeVersion
        AtkVersion  = $atkVersion
    }
}
