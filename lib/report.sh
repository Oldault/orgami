# shellcheck shell=bash
# orgami report — deterministic stats by jq, narrative by claude.
# Numbers never come from the model.

# Durable decisions from this week's PRs, kept as one fragment per week so the
# record only ever grows. `orgami doc` assembles them into DECISIONS.md.
#
# The fragment is model prose about to be published as the team's record, so
# it waits in map/decisions/draft/ for a person to keep or drop each bullet
# (`orgami drafts`), the way a note drafted from a session does. The one
# setting that sends notes out unread, notes_autopublish, sends these out
# unread too — it is the same decision about the same kind of text.
report_decisions() {
  local week=$1 digest=$2 model=$3
  local dest="$DIR/map/decisions"
  mkdir -p "$dest"
  local held=1
  [[ $(cfg notes_autopublish false) == true ]] && held=0

  local body
  body=$( {
    cat "$ROOT/prompts/decisions.md"
    printf '\n\nPULL_REQUESTS\n```json\n'
    cat "$digest"
    printf '\n```\n'
  } | model_call "$model" 2>/dev/null || true)

  if [[ $body == NONE* ]] || ! model_output_ok "$body" '^- '; then
    rm -f "$dest/draft/$week.md"
    [[ $held == 1 ]] || rm -f "$dest/$week.md"
    [[ -n ${body// /} && $body != NONE* ]] && log "decisions for $week discarded — the model call did not complete"
    return 0
  fi

  local out="$dest/$week.md"
  if [[ $held == 1 ]]; then
    mkdir -p "$dest/draft"
    out="$dest/draft/$week.md"
  fi
  {
    echo "## $week"
    echo
    linkify_prs "$ORG" "$DIR/map/graph.json" <<<"$body"
  } >"$out"
  if [[ $held == 1 ]]; then
    log "$(grep -c '^- ' "$out") decision(s) drafted for $week — 'orgami drafts' keeps or drops each one"
  else
    log "decisions recorded for $week"
  fi
}

cmd_report() {
  load_company
  need jq

  local week="" model="" week_flag=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --week) need_arg "$1" $#; week=$2; week_flag=" --week $2"; shift 2 ;;
      --model) need_arg "$1" $#; model=$2; shift 2 ;;
      --stats-only) STATS_ONLY=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [[ -n $week ]] || week=$(iso_week)
  local src="$DIR/cache/prs/$week.json"
  if [[ ! -f $src ]]; then
    # Naming the way out: a bare "run: orgami pull" fetches only this week,
    # which is not the week that was asked for or already cached.
    # A glob, not `ls`: under errexit an `ls` that matches nothing ends the
    # run before either message below is printed.
    local have="" f
    for f in "$DIR"/cache/prs/*.json; do
      [[ -f $f && $f != *.stats.json ]] || continue
      f=${f##*/}
      have+="${f%.json} "
    done
    [[ -z $have ]] ||
      die "no cache for $week — cached: ${have% } — use: orgami report --week <one of them>, or: orgami pull --weeks-ago N"
    die "no cache for $week — run: orgami pull --last 1"
  fi

  local count
  count=$(jq '.prs | length' "$src")
  [[ $count -gt 0 ]] || die "no merged PRs in $week"

  local stats="$DIR/cache/prs/$week.stats.json"
  jq -L "$ROOT/lib" -f "$ROOT/lib/stats.jq" "$src" >"$stats"

  if [[ ${STATS_ONLY:-0} == 1 ]]; then
    cat "$stats"
    return
  fi

  # Here and not at the top: --stats-only never calls the model, so it must
  # work on a machine without claude. Before the digest, so a missing claude
  # leaves no temp file behind.
  need_claude "the weekly recap" "orgami report${week_flag} --stats-only"

  # Trim bodies and comments hard — the model needs intent, not diffs.
  local digest
  digest=$(mktemp)
  jq '[.prs[] | {
        repo: .repository.name,
        number, title, url,
        author: (.author.login // "unknown"),
        body: (.bodyText // "" | .[0:600]),
        labels: [.labels.nodes[].name],
        additions, deletions, changedFiles,
        merged: .mergedAt,
        reviewers: [.reviews.nodes[] | select(.state == "APPROVED"
                    or .state == "CHANGES_REQUESTED")
                    | {(.author.login // "unknown"): .state}] | add,
        review_notes: [.reviewThreads.nodes[].comments.nodes[]
                       | {path, note: (.bodyText // "" | .[0:200])}] | .[0:5]
      }]' "$src" >"$digest"

  [[ -n $model ]] || model=$(cfg report_model claude-sonnet-5)
  local out="$DIR/reports/$week.md"

  log "writing $week recap over $count PRs with $model"

  # Captured and checked before anything is written: a model that answers
  # "API Error: ..." with exit 0 must not become the week's recap.
  local recap
  recap=$( {
    cat "$ROOT/prompts/recap.md"
    printf '\n\nSTATS\n```json\n'
    cat "$stats"
    printf '\n```\n\nPULL_REQUESTS\n```json\n'
    cat "$digest"
    printf '\n```\n'
  } | model_call "$model" 2>/dev/null || true)
  if ! model_output_ok "$recap"; then
    rm -f "$digest"
    die "the model call did not complete — no recap written. Check that claude is authenticated, then: orgami report --week $week"
  fi
  plain_stat_keys "$stats" <<<"$recap" |
    linkify_prs "$ORG" "$DIR/map/graph.json" >"$out.body"

  report_decisions "$week" "$digest" "$model"
  rm -f "$digest"

  # The headline counts people, because that is what `merged` now means. An
  # organization running no bots should not read a zero saying so every week.
  local bot_note="" bot_merged
  bot_merged=$(jq -r .merged_by_bots "$stats")
  if [[ $bot_merged != 0 ]]; then bot_note=" (+$bot_merged by bots)"; fi

  {
    echo "# $COMPANY — week $week"
    echo
    echo "\`$(jq -r .since "$stats")\` to \`$(jq -r .until "$stats")\` · \
$(jq -r .merged "$stats") merged PRs$bot_note · \
$(jq -r .repos_touched "$stats") repos · \
median $(jq -r .median_hours_to_merge "$stats")h to merge"
    echo
    cat "$out.body"
    echo
    echo "---"
    echo
    echo "<sub>Generated by [orgami](https://github.com/Oldault/orgami) on \
$(date -u +%Y-%m-%d). Numbers computed from the GitHub API; prose written by \`$model\`.</sub>"
  } >"$out"
  rm -f "$out.body"

  echo "$out"
}

# orgami latest — read the most recent recap. Paged when a person is watching,
# plain on a pipe so it composes.
cmd_latest() {
  load_company
  local week="" raw=0 dir="$DIR/reports"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --week) need_arg "$1" $#; week=$2; shift 2 ;;
      --raw | --cat) raw=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local file
  if [[ -n $week ]]; then
    file="$dir/$week.md"
    [[ -f $file ]] || die "no recap for $week in $dir"
  else
    # Only YYYY-Www.md: after a join the directory also holds README.md, which
    # sorts after every week.
    file=$(find "$dir" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-W[0-9][0-9].md' 2>/dev/null | sort | tail -1)
    [[ -n $file ]] || die "no recap yet — run: orgami pull && orgami report"
  fi

  if [[ $raw == 1 || ! -t 1 ]]; then
    cat "$file"
    return 0
  fi

  if command -v glow >/dev/null; then
    glow -p "$file"
  elif command -v gum >/dev/null; then
    gum pager <"$file"
  else
    less -R "$file"
  fi
}
