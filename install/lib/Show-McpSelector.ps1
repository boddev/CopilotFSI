function Show-McpSelector {
    <#
    .SYNOPSIS
        Interactive terminal wizard for selecting MCP data providers.
    .DESCRIPTION
        Displays all available MCP providers grouped by category, allows the user
        to toggle selections with number keys, then prompts for server URLs.
    .PARAMETER ConfigPath
        Path to the mcp-providers.json configuration file.
    .OUTPUTS
        Hashtable of selected providers: @{ "provider-id" = "https://url"; ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    # --- Load provider config ---
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Config file not found: $ConfigPath"
        return @{}
    }

    $config = Get-Content -Raw $ConfigPath | ConvertFrom-Json

    # Display-name overrides for providers whose config name differs from desired display
    $displayNameMap = @{
        'lseg'   = 'LSEG / Refinitiv'
        'moodys' = "Moody's Analytics"
    }

    # Auth-type display labels
    $authTypeLabels = @{
        'OAuthPluginVault' = 'OAuth'
        'ApiKey'           = 'API Key'
        'None'             = 'Free'
    }

    # Providers pre-selected by default (built-in M365)
    $defaultSelectedIds = @('sharepoint-onedrive')

    # Build a flat ordered list grouped by category
    $providers = [System.Collections.ArrayList]::new()
    $seenCategories = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $config.providers) {
        if (-not $seenCategories.Contains($p.category)) {
            $seenCategories.Add($p.category)
        }
    }

    foreach ($cat in $seenCategories) {
        foreach ($p in ($config.providers | Where-Object { $_.category -eq $cat })) {
            $displayAuth = if ($authTypeLabels.ContainsKey($p.authType)) { $authTypeLabels[$p.authType] } else { $p.authType }
            $displayName = if ($displayNameMap.ContainsKey($p.id)) { $displayNameMap[$p.id] } else { $p.name }

            $isBuiltIn = ($p.PSObject.Properties['builtIn'] -and $p.builtIn)

            # Derive auth note from provider metadata
            $authNote = if ($isBuiltIn) {
                'built-in to Microsoft 365'
            } elseif ($p.authType -eq 'None') {
                'no auth required'
            } elseif ($p.PSObject.Properties['note'] -and $p.note) {
                $p.note
            } elseif ($p.officialMcp -and -not $p.publicUrl) {
                'MCP integration available'
            } elseif ($p.officialMcp -and $p.publicUrl) {
                'official MCP available'
            } elseif ($p.publicUrl) {
                'public endpoint available'
            } else {
                'Enterprise URL required'
            }

            [void]$providers.Add([PSCustomObject]@{
                Index       = $providers.Count + 1
                Id          = $p.id
                DisplayName = $displayName
                AuthDisplay = $displayAuth
                AuthNote    = $authNote
                PublicUrl   = $p.publicUrl
                UrlPattern  = $p.urlPattern
                Category    = $p.category.ToUpper()
                Selected    = $defaultSelectedIds -contains $p.id
                BuiltIn     = [bool]$isBuiltIn
            })
        }
    }

    # ===== Step 1: Provider selection =====
    $confirmed = $false
    while (-not $confirmed) {
        Clear-Host
        Write-Host ''
        Write-Host ([string]::new([char]0x2550, 55)) -ForegroundColor Cyan
        Write-Host '          FSI Copilot ' -NoNewline -ForegroundColor White
        Write-Host ([char]0x2014) -NoNewline -ForegroundColor DarkGray
        Write-Host ' MCP Server Configuration' -ForegroundColor White
        Write-Host ([string]::new([char]0x2550, 55)) -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Select the data providers your organization has access to.' -ForegroundColor Gray
        Write-Host "Enter numbers to toggle, 'a' for all, 'n' for none, ENTER to confirm." -ForegroundColor DarkGray
        Write-Host ''

        $currentCategory = ''
        foreach ($p in $providers) {
            if ($p.Category -ne $currentCategory) {
                $currentCategory = $p.Category
                Write-Host " $currentCategory" -ForegroundColor Yellow
            }

            $check = if ($p.Selected) { 'X' } else { ' ' }
            $num = $p.Index.ToString().PadLeft(3)
            $nameField = $p.DisplayName.PadRight(22)
            $authInfo = "$($p.AuthDisplay) $([char]0x2014) $($p.AuthNote)"

            if ($p.Selected) {
                Write-Host "$num. " -NoNewline -ForegroundColor White
                Write-Host "[$check] " -NoNewline -ForegroundColor Green
                Write-Host "$nameField" -NoNewline -ForegroundColor White
                Write-Host "($authInfo)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "$num. " -NoNewline -ForegroundColor DarkGray
                Write-Host "[$check] " -NoNewline -ForegroundColor DarkGray
                Write-Host "$nameField" -NoNewline -ForegroundColor Gray
                Write-Host "($authInfo)" -ForegroundColor DarkGray
            }
        }

        Write-Host ''
        $selectedCount = ($providers | Where-Object Selected).Count
        Write-Host "  $selectedCount of $($providers.Count) selected" -ForegroundColor Cyan
        Write-Host ''

        $userInput = Read-Host '>'

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            if ($selectedCount -eq 0) {
                Write-Host ''
                Write-Host '  WARNING: No providers selected.' -ForegroundColor Red
                Write-Host '  At least one provider is recommended.' -ForegroundColor Yellow
                Write-Host ''
                $proceed = Read-Host '  Continue with no providers? (y/N)'
                if ($proceed -eq 'y' -or $proceed -eq 'Y') {
                    return @{}
                }
            }
            else {
                $confirmed = $true
            }
        }
        elseif ($userInput -eq 'a' -or $userInput -eq 'A') {
            foreach ($p in $providers) { $p.Selected = $true }
        }
        elseif ($userInput -eq 'n' -or $userInput -eq 'N') {
            foreach ($p in $providers) { $p.Selected = $false }
        }
        else {
            # Parse space- or comma-separated numbers
            $tokens = $userInput -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
            foreach ($token in $tokens) {
                $idx = [int]$token
                $match = $providers | Where-Object { $_.Index -eq $idx }
                if ($match) {
                    $match.Selected = -not $match.Selected
                }
            }
        }
    }

    # ===== Step 2: URL configuration =====
    $selectedProviders = $providers | Where-Object Selected
    $result = @{}

    Clear-Host
    Write-Host ''
    Write-Host ([string]::new([char]0x2550, 55)) -ForegroundColor Cyan
    Write-Host '          Configure MCP Server URLs' -ForegroundColor White
    Write-Host ([string]::new([char]0x2550, 55)) -ForegroundColor Cyan
    Write-Host ''

    foreach ($p in $selectedProviders) {
        # Built-in providers (e.g., SharePoint & OneDrive) need no URL configuration
        if ($p.BuiltIn) {
            Write-Host "  $($p.DisplayName)" -ForegroundColor White
            Write-Host "  (Built-in to Microsoft 365 — no URL needed)" -ForegroundColor Green
            Write-Host ''
            continue
        }

        Write-Host "  $($p.DisplayName) MCP Server URL" -ForegroundColor White

        if ($p.PublicUrl) {
            Write-Host "  (Default: $($p.PublicUrl))" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  (Enterprise $([char]0x2014) no default available)" -ForegroundColor DarkGray
        }

        $urlValid = $false
        while (-not $urlValid) {
            $urlInput = Read-Host '  >'

            if ([string]::IsNullOrWhiteSpace($urlInput) -and $p.PublicUrl) {
                $result[$p.Id] = $p.PublicUrl
                $urlValid = $true
                Write-Host "  Using: $($p.PublicUrl)" -ForegroundColor Green
            }
            elseif ([string]::IsNullOrWhiteSpace($urlInput) -and -not $p.PublicUrl) {
                Write-Host '  URL is required (no default available). Please enter a URL.' -ForegroundColor Red
            }
            elseif ($urlInput -match '^https?://\S+') {
                $result[$p.Id] = $urlInput.Trim()
                $urlValid = $true
                Write-Host "  Using: $($result[$p.Id])" -ForegroundColor Green
            }
            else {
                Write-Host '  Invalid URL. Must start with https:// or http://' -ForegroundColor Red
            }
        }
        Write-Host ''
    }

    Write-Host ([string]::new([char]0x2550, 55)) -ForegroundColor Cyan
    Write-Host "  Configuration complete: $($result.Count) provider(s) configured." -ForegroundColor Green
    Write-Host ([string]::new([char]0x2550, 55)) -ForegroundColor Cyan
    Write-Host ''

    return $result
}
