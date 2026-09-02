# shellcheck shell=bash
# map/orgami.html — everything orgami looks at, as one page you can open.
#
# graph.html draws the graph. This draws the rest of ~/.orgami/<company>/ beside
# it: the repos, what is deployed, what the DNS says is paid for, the advisories,
# the coupling, the notes, the decisions, the playbooks, the runbooks, the
# recaps. One file, rendered from those files and nothing else, the same rules
# html.sh runs on: no CDN, no fonts, no network, evidence on every fact and its
# kind marked, layouts seeded from names so the file diffs cleanly week to week.
#
# The page is assembled, not written. lib/web/ holds one CSS file and one JS
# file for the shell, and then one .jq, one .js and optionally one .css per
# view, all inlined in glob order — so a view is added by adding files, and no
# shared file is edited. docs/web.md is the contract.

WEB_DIR="$ROOT/lib/web"

# --- what a view may read -----------------------------------------------------
#
# jq cannot open a file by path, so a view's .jq cannot go and read what it
# needs. The runner reads everything once instead and pipes it into every view
# as `.`: the map files parsed, the markdown files as text, and the two caches
# already reduced to the figures lib/stats.jq and lib/daily.jq compute — which
# is how the page keeps to "numbers come from jq" without a view having to run
# a second program. A source that is not there is null, never an error: the
# view is the one that knows which command produces it, and says so.
#
# A JSON file that does not parse is treated the same as one that is missing,
# with a line on stderr. One broken cache file must not take the page down.

# A JSON file's path, or /dev/null when it is absent or unreadable, for
# --slurpfile: `$x[0]` is then the document or null, with no branching in jq.
web_json_or_null() {
  local f=$1
  if [[ -f $f ]] && jq -e . "$f" >/dev/null 2>&1; then
    printf '%s\n' "$f"
  else
    [[ -f $f ]] && log "could not parse ${f#"$DIR"/} — read as missing"
    printf '/dev/null\n'
  fi
}

