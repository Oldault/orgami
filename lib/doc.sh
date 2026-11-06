# shellcheck shell=bash
# orgami doc — render map/graph.json into map/ARCHITECTURE.md.
# Deterministic. --narrate adds one Claude-written intro on top of the same facts.

# One page per repo, plus the org's own agent instructions gathered in one place.
doc_cards() {
  local profiles="$DIR/map/repos.json"
  [[ -f $profiles ]] || return 0
  source "$ROOT/lib/card.sh"
  mkdir -p "$DIR/map/repos"
  # All cards in one pass: a card each, two jq runs and a read of the PR cache
  # apiece, took four seconds for forty repos.
  local n
  n=$(card_render_all "$DIR/map/repos") || n=0
  echo "$n cards in $DIR/map/repos/" >&2
}

doc_conventions() {
  local profiles="$DIR/map/repos.json"
  [[ -f $profiles ]] || return 0
  local out="$DIR/map/CONVENTIONS.md"
  local repo doc path lines
  # clone_file: a committed symlink is read only when it stays in its checkout.
  # The scan already removed the rest, but a cache from before it may not have.
  source "$ROOT/lib/profile.sh"

  {
    echo "# $COMPANY conventions"
    echo
    echo "Every instruction file already committed in \`$ORG\`. Read this before"
    echo "writing code for them, and follow the repo's own file over anything here."
    echo

    # An AGENTS.md in the .github repo is the organization's default.
    if [[ -d $DIR/cache/src/.github ]]; then
      for doc in AGENTS.md CLAUDE.md CONTRIBUTING.md; do
        path="$DIR/cache/src/.github/$doc"
        clone_file "$DIR/cache/src/.github" "$path" || continue
        echo "## Organization default — \`.github/$doc\`"
        echo
        echo "Applies to every repository in the org unless a repo overrides it."
        echo
        head -200 "$path"
        echo
      done
    fi

    echo "## Per repository"
    echo
    local any=0 url branch also
    # One jq run for every repo's documents. A second name for the same file
    # (CLAUDE.md as a link to AGENTS.md) is not a second section; it is named
    # on the one it points at.
    while IFS=$'\t' read -r repo doc url branch also; do
      [[ -n $repo && -n $doc && $repo != ".github" ]] || continue
      path="$DIR/cache/src/$repo/$doc"
      clone_file "$DIR/cache/src/$repo" "$path" || continue
      any=1
      lines=$(wc -l <"$path" | tr -d ' ')
      [[ $also == - ]] && also=""
      echo "### \`$repo/$doc\` — $lines lines${also:+ (also $also)}"
      echo
      if [[ $lines -le 60 ]]; then
        cat "$path"
      else
        echo "Sections:"
        echo
        grep -E '^#{1,3} ' "$path" | head -25 | sed 's/^#\{1,3\} /- /'
        echo
        # The page is published to the docs repo, so the full text is the
        # file on GitHub, not the clone under this machine's home.
        if [[ $url == https://* ]]; then
          echo "Full text: [\`$repo/$doc\`]($url/blob/$branch/$doc)"
        else
          echo "Full text: \`$repo/$doc\`"
        fi
      fi
      echo
    done < <(jq -r '.[] | select((.name | type) == "string")
      | .name as $n | (.meta.url // "" | tostring) as $u
      | (.meta.default_branch // "main" | tostring) as $b
      | (.agent_doc_aliases // {}) as $al
      | (.agent_docs // [])[] as $d
      | [$n, $d, (if $u == "" then "-" else $u end), $b,
         ([$al | to_entries[] | select(.value == $d) | "`" + .key + "`"]
          | if length > 0 then join(", ") else "-" end)]
      | @tsv' "$profiles")
    [[ $any == 1 ]] ||
      echo "No repository carries an AGENTS.md, CLAUDE.md or CONTRIBUTING.md yet."
  } >"$out"

  echo "$out" >&2
}

# One fragment per week, newest first. The file only grows.
doc_decisions() {
  local dest="$DIR/map/decisions"
  compgen -G "$dest/*.md" >/dev/null 2>&1 || return 0
  local out="$DIR/map/DECISIONS.md"
  {
    echo "# $COMPANY decisions"
    echo
    echo "Durable choices pulled out of merged pull requests, newest first. Every"
    echo "bullet carries the pull request it came from — check it before relying on it."
    echo
    local f
    while read -r f; do
      cat "$f"
      echo
    done < <(find "$dest" -maxdepth 1 -name '*.md' | sort -r)
  } >"$out"
  echo "$out" >&2
}

doc_runbooks() {
  [[ -f $DIR/map/repos.json ]] || return 0
  source "$ROOT/lib/runbook.sh"
  source "$ROOT/lib/notes.sh" 2>/dev/null || true
  mkdir -p "$DIR/map/runbooks"
  local n hold
  # shellcheck disable=SC2034  # read by notes_index, in this function's scope
  local NOTES_INDEX_CACHE=""
  # One parse of the notes for every runbook, not one per repo.
  hold=$(mktemp)
  notes_index_hold "$hold"
  # A runbook is some forty small jq, sed and grep runs, about a quarter of a
  # second each repo, so forty repos one after another was most of the ten
  # seconds `orgami doc` took. They share nothing but read-only inputs, so they
  # are written by eight workers, each taking every eighth repo: no queue to
  # keep, and the same eight scan defaults to. Each page goes to a temp file
  # first, so an interrupted run leaves no half a page for `orgami web` to read.
  local names=() k jobs=8
  while read -r n; do [[ -n $n ]] && names+=("$n"); done < <(jq -r '.[].name' "$DIR/map/repos.json")
  ((jobs > ${#names[@]})) && jobs=${#names[@]}
  for ((k = 0; k < jobs; k++)); do
    (
      local i out
      for ((i = k; i < ${#names[@]}; i += jobs)); do
        out="$DIR/map/runbooks/${names[i]}.md"
        runbook_render "${names[i]}" >"$out.tmp.$BASHPID" 2>/dev/null || true
        mv -f "$out.tmp.$BASHPID" "$out"
      done
    ) &
  done
  wait
  runbook_org
  runbook_incidents_page
  rm -f "$hold"

  # The index only. The playbooks themselves are written by a model, so they are
  # rewritten when an instance lands — not on every `orgami doc`.
  source "$ROOT/lib/playbook.sh"
  playbook_index >/dev/null 2>&1 || true
}

# Instructions for a Claude Project pointed at the published repository, so
# anyone — on the team or not — can ask questions without a terminal.
doc_ask_claude() {
  local out="$DIR/map/ASK-CLAUDE.md"
  local project
  project=$(cfg claude_project)

  cat >"$out" <<'ASKEOF'
# Ask Claude about this

Everything in this repository is written to be read by a person or by Claude.
To ask it questions without installing anything:

1. Go to [claude.ai](https://claude.ai) and create a **Project** — call it
   "__COMPANY__ engineering".
2. In the project, connect this GitHub repository so Claude can read it.
3. Paste everything below the line into the project's **custom instructions**.
4. Ask away. The project keeps its own history, so you can come back to it
   week after week.

Once it exists, save the project so everyone gets a direct link to it:

```bash
orgami claude-project https://claude.ai/project/<the-id-in-your-address-bar>
```

The link then appears at the top of this repository's front page, and anyone
with access to the project can open it in one click.

---

You answer questions about the engineering work at __COMPANY__, using only the
files in this repository. They are regenerated every week from the GitHub
organisation `__ORG__`.

What is in here:

- `reports/` — a recap of every week, newest last. What shipped and why, what
  broke, what needs acting on, and how the team worked. Start here for "what
  happened".
- `INCIDENTS.md` — what has broken, what it turned out to be, and what raises
  an alarm when it happens again.
- `DECISIONS.md` — choices that were made and why, each linked to the change
  that made it. Start here for "why is it like this".
- `RUNBOOK.md` and `runbooks/` — how each system is run, shipped and unbroken.
- `PLAYBOOKS.md` and `playbooks/` — how one recurring kind of change is made in
  one repository, written from the instances the team recorded doing it.
- `ARCHITECTURE.md` and `repos/` — what each system is and how they connect.
- `CONVENTIONS.md` — how this team writes code.

How to answer:

- Answer from these files. If the answer is not in them, say so plainly rather
  than reasoning from general knowledge about software. "That is not recorded
  here" is a good answer.
- Match the reader. If they are not an engineer, translate the technical terms
  or leave them out — a repository name like `Billing-API` means nothing to
  them, so say "the billing service". If they are an engineer, give them the
  detail and the links.
- Never state a number that is not written in the files. Do not estimate cost,
  revenue, hours, or customer counts. There is no basis for those here.
- Say which week you are drawing from. These files cover only the weeks that
  have been generated, so "that has never happened" is wrong — "it does not
  appear in the weeks recorded here" is right.
- Every claim in these files carries the pull request or the `file:line` it came
  from. Quote it, so the reader can check you.
- A missing connection between two systems means it was not found in committed
  configuration. It does not mean the two are unconnected.
- If asked what should be done, lay out what the files support and what they do
  not, and leave the decision with the reader.

Decline rather than guess on anything about money, headcount, contracts,
deadlines, or anything happening outside the code.
ASKEOF

  # A value is data: substituted literally, never handed to sed as a program.
  subst_file "$out" __COMPANY__ "$COMPANY" __ORG__ "$ORG"

  if [[ -n $project ]]; then
    local tmp
    tmp=$(mktemp)
    {
      echo "# Ask Claude about this"
      echo
      echo "### [→ Open the $COMPANY engineering project]($project)"
      echo
      echo "Ask it anything about the weeks recorded here. If you have never opened"
      echo "it before, Claude will ask you to sign in and to grant it access to this"
      echo "repository once."
      echo
      echo "---"
      echo
      tail -n +2 "$out"
    } >"$tmp"
    mv "$tmp" "$out"
  fi

  echo "$out" >&2
}

cmd_doc() {
  load_company
  local narrate=0 model=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --narrate) narrate=1; shift ;;
      --model) need_arg "$1" $#; model=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no graph — run: orgami scan"
  local out="$DIR/map/ARCHITECTURE.md"

  {
    echo "# $COMPANY architecture"
    echo
    echo "GitHub organization \`$ORG\` · $(jq -r '[.nodes[] | select(.kind=="repo")] | length' "$g") active repos · \
mapped $(jq -r '.generated | .[0:10]' "$g")"
    echo
    jq -r '[.edges[] | (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end))]
           | (map(select(. == "extracted")) | length) as $e
           | (map(select(. == "inferred")) | length) as $i
           | "\($e + $i) edges — **\($e) extracted**, read out of a committed file and"
             + " carrying the `file:line` you can open; **\($i) inferred**, resolved by"
             + " matching one repo'"'"'s reading against another'"'"'s and checkable only by"
             + " going and looking."' "$g"
    echo

    if [[ $narrate == 1 ]]; then
      need claude
      [[ -n $model ]] || model=$(cfg report_model claude-sonnet-5)
      log "narrating with $model"
      {
        cat <<'PROMPT'
Below is a dependency graph of an engineering organization, built by static
inspection of every repository. Write a short "How this fits together" section:
three to six paragraphs, GitHub-flavored markdown, no heading of its own.

Describe the shape of the system: which repos are central, which are leaves,
what the deployment story is, where the coupling is, and what looks fragile or
inconsistent (two deploy tools for the same kind of service, a repo nothing
references, a host reached from many repos). Only state what the graph supports;
edges carry file:line evidence, use it. Say plainly when the graph is too sparse
to conclude something. No praise, no filler.
PROMPT
        printf '\nGRAPH\n```json\n'
        cat "$g"
        printf '\n```\n'
      } | model_call "$model" || die "claude failed"
      echo
    fi

    echo "## Repositories"
    echo
    # Deployed with is tool: edges only. A vendor: edge shares the kind "uses"
    # but is a bill, not a deploy step, so it has a column of its own, by the
    # vendor's name, and not again when the same company is a deploy tool.
    # Reaches is the network: calls into another repo and hosts the repo
    # reaches. References is a name written in a file — often a README link —
    # which says the repo knows of the other, not that it talks to it.
    echo "| Repo | Language | Deployed with | Vendors | Depends on | Reaches | References |"
    echo "|---|---|---|---|---|---|---|"
    jq -r '
      def cell: unique | join(", ") | if . == "" then "—" else . end;
      . as $g
      | (reduce (.edges // [])[] as $e ({}; .[$e.from // "" | tostring] += [$e])) as $from
      | (reduce (.nodes // [])[] as $v ({}; if $v.kind == "vendor" then .[$v.id] = ($v.name // $v.id) else . end)) as $vn
      | [$g.nodes[] | select(.kind == "repo")] | sort_by(.name)[]
      | .name as $n
      | ($from["repo:" + $n] // []) as $out
      | [$out[] | select(.kind == "uses" and (.to | startswith("tool:"))) | .to | sub("^tool:"; "")] as $tools
      | [
          "[" + $n + "](" + (.meta.url // "") + ")",
          (.meta.language // "—"),
          ($tools | cell),
          ([$out[] | select(.kind == "uses" and (.to | startswith("vendor:")))
            | select(.to | sub("^vendor:"; "") | IN($tools[]) | not)
            | ($vn[.to] // (.to | sub("^vendor:"; "")))] | cell),
          ([$out[] | select(.kind == "depends-on")
            | .to | sub("^service:"; "")] | cell),
          ([$out[] | select(.kind == "calls" or .kind == "reaches")
            | .to | sub("^(repo|host):"; "")] | cell),
          ([$out[] | select(.kind == "references" or .kind == "imports")
            | .to | sub("^repo:"; "")] | cell)
        ] | "| " + join(" | ") + " |"' "$g"
    echo

    local links
    links=$(jq -r '[.edges[] | select(.kind | IN("references", "calls", "imports"))] | length' "$g")
    echo "## How the repositories reference each other"
    echo
    if [[ $links -gt 0 ]]; then
      echo "A solid arrow is **extracted** — the reference is a literal string in a"
      echo "committed file, and the evidence below is the \`file:line\` you can open. A"
      echo "dotted arrow is **inferred** — nothing declared it; it was resolved by"
      echo "matching one repo's reading against another's. Both are worth knowing."
      echo "Only one of them can be checked."
      echo
      echo '```mermaid'
      echo "graph LR"
      jq -r '.edges[] | select(.kind | IN("references", "calls", "imports"))
             | (if (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end)) == "inferred" then " -.-> " else " --> " end) as $arrow
             | "  " + (.from | sub("^repo:"; "") | gsub("[^a-zA-Z0-9]"; "_"))
               + "[" + (.from | sub("^repo:"; "")) + "]" + $arrow
               + (.to | sub("^repo:"; "") | gsub("[^a-zA-Z0-9]"; "_"))
               + "[" + (.to | sub("^repo:"; "")) + "]"' "$g" | sort -u
      echo '```'
      echo
      echo "<details><summary>Evidence for each edge</summary>"
      echo
      jq -r '.edges[] | select(.kind | IN("references", "calls", "imports"))
             | "- `" + (.from | sub("^repo:"; "")) + "` → `"
               + (.to | sub("^repo:"; "")) + "` — `" + .evidence + "`"
               + (if (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end)) == "inferred"
                  then " *(inferred — matched, not declared)*" else "" end)' "$g" | sort -u
      echo
      echo "</details>"
    else
      echo "No repository references another by URL, container image, or package name."
      echo "Either the services are genuinely independent, or they find each other"
      echo "through configuration this scan cannot see (runtime environment variables,"
      echo "service discovery, a shared gateway)."
    fi
    echo

    # Both of the next two sections are omitted outright when the graph has
    # nothing for them. A "## Deployment" with no tools under it, or a heading
    # followed by "No hosts found", is noise in every future diff — and unlike
    # the empty text under "Backing services" and "How the repositories
    # reference each other", it tells the reader nothing the absence of the
    # section does not already say.
    local deploys
    deploys=$(jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "tool")] | sort_by(.name)[]
      | .name as $t
      | "### " + $t + "\n\n"
        + ([$g.edges[] | select(.to == ("tool:" + $t) and .kind == "uses")
            | "- `" + (.from | sub("^repo:"; "")) + "` — `" + .evidence + "`"]
           | unique | join("\n"))' "$g")
    if [[ -n $deploys ]]; then
      echo "## Deployment"
      echo
      echo "$deploys"
      echo
    fi

    local hosts
    hosts=$(jq -r '[.nodes[] | select(.kind == "host")] | length' "$g")
    if [[ $hosts -gt 0 ]]; then
      echo "## Hosts and endpoints"
      echo
      echo "| Host | Reached from | Evidence |"
      echo "|---|---|---|"
      jq -r '
        . as $g
        | [$g.nodes[] | select(.kind == "host")] | sort_by(.name)[]
        | .name as $h
        | [$g.edges[] | select(.to == ("host:" + $h))] as $in
        | "| `" + $h + "` | "
          + ([$in[] | .from | sub("^repo:"; "")] | unique | join(", ")) + " | `"
          + ([$in[] | .evidence] | unique | join("`, `")) + "` |"' "$g"
      echo
      echo "> Hosts are extracted from deployment configuration by pattern match."
      echo "> Check the evidence column before trusting one."
      echo
    fi

    echo "## Backing services"
    echo
    jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "service")] as $svc
      | if ($svc | length) == 0 then
          "No databases, queues, or caches are declared in committed configuration. They may still exist — provisioned by hand, or wired in at runtime."
        else ($svc | sort_by(.name)[]
          | .name as $s
          | "- **" + $s + "** — "
            + ([$g.edges[] | select(.to == ("service:" + $s)) | .from | sub("^repo:"; "")]
               | unique | join(", ")))
        end' "$g"
    echo

    echo "## Unconnected repositories"
    echo
    jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "repo") | .name as $n | ("repo:" + $n) as $id
         | select([$g.edges[] | select((.kind | IN("references", "calls", "imports")) and (.from == $id or .to == $id))] | length == 0)
         | select([$g.edges[] | select(.from == $id and ((.kind == "uses" and (.to | startswith("tool:")))
                                                         or (.kind | IN("deploys-to", "reaches", "depends-on"))))] | length == 0)
         | $n] as $orphans
      | if ($orphans | length) == 0 then "Every repository is connected to something."
        else "These repos link to no other repo and declare no deployment tooling, host or backing service — a vendor they use is no link to anything here. Libraries, archives, or scratch:\n\n"
             + ($orphans | map("- `" + . + "`") | join("\n"))
        end' "$g"
    echo
    echo "---"
    echo
    echo "<sub>Generated by [orgami](https://github.com/Oldault/orgami). \
Extracted edges carry the \`file:line\` they came from; inferred edges say so and \
carry what was matched instead. Verify either before acting on it.</sub>"
  } >"$out"

  source "$ROOT/lib/html.sh"
  html_render
  echo "$DIR/map/graph.html" >&2

  doc_cards
  doc_conventions
  doc_runbooks
  doc_ask_claude
  doc_decisions

  # The whole map as one page, last: it reads what the steps above wrote — the
  # cards, the runbooks, the playbook index, the decisions page — so it has to
  # come after them. It goes where graph.html goes.
  source "$ROOT/lib/web.sh"
  web_render
  echo "$DIR/map/orgami.html" >&2

  echo "$out"
}
