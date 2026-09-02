# The whole map as one page

`orgami web` renders everything under `~/.orgami/<company>/` — the map, the
repo profiles, what is deployed, what the DNS says the org pays for, the
advisories, the coupling, the notes, the decisions, the playbooks, the
runbooks, the recaps — into one self-contained HTML file:

```bash
orgami web            # writes map/orgami.html and prints the path
orgami web --open     # the same, then hands the file to xdg-open or open
```

It is not a web app. README says "no daemon, no database, no web app" and that
stays true: no server, no build step, no framework, no CDN, no network. It is a
rendered artefact like `graph.html`, just wider — it opens from a `file://`
URL, works inside a private docs repo, and works on a plane.

## The rules

Every view is held to these. A view that cannot meet one says so in its own
bead rather than quietly bending it.

1. **Rendered from files, and nothing else.** Input is `~/.orgami/<company>/`
   (`map/`, `notes/`, `reports/`, `cache/`). No network at render time, none
   at view time. No CDN, no fonts, no fetch. One file.
2. **Every fact shows its evidence and what kind of evidence it is.** Five
   kinds, and the page marks each one visibly and the same way everywhere,
   through `web.evidence()`:
   - *extracted* — a `file:line` you can open (a link to the GitHub blob when
     the repo has a url); solid marker
   - *inferred* — resolved by matching, no line to open; dashed marker, `~`,
     and switchable off wherever it is drawn
   - *reading* — an answer a provider or DNS gave, with the command or API and
     the date it was taken (`live.json`, `dns.json`)
   - *human* — a note, an advise rejection, a cost figure: author and date
   - *model* — recap prose, decisions, playbooks: labelled "written by a model
     from the evidence beneath", the evidence printed beneath, never mixed
     into a table of facts
3. **Numbers come from jq.** Every figure the page presents as the org's is
   computed in `lib/web/*.jq` — reusing what `lib/stats.jq`, `lib/daily.jq`
   and `lib/advise.jq` already computed. The browser may count the rows it is
   currently filtering; it never derives an org-level number from prose.
4. **Every view says how old its reading is**, from the source file's
   `generated` field, at the top of the view, through `web.freshness()`. A
   source that does not exist yields a panel naming the command that produces
   it (`orgami live`, `orgami dns`, …), never an empty chart. Sections with
   nothing in them disappear.
5. **Absence is "not found", never "not connected" / "not used".** Wording
   from [map.md](map.md) and [advise.md](advise.md).
6. **Money appears only when a human typed it**, with who and when. Until
   then the vendors view ranks by confidence and blast radius exactly as
   `orgami advise` does, and says in its header that no invoice has been seen.
7. **Deterministic.** Same input files, byte-identical output. Layouts are
   seeded from names, as `graph.html` does. No `Date.now()` in rendering, no
   random. The one clock the page uses is the reader's, for "read 3 days ago",
   and that is computed when the page is looked at, never written into it.
8. **Read-only.** The page changes nothing. Where an action makes sense it
   shows the command to copy.
9. **One palette, both themes, keyboard first.** Colours are `graph.html`'s
   (`lib/web/00-shell.css`), dark through `prefers-color-scheme`, every
   control reachable by tab, `/` focuses search, no horizontal scroll at
   1280px, readable at 900px. No emoji in the UI.
10. **Budget.** Under 2 MB on the fixture, under about 6 MB on a forty-repo
    org. `depth.json` is never inlined whole — only per-repo totals.
11. **Plain and dry.** The voice of AGENTS.md. Headings are the file names
    people already know: Map, Repos, Vendors, Live, Activity, Memory.

## The views

