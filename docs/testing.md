# Trying orgami

This is the page to follow if you were asked to try orgami and say what broke.
It takes about fifteen minutes, needs a GitHub organization you belong to, and
pushes nothing anywhere unless you ask it to.

## Where it runs

| Platform | Status |
|---|---|
| Linux | supported |
| macOS | supported, with bash 4.4 or newer from Homebrew — the `/bin/bash` 3.2 Apple ships is refused |
| WSL (Windows) | supported — use the Linux instructions inside WSL |
| Windows without WSL | not supported for testing; `bootstrap.ps1` installs into WSL or Git Bash, but only WSL runs the timer |

On macOS orgami starts with `#!/usr/bin/env bash`, so the Homebrew bash has to
come before `/bin` on `PATH`. On an older bash every command stops with:

```
orgami: needs bash 4.4 or newer (this is 3.2.57(1)-release) — on macOS: brew install bash, then open a new terminal
```

## What to install

`git`, `gh`, `jq` are required. `fzf` (0.29 or newer) is for `orgami view`,
`gum` for the wizard and the menu. `python3` is only for `orgami mcp` and
`orgami depth`. `claude` (Claude Code) is only for the parts a model writes:
the weekly recap, the daily digest, session notes, playbooks. Everything else
works without it.

The bootstrap script installs whatever is missing — through Homebrew, pacman,
apt, dnf or winget — and on macOS installs a newer bash when the one on `PATH`
is older than 4.4:

```bash
curl -fsSL https://raw.githubusercontent.com/Oldault/orgami/main/bootstrap.sh | bash
gh auth login        # if you are not signed in already
```

On macOS, if it installed bash, open a new terminal before going on.
`--dry-run` prints every step without doing any of them. Doing it by hand is in
[install.md](install.md).

## Check the machine

```bash
orgami doctor
```

One screen: each tool, the `gh` sign-in and its scopes, the git protocol, the
timer's `PATH`, the Claude Code plugin and its hooks, the configured company,
auto-update. Each failing line carries the command that fixes it. It exits 1
only when something blocks, writes nothing, and its only network call is
`gh auth status`. Paste its output into any bug report.

## Fifteen minutes

Use an organization you are a member of. orgami maps organizations only — a
personal account is refused with `orgami maps GitHub organizations — <login> is
a personal account`.

```bash
orgami init                       # the wizard; answer "nowhere" to where reports go
```

or, without questions, and with nothing to publish to:

```bash
orgami init trial --org <github-org> --no-docs
orgami scan                       # clones every active repo into ~/.orgami/trial/cache/src
```

Then look at what it made:

```bash
orgami view                       # Map, Repos, Notes, Recaps — needs a terminal and fzf 0.29+
orgami query <repo>               # one node and every edge, with the evidence
orgami card <repo>                # the repo's page: stack, commands, links
orgami context <repo>             # what an agent is handed at session start
orgami doc                        # map/ARCHITECTURE.md and the repo cards
orgami web --open                 # the whole map as one page, in the browser
```

Write something down, and read it back:

```bash
orgami note --repo <repo> "something true about this repo that is not in the code"
orgami notes --repo <repo>
```

The note stays on your machine until `orgami sync`. The week's numbers need
no model:

```bash
orgami pull                       # this week's merged pull requests
orgami report --stats-only        # the numbers, no model call
orgami daily --stats-only
```

If `claude` is installed, `orgami report` writes the recap around those numbers.
Check a figure or two against GitHub.

If a colleague already mapped the same organization into a docs repo, or you
can use a second machine or user account, try picking it up instead of
scanning:

```bash
orgami join                       # finds the repo that holds the map
orgami join trial2 --repo <docs-repo-url>   # the same, without questions
```

## What to look for

**A wrong edge is the most valuable report.** Every edge carries the file and
line it came from — `orgami query <repo>` prints it, and in `orgami view` it is
in the preview pane. The file is in the checkout the scan made, under the repo
the edge starts from:

```bash
orgami query web --json | jq -c '.edges.out[] | select(.kind == "references")'
# {"from":"repo:web","to":"repo:billing","kind":"references","evidence":"package.json:14",...}
sed -n 14p ~/.orgami/trial/cache/src/web/package.json
```