# Every markdown file matching a glob under $DIR, as [{file, text}] sorted by
# path, in one jq process. `input_filename` is the path as given, so the glob
# runs from inside $DIR to keep the names relative.
web_texts() {
  local -a files=()
  local f
  for f in "$@"; do [[ -f $DIR/$f ]] && files+=("$f"); done
  if [[ ${#files[@]} -eq 0 ]]; then echo '[]'; return 0; fi
  (cd "$DIR" && LC_ALL=C jq -Rn '
    [inputs | {file: input_filename, line: .}]
    | group_by(.file)
    | map({file: .[0].file, text: (map(.line) | join("\n"))})
    | sort_by(.file)' "${files[@]}")
}

# The notes, frontmatter parsed the way lib/notes.sh parses it, plus the two
# things the page needs that `notes_index` drops: the archived ones, and which
# note superseded which. Tags come out as an array.
web_notes() {
  local f
  {
    for f in "$DIR"/notes/*.md "$DIR"/notes/archive/*.md; do
      [[ -f $f ]] || continue
      awk -v file="${f#"$DIR"/}" '
        BEGIN { inmeta = 0; body = "" }
        NR == 1 && $0 == "---" { inmeta = 1; next }
        inmeta && $0 == "---" { inmeta = 0; next }
        inmeta {
          key = $0; sub(/:.*/, "", key)
          val = $0; sub(/^[^:]*:[ ]*/, "", val)
          meta[key] = val
          next
        }
        { body = body $0 "\n" }
        END {
          gsub(/\\/, "\\\\", body); gsub(/"/, "\\\"", body); gsub(/\n/, "\\n", body)
          printf "{\"id\":\"%s\",\"author\":\"%s\",\"date\":\"%s\",\"repo\":\"%s\",\"tags\":\"%s\",\"topic\":\"%s\",\"supersedes\":\"%s\",\"file\":\"%s\",\"body\":\"%s\"}\n",
            meta["id"], meta["author"], meta["date"], meta["repo"], meta["tags"], meta["topic"], meta["supersedes"], file, body
        }' "$f"
    done
  } | LC_ALL=C jq -s '
    map(.tags = (.tags | gsub("[\\[\\] ]"; "") | split(",") | map(select(. != "")))
        | .archived = (.file | startswith("notes/archive/"))
        | .body = (.body | sub("\\n+$"; "")))
    | (map(select(.supersedes != "") | {key: .supersedes, value: .id}) | from_entries) as $by
    | map(.superseded_by = ($by[.id] // null))
    | sort_by(.date, .id) | reverse'
}

# Every week in cache/prs, reduced: the figures lib/stats.jq computes, and the
# pull requests trimmed to what a page can show — no bodies, no review threads.
# One JSON object per line on stdout. A week stats.jq cannot read is kept with
# null figures rather than dropped, so the page can still say the week exists.
web_weeks() {
  local f stats
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    stats=$(jq -L "$ROOT/lib" -c -f "$ROOT/lib/stats.jq" "$f" 2>/dev/null) || {
      log "stats.jq could not read ${f#"$DIR"/} — figures left null"
      stats=null
    }
    jq -c --argjson stats "$stats" --arg file "${f#"$DIR"/}" '
      {file: $file, week, since, until, stats: $stats,
       prs: [(.prs // [])[] | {number, title, url,
              repo: .repository.name, author: (.author.login // "unknown"),
              createdAt, mergedAt, additions, deletions, changedFiles,
              labels: [.labels.nodes[]?.name],
              reviewers: [.reviews.nodes[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
                          | .author.login // "unknown"] | unique}]}' "$f" 2>/dev/null ||
      log "could not parse ${f#"$DIR"/} — week left out"
  done < <(find "$DIR/cache/prs" -maxdepth 1 -name '*.json' -not -name '*.stats.json' 2>/dev/null | LC_ALL=C sort)
}

# Every day in cache/daily, reduced to the figures lib/daily.jq computes.
web_days() {
  local f stats
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    stats=$(jq -L "$ROOT/lib" -c -f "$ROOT/lib/daily.jq" "$f" 2>/dev/null) || {
      log "daily.jq could not read ${f#"$DIR"/} — figures left null"
      stats=null
    }
    jq -c --argjson stats "$stats" --arg file "${f#"$DIR"/}" \
      '{file: $file, date, stats: $stats}' "$f" 2>/dev/null ||
      log "could not parse ${f#"$DIR"/} — day left out"
  done < <(find "$DIR/cache/daily" -maxdepth 1 -name '*.json' 2>/dev/null | LC_ALL=C sort)
}

# The whole sources object on stdout. Built once per render and handed to every
# view; docs/web.md lists the keys.
web_sources() {
  local notes weeks days pages decisions playbooks runbooks reports daily
  notes=$(mktemp) weeks=$(mktemp) days=$(mktemp) pages=$(mktemp) decisions=$(mktemp)
  playbooks=$(mktemp) runbooks=$(mktemp) reports=$(mktemp) daily=$(mktemp)

  # The copy that leaves the machine goes without the live reading unless the
  # org said it may go (lib/publish.sh, live_publish). With WEB_OMIT_LIVE=1 the
  # file is read as missing, and every view says "orgami live" the way it does
  # when nobody has run it.
  local live_json
  if [[ ${WEB_OMIT_LIVE:-0} == 1 ]]; then live_json=/dev/null
  else live_json=$(web_json_or_null "$DIR/map/live.json"); fi
  # The same rule for the figures people typed (lib/cost.sh, publish_costs):
  # a docs repo may be public, so the copy that leaves the machine is rendered
  # without map/costs.json unless the org said the amounts may go.
  local costs_json
  if [[ ${WEB_OMIT_COSTS:-0} == 1 ]]; then costs_json=/dev/null
  else costs_json=$(web_json_or_null "$DIR/map/costs.json"); fi

  web_notes >"$notes"
  web_weeks >"$weeks"
  web_days >"$days"
  local md=()
  for f in "$DIR"/map/*.md; do [[ -f $f ]] && md+=("map/$(basename "$f")"); done
  web_texts "${md[@]:-}" >"$pages"
  md=(); for f in "$DIR"/map/decisions/*.md; do [[ -f $f ]] && md+=("map/decisions/$(basename "$f")"); done
  web_texts "${md[@]:-}" >"$decisions"
  md=(); for f in "$DIR"/map/playbooks/*.md; do [[ -f $f ]] && md+=("map/playbooks/$(basename "$f")"); done
  web_texts "${md[@]:-}" >"$playbooks"
  md=(); for f in "$DIR"/map/runbooks/*.md; do [[ -f $f ]] && md+=("map/runbooks/$(basename "$f")"); done
  web_texts "${md[@]:-}" >"$runbooks"
  md=(); for f in "$DIR"/reports/*.md; do [[ -f $f ]] && md+=("reports/$(basename "$f")"); done
  web_texts "${md[@]:-}" >"$reports"
  md=(); for f in "$DIR"/reports/daily/*.md; do [[ -f $f ]] && md+=("reports/daily/$(basename "$f")"); done
  web_texts "${md[@]:-}" >"$daily"

  # depth.json is never inlined whole — only what graph.html already shows per
  # repo, the same reduction html_payload makes.
  jq -n \
    --slurpfile config "$(web_json_or_null "$DIR/config.json")" \
    --slurpfile graph "$(web_json_or_null "$DIR/map/graph.json")" \
    --slurpfile repos "$(web_json_or_null "$DIR/map/repos.json")" \
    --slurpfile coupling "$(web_json_or_null "$DIR/map/coupling.json")" \
    --slurpfile live "$live_json" \
    --slurpfile dns "$(web_json_or_null "$DIR/map/dns.json")" \
    --slurpfile advise "$(web_json_or_null "$DIR/map/advise.json")" \
    --slurpfile costs "$costs_json" \
    --slurpfile depth "$(web_json_or_null "$DIR/map/depth.json")" \
    --slurpfile notes "$notes" \
    --slurpfile weeks "$weeks" \
    --slurpfile days "$days" \
    --slurpfile pages "$pages" \
    --slurpfile decisions "$decisions" \
    --slurpfile playbooks "$playbooks" \
    --slurpfile runbooks "$runbooks" \
    --slurpfile reports "$reports" \
    --slurpfile daily "$daily" \
    '{config: ($config[0] // null),
      map: {graph: ($graph[0] // null),
            repos: ($repos[0] // null),
            coupling: ($coupling[0] // null),
            live: ($live[0] // null),
            dns: ($dns[0] // null),
            advise: ($advise[0] // null),
            costs: ($costs[0] // null),
            depth: ($depth[0] // null
                    | if . == null then null
                      else {generated, totals,
                            repos: [(.repos // [])[] | select((.parsed // 0) > 0)
                                    | {name, parsed, symbol_count, exported_count,
                                       external_modules, languages}]} end)},
      notes: ($notes[0] // []),
      weeks: $weeks,
      days: $days,
      pages: ($pages[0] // []),
      decisions: ($decisions[0] // []),
      playbooks: ($playbooks[0] // []),
      runbooks: ($runbooks[0] // []),
      reports: ($reports[0] // []),
      daily: ($daily[0] // [])}'

  rm -f "$notes" "$weeks" "$days" "$pages" "$decisions" "$playbooks" "$runbooks" "$reports" "$daily"
}

# --- the payload --------------------------------------------------------------
#
# {company, org, map, repos, views}. `views` holds one object per lib/web/NN-<id>.jq,
# keyed by id, each carrying its own `generated` (or `missing`: the command that
# produces the source it wanted). `map` is the graph's freshness in the same
# shape, so the shell can say how old the map is with no view registered at
# all, and `repos` maps a repo name to its GitHub url, which is what turns a
# `file:line` into a link the reader can open.
#
# $1 the sources file. The payload goes to stdout, compact.
web_payload() {
  local sources=$1 f id out tmp
  out=$(mktemp) tmp=$(mktemp)
  : >"$tmp"
  for f in "$WEB_DIR"/[0-9][0-9]-*.jq; do
    [[ -f $f ]] || continue
    id=$(basename "$f" .jq)
    id=${id#[0-9][0-9]-}
    jq -c -L "$ROOT/lib" --arg dir "$DIR" --arg company "$COMPANY" --arg org "$ORG" \
      -f "$f" "$sources" >"$out" ||
      die "lib/web/$(basename "$f") did not run — fix it, or move it out of lib/web/"
    jq -e 'type == "object"' "$out" >/dev/null 2>&1 ||
      die "lib/web/$(basename "$f") must emit one object — see docs/web.md"
    jq -c --arg id "$id" '{id: $id, view: .}' "$out" >>"$tmp"
  done

  jq -c --arg company "$COMPANY" --arg org "$ORG" --slurpfile views "$tmp" '
    .map.graph as $g
    | {company: $company, org: $org,
       map: (if $g == null then {generated: null, missing: "orgami scan"}
             else {generated: ($g.generated // null),
                   nodes: ($g.nodes | length), edges: ($g.edges | length)} end),
       repos: ([($g.nodes // [])[] | select(.kind == "repo")
                | {key: .name, value: {url: (.meta.url // null)}}] | from_entries),
       views: ($views | map({key: .id, value: .view}) | from_entries)}' "$sources"
  rm -f "$out" "$tmp"
}

# --- the page -----------------------------------------------------------------

# A file inlined into <script> or <style> ends the block the moment it contains
# the closing tag, whatever string it sits in. Refused at render rather than
# found in a browser: write `<\/` in the source instead.
web_check_inline() {
  local f=$1
  if grep -qiE '</(script|style)' "$f"; then
    die "lib/web/$(basename "$f") contains a closing tag that would end the block it is inlined into — write <\\/ instead"
  fi
}

# $1, when given, is where the page is written instead of map/orgami.html —
# publish renders the copy it ships rather than copying the local one. Nothing
# in this file passes it, which is what shellcheck's SC2120 is about.
# shellcheck disable=SC2120
web_render() {
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || log "no map yet — the page will say so (orgami scan)"
  mkdir -p "$DIR/map"
  local out="${1:-$DIR/map/orgami.html}" sources payload tmp f
  sources=$(mktemp) payload=$(mktemp) tmp=$(mktemp)

  log "reading $DIR"
  web_sources >"$sources"
  web_payload "$sources" >"$payload"
  rm -f "$sources"

  for f in "$WEB_DIR"/*.css "$WEB_DIR"/*.js; do
    [[ -f $f ]] && web_check_inline "$f"
  done

  {
    cat <<'HTMLHEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HTMLHEAD
    printf '<title>%s — orgami</title>\n' "$(html_escape "$COMPANY")"
    # An empty inline icon, so a browser does not go looking for one: the page
    # requests nothing, not even a favicon.
    printf '<link rel="icon" href="data:,">\n'
    for f in "$WEB_DIR"/*.css; do
      [[ -f $f ]] || continue
      printf '<style data-file="lib/web/%s">\n' "$(basename "$f")"
      cat "$f"
      printf '</style>\n'
    done
    cat <<'HTMLBODY'
</head>
<body>
<header id="top">
HTMLBODY
    printf '  <h1><a href="#/">%s</a></h1>\n' "$(html_escape "$COMPANY")"
    cat <<'HTMLBODY2'
  <span class="sub" id="sub"></span>
  <nav id="nav" aria-label="views"></nav>
  <input type="search" id="q" placeholder="search — / to focus" autocomplete="off" spellcheck="false" aria-label="search">
</header>
<main id="main" tabindex="-1"></main>
<footer id="foot" aria-label="evidence key"></footer>
<script id="data" type="application/json">
HTMLBODY2
    # `</script>` inside the data would end the block early. Escaping the slash
    # keeps the JSON identical to a parser and inert to the HTML tokenizer —
    # the same move html.sh makes, done with sed because the payload can run
    # to megabytes and a bash substitution over that is slow.
    sed 's|</|<\\/|g' "$payload"
    printf '</script>\n'
    for f in "$WEB_DIR"/*.js; do
      [[ -f $f ]] || continue
      printf '<script data-file="lib/web/%s">\n' "$(basename "$f")"
      cat "$f"
      printf '</script>\n'
    done
    cat <<'HTMLTAIL'
</body>
</html>
HTMLTAIL
  } >"$tmp"
  rm -f "$payload"
  mv "$tmp" "$out"
}

# orgami web [--open] — render the page. stdout is the path and nothing else.
cmd_web() {
  load_company
  local open=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --open) open=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  web_render
  local out="$DIR/map/orgami.html"
  echo "$out"
  if [[ $open == 1 ]]; then
    if command -v xdg-open >/dev/null; then xdg-open "$out" >/dev/null 2>&1 &
    elif command -v open >/dev/null; then open "$out"
    else log "nothing here opens a file — open $out yourself"
    fi
  fi
}

# A company name goes into the page as text; same as html.sh, kept local so
# `orgami web` sources one file.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
