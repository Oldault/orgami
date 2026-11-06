# orgami on Windows, in one command.
#
#   irm https://raw.githubusercontent.com/Oldault/orgami/main/bootstrap.ps1 | iex
#
# orgami is bash, so this installs Git for Windows (which brings bash and the
# GNU tools it needs), the four command-line dependencies through winget, and
# then hands over to bootstrap.sh running inside that bash.
#
# Prefer WSL if you have it — this script uses it when it is already installed.
#
# Cursor (its user hooks.json and mcp.json) is asked about when there is a
# console, and left alone when there is not. `irm | iex` takes no arguments, so
# the flags of bootstrap.sh are set through the environment instead:
#   $env:ORGAMI_CURSOR = '1'   wire Cursor without asking (--cursor)
#   $env:ORGAMI_CURSOR = '0'   leave Cursor alone (--no-cursor)
#   $env:ORGAMI_REF = 'v1.3.1'  install that release and hold it there (--ref)

$ErrorActionPreference = 'Stop'

# The shell installer comes from the same ref it installs, so a pinned install
# runs the script that shipped with that release.
$ref = if ($env:ORGAMI_REF) { $env:ORGAMI_REF } else { 'main' }
$refFlag = if ($env:ORGAMI_REF) { "--ref=$($env:ORGAMI_REF)" } else { '' }

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

# The same decision bootstrap.sh makes, made here: under `bash -lc "curl | bash"`
# started from PowerShell, bash has no terminal of its own to ask on.
function CursorFlag {
  if ($env:ORGAMI_CURSOR -eq '1') { return '--cursor' }
  if ($env:ORGAMI_CURSOR -eq '0') { return '--no-cursor' }
  $found = (Test-Path "$env:USERPROFILE\.cursor") -or (Get-Command cursor -ErrorAction SilentlyContinue)
  if (-not $found) { return '--no-cursor' }
  if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $answer = Read-Host "Wire Cursor too (a sessionStart hook and the orgami MCP server in ~/.cursor)? [Y/n]"
    if ($answer -match '^[nN]') { return '--no-cursor' }
    return '--cursor'
  }
  Write-Host "Cursor found, left alone with no console to ask on. To wire it, run this again with: `$env:ORGAMI_CURSOR = '1'"
  return '--no-cursor'
}

Step "Checking for WSL"
$wsl = $null
try {
  $distros = (wsl.exe --list --quiet) 2>$null
  if ($LASTEXITCODE -eq 0 -and $distros) { $wsl = $true }
} catch { $wsl = $null }

if ($wsl) {
  Write-Host "WSL found — installing orgami inside it, which is the better home for it."
  $cursor = CursorFlag
  wsl.exe -e bash -lc "curl -fsSL https://raw.githubusercontent.com/Oldault/orgami/$ref/bootstrap.sh | bash -s -- $cursor $refFlag"
  Write-Host "`nDone. Open your WSL shell and run: orgami init" -ForegroundColor Green
  Write-Host "For Windows-native Cursor or Claude Code, point hook commands at: wsl.exe bash -lc `"orgami ...`""
  exit 0
}

Step "Installing dependencies with winget"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Warn "winget is not available. Install 'App Installer' from the Microsoft Store, then run this again."
  Warn "Or install WSL instead — it is the smoother path: wsl --install"
  exit 1
}

$packages = @(
  @{ id = 'Git.Git';            cmd = 'git' },
  @{ id = 'GitHub.cli';         cmd = 'gh' },
  @{ id = 'jqlang.jq';          cmd = 'jq' },
  @{ id = 'junegunn.fzf';       cmd = 'fzf' },
  @{ id = 'charmbracelet.gum';  cmd = 'gum' },
  @{ id = 'Python.Python.3.12'; cmd = 'python' }
)

foreach ($p in $packages) {
  if (Get-Command $p.cmd -ErrorAction SilentlyContinue) {
    Write-Host "  $($p.cmd) already present"
  } else {
    Write-Host "  installing $($p.id)"
    winget install -e --id $p.id --accept-package-agreements --accept-source-agreements
  }
}

Step "Locating bash"
$bash = $null
foreach ($candidate in @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
  if (Test-Path $candidate) { $bash = $candidate; break }
}
if (-not $bash) {
  Warn "Could not find Git Bash. Open a new terminal so PATH refreshes, then run this script again."
  exit 1
}
Write-Host "  $bash"

Step "Installing orgami"
$cursor = CursorFlag
& $bash -lc "curl -fsSL https://raw.githubusercontent.com/Oldault/orgami/$ref/bootstrap.sh | bash -s -- $cursor $refFlag"

Write-Host "`nDone." -ForegroundColor Green
Write-Host @"

Use orgami from Git Bash:

    "$bash" -lc "orgami init"

Or open Git Bash from the Start menu and run `orgami init` there.

The weekly job has no systemd here — `orgami schedule` prints a cron line for
Git Bash, or point Task Scheduler at:

    "$bash" -lc "orgami weekly"
"@
