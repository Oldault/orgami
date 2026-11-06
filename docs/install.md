# Installing orgami by hand

The one-command install in the [README](../README.md) covers macOS, Linux, WSL
and Windows. This page is for doing each step yourself, or for a machine where
the bootstrap script cannot run.

## 1. Dependencies

Pick the line for your machine. `git` is assumed; everything else is one command.

**macOS** — [Homebrew](https://brew.sh):

```bash
brew install bash gh jq fzf gum
```

orgami needs bash 4.4 or newer and macOS ships 3.2, so the Homebrew `bash` has
to come before `/bin` on `PATH` — open a new terminal after installing it.

**Arch, Omarchy, Manjaro**:

```bash
sudo pacman -S github-cli jq fzf gum python
```

**Debian, Ubuntu, WSL** — `gh` and `gum` ship from their own repositories:

```bash
sudo apt update && sudo apt install -y jq fzf python3 curl

# GitHub CLI
(type -p wget >/dev/null || sudo apt install -y wget) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
     | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt update && sudo apt install -y gh

# gum
sudo mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
     | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null \
  && sudo apt update && sudo apt install -y gum
```

**Fedora**:

```bash
sudo dnf install -y gh jq fzf gum python3
```

**Windows** — orgami is bash. Use [WSL](https://learn.microsoft.com/windows/wsl/install),
then follow the Ubuntu line above inside it:

```powershell
wsl --install
```

Git Bash also works for the CLI, but WSL is the path with a working weekly
schedule. If you drive orgami from Windows-native Cursor or Claude Code, point
hook commands at `wsl.exe bash -lc "..."`.

Nothing above is guessed at install time: `install.sh` checks each tool and
prints the exact command for *your* package manager if one is missing.

| Tool | Needed for |
|---|---|
| `bash` 4.4+ | everything — older versions are refused at start |
| `gh`, `git` | everything |
| `jq` 1.6+ | everything — 1.7 or newer recommended: `orgami doc` runs several times faster. CI tests 1.6 and 1.7.1 in its `jq-compat` job |
| `fzf` 0.29+ | `orgami view`, the terminal map browser |
| `gum` | `orgami init` and the menu — flags work without it |
| `python3` | optional: `orgami mcp` (the MCP server, including the one the Claude Code plugin starts) and `orgami depth` |
| `claude` | optional: the recap and decision mining, `orgami daily`, session notes, playbooks, `doc --narrate`, `review --auto` |

`orgami doctor` checks all of these, and the `gh` sign-in, and prints the fix
for whatever is missing.

## 2. Sign in to GitHub

```bash
gh auth login
```

## 3. Install orgami

**In Claude Code** — this also gives you the skill, `/orgami:context`,
`/orgami:note` and the session hook:

```
/plugin marketplace add Oldault/orgami
/plugin install orgami@orgami
```

or the same in one command:

```
/plugin install orgami --marketplace Oldault/orgami
```

then, once, to put the CLI on your PATH:

```bash
~/.claude/plugins/marketplaces/orgami/install.sh
```

**Anywhere else** — Cursor, opencode, a plain terminal, a server that only runs
the weekly job:

```bash
git clone https://github.com/Oldault/orgami ~/orgami
cd ~/orgami && ./install.sh
```

## 4. Staying up to date

Two copies of orgami end up on a machine and neither updates itself: the clone
that owns the CLI on your PATH, and the clone Claude Code keeps for the plugin —
the skill, the slash commands and the session hooks. They drift apart silently,
and the symptom is a fix you know landed doing nothing.

```bash
orgami update          # move both, and relink whatever is new
orgami update --check  # what you would get, without taking it
```

It runs on its own too: once a day at session start, detached, and again at the
start of the weekly timer. The next session says what moved, once. It moves
*every* copy on the machine, not the one that happens to be running — a plugin
hook executes the plugin's copy while the CLI on your PATH is a different clone
entirely, and updating only one of them is how the other stays a fortnight
behind. The CLI on your PATH counts only when it lives under `$HOME`: run with
`HOME` pointed at a scratch directory, `orgami update` leaves the real clone
alone and moves only the copy you ran.

A CLI old enough to need updating has no `orgami update` in it, so the session
hook falls back to the plugin's copy, which moves both. That closes the loop:
whichever copy is current updates the other, and there is no manual first step
on a machine that has the plugin.

It refuses any checkout with uncommitted work, commits of its own, or no
upstream, and it never pulls Claude Code's clone directly. For the plugin it
refreshes the marketplace (`claude plugin marketplace update orgami`), then
moves the installed plugin (`claude plugin update orgami@orgami`), and reports
it only when the installed version changed. `orgami update --check` lists the
plugin with its own state. Between releases the plugin stays on the release
version while the CLI clone moves per commit, and `orgami doctor` does not warn
about that.

Turn it off with `ORGAMI_AUTOUPDATE=0`, or `"auto_update": false` in
`~/.orgami/config.json`.

### Pinning a release

The one-line install follows `main`, and so does auto-update. To hold a team on
a release you have read, fetch the installer from that tag and tell it the tag:

```bash
curl -fsSL https://raw.githubusercontent.com/Oldault/orgami/v1.3.0/bootstrap.sh | ORGAMI_REF=v1.3.0 bash
```

```powershell
$env:ORGAMI_REF = 'v1.3.0'; irm https://raw.githubusercontent.com/Oldault/orgami/v1.3.0/bootstrap.ps1 | iex
```

The script that runs and the code it installs both come from the tag. The clone
is left on the tag, with no branch to follow, so `orgami update` and the daily
auto-update leave it where it is and say it tracks no upstream branch. Run the
installer again with a newer `ORGAMI_REF` to move it, or with none to put it
back on `main`. Tags are listed at
[github.com/Oldault/orgami/tags](https://github.com/Oldault/orgami/tags).

### Working on orgami itself

Point both installs at your checkout, and an edit is live in the next session
with no commit, push or pull in between:

```bash
cd ~/path/to/orgami
orgami update --dev
```

That links the CLI to the checkout and swaps the Claude Code marketplace from
GitHub to the local path. To go back:

```bash
claude plugin marketplace remove orgami
claude plugin marketplace add Oldault/orgami
```

## 5. Removing it

```bash
orgami uninstall --dry-run     # list what it would remove
orgami uninstall               # remove it, after asking; --yes with no terminal
orgami uninstall --purge       # also ~/.orgami and the clone in ~/.local/share/orgami
```

It removes what orgami installed — the PATH link, completions, the skill link,
the systemd or launchd timers, its crontab line, its Cursor hook and MCP
entries, git-hook lines, the Claude Code plugin and its marketplace — and never
the docs repo or anything published. `--purge` leaves the clone if it has
uncommitted changes. It finishes by removing the directories orgami used when
they are left empty (`~/.local/bin`, `~/.claude/skills`,
`~/.config/systemd/user`, and so on); a directory with anything else in it
stays.

## 6. Point it at an organization

```bash
orgami init     # map one yourself — pick the org, it does the rest
orgami init <name> --org <github-org> --no-docs   # the same, with no questions
orgami join     # or pick up one a colleague already mapped, no scan needed
```

It maps a GitHub organization, not a personal account. To try it on a public
one: `orgami init demo --org honojs --no-docs && orgami scan && orgami brief hono`.

## 7. Optional, once per organization

```bash
orgami schedule                # weekly, on systemd or launchd, cron line elsewhere
orgami agents --cursor-hook    # Cursor injects the context every session
orgami mcp --config cursor     # or opencode, codex, windsurf, zed, vscode
```

## What the bootstrap script does

- installs any of `git gh jq fzf gum python3` you are missing, through Homebrew,
  pacman, apt, dnf or winget — adding the GitHub CLI and Charm apt repositories
  when the distribution needs them, with `curl` and `gnupg` installed first
  for their keys. apt runs non-interactively, so a question from a package
  never reads the piped script as its answer
- stops at the first command that fails, with a message naming that command;
  run it again once that is fixed
- warns when the `jq` on `PATH` is older than 1.6
- when `~/.local/bin` is not on `PATH` and no shell profile adds it, asks
  whether to add it to your shell's profile (`~/.bashrc`, plus `~/.bash_profile`
  or `~/.profile` for login shells on Linux; `~/.zshrc`; fish's
  `config.fish`). With no terminal to ask on it prints the exact line instead;
  `--path` / `--no-path` (or `ORGAMI_PATH=1` / `0`) decide without asking. The
  line checks `PATH` first, so a second run adds nothing
- clones orgami to `~/.local/share/orgami` (at the release `--ref` or
  `ORGAMI_REF` names, when one does) and links `orgami` into `~/.local/bin`
- on macOS, installs a newer bash with Homebrew when the one on `PATH` is older
  than 4.4, and says to open a new terminal
- **Claude Code**, if present: adds the marketplace and installs the plugin, so
  the skill, `/orgami:context`, `/orgami:note`, the session hooks and the
  `orgami_*` MCP tools come with it; it then removes any
  `~/.claude/skills/orgami` link an earlier install made, so the skill is not
  loaded twice
- **Cursor**, if present: asks first, then installs the `sessionStart` hook for
  every project and registers the MCP server in `~/.cursor/mcp.json`. With no
  terminal to ask on it leaves Cursor alone and prints the command to wire it
  later; `--cursor` / `--no-cursor` (or `ORGAMI_CURSOR=1` / `0`) decide without
  asking
- installs the weekly timer units

`--dry-run` prints every step without touching anything. `--no-deps` and
`--no-editors` skip those parts. On Windows the PowerShell script prefers WSL
when it is installed, and otherwise sets up Git for Windows and runs the same
bash installer inside it.
