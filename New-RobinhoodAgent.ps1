#Requires -Version 5.1
<#
  New-RobinhoodAgent.ps1
  Creator for Robinhood trading agents that use the "opening-price limit order"
  strategy:
      1. At/after market open, read the symbol's official opening price.
      2. Derive a limit price from it (percent offset off the open).
      3. Place a single limit order via the robinhood-trading MCP.

  It writes a ready-to-run agent definition to .\agents\<name>.md and can launch
  it in Claude Code against the robinhood-trading MCP.

  IMPORTANT (beta): Robinhood Agentic Trading currently supports EQUITIES only.
  Option fields below are templated and ready, but option orders may be rejected
  by the MCP until Robinhood enables options. Set -AssetClass Option only once
  options are live for your account.

  SAFETY: Without -Live the agent describes the exact order and waits for your
  explicit confirmation before placing anything. With -Live it places the order
  autonomously, still bounded by -BudgetUsd. Use a dedicated Robinhood agent
  account with a funded budget and per-trade notifications enabled in the app.

  Examples:
    # Equity: buy SPY at 0.5% below the open, $500 cap, confirm first
    .\New-RobinhoodAgent.ps1 -Name spy-open-dip -Symbol SPY -Side Buy `
        -LimitOffsetPct -0.5 -Quantity 1 -BudgetUsd 500 -Launch

    # Option (when enabled): buy 1 AAPL call, limit 2% below the contract's open
    .\New-RobinhoodAgent.ps1 -Name aapl-call -Symbol AAPL -AssetClass Option `
        -Right Call -Strike 220 -Expiration 2026-07-17 -Side Buy `
        -LimitOffsetPct -2 -Quantity 1 -BudgetUsd 300
#>

[CmdletBinding()]
param(
    [string]$Name,
    [string]$Symbol,
    [ValidateSet('Equity','Option')] [string]$AssetClass = 'Equity',
    [ValidateSet('Buy','Sell')]      [string]$Side = 'Buy',

    # Option-only contract details
    [ValidateSet('Call','Put')] [string]$Right,
    [string]$Expiration,                 # YYYY-MM-DD
    [double]$Strike,

    # Limit rule derived from the opening price.
    #   limit = open * (1 + LimitOffsetPct/100)
    #   e.g. -0.5 => 0.5% below the open (good for buys); +0.5 => above (for sells)
    [double]$LimitOffsetPct = -0.5,

    [int]$Quantity = 1,
    [double]$BudgetUsd = 100,
    [ValidateSet('day','gtc')] [string]$TimeInForce = 'day',

    [switch]$Live,      # place the order autonomously (default: confirm first)
    [switch]$Launch     # launch the agent in Claude Code after creating it
)

$ErrorActionPreference = 'Stop'

function Read-Default($prompt, $default) {
    $v = Read-Host ("{0}{1}" -f $prompt, $(if ($default) { " [$default]" } else { "" }))
    if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v }
}

# ---- Fill required fields interactively if not supplied ----------------
if (-not $Name)   { $Name   = Read-Default "Agent name (file-safe, e.g. spy-open-dip)" "open-limit-agent" }
if (-not $Symbol) { $Symbol = (Read-Default "Symbol (e.g. SPY)" "SPY").ToUpper() }

if ($AssetClass -eq 'Option') {
    if (-not $Right)      { $Right      = Read-Default "Option right (Call/Put)" "Call" }
    if (-not $Expiration) { $Expiration = Read-Default "Expiration (YYYY-MM-DD)" "" }
    if (-not $Strike)     { $Strike     = [double](Read-Default "Strike price" "0") }
}

# ---- Derive human-readable pieces -------------------------------------
$offsetWord = if ($LimitOffsetPct -lt 0) { "{0}% below" -f [math]::Abs($LimitOffsetPct) } elseif ($LimitOffsetPct -gt 0) { "{0}% above" -f $LimitOffsetPct } else { "equal to" }

$instrument = if ($AssetClass -eq 'Option') {
    "the {0} {1} ${2} {3} option contract expiring {4}" -f $Symbol, $AssetClass, $Strike, $Right, $Expiration
} else {
    "shares of {0}" -f $Symbol
}

$confirmStep = if ($Live) {
    "Place the order autonomously. Do not ask for confirmation, but stay within the budget below."
} else {
    "Do NOT place it yet. Show me the exact order (instrument, side, quantity, limit price, time-in-force, estimated cost) and WAIT for my explicit ``yes`` before placing it."
}

$multiplier = if ($AssetClass -eq 'Option') { " (remember each option contract controls 100 shares, so cost = quantity x limit x 100)" } else { "" }

# ---- Build the agent definition ---------------------------------------
$agent = @"
# Robinhood Agent: $Name

| Field            | Value |
|------------------|-------|
| Strategy         | Opening-price limit order |
| Asset class      | $AssetClass |
| Symbol           | $Symbol |
| Instrument       | $instrument |
| Side             | $Side |
| Limit rule       | $offsetWord today's open ($LimitOffsetPct%) |
| Quantity         | $Quantity |
| Time-in-force    | $TimeInForce |
| Budget cap (USD) | $BudgetUsd |
| Mode             | $(if ($Live) { "LIVE (autonomous)" } else { "CONFIRM-FIRST" }) |

## Instructions for the agent

You are a Robinhood trading agent using the ``robinhood-trading`` MCP tools.
Execute the strategy below exactly once, then stop.

1. Confirm the ``robinhood-trading`` MCP is connected and authenticated. If it is
   not, stop and tell me to run ``/mcp`` and authenticate.
2. Get today's **official opening price** for **$Symbol** (the first regular-session
   trade / opening quote)$(if ($AssetClass -eq 'Option') { ", for $instrument" } else { "" }).
   - If the market has not opened yet, tell me and wait for the open rather than
     using yesterday's data.
3. Compute the **limit price**:
   ``limit = open * (1 + ($LimitOffsetPct / 100))`` — i.e. $offsetWord the open —
   rounded to a valid price increment for this instrument.
4. **Budget check:** estimated cost = quantity x limit$multiplier. If it exceeds
   **`$$BudgetUsd**, do NOT place the order — report the numbers and stop.
