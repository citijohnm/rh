#Requires -Version 5.1
<#
  setup-claude-robinhood.ps1
  Seamless setup on Windows:
    - Installs Git + GitHub CLI (via winget) and Claude Code
    - Logs into GitHub (browser) and wires up git credentials
    - Logs into Claude Code (browser)
    - Adds the Robinhood trading MCP (hosted endpoint)
    - Clones ALL your GitHub repos
    - Launches Claude Code and starts your first (read-only) Robinhood agent
  Every login opens YOUR default browser and reuses your existing Google/GitHub
  session. This script handles NO passwords, tokens, or cookies itself.
#>

$ErrorActionPreference = 'Stop'

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = ($m, $u, "$env:USERPROFILE\.local\bin" -join ';')
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }
    Write-Error ("winget (App Installer) not found. Install it from the Microsoft " +
                 "Store ('App Installer'), then re-run this script.")
    exit 1
}

function Winget-Install($id, $cmd) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host "$cmd already present."
        return
    }
    Write-Host "Installing $id ..."
    winget install --id $id --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
}

# ---- 1. GitHub prerequisites ------------------------------------------
Ensure-Winget
Winget-Install 'Git.Git'    'git'
Winget-Install 'GitHub.cli' 'gh'
Refresh-Path

foreach ($c in 'git','gh') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        Write-Error "$c not on PATH. Open a NEW terminal and re-run."; exit 1
    }
}
Write-Host "git:" (git --version) " | gh:" (gh --version | Select-Object -First 1)

# ---- 2. Authenticate GitHub (interactive: opens browser) --------------
if (-not (gh auth status 2>$null)) {
    Write-Host "`n=== Logging into GitHub ==="
    gh auth login --hostname github.com --git-protocol https --web
}
gh auth setup-git          # makes git use your gh credentials, no prompts

# ---- 3. Install Claude Code -------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "`nInstalling Claude Code..."
    irm https://claude.ai/install.ps1 | iex
    Refresh-Path
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error "claude not on PATH. Open a NEW terminal and re-run."; exit 1
}
Write-Host "Claude Code:" (claude --version)

# ---- 4. Log into Claude Code (interactive: opens browser) -------------
Write-Host "`n=== Logging into Claude Code ==="
Write-Host "Browser opens -> 'Continue with Google' (reuses your Google session)."
claude   # complete login, then /exit to continue the script

# ---- 5. Add the Robinhood trading MCP (hosted endpoint) ---------------
Write-Host "`n=== Adding Robinhood trading MCP ==="
claude mcp add robinhood-trading --transport http https://agent.robinhood.com/mcp/trading
claude mcp list

# ---- 6. Clone ALL your repositories -----------------------------------
$workdir = Join-Path $env:USERPROFILE "robinhood"
New-Item -ItemType Directory -Force -Path $workdir | Out-Null
Write-Host "`nCloning all your repos into $workdir ..."
$me = (gh api user --jq '.login')
gh repo list $me --no-archived --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' |
  ForEach-Object {
    $name = ($_ -split '/')[-1]
    $dest = Join-Path $workdir $name
    if (Test-Path $dest) { git -C $dest pull } else { gh repo clone $_ $dest }
  }

# ---- 7. Authenticate Robinhood (interactive OAuth) -------------------
Write-Host "`n=== Authenticate Robinhood ==="
Write-Host "Claude Code will open. Inside it:"
Write-Host "  1) run  /mcp"
Write-Host "  2) select 'robinhood-trading'  ->  complete the browser login"
Write-Host "  3) run  /exit  to continue this script"
Set-Location $workdir
claude

# ---- 8. Launch your first Robinhood agent ----------------------------
# Read-only first run: it summarizes your account and will NOT place,
# modify, or cancel any orders. Edit $firstAgentPrompt to change scope.
Write-Host "`n=== Launching your first Robinhood agent ==="
$firstAgentPrompt = @'
You are my Robinhood assistant. Use the robinhood-trading MCP tools to give me a
read-only overview of my account: total portfolio value, buying power, and my
current positions with each position's gain/loss. Do NOT place, modify, or
cancel any orders -- just report. After the summary, ask me what I'd like to do
next and wait for my confirmation before taking any action.
'@
claude $firstAgentPrompt
