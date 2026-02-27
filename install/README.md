# FSI Copilot Installer

Deploy the Financial Services Copilot agent suite to your Microsoft 365 tenant.

## What Gets Installed

20 declarative agents organized in 4 tiers:

| Tier | Agents | Description |
|------|--------|-------------|
| 0 | 10 MCP Data Connectors | FactSet, S&P Global, Bloomberg, Alpha Vantage, LSEG, Morningstar, Moody's, PitchBook, Chronograph, Aiera, Third Bridge, MT Newswires, SEC EDGAR, FMP, Daloopa, Financial Datasets, Box, Egnyte, Snowflake, Databricks |
| 1 | 2 Utility Agents | Semantic Normalization, Compliance Guardrail |
| 2 | 6 Skill Agents | Comparable Analysis, DCF Model, Due Diligence, Company Profile, Earnings Analysis, Precedent Transactions |
| 3 | 2 Orchestrators | Coverage Report, FSI Primary Agent (main entry point) |

## Prerequisites

- **Windows** with PowerShell 7.0+
- **Node.js** 18.0+ (https://nodejs.org)
- **Microsoft 365 Copilot license** with admin permissions
- **M365 Agents Toolkit CLI** (auto-installed if missing)

## Quick Start

```powershell
cd install
.\Install-FSICopilot.ps1
```

The installer will:
1. ✅ Check prerequisites
2. 🔐 Authenticate to your M365 tenant
3. 📋 Let you select which data providers you have access to
4. 🔗 Configure MCP server URLs
5. 🚀 Provision all agents in dependency order
6. 🌐 Open the FSI Primary Agent in your browser

## Options

| Flag | Description |
|------|-------------|
| `-DryRun` | Simulate installation without provisioning |
| `-Environment <name>` | Target environment (default: "prod") |
| `-SkipPrerequisites` | Skip the prerequisites check |
| `-AutoInstallPrereqs` | Auto-install missing prerequisites |
| `-NonInteractive` | Use defaults (SEC EDGAR + Alpha Vantage only) |

## MCP Server Setup

The installer asks which data providers you have access to. Each provider requires an MCP server endpoint.

### Providers with Public Endpoints

These have free/public APIs that can be used directly:

- **SEC EDGAR** — `https://data.sec.gov` (free, no auth)
- **Alpha Vantage** — `https://www.alphavantage.co` (free tier available)
- **Financial Modeling Prep** — `https://financialmodelingprep.com` (free tier available)
- **Financial Datasets** — `https://api.financialdatasets.ai`

### Providers with Official MCP Servers

These providers have official MCP server implementations:

- **Aiera** — github.com/aiera-inc/aiera-mcp
- **Daloopa** — docs.daloopa.com/docs/mcp-integrations

### Enterprise Providers

These require enterprise agreements and custom MCP server hosting:

- FactSet, S&P Global, Bloomberg, LSEG, Morningstar, Moody's, PitchBook, Chronograph, Third Bridge, MT Newswires, Box, Egnyte, Snowflake, Databricks

For enterprise providers, you'll need to either:

1. Host your own MCP server that wraps the provider's API
2. Use the provider's official MCP server if available
3. Use a third-party MCP gateway service

## Uninstalling

```powershell
.\Uninstall-FSICopilot.ps1
```

Options:

- `-DryRun` — Show what would be removed
- `-KeepConfig` — Don't restore placeholder URLs

## Troubleshooting

### "atk auth login" fails

Ensure you have admin permissions on the M365 tenant and a valid Copilot license.

### Agent provisioning fails

- Check you're not hitting rate limits (the installer provisions in parallel)
- Ensure the teamsapp.yml files are valid: `atk validate` in the agent directory
- Check the atk CLI version: `atk --version` (requires recent version)

### Worker agents not connecting

The installer resolves title IDs automatically, but if an agent fails to provision,
its title ID won't be available for downstream agents. Re-run the installer to retry.

### MCP server connection errors

Verify your MCP server URLs are accessible from the M365 tenant's network.
Enterprise MCP servers may require VPN or private endpoints.

## Architecture

```
agents/
├── fsi-primary-agent/            ← Main entry point (Tier 3)
├── coverage-report-agent/        ← Orchestrates multi-skill reports (Tier 3)
├── comparable-analysis-agent/    ← Trading comps (Tier 2)
├── dcf-model-agent/              ← DCF/WACC models (Tier 2)
├── due-diligence-agent/          ← DD data packs (Tier 2)
├── company-profile-agent/        ← Teasers/one-pagers (Tier 2)
├── earnings-analysis-agent/      ← Beat/miss analysis (Tier 2)
├── precedent-transactions-agent/ ← M&A comps (Tier 2)
├── semantic-normalization-agent/ ← Data normalization (Tier 1)
├── compliance-guardrail-agent/   ← FINRA/SEC screening (Tier 1)
└── mcp/                          ← MCP Data Connectors (Tier 0)
    ├── mcp-factset/
    ├── mcp-sp-global/
    ├── mcp-market-data/
    ├── mcp-research-ratings/
    ├── mcp-private-capital/
    ├── mcp-transcripts-intel/
    ├── mcp-public-filings/
    ├── mcp-document-platforms/
    ├── mcp-data-warehouses/
    └── mcp-bloomberg/
```