5. Prepare a **$Side limit order** for **$Quantity** $instrument at the computed
   limit, time-in-force **$TimeInForce**.
6. $confirmStep
7. After placing, report the order id, status, and (if filled) the fill price.
   Place **exactly one** order this run — never retry or place extras.

## Guardrails

- Never exceed the **`$$BudgetUsd** budget.
- Trade **only $Symbol** / the instrument above. Never touch other positions.
- If any MCP tool errors, data is missing, or the price looks implausible, **stop
  and report** rather than guessing or improvising.
- This is real money. When in doubt, ask me.
"@

# ---- Write it out ------------------------------------------------------
$outDir = Join-Path $PSScriptRoot 'agents'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$safeName = ($Name -replace '[^\w\-]', '-')
$outFile = Join-Path $outDir "$safeName.md"
$agent | Set-Content -Path $outFile -Encoding UTF8

Write-Host ""
Write-Host "Created agent: $outFile"
Write-Host "  Symbol=$Symbol  Side=$Side  Limit=$offsetWord open  Budget=`$$BudgetUsd  Mode=$(if ($Live) {'LIVE'} else {'CONFIRM-FIRST'})"
if ($AssetClass -eq 'Option') {
    Write-Warning "Asset class is Option. Robinhood agentic trading is equities-only in beta; option orders may be rejected until options are enabled."
}

# ---- Optionally launch it in Claude Code ------------------------------
if ($Launch) {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Error "claude not found on PATH. Run setup-claude-robinhood.ps1 first."
        exit 1
    }
    Write-Host "`nLaunching the agent in Claude Code..."
    claude (Get-Content -Raw -Path $outFile)
} else {
    Write-Host "`nTo run it later:  claude `"`$(Get-Content -Raw '$outFile')`""
}
