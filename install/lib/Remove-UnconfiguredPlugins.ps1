function Remove-UnconfiguredPlugins {
    <#
    .SYNOPSIS
        Removes ai-plugin-*.json files that still contain {{MCP_HOST}} placeholders.
    .DESCRIPTION
        After MCP URL configuration, any plugin files still containing the {{MCP_HOST}}
        placeholder correspond to providers that were not selected. These files must be
        removed before provisioning because ATK's zipAppPackage includes all files in
        appPackage/ and validateAppPackage will reject unresolved placeholders.

        Only cleans up agents that have at least one OTHER configured plugin file
        (without {{MCP_HOST}}), so agents where ALL plugins are unconfigured are left
        alone and correctly skipped by Test-AgentReady.

        The corresponding action references in declarativeAgent.json are also removed
        so the agent provisions cleanly with only its configured plugins.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .PARAMETER DryRun
        If specified, logs what would change without modifying any files.
    .OUTPUTS
        System.Int32 — count of plugin files removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [switch]$DryRun
    )

    $removedCount = 0
    $agentsDir = Join-Path $ProjectRoot "agents"

    if (-not (Test-Path $agentsDir)) {
        Write-Warning "Agents directory not found: $agentsDir"
        return 0
    }

    # Find all appPackage directories that contain ai-plugin-*.json files
    $pluginFiles = Get-ChildItem -Path $agentsDir -Filter "ai-plugin-*.json" -Recurse |
        Where-Object { $_.Directory.Name -eq "appPackage" }

    if ($pluginFiles.Count -eq 0) {
        return 0
    }

    # Group by appPackage directory so we can check per-agent
    $groupedByDir = $pluginFiles | Group-Object { $_.Directory.FullName }

    foreach ($group in $groupedByDir) {
        $appPackageDir = $group.Name
        $allPlugins = @($group.Group)

        # Classify each plugin as configured or unconfigured
        $configured = @()
        $unconfigured = @()

        foreach ($pf in $allPlugins) {
            $content = Get-Content -Path $pf.FullName -Raw
            if ($content -match '\{\{MCP_HOST\}\}') {
                $unconfigured += $pf
            } else {
                $configured += $pf
            }
        }

        # Skip if nothing to clean up
        if ($unconfigured.Count -eq 0) { continue }

        # Only clean up if at least one configured plugin remains.
        # This prevents stripping Tier 0 MCP connector agents down to zero plugins
        # when none of their providers were selected (they should stay skipped).
        if ($configured.Count -eq 0) {
            Write-Verbose "  Skipping $appPackageDir — all plugins unconfigured, leaving for Test-AgentReady to skip"
            continue
        }

        # Remove each unconfigured plugin file and its declarativeAgent.json reference
        foreach ($pf in $unconfigured) {
            $pluginFileName = $pf.Name

            if ($DryRun) {
                Write-Host "  [DRY RUN] Would remove: $pluginFileName from $(Split-Path $appPackageDir -Parent | Split-Path -Leaf)" -ForegroundColor Yellow
            } else {
                Remove-Item -Path $pf.FullName -Force
                Write-Host "  Removed: $pluginFileName from $(Split-Path $appPackageDir -Parent | Split-Path -Leaf)" -ForegroundColor DarkGray
            }
            $removedCount++

            # Update declarativeAgent.json to remove the dead action reference
            $daPath = Join-Path $appPackageDir "declarativeAgent.json"
            if (-not (Test-Path $daPath)) { continue }

            try {
                $daContent = Get-Content -Path $daPath -Raw | ConvertFrom-Json

                if (-not $daContent.actions -or $daContent.actions.Count -eq 0) { continue }

                $originalCount = $daContent.actions.Count
                $daContent.actions = @($daContent.actions | Where-Object { $_.file -ne $pluginFileName })

                if ($daContent.actions.Count -lt $originalCount) {
                    if ($DryRun) {
                        Write-Host "  [DRY RUN] Would update declarativeAgent.json: remove $pluginFileName reference" -ForegroundColor Yellow
                    } else {
                        $daContent | ConvertTo-Json -Depth 20 | Set-Content -Path $daPath -Encoding UTF8 -NoNewline
                        Write-Host "  Updated declarativeAgent.json: removed $pluginFileName reference" -ForegroundColor DarkGray
                    }
                }
            }
            catch {
                Write-Warning "Failed to update declarativeAgent.json in $appPackageDir`: $_"
            }
        }
    }

    return $removedCount
}
