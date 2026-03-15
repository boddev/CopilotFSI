# Agent Communication Matrix

> 100% M365 Copilot native — all agents are declarative, no backend code required.

## Orchestrator Agents (Tier 3)

| Agent | Capabilities | MCP Data Sources | Agent Dependencies |
|---|---|---|---|
| **FSI Primary** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors, People | *none* | Comp Analysis, DCF Model, Due Diligence, Company Profile, Earnings Analysis, Coverage Report, Precedent Txns, Compliance |
| **Coverage Report** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors | FactSet, S&P Global, Public Filings, Research & Ratings | Comp Analysis, DCF Model, Earnings Analysis, Precedent Txns |

## Skill Agents (Tier 2)

| Agent | Capabilities | MCP Data Sources | Agent Dependencies |
|---|---|---|---|
| **Comp Analysis** | WebSearch, CodeInterpreter, GraphConnectors, OneDrive/SP | FactSet, Public Filings, Market Data | *none* |
| **DCF Model** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors | FactSet, S&P Global, Market Data, Research & Ratings | *none* |
| **Earnings Analysis** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors | FactSet, Public Filings, Transcripts & Intel | *none* |
| **Due Diligence** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors | FactSet, Public Filings, Research & Ratings | *none* |
| **Company Profile** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors | FactSet, S&P Global, Research & Ratings | *none* |
| **Precedent Txns** | WebSearch, CodeInterpreter, GraphConnectors, OneDrive/SP | FactSet, S&P Global | *none* |
| **Coverage Report** | WebSearch, CodeInterpreter, OneDrive/SP, GraphConnectors | FactSet, S&P Global, Public Filings, Research & Ratings | Comp Analysis, DCF Model, Earnings Analysis, Precedent Txns |

## Utility Agents (Tier 1)

| Agent | Capabilities | MCP Data Sources | Agent Dependencies |
|---|---|---|---|
| **Compliance** | OneDrive/SP, GraphConnectors | *none* | *none* |

## MCP Data Sources (Tier 0)

| MCP Connector | Used By |
|---|---|
| **FactSet** | Comp Analysis, DCF Model, Earnings Analysis, Due Diligence, Company Profile, Precedent Txns, Coverage Report |
| **S&P Global** | DCF Model, Company Profile, Precedent Txns, Coverage Report |
| **Public Filings** | Comp Analysis, Earnings Analysis, Due Diligence, Coverage Report |
| **Market Data** | Comp Analysis, DCF Model |
| **Research & Ratings** | DCF Model, Company Profile, Due Diligence, Coverage Report |
| **Transcripts & Intel** | Earnings Analysis |
| **Bloomberg** | *not currently wired* |
| **Private Capital** | *not currently wired* |
| **Doc Platforms** | *not currently wired* |
| **Data Warehouses** | *not currently wired* |

## Data Source Priority

All skill agents follow this priority order:
1. **MCP data connector worker agents** — ALWAYS try these first
2. **WebSearch fallback** — LAST RESORT only, after MCP connectors have been tried

## WebSearch Fallback Sites

All skill agents and the FSI Primary agent have scoped WebSearch restricted to:

- `https://sec.gov` — SEC EDGAR filings
- `https://finance.yahoo.com` — Market data, financials, quotes
- `https://investor.gov` — Investor education and resources
