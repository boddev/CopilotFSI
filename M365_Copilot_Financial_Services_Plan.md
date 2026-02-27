# M365 Copilot for Financial Services -- Implementation Plan

## Context

**Problem:** Claude for Financial Services (launched July 2025, expanded October 2025) provides financial institutions with a unified conversational interface over 16 financial data connectors, 6 pre-built agent skills, Python/SQL execution, and 500K-1M token context -- all via MCP. No equivalent integrated solution exists for Microsoft 365 Copilot.

**Goal:** Build an equivalent "M365 Copilot for Financial Services" using Copilot's extensibility model: declarative agents, MCP servers on Azure Functions, Copilot Connectors, and Code Interpreter. This plan maps every Claude capability to an M365 approach and identifies what's possible out of the box, what needs custom work, and what has hard limitations.

---

## 1. Architecture Overview

```
 User Surface (native M365 Copilot UX)
 +-----------+  +-----------+  +----------------+
 | Copilot   |  | Copilot   |  | Copilot in     |
 | in Excel  |  | Chat      |  | Word/PPT/Teams |
 +-----------+  +-----------+  +----------------+
       |              |               |
       v              v               v
 +--------------------------------------------------+
 | Primary Financial Services Declarative Agent      |
 | - Finance domain system instructions              |
 | - SharePoint/Graph Connector knowledge sources    |
 | - Routes to 6 skill-specific sub-agents           |
 +--------------------------------------------------+
       |
       +------+------+------+------+------+------+
       v      v      v      v      v      v      v
  [Comp]  [DCF]  [Due  ] [Co.  ] [Earn.] [Cov. ]
  [Anal.] [Model] [Dilig] [Teas.] [Anal.] [Rpt. ]
  (Each: declarative agent + 3-5 MCP plugins + Code Interpreter)
       |
       v
 +--------------------------------------------------+
 |     Azure Functions MCP Server Layer              |
 |  20 MCP servers (C# isolated worker, .NET 8+)    |
 |  + Semantic Normalization Server                  |
 |  Behind Azure API Management (auth, rate limits)  |
 +--------------------------------------------------+
       |              |               |
       v              v               v
 [Premium APIs]  [Open APIs]    [Internal Data]
 FactSet, S&P,   SEC EDGAR,     Snowflake,
 Morningstar,    Alpha Vantage, Databricks,
 PitchBook,      XBRL, FMP     SharePoint
 LSEG, Bloomberg
```

**Key architectural decisions:**

1. **Declarative agents** (not Copilot Studio standalone bots) -- they run natively inside Excel/Word/PPT/Teams/Copilot Chat
2. **Azure Functions** with MCP trigger extension for all custom MCP servers (serverless, auto-scaling)
3. **Sub-agent pattern** -- each skill agent stays within the 5-plugin ceiling; primary agent routes to skills
4. **Code Interpreter** (Python) for all computation: DCFs, Monte Carlo, sensitivity tables, Excel/Word generation
5. **Copilot Connectors** (Graph Connectors) for persistent reference data that changes infrequently (filing index, industry classifications)

---

## 2. Feature Capability Matrix

### Category 1: Out of the Box (No Custom Development)

| Claude Feature | M365 Copilot Equivalent | Status |
|---|---|---|
| Excel sidebar integration | Copilot in Excel (native) + Office Add-in unified manifest | GA |
| Python/SQL execution for financial modeling | Code Interpreter in declarative agents & Copilot Studio | GA |
| Source attribution / citations | Copilot citations from Graph Connector items (auto-generated with links) | GA |
| GDPR compliance | M365 compliance infrastructure + EU Data Boundary | GA |
| SEC 17a-4 record retention | Microsoft Purview retention policies (Cohasset Associates-assessed Jan 2025) | GA |
| Finance reconciliation & variance analysis | Copilot for Finance (Dynamics 365 Finance / SAP integration) | GA |
| Finance-specific prompt library | Declarative agent custom instructions + Copilot Lab for shared prompts | GA |
| SharePoint/OneDrive/Teams data grounding | Microsoft Graph Semantic Index (built-in vector RAG) | GA |
| MCP server connectivity | MCP in Copilot Studio (GA) + MCP in declarative agents (public preview) | Preview/GA |
| Word/PowerPoint document generation | Code Interpreter (python-docx/python-pptx) + native Copilot in Word/PPT | GA |

### Category 2: Requires Custom Development

