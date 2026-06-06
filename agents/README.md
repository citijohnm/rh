# Robinhood agents

Generated agent definitions live here. Create one with the helper in the repo
root:

```powershell
.\New-RobinhoodAgent.ps1 -Name spy-open-dip -Symbol SPY -Side Buy `
    -LimitOffsetPct -0.5 -Quantity 1 -BudgetUsd 500 -Launch
```

Each agent is a self-contained markdown spec the Claude + `robinhood-trading`
MCP agent follows. Run an existing one any time:

```powershell
claude "$(Get-Content -Raw .\agents\spy-open-dip.md)"
```

## Notes

- **Equities only (beta):** Robinhood Agentic Trading currently supports stocks.
  Option agents can be authored (`-AssetClass Option`) but orders may be rejected
  until Robinhood enables options.
- **Safety:** agents default to confirm-first. Add `-Live` for autonomous
  placement, bounded by `-BudgetUsd`. Use a dedicated, budgeted Robinhood agent
  account with per-trade notifications on.
- `templates/open-price-limit.md` is the underlying strategy template.
