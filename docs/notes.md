# Five people, one memory

The map and the recaps are generated. What a team knows is not — the cause
someone found at 2am, the reason the obvious fix does not work, the step missing
from the README. `orgami note` records that, and the docs repo syncs it.

```bash
orgami note "Parse Dashboard config lives in WinIt-ParseDashboard/index.js,
             not the fork. Copying it into SSM by hand drops every user's apps[]."
orgami notes --repo WinIt-backend
orgami sync
```

`--repo` has to name a repository the map holds; case does not matter, and the
note is filed under the map's spelling. A name the map does not hold is refused
with the closest ones it does, and leaving `--repo` out files an org-wide note.
`orgami notes` and `orgami stale` with no notes say so and exit 0; `stale`
takes a whole number of days.

Three things keep this from turning into a landfill or a leak.

## A note holds a fact; a playbook holds a procedure

Some work is not one fact. A repository holds thirty fetchers and the job is
fixing another one — nothing surprising, which is why nobody writes it down, and
why the fifth one starts where the first did. Tag a note `pattern` and give it a
`--topic` and it becomes an instance of that job instead of a standing fact:

```bash
orgami note --repo scraphome --tag pattern --topic broken-fetcher "…"
```

Two instances under one topic write the playbook for it, and every one after
rewrites it. See **[playbooks.md](playbooks.md)**.

## Nothing shareable gets in

Before a note is written — and again before anything is pushed — it is screened
for credentials: its text, and its file name and front matter, which are pushed
with it. The list is `lib/secrets.tsv`, the same one that redacts a session
transcript before the session-end note is drafted: GitHub, Anthropic, OpenAI,
Stripe, npm, GitLab and Slack tokens, Slack webhooks, AWS keys, `Bearer` and
`Authorization` values, passwords in URLs, `KEY=`, `TOKEN=`, `SECRET=` and
`PASSWORD=` assignments, private key blocks, and "password is X". It is
pattern-based: a secret in a shape nobody listed can still get through. A
screen that cannot run refuses the note rather than passing it. It is also
screened for the name of any *other* organization configured on the same
machine, because notes are the obvious place for one org's details to end up in
another's repository. Either refuses the write outright. `orgami notes --check` screens
everything already on disk, including what arrived from teammates, and also
flags a note filed under a repo the map does not hold, with the `orgami prune
--id` that archives it; `sync` holds such a note back.

Writing a note from inside one organization's checkout while another is the
current one is refused too, by comparing the checkout's git remote against the
configured organization.

## A person can review it first

Set `"notes_review": true` in the company config and `orgami sync` opens a pull
request instead of committing — one branch per author, reused, so syncing twice
before review updates the same pull request rather than opening another. Notes
reach the team only when someone merges.

`orgami review --auto` has Claude read each pending note and comment its
verdict; `--merge` (or `"notes_auto_merge": true`) merges what passed. It leaves
a pull request for a person when it comes from a fork, changes anything outside
`<docs_path>/notes/*.md`, cannot be fetched, moves while it is being read, or
holds a note the reviewer gave no verdict for. A pull request counts as
removals-only only when GitHub reports every file in it as deleted. A merge is
pinned to the commit that was reviewed, and once rejected notes have been held
back the pull request merges on the next review, when the branch holds only
what passed.

`orgami review --install-check` puts the same screen in the docs repo's CI. It
says what it will push and asks first (`--yes` skips the question, and is
required with no terminal), adds the `screen` check to existing branch
protection rather than replacing it, and pins the workflow to the orgami commit
or tag that installed it.

## It gets pruned

A note that is now wrong is replaced, not contradicted:

```bash
orgami note --supersede <old-id> "what is true now"
orgami stale 120        # notes nobody has touched in four months
orgami prune --superseded
```

A superseded note disappears from the repo pages, the notes list and every
agent's context the moment its replacement lands. `orgami prune` moves it to
`notes/archive/` — kept on disk, removed from the shared repository on the next
sync. Nothing is ever deleted outright.

Run inside a checkout, a note attaches itself to that repo, and from then on it
appears on the repo's page — so the next person's agent reads it before touching
the code. Each note is its own file, named by timestamp and author, so five
people writing at once never produce a conflict. `orgami sync` runs on its own as
part of `orgami weekly`.

The session-start hook runs `orgami autosync`, which only takes what teammates
wrote. Publishing your own notes, opening pull requests and the automatic
review and merge happen there only with `"notes_autosync": true` in the company
config. `orgami sync` typed by hand pushes either way.

## Joining an org someone already mapped

A colleague does not need to scan anything, or know where the map lives:

```bash
orgami join
```

Pick the organization and it finds the repo that already holds a map — probing
every repo in the org in parallel, a couple of seconds — then pulls the map, the
cards, the conventions, the decisions, the playbooks, the runbooks, the daily
digests, the weekly recaps and every note out of it. One command instead of
forty clones. Only whoever runs the weekly timer needs the checkouts.

Afterwards `orgami sync` and `orgami sync --pull` take any published file the
docs repo has and this machine lacks, and never overwrite a local one. A docs
repo created empty keeps working after the first publish, and a `cache/docs`
checkout left behind by an older version heals itself. `orgami publish` names
in its commit subject the recap weeks the commit changes (`acme 2026-W44 recap
and map`, `W44..W45 recaps and map`), or `acme map` when no recap changed.

`orgami join <company> --repo <url> [--path <dir>]` skips the questions, for
scripts and for a docs repo that lives outside the org. With no terminal, bare
`orgami join` stops and prints that form.

From the docs repo's `settings.json` it takes `notes_review`,
`notes_auto_merge` and `report_model`, and nothing else: whether your notes
publish unread or sync on their own stays your decision, and the org, docs repo
and workspaces come from the command line, not from the repo. A `graph.json`
whose org is not a valid GitHub name is refused.