| Claude Feature | M365 Implementation Approach | Effort | Phase |
|---|---|---|---|
| **16 financial data MCP connectors** (FactSet, S&P, Morningstar, PitchBook, LSEG, Aiera, etc.) | 20 custom MCP servers hosted on Azure Functions (14 built from scratch, 4 ported from open-source, 2 using managed MCP from Snowflake/Databricks) | **High** | 1-3 |
| **6 pre-built agent skills** (comp analysis, DCF, due diligence, teasers, earnings analysis, coverage reports) | 6 declarative sub-agents with tailored system instructions, MCP plugin actions, and Code Interpreter prompts | **High** | 1-3 |
| Cross-source data verification | Agent instructions directing multi-source queries for same metrics + threshold-based discrepancy flagging | **Medium** | 2 |
| Semantic normalization layer | Custom "Semantic Normalization" MCP server mapping provider-specific schemas to a canonical financial data model | **High** | 2 |
| Bloomberg Terminal connectivity | BLPAPI REST gateway service on VM with Terminal access + Azure Functions MCP wrapper calling the gateway | **Medium** | 3 |
| FINRA communications supervision | Microsoft Purview Communication Compliance + Smarsh/NICE integration for Copilot interaction capture | **Medium** | 3 |
| Excel Add-in with cell-level read/write | Office Add-in using unified manifest + Office JS API combined with declarative agent | **Medium** | 1-2 |
| Data room document processing | Box/Egnyte MCP servers + Azure AI Document Intelligence (Form Recognizer) for PDF/image OCR and table extraction | **Medium** | 3 |

### Category 3: Not Currently Possible / Hard Limitations

| Claude Feature | M365 Limitation | Impact | Best Mitigation |
|---|---|---|---|
| **500K-1M token single-pass context** | M365 Copilot uses RAG chunking; effective context ~128K tokens, retrieval window significantly smaller | **High** -- cannot process a full 300-page 10-K filing in a single query | Design MCP tools for targeted section extraction (e.g., "get revenue recognition note from 10-K"); multi-turn decomposition across conversation turns |
| **Full document ingestion** (entire filing in one prompt) | No equivalent to Claude's extended context window | **High** -- limits complex cross-referencing within a single document | Break into sections via MCP tools; Code Interpreter can process uploaded files in chunks; accept multi-turn workflows |
| **Real-time streaming data feeds** | MCP servers must use HTTP request/response (no persistent WebSocket/SSE from declarative agents) | **Medium** -- no live ticker or streaming transcript | Point-in-time fetches with Azure Redis caching (15-min TTL for market data); short-polling for near-real-time needs |
| **Code Interpreter on enterprise-searched files** | Known M365 limitation: Code Interpreter cannot process files found via enterprise search / Graph connector queries | **Medium** -- requires workarounds for file-based analysis | MCP tools fetch and return file content directly as structured data; or design workflows requiring explicit user file upload |
| **>50 total tools across all plugins** | ~5 plugin ceiling before semantic matching degrades; ~10 functions per plugin practical limit | **Medium** -- constrains complexity of individual agents | Sub-agent architecture isolates plugin sets per skill; composite MCP servers bundle related tools |
| **Nested objects in API plugin schemas** | OpenAPI plugin limitation in M365 Copilot | **Low** -- can be worked around | Use MCP servers (no such limitation) instead of raw API plugins; flatten response schemas where API plugins are required |

---

## 3. Data Connector Strategy

### Replicating Claude's 16 Financial Data Connectors

Claude connects to data providers via MCP servers. M365 Copilot can do the same using custom MCP servers hosted on Azure Functions.

#### Pattern A: Custom MCP Server on Azure Functions (14 servers)

Each server: C# isolated worker + `Microsoft.Azure.Functions.Worker.Extensions.Mcp` NuGet package + Azure Key Vault for credentials + Azure API Management front door.