| id | shows | reads |
|---|---|---|
| overview | the org at a glance: counts, freshness of every reading with the command that refreshes it, what changed this week, what advise ranks first | graph, repos, live, dns, advise, coupling, reports, notes |
| map | the graph as a picture: force layout, kind filters, inferred toggle, search, node panel with both directions of every edge and the evidence | graph (+ depth and live totals) |
| repos | a table (language, framework, runtime, edges, last push, deploy target, live state) and a page per repo | repos, graph, coupling, live, notes, runbooks, playbooks |
| vendors | what the org pays for: vendor × repo by category, source badge (code / dns / both), advise proposals ranked with evidence, suppressed ones with reason and author, "not proposed, on purpose" | graph vendor nodes and edges, dns, advise, notes |
| live | deployed vs configured: per provider, per repo, state, urls, age; "configured but not seen" and "seen but not configured"; DNS records by kind | live, dns, graph deploys-to edges |
| activity | the weeks as small multiples from `stats.jq`, the daily digests from `daily.jq`, coupling as a repo × repo matrix labelled correlation-not-dependency | weeks, days, reports, daily, coupling |
| memory | notes by tag and repo (newest first, author, age, superseded chain), decisions per week, playbooks with instance counts and the evidence beneath, runbooks | notes, decisions, playbooks, runbooks, pages |

Each view is its own set of files. The shell renders a sensible page with no
view at all: the org name, how old the map is, an empty nav.

## The shape

```
lib/web.sh              cmd_web, web_render, web_payload, web_sources
lib/web/00-shell.css    the palette, both themes, the shared components' styles
lib/web/00-shell.js     nav, hash router, registry, shared components
lib/web/NN-<id>.jq      the payload for one view: reads the sources, emits one object
lib/web/NN-<id>.js      the view: web.register({id, title, needs, render})
lib/web/NN-<id>.css     optional
map/orgami.html         the output — one file, everything inlined
test/fixtures/company/  a fake ~/.orgami/<company> with every file kind
test/web_render_test.sh the gate in script/check
```

Files are inlined in glob order — `lib/web/*.css` into one `<style>` each,
`lib/web/*.js` into one `<script>` each, after the data block — so `00-shell`
comes first and a view with a lower number is left of one with a higher
number in the nav. Only files named `NN-<id>.jq` are views; anything else in
the directory is ignored by the payload.

## Adding a view

Three files, no shared edits:

1. **`lib/web/NN-<id>.jq`** — a jq program. Its input `.` is the sources
   object below, and it has `$dir`, `$company` and `$org`. It emits exactly one
   object, which the page receives as `all.views.<id>`. Give it a `generated`
   (the newest `generated` among what it read) or, when its main source is
   not there, `{generated: null, missing: "orgami <command>"}`. Never error
   on a missing source: the renderer stops on a view that fails, because a
   silently absent view hides a bug. Every org-level figure the view shows is
   computed here (rule 3).
2. **`lib/web/NN-<id>.js`** — calls `web.register({id, title, needs, render})`
   once. `needs` lists the source files it reads, for the panel the shell
   draws when the payload is missing. `render(el, view, all, route)` fills the
   section `el`; `view` is the object the .jq emitted, `all` is the whole
   payload, `route` is `{id, rest, parts}` from the hash. Open with
   `el.append(web.freshness(view))`. Build DOM with `web.h()`; never write
   `</` in a string — the renderer refuses a file that would close its own
   `<script>` tag.
3. **`lib/web/NN-<id>.css`** — optional, scoped under `[data-view="<id>"]`.

Then extend `test/fixtures/company/` if the view needs a file the fixture
lacks, and add assertions for the view to `test/web_render_test.sh`. Do not
edit `lib/web.sh`, the `00-shell.*` files, `bin/orgami`, or the shared fixture
files (`graph.json`, `repos.json`); if the foundation is missing something,
say so in the view's bead and work around it in the view.

## The payload contract

The data block, `<script id="data" type="application/json">`, is

```json
{"company": "acme", "org": "acme-inc",
 "map":   {"generated": "2026-08-18T06:12:40Z", "nodes": 49, "edges": 71},
 "repos": {"web": {"url": "https://github.com/acme-inc/web"}, "…": {}},
 "views": {"<id>": {"generated": "…", "…": "…"}}}
```

- `map` is the graph's freshness in the same shape a view uses, so the shell
  can say how old the map is with no view registered; when there is no
  `map/graph.json` it is `{"generated": null, "missing": "orgami scan"}`.
- `repos` maps a repo name to its GitHub url, which is what turns a
  `file:line` into a blob link. `web.evidence()` reads it.
- `views` holds one object per `lib/web/NN-<id>.jq`, keyed by id. Each
  carries its own `generated` or `missing`.
- `</` inside the block is written `<\/`, which is the same JSON to a parser
  and inert to the HTML tokenizer.

