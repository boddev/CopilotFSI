function Set-OAuthCredentials {
    <#
    .SYNOPSIS
        Collects OAuth credentials for MCP providers, injects oauth/register into
        m365agents.yml, and updates ai-plugin auth from None to OAuthPluginVault.
    .DESCRIPTION
        For each selected MCP provider that uses OAuthPluginVault authentication:
        1. Checks if OAuth endpoint URLs are configured (not placeholders)
        2. Prompts user for client ID and client secret
        3. Writes OAuth env vars to the agent's .env file
        4. Injects the oauth/register lifecycle step into m365agents.yml
        5. Updates the ai-plugin JSON auth from None to OAuthPluginVault with reference_id

        If OAuth endpoints are not configured or the user skips a provider,
        that provider deploys with auth type None (no login prompt, MCP calls
        may fail if the server requires auth, but the agent itself still deploys
        and skill agents can fall back to WebSearch).
    .PARAMETER SelectedProviders
        Hashtable of selected provider IDs to URLs (from Show-McpSelector).
    .PARAMETER ConfigPath
        Path to mcp-providers.json configuration file.
    .PARAMETER ProjectRoot
        Root path of the CopilotFSI project.
    .PARAMETER Environment
        The atk environment name (default: "prod").
    .PARAMETER NonInteractive
        Skip prompting; expect credentials to already exist in env files.
    .PARAMETER DryRun
        Show what would be written without modifying any files.
    .OUTPUTS
        System.Int32 — count of providers configured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SelectedProviders,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$Environment = "prod",

        [switch]$NonInteractive,

        [switch]$DryRun
    )

    $configuredCount = 0

    # Load provider configuration
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "MCP providers config not found: $ConfigPath"
        return 0
    }

    try {
        $providersConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse MCP providers config: $_"
        return 0
    }

    # Find OAuth providers among selected providers
    $oauthProviders = @()
    foreach ($providerId in $SelectedProviders.Keys) {
        $providerEntry = $providersConfig.providers | Where-Object { $_.id -eq $providerId }
        if (-not $providerEntry) { continue }
        if ($providerEntry.authType -ne 'OAuthPluginVault') { continue }
        if (-not $providerEntry.oauth) { continue }

        # Skip providers whose OAuth URLs are still placeholders
        $authUrl = $providerEntry.oauth.authorizationUrl
        if ($authUrl -match '^\{\{.*\}\}$') {
            Write-Host "  ⏭️  $($providerEntry.name) — OAuth endpoints not configured, deploying without auth" -ForegroundColor DarkGray
            Write-Host "     Edit mcp-providers.json to set OAuth URLs for this provider" -ForegroundColor DarkGray
            continue
        }

        $oauthProviders += $providerEntry
    }

    if ($oauthProviders.Count -eq 0) {
        Write-Host "  No OAuth providers require credential setup" -ForegroundColor DarkGray
        return 0
    }

    foreach ($provider in $oauthProviders) {
        $envPrefix = $provider.oauth.envPrefix
        if (-not $envPrefix) {
            $envPrefix = ($provider.id -replace '-', '_').ToUpper() + "_OAUTH"
        }

        # Determine agent root from pluginFiles path
        $agentRoot = $null
        $pluginFullPath = $null
        if ($provider.pluginFiles -and $provider.pluginFiles.Count -gt 0) {
            $pluginRelPath = $provider.pluginFiles[0]
            $pluginFullPath = Join-Path $ProjectRoot $pluginRelPath
            # Agent root is 2 levels up: appPackage -> agent folder
            $agentRoot = Split-Path (Split-Path $pluginFullPath -Parent) -Parent
        }

        if (-not $agentRoot) {
            Write-Warning "  Could not determine agent directory for $($provider.name) — skipping"
            continue
        }

        $agentEnvDir = Join-Path $agentRoot "env"
        $envFile = Join-Path $agentEnvDir ".env.$Environment"
        $yamlFile = Join-Path $agentRoot "m365agents.yml"

        Write-Host ""
        Write-Host "  🔐 $($provider.name) OAuth Configuration" -ForegroundColor Cyan

        # --- Collect credentials ---
        $clientId = $null
        $clientSecret = $null

        if ($NonInteractive) {
            if (Test-Path $envFile) {
                $existingContent = Get-Content -Path $envFile -Raw
                if ($existingContent -match "${envPrefix}_CLIENT_ID=(.+)") {
                    $clientId = $Matches[1].Trim()
                    Write-Host "    ✅ Credentials already present in env file" -ForegroundColor Green
                }
            }
            if (-not $clientId) {
                Write-Host "    ⚠️  No credentials found — set ${envPrefix}_CLIENT_ID and ${envPrefix}_CLIENT_SECRET in $envFile" -ForegroundColor Yellow
                Write-Host "    Agent will deploy without OAuth (auth: None)" -ForegroundColor Yellow
                continue
            }
        }
        else {
            $clientId = Read-Host "    Enter Client ID for $($provider.name) (press Enter to skip)"
            if ([string]::IsNullOrWhiteSpace($clientId)) {
                Write-Host "    ⏭️  Skipped — agent will deploy without OAuth (auth: None)" -ForegroundColor DarkGray
                continue
            }

            $clientSecretSecure = Read-Host "    Enter Client Secret for $($provider.name)" -AsSecureString
            $clientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecretSecure)
            )

            if ([string]::IsNullOrWhiteSpace($clientSecret)) {
                Write-Host "    ⏭️  Skipped — agent will deploy without OAuth (auth: None)" -ForegroundColor DarkGray
                continue
            }
        }

        # --- Build env vars ---
        $envVars = @(
            "${envPrefix}_CLIENT_ID=$clientId"
        )
        if ($clientSecret) {
            $envVars += "${envPrefix}_CLIENT_SECRET=$clientSecret"
        }
        $envVars += @(
            "${envPrefix}_AUTH_URL=$($provider.oauth.authorizationUrl)",
            "${envPrefix}_TOKEN_URL=$($provider.oauth.tokenUrl)",
            "${envPrefix}_REFRESH_URL=$($provider.oauth.refreshUrl)",
            "${envPrefix}_SCOPE=$($provider.oauth.scope)"
        )

        # --- Build oauth/register YAML block ---
        $oauthName = ($provider.id -replace '-', '-') + "-oauth"
        $yamlBlock = @"

  - uses: oauth/register
    with:
      name: $oauthName-`${{TEAMSFX_ENV}}
      flow: authorizationCode
      clientId: `${{${envPrefix}_CLIENT_ID}}
      clientSecret: `${{${envPrefix}_CLIENT_SECRET}}
      authorizationUrl: `${{${envPrefix}_AUTH_URL}}
      tokenUrl: `${{${envPrefix}_TOKEN_URL}}
      refreshUrl: `${{${envPrefix}_REFRESH_URL}}
      scope: `${{${envPrefix}_SCOPE}}
    writeToEnvironmentFile:
      configurationId: ${envPrefix}_CONFIGURATION_ID
"@

        $configIdRef = "`${{${envPrefix}_CONFIGURATION_ID}}"

        if ($DryRun) {
            Write-Host "    [DRY RUN] Would write OAuth env vars to $envFile" -ForegroundColor Yellow
            foreach ($v in $envVars) {
                if ($v -match '_CLIENT_SECRET=') {
                    Write-Host "      $($v.Split('=')[0])=********" -ForegroundColor Yellow
                } else {
                    Write-Host "      $v" -ForegroundColor Yellow
                }
            }
            Write-Host "    [DRY RUN] Would inject oauth/register into $yamlFile" -ForegroundColor Yellow
            Write-Host "    [DRY RUN] Would update auth in $pluginFullPath" -ForegroundColor Yellow
        }
        else {
            # 1. Write env vars
            if (-not (Test-Path $agentEnvDir)) {
                New-Item -Path $agentEnvDir -ItemType Directory -Force | Out-Null
            }

            $newContent = "`n# OAuth credentials for $($provider.name)`n"
            $newContent += ($envVars -join "`n") + "`n"

            if (Test-Path $envFile) {
                $existingContent = Get-Content -Path $envFile -Raw
                if ($existingContent -match "${envPrefix}_CLIENT_ID=") {
                    foreach ($envVar in $envVars) {
                        $key = $envVar.Split('=')[0]
                        $existingContent = $existingContent -replace "(?m)^${key}=.*$", $envVar
                    }
                    Set-Content -Path $envFile -Value $existingContent -Encoding UTF8 -NoNewline
                }
                else {
                    Add-Content -Path $envFile -Value $newContent -Encoding UTF8
                }
            }
            else {
                Set-Content -Path $envFile -Value $newContent.TrimStart() -Encoding UTF8 -NoNewline
            }
            Write-Host "    ✅ Credentials written to env file" -ForegroundColor Green

            # 2. Inject oauth/register into m365agents.yml (before teamsApp/zipAppPackage)
            if (Test-Path $yamlFile) {
                $yamlContent = Get-Content -Path $yamlFile -Raw
                if ($yamlContent -notmatch 'oauth/register') {
                    # Insert before the first teamsApp/zipAppPackage line
                    $yamlContent = $yamlContent -replace '(\n  - uses: teamsApp/zipAppPackage)', ($yamlBlock + '$1')
                    Set-Content -Path $yamlFile -Value $yamlContent -Encoding UTF8 -NoNewline
                    Write-Host "    ✅ Injected oauth/register into m365agents.yml" -ForegroundColor Green
                }
                else {
                    Write-Host "    ✅ oauth/register already present in m365agents.yml" -ForegroundColor Green
                }
            }
            else {
                Write-Warning "    m365agents.yml not found at $yamlFile"
            }

            # 3. Update ai-plugin JSON auth from None to OAuthPluginVault
            if ($pluginFullPath -and (Test-Path $pluginFullPath)) {
                $pluginContent = Get-Content -Path $pluginFullPath -Raw

                # Replace "type": "None" with OAuthPluginVault + reference_id in the auth block
                # Handle both compact and indented JSON formats
                $pluginContent = $pluginContent -replace `
                    '("auth"\s*:\s*\{[^}]*"type"\s*:\s*)"None"(\s*\})', `
                    ('$1"OAuthPluginVault",' + "`n" + '                                      "reference_id": "' + $configIdRef + '"' + "`n" + '                                  }')

                Set-Content -Path $pluginFullPath -Value $pluginContent -Encoding UTF8 -NoNewline
                Write-Host "    ✅ Updated ai-plugin auth to OAuthPluginVault" -ForegroundColor Green
            }
        }

        $configuredCount++
    }

    return $configuredCount
}