| # | Provider | Claude Use | MCP Tools (est.) | Auth | Open-Source Base? |
|---|---|---|---|---|---|
| 1 | **FactSet** | Equity prices, fundamentals, consensus estimates | 8 | OAuth 2.0 | No -- custom build |
| 2 | **S&P Global / Capital IQ** | Financials, earnings transcripts | 7 | API Key | No -- custom build |
| 3 | **Morningstar** | Valuation data, research analytics | 5 | OAuth 2.0 | No -- custom build |
| 4 | **PitchBook** | Private capital market data | 6 | API Key | No -- custom build |
| 5 | **Daloopa** | Auto-extracted financial data from filings | 3 | API Key | No -- custom build |
| 6 | **LSEG / Refinitiv** | Live market data, fixed income, FX, macro | 6 | OAuth 2.0 | No -- custom build |
| 7 | **Aiera** | Real-time earnings transcripts, event summaries | 4 | API Key | No -- custom build |
| 8 | **Third Bridge** | Expert interviews, company intelligence | 3 | API Key | No -- custom build |
| 9 | **Chronograph** | PE operational/financial data, portfolio monitoring | 3 | API Key | No -- custom build |
| 10 | **Moody's** | Credit ratings, research, ownership data | 4 | API Key | No -- custom build |
| 11 | **MT Newswires** | Global financial news | 3 | API Key | No -- custom build |
| 12 | **SEC EDGAR** | Company filings, XBRL financials, insider trading | 6 | None (free) | Yes -- port from [sec-edgar-mcp](https://github.com/stefanoamorelli/sec-edgar-mcp) |
| 13 | **Alpha Vantage** | Stock/forex/crypto prices, technicals | 5 | API Key | Yes -- port from community implementations |
| 14 | **Financial Modeling Prep / XBRL** | Fundamentals, ratios, structured XBRL data | 5 | API Key / None | Yes -- port from [financial-datasets/mcp-server](https://github.com/financial-datasets/mcp-server) |

#### Pattern B: Managed MCP (2 servers -- minimal custom code)

| # | Provider | Approach |
|---|---|---|
| 15 | **Snowflake** | Snowflake managed MCP server via Cortex, or CData Connect AI bridge. Connect Copilot Studio / declarative agent directly to Snowflake MCP endpoint. |
| 16 | **Databricks** | Databricks managed MCP via Unity Catalog. Connect directly to Databricks MCP endpoint. |

#### Pattern C: Document Platform + Azure AI Document Intelligence (2 servers)

| # | Provider | Approach |
|---|---|---|
| 17 | **Box** | Custom MCP server wrapping Box Platform API. Document extraction via Azure AI Document Intelligence for PDF parsing, OCR, table extraction. |
| 18 | **Egnyte** | Custom MCP server wrapping Egnyte Connect API + Azure AI Document Intelligence. |

#### Bloomberg Special Case

Bloomberg requires a unique architecture:
- A "Bloomberg Gateway" REST service running on a VM with Bloomberg Terminal access (on-premises or Azure with ExpressRoute)
- The Azure Functions MCP server calls this REST gateway
- Adds 50-200ms latency and operational complexity (Terminal licensing, VM maintenance)
- **Alternative:** For firms with Bloomberg B-PIPE or Bloomberg Data License, build against those APIs instead
- **Note:** Bloomberg has officially embraced MCP as a protocol -- community implementation exists at [blpapi-mcp](https://github.com/djsamseng/blpapi-mcp)

#### Supporting Infrastructure

| Component | Purpose |
|---|---|
| **Semantic Normalization MCP Server** | Maps provider field names to canonical model (e.g., FactSet `FF_SALES` = S&P `IQ_TOTAL_REV` = canonical `Revenue`) |
| **Copilot Connectors (Graph Connectors)** | Index infrequently-changing reference data into Microsoft Graph: SEC filing index, GICS industry classifications, company reference data. Provides automatic grounding without consuming MCP plugin slots. |
| **Azure API Management** | Unified auth, rate limiting, circuit breaking, logging across all MCP server endpoints |
| **Azure Key Vault** | Centralized credential management for all data provider API keys/secrets |
| **Azure Redis Cache** | Response caching: 15-min TTL for market data, 24-hr for fundamentals |

---

## 4. Agent Skills Replication

Each of Claude's 6 pre-built skills maps to a **declarative sub-agent** with tailored instructions, 3-5 MCP plugins, and Code Interpreter enabled.

### Skill 1: Comparable Company Analysis

**What Claude does:** Generates valuation multiples (EV/EBITDA, P/E, EV/Revenue) and operating metrics tables for a peer set. Auto-refreshable.

**M365 Implementation:**
- **Declarative agent:** `comparable-analysis-agent`
- **MCP plugins (3):** FactSet (financials, prices, estimates) + Financial Datasets (fallback) + Alpha Vantage (real-time prices for market cap)
- **Knowledge source:** Graph Connector with GICS/ICB industry classification for peer identification
- **Code Interpreter:** Calculates derived multiples (EV = Market Cap + Debt - Cash), generates formatted comp table, outputs Excel workbook
- **Excel integration:** Office Add-in populates pre-built comp template in active worksheet via Office JS `Range.values` API

### Skill 2: DCF Models

**What Claude does:** Free cash flow projections, WACC calculations, scenario toggles, sensitivity analysis with Monte Carlo simulations.

**M365 Implementation:**
- **Declarative agent:** `dcf-model-agent`
- **MCP plugins (3):** FactSet (financials, estimates) + S&P Global (credit rating, debt schedule) + Alpha Vantage (risk-free rate via Treasury yields)
- **Code Interpreter (critical):** 5-year FCF projections, WACC via CAPM, terminal value (Gordon Growth + exit multiple), sensitivity tables (WACC vs. terminal growth matrix), Monte Carlo simulations, Excel workbook output with named ranges and formulas
- **Scenario toggles:** Base/bull/bear scenarios via parameterized Code Interpreter prompts

### Skill 3: Due Diligence Data Packs

**What Claude does:** Processes data room documents into structured Excel workbooks (financials, customer lists, contracts).

**M365 Implementation:**
- **Declarative agent:** `due-diligence-agent`
- **MCP plugins (4):** Box/Egnyte (document retrieval via search/download) + SEC EDGAR (filings) + FactSet (supplemental financials) + Semantic Normalization
- **Code Interpreter:** Processes document text extracted by Box/Egnyte MCP servers (which use Azure AI Document Intelligence for PDF parsing). Generates structured Excel workbook with tabs per DD category (financial, legal, operational, commercial), red flag highlights, and data quality indicators.
- **Limitation:** Large data rooms processed in batches via multi-turn conversation

### Skill 4: Company Teasers / Profiles

**What Claude does:** Condensed company overviews for pitch books.

**M365 Implementation:**
- **Declarative agent:** `company-profile-agent`
- **MCP plugins (4):** FactSet (financials, profile) + S&P Global (industry analysis) + PitchBook (deals, investors) + Morningstar (ratings, research)
- **Code Interpreter:** Generates Word document (python-docx) or PowerPoint slide (python-pptx) for pitch book insertion
- **Knowledge source:** Historical teasers and company logos in SharePoint, indexed via Graph Connector

### Skill 5: Earnings Analyses

**What Claude does:** Processes quarterly transcripts and financial research, extracts key metrics and guidance changes.

**M365 Implementation:**
- **Declarative agent:** `earnings-analysis-agent`
- **MCP plugins (4):** Aiera (transcripts, event sentiment) + SEC EDGAR (10-Q, 8-K) + FactSet (estimates, actuals) + Financial Datasets (fallback)
- **Code Interpreter:** Calculates beat/miss percentages, visualizes guidance revision trends, generates summary tables comparing actual vs. estimate vs. prior quarter
- **Cross-source verification:** Agent instructions direct comparison of reported actuals from transcript vs. SEC filing data vs. FactSet consensus, flagging discrepancies

### Skill 6: Coverage Report Initiation

**What Claude does:** Full industry analysis, company deep-dives, and valuation frameworks for initiating analyst coverage.

**M365 Implementation:**
- **Declarative agent:** `coverage-report-agent`
- **MCP plugins (5 -- at ceiling):** FactSet + S&P Global + Morningstar + SEC EDGAR + LSEG
- **Code Interpreter:** Generates full Word report (exec summary, industry overview, competitive landscape, company analysis, financial model, valuation, risks, price target) + supporting Excel model
- **Multi-turn orchestration:** 4-step workflow in agent instructions:
  1. Industry analysis pass (query industry data, competitive dynamics)
  2. Company deep-dive pass (financials, management, strategy)
  3. Valuation pass (comp analysis + DCF sub-routines)
  4. Report generation pass (compile findings into structured document)

---

## 5. Implementation Phases

### Phase 0: Foundation (Weeks 1-4)

| Task | Details |
|---|---|
| Azure infrastructure | Resource groups (`rg-finserv-copilot-{env}`), Bicep IaC templates |
| Dev environment | M365 Agents Toolkit in VS Code, Azure Functions Core Tools |
| Solution structure | C# isolated worker solution, .NET 8+, NuGet: `Microsoft.Azure.Functions.Worker.Extensions.Mcp`, `ModelContextProtocol` |
| Canonical data model | C# records: Company, FinancialStatement, ValuationMultiple, MarketData, EarningsData, FilingDocument, AnalystEstimate |
| Security infrastructure | Azure Key Vault, Azure API Management, Managed Identities |
| Primary agent manifest | `declarativeAgent.json` with finance domain system instructions |
| Compliance baseline | Microsoft Purview retention policies for Copilot interaction capture (SEC 17a-4) |

**Deliverables:** IaC templates, solution skeleton, canonical data model, agent manifest v0.1

### Phase 1: Open Data + First 2 Skills (Weeks 5-12)

| Task | Details |
|---|---|
| MCP servers (4) | SEC EDGAR, Financial Datasets/FMP, Alpha Vantage, XBRL |
| Agent skills (2) | Comparable Company Analysis, Earnings Analysis |
| Graph Connector (1) | SEC filing index (company, filing type, date, URL) |
| Excel Add-in prototype | Unified manifest combining agent with Office JS cell read/write |
| Prompt library | 20-30 finance-specific prompts published to Copilot Lab |

### Phase 2: Premium Data + Next 2 Skills (Weeks 13-22)

| Task | Details |
|---|---|
| MCP servers (6) | FactSet, S&P Global, Morningstar, PitchBook, Snowflake (managed), Databricks (managed) |
| Agent skills (2) | DCF Models, Company Teasers/Profiles |
| Semantic Normalization | Custom MCP server mapping all provider schemas to canonical model |
| Cross-source verification | Logic in agent instructions for multi-source metric comparison |
| Excel Add-in GA | Full sidebar agent with cell-level data insertion and formula generation |

### Phase 3: Full Coverage + Final Skills (Weeks 23-34)

| Task | Details |
|---|---|
| MCP servers (10) | Box, Egnyte, Daloopa, Bloomberg, LSEG, Aiera, Third Bridge, Chronograph, Moody's, MT Newswires |
| Agent skills (2) | Due Diligence Data Packs, Coverage Report Initiation |
| Compliance | FINRA supervision (Smarsh/Purview Communication Compliance), DLP policies for MNPI |
| Production hardening | APIM rate limiting, circuit breaking, Application Insights monitoring |
| UAT | Pilot testing with analyst teams |

### Phase 4: Optimization & Rollout (Weeks 35-42)

| Task | Details |
|---|---|
| Performance | Azure Functions Premium plan (pre-warmed), Azure Redis caching |
| Analytics | Power BI dashboard: queries per skill, data source utilization, quality ratings |
| Security | Pen testing of all MCP server endpoints |
| Rollout | Role-based agent configurations (analysts, associates, PMs) |
| Training | Documentation and training materials |

---

## 6. Verification & Testing

### Component Testing

| What | How | Target |
|---|---|---|
| MCP server unit tests | xUnit + WireMock.NET mocking provider APIs | 80%+ code coverage per server |
| MCP integration tests | Azure Functions test host against provider sandbox environments | End-to-end data retrieval, <3s latency |
| Normalization tests | Assert field mappings across all providers; cross-provider reconciliation | Values within 0.1% tolerance |

### Agent Testing

| What | How | Target |
|---|---|---|
| Prompt accuracy | 50+ test prompts per skill agent | Factual accuracy, citations, correct format |
| Code Interpreter outputs | Standard requests verified against hand-calculated values | Within 1% tolerance |
| Cross-source verification | 10 major companies queried from all providers | Discrepancies correctly flagged |

### End-to-End Scenarios

1. **Comp Analysis in Excel:** User asks for Salesforce comp table -> agent fetches data via MCP -> generates table -> populates Excel cells
2. **Earnings Quick Analysis:** User asks about Apple Q4 earnings -> agent pulls transcript + actuals + filing -> generates beat/miss summary
3. **Full Coverage Report:** User initiates CrowdStrike coverage -> multi-turn workflow -> Word document + Excel model output

### Performance Targets

| Metric | Target |
|---|---|
| MCP tool response (open data) | < 2 seconds |
| MCP tool response (premium data) | < 5 seconds |
| Comp table generation | < 30 seconds |
| DCF model generation | < 60 seconds |
| Coverage report generation | < 5 minutes |

### Compliance Verification

- Purview retention captures all Copilot interactions (SEC 17a-4)
- DLP policies block MNPI sharing outside authorized groups
- Smarsh captures Copilot content for FINRA supervision
- Full audit trail: user query -> MCP tool calls -> provider API calls

---

## 7. Key Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| M365 Copilot MCP support stays in preview | High | Maintain parallel API plugin implementations as fallback; track M365 roadmap |
| Context window too small for full 10-K analysis | High | MCP tools extract targeted sections; multi-turn decomposition; accept as known gap vs. Claude |
| Premium data provider API rate limits or latency | Medium | Azure Redis caching (15-min TTL market data, 24-hr fundamentals); APIM rate limiting |
| Plugin slot ceiling (~5 always-on per agent) | Medium | Sub-agent architecture isolates plugins per skill |
| Bloomberg network access from Azure | Medium | Dedicated VM with ExpressRoute; or Bloomberg B-PIPE/Data License APIs |
| Code Interpreter can't access Graph-indexed files | Medium | MCP tools fetch and return file content directly; user upload workflow |

---

## 8. Technology Stack Summary

| Layer | Technology |
|---|---|
| User interface | M365 Copilot (Excel, Word, PPT, Teams, Chat) |
| Agent framework | Declarative Agents (M365 Agents Toolkit in VS Code) |
| Low-code extension | Microsoft Copilot Studio (MCP GA) |
| MCP server hosting | Azure Functions (C# isolated worker, .NET 8+) |
| MCP SDK | `ModelContextProtocol` NuGet (official C# SDK) + `Microsoft.Azure.Functions.Worker.Extensions.Mcp` |
| API gateway | Azure API Management |
| Secrets | Azure Key Vault |
| Caching | Azure Redis Cache |
| Document AI | Azure AI Document Intelligence (Form Recognizer) |
| Data grounding | Microsoft Graph Semantic Index + Copilot Connectors |
| Compliance | Microsoft Purview + Smarsh |
| Monitoring | Application Insights |
| Analytics | Power BI |
| IaC | Bicep templates |
| CI/CD | GitHub Actions |

---

## References

- [Build declarative agents with MCP](https://devblogs.microsoft.com/microsoft365dev/build-declarative-agents-for-microsoft-365-copilot-with-mcp/)
- [Build MCP plugins for M365 Copilot](https://learn.microsoft.com/en-us/microsoft-365-copilot/extensibility/build-mcp-plugins)
- [MCP tool trigger for Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-mcp-trigger)
- [Build MCP servers with Azure Functions (.NET)](https://devblogs.microsoft.com/dotnet/build-mcp-remote-servers-with-azure-functions/)
- [Code Interpreter for declarative agents](https://learn.microsoft.com/en-us/microsoft-365-copilot/extensibility/code-interpreter)
- [Declarative agents overview](https://learn.microsoft.com/en-us/microsoft-365-copilot/extensibility/overview-declarative-agent)
- [Copilot Connectors overview](https://learn.microsoft.com/en-us/microsoft-365-copilot/extensibility/overview-copilot-connector)
- [Combine agents with Office Add-ins](https://learn.microsoft.com/en-us/office/dev/add-ins/design/agent-and-add-in-overview)
- [MCP GA in Copilot Studio](https://www.microsoft.com/en-us/microsoft-copilot/blog/copilot-studio/model-context-protocol-mcp-is-now-generally-available-in-microsoft-copilot-studio/)
- [Agent 365 MCP Servers](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview)
- [Official MCP C# SDK](https://github.com/modelcontextprotocol/csharp-sdk)
- [Financial services compliance assessment for M365 Copilot](https://www.microsoft.com/en-us/industry/blog/financial-services/2025/01/30/new-compliance-assessment-builds-financial-services-confidence-in-microsoft-365-copilot/)
- [SEC EDGAR MCP Server](https://github.com/stefanoamorelli/sec-edgar-mcp)
- [Financial Datasets MCP Server](https://github.com/financial-datasets/mcp-server)
- [Bloomberg embraces MCP](https://www.bloomberg.com/company/stories/closing-the-agentic-ai-productionization-gap-bloomberg-embraces-mcp/)
- [Claude for Financial Services](https://www.anthropic.com/news/claude-for-financial-services)
- [Advancing Claude for Financial Services](https://www.anthropic.com/news/advancing-claude-for-financial-services)
- [Copilot for Finance](https://www.microsoft.com/en-us/microsoft-365-copilot/copilot-for-finance)
- [Smarsh FINRA compliance for Copilot](https://www.smarsh.com/blog/product-spotlight/embracing-microsoft-copilot-in-financial-services-how-smarsh-eliminates-compliance-barriers)