### The sources a view reads

jq cannot open a file by path, so `lib/web.sh` reads the company directory
once and pipes one object into every view as `.`. A source that does not
exist is `null` (or `[]` for a list); a JSON file that does not parse is read
as missing, with a line on stderr.

| key | from | shape |
|---|---|---|
| `config` | `config.json` | as written |
| `map.graph` | `map/graph.json` | as written |
| `map.repos` | `map/repos.json` | as written |
| `map.coupling` | `map/coupling.json` | as written |
| `map.live` | `map/live.json` | as written |
| `map.dns` | `map/dns.json` | as written |
| `map.advise` | `map/advise.json` | as written |
| `map.depth` | `map/depth.json` | `{generated, totals, repos: [{name, parsed, symbol_count, exported_count, external_modules, languages}]}` — never the whole file |
| `notes` | `notes/*.md`, `notes/archive/*.md` | `[{id, author, date, repo, tags: [], topic, supersedes, superseded_by, archived, file, body}]`, newest first |
| `weeks` | `cache/prs/<week>.json` | `[{file, week, since, until, stats: <lib/stats.jq>, prs: [{number, title, url, repo, author, createdAt, mergedAt, additions, deletions, changedFiles, labels, reviewers}]}]` |
| `days` | `cache/daily/<date>.json` | `[{file, date, stats: <lib/daily.jq>}]` |
| `pages` | `map/*.md` | `[{file, text}]` |
| `decisions` | `map/decisions/*.md` | `[{file, text}]` |
| `playbooks` | `map/playbooks/*.md` | `[{file, text}]` — `<repo>--<topic>.md` |
| `runbooks` | `map/runbooks/*.md` | `[{file, text}]` |
| `reports` | `reports/*.md` | `[{file, text}]` |
| `daily` | `reports/daily/*.md` | `[{file, text}]` |

Lists are sorted by file name. `file` is relative to the company directory.
The pull request caches are reduced on purpose: bodies and review threads
never reach a view, and the figures are the ones `orgami report --stats-only`
prints, so the page and the recap cannot disagree.

## The shell's API

`web` is a global defined by `lib/web/00-shell.js`.

| | |
|---|---|
| `web.register({id, title, needs, render})` | add a view; nav order is file order |
| `web.data` | the payload |
| `web.route()` | `{id, rest, parts}` of the current hash: `#/repos/web` is `{id: "repos", rest: "web", parts: ["web"]}` |
| `web.h(tag, attrs, ...children)` | build an element; `class`, `text`, `dataset`, `on<event>` handled |
| `web.freshness(view)` | the rule-4 line: "read 3 days ago · 2026-08-18", or "not run yet — `orgami live`" from `view.missing`; adds "stale" when `view.stale` |
| `web.evidence({kind, at, repo, url, command, date, author, text})` | one of the five kinds, marked; extracted `file:line` becomes a blob link when the repo has a url |
| `web.empty()` | nothing — for a section with nothing in it |
| `web.table(cols, rows)` | a table; `cols` are keys or `{key, label, num, render, sort}`; headers sort what is on the page |
| `web.search`, `web.query()`, `web.onSearch(fn)` | the search box, its lowercased value, and a listener for the current view (`/` focuses it, Escape clears it) |
| `web.age(iso)`, `web.day(iso)` | "3 days", "2026-08-18" |
| `web.kinds`, `web.color(kind)` | the six node kinds and their colours from the palette |

A view whose payload is missing (`all.views.<id>` absent or carrying
`missing`) is not rendered: the shell draws its title and the freshness panel
and stops. A view whose `render` throws gets its error drawn in its section
instead of taking the page down.

## The fixture

`test/fixtures/company/` is a fake `~/.orgami/<company>` — ten repos, every
node kind, every edge kind, extracted and inferred, a description that tries
to close a script tag, a DNS reading, a live reading, six notes (one an
advise rejection, one superseded, one archived), a week and a day of cache
with their recaps, a decisions fragment, a playbook and a runbook. Every file
takes its shape from the lib file that writes it. `map/advise.json` was
produced by `lib/advise.jq` over the fixture graph and DNS reading with the
clock fixed at `2026-08-18T07:00:00Z`; rerun it that way if the graph or the
notes change.
