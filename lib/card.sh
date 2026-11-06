# shellcheck shell=bash
# One page per repo, and the bundle an agent reads before touching it.

# Recent merged PRs, newest first, out of the cached weeks: "repo<TAB>line" for
# every repo, at most $1 per repo. One read of the cache serves every card.
card_recent_prs_all() {
  local limit=${1:-6}
  find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tail -8 | tr '\n' '\0' | xargs -0 cat 2>/dev/null |
    jq -sr --argjson n "$limit" \
      '[.[].prs[]? | select((.repository.name // "") | type == "string" and . != "")]
       | group_by(.repository.name)[]
       | sort_by(.mergedAt) | reverse | .[0:$n][]
       | .repository.name + "\t"
         + ("- #\(.number) \(.title) — \(.author.login // "unknown"), \(.mergedAt[0:10])" | gsub("[\t\n]"; " "))' 2>/dev/null || true
}

# The same, for one repo, as the lines alone.
card_recent_prs() {
  local repo=$1 limit=${2:-6} r line
  while IFS=$'\t' read -r r line; do
    [[ $r == "$repo" ]] && printf '%s\n' "$line"
  done < <(card_recent_prs_all "$limit")
  return 0
}

# The card body as one jq program, so one card and every card are the same
# text: `orgami doc` renders the whole org in a single jq run instead of two per
# repo. Edges are indexed by end once, rather than every section walking every
# edge of the graph again.
CARD_JQ='
def conf: (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end));
def by_end($g; f): reduce ($g.edges // [])[] as $e ({}; .[($e | f) // "" | tostring] += [$e]);
def vendor_names($g):
  reduce (($g.nodes // [])[] | select(.kind == "vendor")) as $n ({};
    .[$n.id | tostring] = ($n.name // ($n.id | tostring | sub("^vendor:"; ""))));
def card($prof; $repo; $out; $in; $vn):
  ("repo:" + $repo) as $id
  | $prof.meta as $m
  # Only tool: edges are deployment. A vendor: edge is a bill the repo runs
  # up, which the Vendors section below names. aws and cloudflare can be both;
  # they are then said once, here.
  | ([$out[] | select(.kind == "uses" and (.to | startswith("tool:"))) | .to | sub("^tool:"; "")] | unique) as $tools
  | ([$out[] | select(.kind == "deploys-to") | .to | sub("^host:"; "")] | unique) as $hosts
  | ([$out[] | select(.kind == "reaches") | .to | sub("^host:"; "") | select(IN($hosts[]) | not)] | unique) as $reach
  | ([$out[] | select(.kind == "depends-on") | .to | sub("^service:"; "")] | unique) as $svc
  | ([$out[] | select(.kind == "uses" and (.to | startswith("vendor:")))
      | select(.to | sub("^vendor:"; "") | IN($tools[]) | not)]
     | group_by(.to) | map({name: ($vn[.[0].to] // (.[0].to | sub("^vendor:"; ""))),
                            at: (.[0].evidence // "" | tostring)})
     | sort_by(.name | ascii_downcase)) as $vendors
  | [
      "# " + $repo,
      "",
      ([($m.language // empty),
        ($prof.frameworks | if length > 0 then join(", ") else empty end),
        (if $m.private then "private" else "public" end),
        ("pushed " + ($m.pushed_at // "")[0:10])]
       | map(select(. != null and . != "")) | join(" · ")),
      ($m.url // ""),
      ""
    ]
    + (if ($m.description // "") != "" then [$m.description, ""] else [] end)

    # Which package of a monorepo brought which framework into the line above.
    + (($prof.workspaces // []) as $ws
       | if ($ws | length) == 0 then []
         else ["## Packages", ""]
              + ($ws | map("- `" + (.dir | tostring) + "`"
                  + (if (.name // "") != "" and .name != .dir then " — " + .name else "" end)
                  + ((.frameworks // []) | if length > 0 then " · " + join(", ") else "" end)))
              + [""]
         end)

    + (($prof.commands.scripts | to_entries) as $s
       | ($prof.commands.evidence // {}) as $ev
       | if ($s | length) == 0 and ($prof.commands.runtime // "") == "" then []
         else ["## Run it", ""]
              + ($s | map(. as $c | ($ev[$c.key] // "") as $at
                  | "- `" + $c.key + "` — `" + $c.value + "`"
                    + (if ($at | type) == "string" and $at != "" then " (`" + $at + "`)" else "" end)))
              # Each part named: "pnpm" alone under the command list read as a
              # stray word, not as the package manager.
              + ([[($prof.commands.package_manager // "" | select(. != "") | "package manager: " + .),
                   ($prof.commands.runtime // "" | select(. != "") | "runtime: " + .),
                   ($prof.commands.procfile // [] | if length > 0 then "Procfile: " + join(", ") else empty end)]
                  | map(select(. != null and . != "")) | join(" · ")]
                 | map(select(. != "")) | map("", .))
              + [""]
         end)

    + ([$out[] | select(.kind | IN("calls", "references", "imports", "shares-config"))
        | "- " + (if .kind == "calls" then "calls" elif .kind == "references" then "references"
              elif .kind == "imports" then "imports from" else "shares config with" end)
          + " **" + (.to | sub("^repo:"; "")) + "** — `" + .evidence + "`"
          + (if conf == "inferred" then " *(inferred)*" else "" end)]
       + [$in[] | select(.kind | IN("calls", "references", "imports", "shares-config"))
          | "- " + (if .kind == "calls" then "called by" elif .kind == "references" then "referenced by"
              elif .kind == "imports" then "imported by" else "shares config with" end)
            + " **" + (.from | sub("^repo:"; "")) + "** — `" + .evidence + "`"
            + (if conf == "inferred" then " *(inferred)*" else "" end)]
       | unique
       | if length == 0 then
           ["## Talks to", "", "Nothing links this repo to another in committed configuration. That is not proof it stands alone — runtime wiring leaves no trace here.", ""]
         else ["## Talks to", ""] + . + [""] end)

    + ($prof.serves as $sv
       | if ($sv | length) == 0 then []
         else ["## Serves", ""] + ($sv | map("- `" + . + "`")) + [""] end)

    # routes_total is how many the profile found before it kept the first 40.
    # A profile from before the field existed may hold more than 40 itself.
    + ($prof.routes as $rt
       | if ($rt | length) == 0 then []
         else ($rt | .[0:40]) as $kept
              | ([($prof.routes_total // 0), ($rt | length)] | max) as $total
              | ["## Endpoints", "",
                 "<details><summary>"
                 + (if $total > ($kept | length) then "\($kept | length) of \($total) shown"
                    else "\($kept | length) found" end)
                 + "</summary>", ""]
                + ($kept | map("- `" + . + "`"))
                + ["", "</details>", ""]
         end)

    + (if ($tools + $hosts + $reach + $svc | length) == 0 then []
       else ["## Runs on", ""]
            + (if ($tools | length) > 0 then ["- deployed with " + ($tools | join(", "))] else [] end)
            + (if ($hosts | length) > 0 then ["- hosts " + ($hosts | map("`" + . + "`") | join(", "))] else [] end)
            + (if ($reach | length) > 0 then ["- reaches " + ($reach | map("`" + . + "`") | join(", "))] else [] end)
            + (if ($svc | length) > 0 then ["- backed by " + ($svc | join(", "))] else [] end)
            + [""]
       end)
    + (if ($vendors | length) == 0 then []
       else ["## Vendors", ""]
            + ($vendors | map("- " + .name + (if .at != "" then " — `" + .at + "`" else "" end)))
            + [""]
       end)

    + ($prof.env as $e
       | if ($e | length) == 0 then []
         else ([($prof.env_total // 0), ($e | length)] | max) as $total
              | ["## Configuration", "",
                 "<details><summary>"
                 + (if $total > ($e | length) then "\($e | length) of \($total)" else "\($e | length)" end)
                 + (if $total == 1 then " environment variable" else " environment variables" end)
                 + "</summary>", "",
                 "`" + ($e | join("`, `")) + "`", "", "</details>", ""]
         end)

    # agent_doc_aliases maps a name left out of agent_docs to the file it is a
    # link to, so CLAUDE.md -> AGENTS.md is listed once and says so.
    + ($prof.agent_docs as $d
       | ($prof.agent_doc_aliases // {}) as $al
       | if ($d | length) == 0 then []
         else ["## Already written for agents", ""]
              + ($d | map(. as $doc
                  | "- [`" + $doc + "`](" + ($m.url // "") + "/blob/" + ($m.default_branch // "main") + "/" + $doc + ")"
                    + ([$al | to_entries[] | select(.value == $doc) | "`" + .key + "`"]
                       | if length > 0 then " (also " + join(", ") + ")" else "" end)))
              + [""]
         end);
def card_of($g; $prof; $repo):
  ("repo:" + $repo) as $id
  | card($prof; $repo; (by_end($g; .from)[$id] // []); (by_end($g; .to)[$id] // []); vendor_names($g));
'

# The sections other files own, appended in the order the card has always had.
card_sections() {
  local repo=$1
  if [[ -f $DIR/map/depth.json ]]; then
    source "$ROOT/lib/depth.sh"
    depth_section "$repo"
  fi

  if [[ -f $DIR/map/live.json ]]; then
    source "$ROOT/lib/live.sh"
    live_section "$repo"
  fi

  if [[ -d $DIR/notes ]]; then
    source "$ROOT/lib/notes.sh"
    notes_for_repo "$repo"
  fi

  if [[ -d $DIR/map/playbooks ]]; then
    source "$ROOT/lib/playbook.sh"
    playbook_section "$repo"
  fi
}

card_prs_section() {
  [[ -n $1 ]] || return 0
  echo "## Recent merged work"
  echo
  printf '%s' "$1"
  echo
}

card_render() {
  local repo=$1
  local g="$DIR/map/graph.json" p="$DIR/map/repos.json"
  local prof
  prof=$(jq -c --arg r "$repo" '.[] | select(.name == $r)' "$p" 2>/dev/null)
  [[ -n $prof ]] || return 1

  jq -r --argjson prof "$prof" --arg repo "$repo" \
    "$CARD_JQ"' . as $g | card_of($g; $prof; $repo) | .[]' "$g"

  card_sections "$repo"

  local prs
  prs=$(card_recent_prs "$repo")
  [[ -z $prs ]] || card_prs_section "$prs"$'\n'
}

# Every card into <dir>/<repo>.md, one jq run for every card body and one read
# of the PR cache for every "Recent merged work". Each card is written beside
# its target and moved into place, so an interrupted run leaves the old card.
card_render_all() {
  local dest=$1
  local g="$DIR/map/graph.json" p="$DIR/map/repos.json"
  local tmp repo line
  tmp=$(mktemp -d)
  # A repo name becomes a file name: GitHub's own character set, and never a
  # name that walks out of the directory.
  jq -r --slurpfile ps "$p" "$CARD_JQ"'
    . as $g
    | by_end($g; .from) as $from | by_end($g; .to) as $to | vendor_names($g) as $vn
    | $ps[0][]
    | select((.name | type) == "string" and (.name | test("^[A-Za-z0-9._-]+$")) and .name != "." and .name != "..")
    | .name as $r
    | ("\u001e" + $r),
      (card(.; $r; ($from["repo:" + $r] // []); ($to["repo:" + $r] // []); $vn) | .[] | gsub("\u001e"; ""))' "$g" |
    awk -v dir="$tmp" -v sep=$'\036' '
      index($0, sep) == 1 { if (f != "") close(f); f = dir "/" substr($0, 2) ".md"; printf "" > f; next }
      f != "" { print > f }
      END { if (f != "") close(f) }' || { rm -rf "$tmp"; return 1; }

  local -A prs=()
  while IFS=$'\t' read -r repo line; do
    [[ -n $repo ]] && prs[$repo]+="$line"$'\n'
  done < <(card_recent_prs_all)

  # Every card reads the notes; parse them once for the whole pass.
  # shellcheck disable=SC2034  # read by notes_index, in this function's scope
  local NOTES_INDEX_CACHE=""
  if [[ -d $DIR/notes ]]; then
    source "$ROOT/lib/notes.sh"
    notes_index_hold "$tmp/.notes.json"
  fi

  # find, not a glob: `.github` is a repo, and a glob skips its card.
  local f n=0
  while IFS= read -r f; do
    repo=$(basename "$f" .md)
    {
      card_sections "$repo"
      card_prs_section "${prs[$repo]-}"
    } >>"$f" 2>/dev/null || true
    mv "$f" "$dest/$repo.md"
    n=$((n + 1))
  done < <(find "$tmp" -type f -name '*.md' | LC_ALL=C sort)
  rm -rf "$tmp"
  echo "$n"
}

cmd_card() {
  case ${1:-} in
    -h | --help)
      echo "usage: orgami card <repo> — the repo's page from the map: stack, commands, links, what it talks to"
      return 0 ;;
  esac
  load_company
  local repo=${1:-}
  [[ -n $repo ]] || die "usage: orgami card <repo>"
  [[ -f $DIR/map/repos.json ]] || die "no profiles — run: orgami scan"
  card_render "$repo" || die "no repo called '$repo' in the map"
}

# Resolves a repo from an argument, or from the git remote of the directory
# the agent is standing in.
# shellcheck disable=SC2120  # the optional argument is passed from other libs
card_repo_here() {
  local dir=${1:-$PWD} url name
  url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [[ -n $url ]]; then
    name=${url##*/}
    echo "${name%.git}"
    return 0
  fi
  # No usable remote — a worktree, a half-synced checkout, a plain directory.
  # The directory name is a fair guess; the caller checks it against the map.
  basename "$dir"
}

# The GitHub owner in the origin remote of the directory here, or nothing.
card_org_here() {
  local url
  url=$(git -C "$PWD" remote get-url origin 2>/dev/null || true)
  [[ -n $url ]] || return 0
  sed -E 's|.*[:/]([^/]+)/[^/]+$|\1|' <<<"$url"
}

# A path under $HOME with the home written as ~, which is how the skill names
# the map and says nothing about whose machine printed it.
card_tilde() {
  local p=$1
  if [[ -n ${HOME:-} && $p == "$HOME"/* ]]; then p=\~${p#"$HOME"}; fi
  printf '%s' "$p"
}

context_overview() {
  local g="$DIR/map/graph.json" map
  map=$(card_tilde "$DIR/map")

  echo "# $COMPANY — $ORG"
  echo
  echo "$(jq '[.nodes[] | select(.kind == "repo")] | length' "$g") repositories, mapped $(jq -r '.generated | .[0:10]' "$g")."
  echo

  # Only what is there: until `orgami doc` has run there is no ARCHITECTURE.md
  # and no repos/, and a pointer to a missing file sends the agent looking.
  local where=()
  [[ -f $DIR/map/ARCHITECTURE.md ]] &&
    where+=("- \`$map/ARCHITECTURE.md\` — the whole org: repos, deployment, hosts, services")
  where+=("- \`orgami context <repo>\` — one repo's page")
  [[ -f $DIR/map/CONVENTIONS.md ]] &&
    where+=("- \`$map/CONVENTIONS.md\` — every AGENTS.md and CLAUDE.md committed in the org")
  [[ -f $DIR/map/DECISIONS.md ]] &&
    where+=("- \`$map/DECISIONS.md\` — durable decisions mined from merged pull requests")
  compgen -G "$DIR/reports/*.md" >/dev/null 2>&1 &&
    where+=("- \`$(card_tilde "$DIR/reports")/\` — the weekly recaps")
  echo "## Where things are"
  echo
  printf '%s\n' "${where[@]}"
  echo

  local links
  links=$(jq -r '.edges[] | select(.kind | IN("calls", "references", "imports"))
    | "- **" + (.from | sub("^repo:"; "")) + "** "
      + (if .kind == "calls" then "calls" elif .kind == "imports" then "imports from" else "references" end)
      + " **" + (.to | sub("^repo:"; "")) + "** — `" + .evidence + "`"
      + (if (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end)) == "inferred" then " *(inferred)*" else "" end)' "$g" | sort -u)
  if [[ -n $links ]]; then
    echo "## How the repos connect"
    echo
    echo "$links"
    echo
  fi

  # A pair one person made in one sitting is how that person works, not a
  # coupling; coupling.json marks the pairs that are with `stable`. A file from
  # before the field has none, and its pairs all stand.
  if [[ -f $DIR/map/coupling.json ]]; then
    local pairs
    pairs=$(jq -r '[.pairs[] | select(.stable != false)] | sort_by(-.days, -.weeks) | .[0:8][]
      | "- **\(.a)** + **\(.b)** — same day \(.days)×, same week \(.weeks)×"' \
      "$DIR/map/coupling.json" 2>/dev/null || true)
    if [[ -n $pairs ]]; then
      echo "## What changes together"
      echo
      echo "$pairs"
      echo
      echo "From merged pull requests, not from the code — a hint about blast radius."
      echo
    fi
  fi

  if [[ -f $DIR/map/live.json ]]; then
    source "$ROOT/lib/live.sh"
    live_overview
  fi

  # The vendors no repository names. This one belongs on the org page and
  # nowhere else: a DNS record is about a domain, and a domain is not a repo's
  # to claim.
  if [[ -f $DIR/map/dns.json ]]; then
    source "$ROOT/lib/dns.sh"
    dns_overview
  fi

  local busy
  busy=$(find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tail -8 | tr '\n' '\0' | xargs -0 cat 2>/dev/null |
    jq -sr '[.[].prs[]? | .repository.name] | group_by(.) | map({r: .[0], n: length})
            | sort_by(-.n) | .[0:8][] | "- \(.r) — \(.n) merged"' 2>/dev/null || true)
  if [[ -n $busy ]]; then
    echo "## Biggest repos by recent work"
    echo
    echo "$busy"
    echo
  fi
  echo "Ask for one by name: \`orgami context <repo>\`."
}

# Asked with no repo, from a directory that is not one in the map. The org
# overview here would put one organization's repos into the context of work
# that has nothing to do with it, so this says what it found and stops.
context_not_here() {
  local want=$1 org
  org=$(card_org_here)
  if [[ -n $org && $org == "$ORG" ]]; then
    echo "'$want' is in $ORG but not in the map yet — run: orgami scan"
  else
    echo "'$want' is not a repo in the $COMPANY map ($ORG). For the organization: orgami context --org. For one of its repos: orgami context <repo>."
  fi
}

# A short version for automatic injection at session start: the facts an agent
# needs before its first edit, and nothing it can look up later.
card_brief() {
  local repo=$1
  local g="$DIR/map/graph.json" p="$DIR/map/repos.json"
  local prof
  prof=$(jq -c --arg r "$repo" '.[] | select(.name == $r)' "$p" 2>/dev/null)
  [[ -n $prof ]] || return 1

  jq -r --argjson prof "$prof" --arg repo "$repo" '
    . as $g
    | ("repo:" + $repo) as $id
    | [
        ($repo + " — " + ([($prof.meta.language // empty),
           ($prof.frameworks | if length > 0 then join(", ") else empty end)]
          | map(select(. != null and . != "")) | join(", "))),
        ""
      ]
      + (($prof.commands.scripts | to_entries | .[0:5]) as $s
         | if ($s | length) == 0 then []
           else ($s | map("  " + .key + ": " + .value)) + [""] end)
      + ([$g.edges[] | select((.from == $id or .to == $id)
            and (.kind | IN("calls", "references", "imports", "shares-config", "changes-with")))
          | ((if (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end)) == "inferred" then " (inferred)" else "" end)) as $c
          | if .from == $id
            then "  " + .kind + " -> " + (.to | sub("^repo:"; "")) + $c
            else "  " + .kind + " <- " + (.from | sub("^repo:"; "")) + $c end]
         | unique | .[0:8]
         | if length == 0 then [] else ["linked repos:"] + . + [""] end)
      | .[]' "$g"
}

cmd_brief() {
  local want=${1:-}
  [[ -n $want ]] || want=$(card_repo_here 2>/dev/null || true)
  context_pick_company "$want"
  load_company 2>/dev/null || return 0
  [[ -f $DIR/map/repos.json ]] || return 0
  [[ -n $want ]] || return 0
  jq -e --arg r "$want" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null 2>&1 || return 0

  echo "orgami — $COMPANY ($ORG), map from $(jq -r '.generated | .[0:10]' "$DIR/map/graph.json")"
  echo
  card_brief "$want" || return 0
  if [[ -f $DIR/map/depth.json ]]; then
    source "$ROOT/lib/depth.sh"
    depth_brief "$want"
  fi
  if [[ -f $DIR/map/live.json ]]; then
    source "$ROOT/lib/live.sh"
    live_brief "$want"
  fi
  source "$ROOT/lib/notes.sh"
  notes_for_repo "$want" | sed 's/^## What the team has learned/team notes on this repo:/'
  if [[ -d $DIR/map/playbooks ]]; then
    source "$ROOT/lib/playbook.sh"
    playbook_brief "$want"
  fi
  # `orgami agents` commits this text into the repo, so it names no path on
  # this machine, and DECISIONS.md only once `orgami doc` has written one.
  local why=""
  [[ -f $DIR/map/DECISIONS.md ]] && why=" · why: DECISIONS.md in the map"
  echo "full page: orgami context · org: orgami context --org$why"
}

# Point the company at whichever config owns this checkout's org.
context_pick_company() {
  [[ -z ${ORGAMI_COMPANY:-} ]] || return 0
  local org c
  org=$(card_org_here)
  [[ -n $org ]] || return 0
  while read -r c; do
    [[ -n $c ]] || continue
    if [[ $(jq -r .org "$(company_dir "$c")/config.json" 2>/dev/null) == "$org" ]]; then
      export ORGAMI_COMPANY="$c"
      return 0
    fi
  done < <(companies)
}

context_usage() {
  echo "usage: orgami context [repo | --org] — everything an agent needs before editing: the repo's page from the map and what it usually changes with; with no repo, the checkout here; --org, an overview of the organization"
}

cmd_context() {
  local want="" org=0 guessed=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help) context_usage; return 0 ;;
      --org) org=1; shift ;;
      -*) die "unknown flag: $1 — usage: orgami context [repo | --org]" ;;
      *)
        [[ -z $want ]] || die "one repo at a time — usage: orgami context [repo | --org]"
        want=$1; shift ;;
    esac
  done
  [[ $org == 0 || -z $want ]] || die "--org is the whole organization, so it takes no repo — run: orgami context $want"

  if [[ $org == 0 && -z $want ]]; then
    want=$(card_repo_here) || true
    guessed=1
  fi

  context_pick_company

  load_company
  [[ -f $DIR/map/repos.json ]] || die "no map yet — run: orgami scan"

  if [[ $org == 1 ]]; then
    context_overview
    return 0
  fi

  if [[ -z $want ]] || ! jq -e --arg r "$want" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null; then
    if [[ $guessed == 1 ]]; then
      context_not_here "$want"
      return 0
    fi
    die "no repo called '$want' in the $ORG map — orgami context --org lists the organization"
  fi

  echo "<!-- orgami · $COMPANY ($ORG) · map generated $(jq -r '.generated | .[0:10]' "$DIR/map/graph.json") -->"
  echo
  card_render "$want" || die "'$want' is not in the map — orgami view to browse"

  local coupled
  if [[ -f $DIR/map/coupling.json ]]; then
    coupled=$(jq -r --arg r "$want" '
      [.pairs[] | select((.a == $r or .b == $r) and .stable != false)
       | {other: (if .a == $r then .b else .a end), weeks: .weeks, days: .days, authors: .authors}]
      | sort_by(-.days, -.weeks) | .[0:6][]
      | "- **\(.other)** — same day \(.days)×, same week \(.weeks)× (\(.authors | join(", ")))"' \
      "$DIR/map/coupling.json" 2>/dev/null || true)
    if [[ -n $coupled ]]; then
      echo "## Usually changes with"
      echo
      echo "$coupled"
      echo
      echo "From merged pull request history, not from the code. Treat it as a hint about blast radius."
      echo
    fi
  fi

  echo "---"
  echo
  echo "More: \`orgami query <name>\` for one node, \`orgami context --org\` for the whole org."
}
