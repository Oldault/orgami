# shellcheck shell=bash
# orgami pull — cache merged PRs for a week from the GitHub GraphQL search API.
# Re-running the same week overwrites its cache file; nothing else is touched.

# orgami reads an organization: its repo list, its `org:` searches, its members.
# A personal account has none of those endpoints, and GitHub's answer is a bare
# 404 or an empty search, so the reason is said here instead. Supporting one
# would mean `users/` and `user:` in every file that names the org, not a flag.
gh_refuse_personal() {
  local type
  type=$(gh api "users/$ORG" --jq .type 2>/dev/null || true)
  [[ $type == User ]] || return 0
  die "orgami maps GitHub organizations — $ORG is a personal account. Point $COMPANY at an organization instead: orgami init $COMPANY --org <github-org>"
}

# One page of a search, or a death that says why there is none. gh exits
# non-zero on a GraphQL error, and a response without `.data.search` would
# otherwise be read as a week with nothing in it.
pull_page() {
  local q=$1 after=${2-} out err why
  local args=(-F query="@$ROOT/lib/prs.graphql" -f q="$q")
  [[ -z $after ]] || args+=(-f after="$after")
  err=$(mktemp)
  out=$(gh api graphql "${args[@]}" 2>"$err") || {
    why=$(head -1 "$err")
    rm -f "$err"
    gh_refuse_personal
    die "GitHub search failed for '$q': $why — check: gh auth status"
  }
  rm -f "$err"
  jq -e '.data.search | type == "object"' <<<"$out" >/dev/null 2>&1 ||
    die "GitHub search returned no results for '$q' — check: gh auth status"
  printf '%s\n' "$out"
}

# One search query, every page of it, as a JSON array of pull requests on stdout.
# `orgami daily` runs the same query shape over a single day.
pull_search() {
  local q=$1 after="null" page=0 nodes tmp all
  all=$(mktemp)
  echo '[]' >"$all"

  while :; do
    if [[ $after == "null" ]]; then
      nodes=$(pull_page "$q") || { rm -f "$all"; return 1; }
    else
      nodes=$(pull_page "$q" "$after") || { rm -f "$all"; return 1; }
    fi

    page=$((page + 1))
    tmp=$(mktemp)
    jq --slurpfile new <(jq '[.data.search.nodes[] | select(.number != null)]' <<<"$nodes") \
      '. + $new[0]' "$all" >"$tmp"
    mv "$tmp" "$all"

    [[ $(jq -r '.data.search.pageInfo.hasNextPage' <<<"$nodes") == "true" ]] || break
    after=$(jq -r '.data.search.pageInfo.endCursor' <<<"$nodes")
    [[ $page -lt 20 ]] || { log "stopping at 1000 results (GitHub search cap) — narrow the range"; break; }
  done

  cat "$all"
  rm -f "$all"
}

cmd_pull() {
  load_company
  need gh

  local weeks_ago=0 since="" until=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --last) need_arg "$1" $#; weeks_ago=$2; shift 2 ;;
      --since) need_arg "$1" $#; since=$2; shift 2 ;;
      --until) need_arg "$1" $#; until=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  if [[ -z $since ]]; then
    since=$(week_start "$weeks_ago")
    until=$(date_shift "$since" +6)
  fi
  [[ -n $until ]] || until=$(date -u +%Y-%m-%d)

  local label
  label=$(date_fmt "$since" %G-W%V)
  local out="$DIR/cache/prs/$label.json"

  local q="org:$ORG is:pr is:merged merged:$since..$until"
  log "$COMPANY: $q"

  local after="null" page=0 total=0
  local nodes tmp all
  all=$(mktemp)
  echo '[]' >"$all"

  while :; do
    if [[ $after == "null" ]]; then
      nodes=$(pull_page "$q") || { rm -f "$all"; return 1; }
    else
      nodes=$(pull_page "$q" "$after") || { rm -f "$all"; return 1; }
    fi

    page=$((page + 1))
    total=$(jq -r '.data.search.issueCount // 0' <<<"$nodes")
    # An empty first page is also what `org:` returns for a personal account.
    [[ $page == 1 && $total == 0 ]] && gh_refuse_personal

    tmp=$(mktemp)
    jq --slurpfile new <(jq '[.data.search.nodes[] | select(.number != null)]' <<<"$nodes") \
      '. + $new[0]' "$all" >"$tmp"
    mv "$tmp" "$all"

    [[ $(jq -r '.data.search.pageInfo.hasNextPage' <<<"$nodes") == "true" ]] || break
    after=$(jq -r '.data.search.pageInfo.endCursor' <<<"$nodes")
    [[ $page -lt 20 ]] || { log "stopping at 1000 PRs (GitHub search cap) — narrow the range"; break; }
  done

  tmp=$(mktemp "$out.XXXXXX")
  jq -n --arg company "$COMPANY" --arg org "$ORG" --arg week "$label" \
    --arg since "$since" --arg until "$until" --argjson total "$total" \
    --slurpfile prs "$all" \
    '{company: $company, org: $org, week: $week, since: $since, until: $until,
      issue_count: $total, prs: $prs[0]}' >"$tmp"
  rm -f "$all"
  # The report reads this file as the week's truth; a half-written one would
  # be a week with fewer pull requests in it than really merged.
  jq -e '(.prs | type) == "array"' "$tmp" >/dev/null 2>&1 ||
    { rm -f "$tmp"; die "could not assemble $out — run orgami pull again"; }
  mv "$tmp" "$out"

  echo "$out  ($(jq '.prs | length' "$out") merged PRs, $since..$until)"
}