Then say which of these it is:

- the line does not say what the edge claims
- the edge is right but the line is not the one that proves it
- an edge is missing — name the file and line that should have produced it
- a framework, service, host or deploy target was not recognized, or was named wrong

Also worth reporting: a command that hangs, a message with no next step, a
number in a recap that does not match GitHub, a step that asked a question it
had no flag for, anything that wrote to a repository you did not ask it to.

`changes-with` and `shares-config` edges are *inferred* — two repos merging in
the same week, two repos reading the same variable name. They are correlation
by design; report one only if the underlying fact is wrong.

## Reporting

Open an issue on [Oldault/orgami](https://github.com/Oldault/orgami/issues/new/choose):

- **[Wrong map](https://github.com/Oldault/orgami/issues/new?template=wrong-map.yml)** —
  an edge that is not real, one that is missing, something not recognized.
- **[Bug report](https://github.com/Oldault/orgami/issues/new?template=bug.yml)** —
  a command that fails, hangs, or does something other than it says. Paste
  `orgami doctor`.

Replace client repository names, hostnames and tokens with stand-ins
(`acme-inc`, `repo-one`, `host.example.com`) before pasting. A credential that
got past the note screening goes by email to ad@antoinedv.com, not to an issue.

## Removing it

```bash
orgami uninstall --dry-run        # what would go
orgami uninstall                  # the PATH link, completions, the skill, timers,
                                  # the cron line, Cursor hook and MCP entries,
                                  # git-hook lines, the Claude Code plugin
orgami uninstall --purge          # also ~/.orgami and the clone in ~/.local/share/orgami
```

`--purge` keeps the clone if it has uncommitted changes. Nothing in a docs repo
or anything published is touched. Without a terminal it needs `--yes`.

## Trying it with Claude Code

orgami is built to be driven by a coding agent: every step has a flag, and a
step that would ask a question stops at once and names the flag instead. Paste
this into Claude Code, with `<github-org>` replaced:

````text
Install orgami, check this machine with it, map the GitHub organization
<github-org>, and tell me what looks wrong in the map. Rules:

- Your shell has no terminal. Never wait on a prompt: if orgami says "there is
  no terminal", rerun with the flag it names. If a step needs sudo or a
  password, stop and give me the exact command to run myself.
- Do not run publish, sync, autosync, review or weekly, and do not pass --yes
  to anything. Nothing should be pushed.

Steps:
1. curl -fsSL https://raw.githubusercontent.com/Oldault/orgami/main/bootstrap.sh | bash
   then: export PATH="$HOME/.local/bin:$PATH"
   On macOS, if it installed a newer bash, stop and tell me to restart Claude
   Code from a new terminal.
2. orgami doctor --json. For every check with "ok": false, give me its "fix".
   If any check is "blocking": true, stop there.
3. orgami init trial --org <github-org> --no-docs
4. orgami scan (it can take a few minutes on a large org), then orgami doc.
5. jq '{repos: [.nodes[] | select(.id | startswith("repo:"))] | length,
        edges: (.edges | length)}' ~/.orgami/trial/map/graph.json
6. Pick the three repos with the most edges. For each:
   orgami query <repo> --json, then for five edges in .edges.out whose
   "evidence" is a file:line, open that line under
   ~/.orgami/trial/cache/src/<repo>/ and say whether it supports the edge. Read the repo's README and say what the map
   missed: a service it calls, where it deploys, how it is run or tested.
7. orgami context <repo> for one of them, and say whether it would have helped
   you start work there.
8. Report: the doctor failures, the counts from step 5, every edge you judged
   wrong or unsupported (from, to, kind, evidence, and the line itself), and
   what was missing. Write each wrong edge so I can paste it into
   https://github.com/Oldault/orgami/issues/new?template=wrong-map.yml with
   repository names replaced by stand-ins.
9. Do not uninstall. Tell me the command: orgami uninstall --purge
````

orgami's own model calls run with no tools and none of your Claude Code
settings or hooks, so the session above is the only thing acting on your
machine. More on agents in [agents.md](agents.md).
