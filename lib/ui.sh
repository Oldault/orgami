# shellcheck shell=bash
# The interactive front door: `orgami` with no arguments, and `orgami init`
# with no arguments. Every flag form still works without gum for scripts.

ui_need_gum() {
  command -v gum >/dev/null && return 0
  cat >&2 <<'EOF'
orgami: the interactive screens need gum (https://github.com/charmbracelet/gum)

  arch:     sudo pacman -S gum
  mac:      brew install gum

Everything works without it, with flags:
  orgami init acme --org acme-inc --docs-repo https://github.com/acme-inc/handbook.git
EOF
  return 1
}

ui_title() {
  style_init
  printf '%s%s%s\n' "${S_ACCENT}${S_B}" "$1" "$S_R"
}
ui_dim() {
  style_init
  printf '%s%s%s\n' "$S_MUTED" "$1" "$S_R"
}

ui_pause() {
  echo
  gum input --placeholder "enter to go back" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- setup wizard

# Organizations only: orgami cannot map a personal account (see
# gh_refuse_personal in lib/pull.sh), so the person's own login is not offered.
ui_pick_org() {
  local logins
  logins=$(gum spin --show-output --spinner dot --title "reading your GitHub organizations…" -- \
    bash -c 'gh api user/orgs --jq ".[].login" 2>/dev/null' |
    grep -v '^$' | sort -u || true)
  # user/orgs is empty for a token without read:org, too, so say both reasons.
  [[ -n $logins ]] ||
    ui_dim "gh lists no organizations for this account — orgami maps organizations, not personal accounts (if you are in one, try: gh auth refresh -s read:org)" >&2

  # ORGAMI_ORGS, or an "orgs" list in the root config, narrows the picker to the
  # ones worth seeing. "type another…" still reaches everything else.
  local only=${ORGAMI_ORGS:-}
  if [[ -z $only && -f $ORGAMI_HOME/config.json ]]; then
    only=$(jq -r '(.orgs // []) | join(" ")' "$ORGAMI_HOME/config.json")
  fi
  if [[ -n $only ]]; then
    logins=$(grep -Fxi -f <(printf '%s\n' ${only//,/ }) <<<"$logins" || true)
  fi

  local n
  n=$(wc -l <<<"$logins")
  if [[ $n -gt 8 ]]; then
    printf '%s\n' "$logins" "type another…" |
      gum filter --placeholder "which GitHub organization?" --height 12
  else
    # shellcheck disable=SC2046
    gum choose --header "Which GitHub organization?" $(printf '%s ' "$logins") "type another…"
  fi
}

ui_pick_docs_repo() {
  local org=$1 repos
  repos=$(gum spin --show-output --spinner dot --title "reading $org's repositories…" -- \
    bash -c "gh api 'orgs/$org/repos?per_page=100&sort=pushed' --jq '.[] | select(.archived | not) | .name' 2>/dev/null ||
             gh api 'users/$org/repos?per_page=100&sort=pushed' --jq '.[].name' 2>/dev/null || true")
  printf 'keep the reports local — no docs repo\ncreate a new repo in %s…\n%s\ntype a git URL…\n' \
    "$org" "$repos" |
    grep -v '^$' |
    gum filter --placeholder "where should the weekly report be committed?" --height 12
}

# Everything the weekly run writes is about the organization's private
# repositories as much as its public ones, so a public docs repo publishes that.
# Asked with no as the default, every time a public repo is about to be used.
ui_confirm_public() {
  local slug=$1
  {
    gum style --foreground 3 "$slug is public."
    ui_dim "Publishing there makes public: repository names and descriptions, the"
    ui_dim "environment variable names and hosts each repo uses, and recaps of work"
    ui_dim "in private repositories."
  } >&2
  gum confirm --default=no "Publish orgami's output to a public repo?" \
    --affirmative "yes, public" --negative "no"
}

# owner/repo out of a GitHub clone URL in either form, or nothing.
ui_repo_slug() {
  local url=$1 slug
  [[ $url =~ ^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)([^/]+/[^/]+)$ ]] || return 1
  slug=${BASH_REMATCH[2]%.git}
  valid_gh_name "$slug" slug || return 1
  echo "$slug"
}

# Creates the docs repo on GitHub and echoes its clone URL. Loops on a name clash.
ui_create_docs_repo() {
  local org=$1 name visibility out
  while :; do
    name=$(gum input --prompt "new repo in $org: " --value "orgami-reports") || return 1
    [[ -n $name ]] || return 1
    valid_gh_name "$name" repo ||
      { gum style --foreground 1 "'$name' is not a GitHub repository name" >&2; continue; }

    if gh api "repos/$org/$name" >/dev/null 2>&1; then
      gum style --foreground 3 "$org/$name already exists" >&2
      if gum confirm "Use it as the docs repo?"; then
        if [[ $(gh repo view "$org/$name" --json visibility --jq .visibility 2>/dev/null) != PUBLIC ]] ||
          ui_confirm_public "$org/$name"; then
          gh_clone_url "$org" "$name"
          return 0
        fi
      fi
      continue
    fi

    visibility=$(gum choose --header "Visibility?" "private" "public") || return 1
    [[ -n $visibility ]] || return 1
    if [[ $visibility == public ]] && ! ui_confirm_public "$org/$name"; then
      visibility=private
      ui_dim "creating it private" >&2
    fi

    if out=$(gh repo create "$org/$name" "--$visibility" --add-readme \
      --description "Weekly engineering recaps and architecture map, generated by orgami" 2>&1); then
      gum style --foreground 2 "✓ created $org/$name ($visibility)" >&2
      gh_clone_url "$org" "$name"
      return 0
    fi

    gum style --foreground 1 "$(head -2 <<<"$out")" >&2
    gum confirm "Try another name?" || return 1
  done
}

cmd_setup() {
  need_tty "pass it as flags: $INIT_USAGE"
  ui_need_gum || return 1
  need gh
  gh auth status >/dev/null 2>&1 || die "gh is not signed in — run: gh auth login"

  echo
  ui_title "Add an org to orgami"
  ui_dim "Everything stays in $ORGAMI_HOME. Nothing leaves your machine until you publish."
  echo

  local org
  org=$(ui_pick_org) || return 1
  [[ -n $org ]] || return 1
  if [[ $org == "type another…" ]]; then
    org=$(gum input --placeholder "github organization login" --prompt "org: ") || return 1
  fi
  [[ -n $org ]] || return 1

  init_check_org "$org"

  local company
  company=$(gum input --prompt "short name for this org: " --value "$org") || return 1
  company=${company// /-}
  [[ -n $company ]] || return 1
  [[ $company != */* && $company != .* ]] ||
    die "'$company' cannot be a directory name under $ORGAMI_HOME — pick a short name like acme"
  [[ -f $(company_dir "$company")/config.json ]] &&
    die "'$company' already exists — orgami list"

  local docs_repo="" docs_path="orgami" choice asked=0
  choice=$(ui_pick_docs_repo "$org") || return 1
  case $choice in
    "keep the reports local"*) docs_repo="" ;;
    "create a new repo in "*)
      # It asks about a public repo itself, at the point of choosing one.
      docs_repo=$(ui_create_docs_repo "$org") || return 1
      asked=1
      ;;
    "type a git URL…")
      docs_repo=$(gum input --placeholder "https://github.com/$org/handbook.git" --prompt "docs repo: ") || return 1
      ;;
    "") ;;
    *) docs_repo=$(gh_clone_url "$org" "$choice") ;;
  esac

  # A repo that is already public: the same question, before anything is
  # written, so the first publish below never surprises anyone. A no keeps the
  # repo in the config but leaves the push to `orgami publish`, which asks again.
  local publish_now=1 slug vis
  if [[ $asked == 0 && -n $docs_repo ]] && slug=$(ui_repo_slug "$docs_repo"); then
    vis=$(gh repo view "$slug" --json visibility --jq .visibility 2>/dev/null || true)
    if [[ $vis == PUBLIC ]] && ! ui_confirm_public "$slug"; then
      publish_now=0
    fi
  fi

  if [[ -n $docs_repo ]]; then
    docs_path=$(gum input --prompt "path inside that repo: " --value "orgami") || return 1
  fi

  local exclude="[]" patterns
  if gum confirm --default=no "Skip some repositories?" --affirmative "yes" --negative "no"; then
    patterns=$(gum input --prompt "skip repos matching: " \
      --placeholder "archived-, -sandbox, ^test") || true
    [[ -n $patterns ]] && exclude=$(jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))' <<<"$patterns")
  fi

  local model
  model=$(gum choose --header "Which model writes the recap?" \
    "claude-sonnet-5" "claude-opus-5" "claude-haiku-4-5-20251001") || return 1

  local dir
  dir=$(company_dir "$company")
  mkdir -p "$dir"/{cache/prs,cache/repos,cache/src,reports,map}
  jq -n --arg company "$company" --arg org "$org" --arg docs_repo "$docs_repo" \
    --arg docs_path "$docs_path" --argjson exclude "$exclude" --arg model "$model" \
    '{company: $company, org: $org, docs_repo: $docs_repo, docs_path: $docs_path,
      exclude: $exclude, include: [], report_model: $model}' >"$dir/config.json.tmp"
  mv "$dir/config.json.tmp" "$dir/config.json"

  mkdir -p "$ORGAMI_HOME"
  [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
  local tmp
  tmp=$(mktemp)
  jq --arg c "$company" '.default = (.default // $c)' "$ORGAMI_HOME/config.json" >"$tmp"
  mv "$tmp" "$ORGAMI_HOME/config.json"

  echo
  gum style --foreground 2 "✓ $company saved to $dir/config.json"
  echo

  export ORGAMI_COMPANY="$company"

  # The first build runs on its own — an org that is configured but empty is of
  # no use to anyone. Ctrl-C leaves the config in place and stops cleanly.
  trap 'rm -f "${err:-}"; echo; ui_dim "stopped — $company is saved, finish it later with: orgami"; exit 0' INT

  # The map first: the recap links pull requests only in repositories the map
  # already holds (linkify_prs), so a recap written before the first scan would
  # come out with no links at all.
  ui_dim "scanning every repo in $org — the slow part, once per refresh"
  if "$ORGAMI_BIN" scan; then
    "$ORGAMI_BIN" doc >/dev/null && gum style --foreground 2 "✓ map/ARCHITECTURE.md"
  else
    gum style --foreground 3 "scan failed — try again with: orgami scan"
  fi

  local week prs err why
  week=$(iso_week)
  err=$(mktemp)

  if gum spin --spinner dot --title "fetching merged pull requests…" -- "$ORGAMI_BIN" pull; then
    # Set up on a Monday and this week is empty. Recap the last full week instead.
    prs=$(jq '.prs | length' "$dir/cache/prs/$week.json" 2>/dev/null || echo 0)
    if [[ ${prs:-0} -eq 0 ]]; then
      week=$(date_fmt "$(week_start 1)" %G-W%V)
      gum spin --spinner dot --title "nothing merged yet this week — fetching $week…" -- \
        "$ORGAMI_BIN" pull --last 1 || true
    fi
    if ! command -v claude >/dev/null; then
      gum style --foreground 3 "no recap — claude is not on PATH; install Claude Code, then: orgami report --week $week"
    elif gum spin --spinner dot --title "writing the $week recap with $model…" -- \
      bash -c '"$0" report --week "$1" 2>"$2"' "$ORGAMI_BIN" "$week" "$err"; then
      gum style --foreground 2 "✓ reports/$week.md"
    else
      # The reason is report's own last word on stderr: nothing merged, a model
      # error, a missing cache. Guessing "nothing merged" hid the other two.
      why=$(grep -v '^[[:space:]]*$' "$err" | tail -1 || true)
      why=${why#orgami: }
      gum style --foreground 3 "no recap for $week — ${why:-report exited without saying why}"
    fi
  else
    gum style --foreground 3 "could not read pull requests from $org"
  fi
  rm -f "$err"

  if [[ -n $docs_repo && $publish_now == 1 ]]; then
    if gum spin --spinner dot --title "publishing to $docs_repo…" -- "$ORGAMI_BIN" publish --yes; then
      gum style --foreground 2 "✓ pushed to $docs_repo"
    else
      gum style --foreground 3 "could not publish — try again with: orgami publish"
    fi
  elif [[ -n $docs_repo ]]; then
    ui_dim "not published — orgami publish pushes it when you are ready"
  fi

  trap - INT

  if gum confirm "Run all of that every Friday?"; then
    "$ORGAMI_BIN" schedule || gum style --foreground 3 "could not schedule it — orgami schedule"
  fi

  # The digest is a second, much smaller habit: one model call a weekday
  # morning, and nothing at all on a day where nothing landed.
  ui_dim "A digest of each day — what merged, what opened, what is waiting on"
  ui_dim "someone — costs one model call a weekday morning, and writes nothing"
  ui_dim "on a quiet day."
  if gum confirm "And a digest each weekday morning?"; then
    "$ORGAMI_BIN" schedule --daily ||
      gum style --foreground 3 "could not schedule it — orgami schedule --daily"
  fi

  echo
  ui_dim "orgami        the menu"
  ui_dim "orgami view   browse the map"
  ui_dim "orgami daily  today so far, any time you want it"
}

# ----------------------------------------------------------------- main menu

ui_status_line() {
  local dir=$1 line=""
  local latest
  latest=$(find "$dir/reports" -name '*.md' 2>/dev/null | sort | tail -1)
  if [[ -n $latest ]]; then
    line="last recap $(basename "$latest" .md)"
  else
    line="no recap yet"
  fi
  if [[ -f $dir/map/graph.json ]]; then
    line="$line · map from $(jq -r '.generated | .[0:10]' "$dir/map/graph.json")"
    line="$line · $(jq -r '[.nodes[] | select(.kind == "repo")] | length' "$dir/map/graph.json") repos"
  else
    line="$line · no map yet"
  fi
  echo "$line"
}

cmd_menu() {
  need_tty "every menu entry is a subcommand: orgami help lists them"
  ui_need_gum || { usage; return 1; }

  if [[ -z $(companies) ]]; then
    ui_title "orgami"
    ui_dim "Nothing configured yet."
    echo
    gum confirm "Add your first org?" && cmd_setup
    return 0
  fi

  local company dir action
  while :; do
    # current_company dies, which ends its own subshell before any `|| true`
    # inside it could run; the status is caught out here instead.
    company=$(current_company 2>/dev/null) || company=""
    # Companies but no default (or a default that is gone): setup picks one.
    # Cancelling it ends the menu, rather than coming straight back round to the
    # same question.
    [[ -n $company && -f $(company_dir "$company")/config.json ]] ||
      { cmd_setup || return 0; continue; }
    dir=$(company_dir "$company")
    export ORGAMI_COMPANY="$company"

    clear
    style_init
    COMPANY=$company DIR=$dir ORG=$(jq -r .org "$dir/config.json") tui_status_line
    style_rule "$(style_cols)"
    echo

    local daily_toggle="turn the daily digest on"
    [[ $(jq -r '.daily // false' "$dir/config.json") == true ]] &&
      daily_toggle="turn the daily digest off"

    # One organization is the common case: the switcher only shows up once
    # there is something to switch to.
    local -a org_actions=("add an org")
    [[ $(companies | wc -l) -gt 1 ]] && org_actions=("switch org" "add an org")

    action=$(gum choose \
      "browse the map" \
      "open the map in a browser" \
      "see what to consolidate" \
      "read the org's DNS" \
      "read the latest recap" \
      "write this week's recap" \
      "write today's digest" \
      "$daily_toggle" \
      "rebuild the map" \
      "publish to the docs repo" \
      "${org_actions[@]}" \
      "quit") || return 0

    case $action in
      "browse the map")
        [[ -f $dir/map/graph.json ]] ||
          { gum style --foreground 3 "no map yet — rebuild it first"; ui_pause; continue; }
        "$ORGAMI_BIN" view
        ;;
      "open the map in a browser")
        [[ -f $dir/map/graph.json ]] ||
          { gum style --foreground 3 "no map yet — rebuild it first"; ui_pause; continue; }
        "$ORGAMI_BIN" web --open >/dev/null ||
          { gum style --foreground 3 "could not render the page — orgami web"; ui_pause; }
        ;;
      "see what to consolidate")
        [[ -f $dir/map/graph.json ]] ||
          { gum style --foreground 3 "no map yet — rebuild it first"; ui_pause; continue; }
        "$ORGAMI_BIN" advise | gum pager
        ;;
      # Not behind the pager: this one asks which domains it may query, and a
      # pager would swallow the question.
      "read the org's DNS")
        "$ORGAMI_BIN" dns || gum style --foreground 3 "nothing was read"
        ui_pause
        ;;
      "read the latest recap")
        local latest
        latest=$(find "$dir/reports" -name '*.md' 2>/dev/null | sort | tail -1)
        [[ -n $latest ]] ||
          { gum style --foreground 3 "no recap yet"; ui_pause; continue; }
        if command -v glow >/dev/null; then
          glow -p "$latest"
        else
          gum pager <"$latest"
        fi
        ;;
      "write this week's recap")
        gum spin --spinner dot --title "fetching merged pull requests…" -- \
          "$ORGAMI_BIN" pull || { gum style --foreground 1 "pull failed"; ui_pause; continue; }
        gum spin --spinner dot --title "writing the recap…" -- \
          "$ORGAMI_BIN" report || { gum style --foreground 1 "report failed"; ui_pause; continue; }
        gum style --foreground 2 "✓ reports/$(iso_week).md"
        ui_pause
        ;;
      "write today's digest")
        "$ORGAMI_BIN" daily || gum style --foreground 3 "the digest did not run"
        ui_pause
        ;;
      "turn the daily digest off")
        "$ORGAMI_BIN" schedule --daily --off || true
        ui_pause
        ;;
      "turn the daily digest on")
        "$ORGAMI_BIN" schedule --daily || true
        ui_pause
        ;;
      "rebuild the map")
        "$ORGAMI_BIN" scan && "$ORGAMI_BIN" doc >/dev/null &&
          gum style --foreground 2 "✓ map/ARCHITECTURE.md"
        ui_pause
        ;;
      "publish to the docs repo")
        "$ORGAMI_BIN" publish || true
        ui_pause
        ;;
      "switch org")
        local pick
        # shellcheck disable=SC2046
        pick=$(gum choose --header "Which org?" $(companies | tr '\n' ' ')) || continue
        [[ -n $pick ]] && cmd_use "$pick" >/dev/null
        ;;
      "add an org")
        cmd_setup
        ui_pause
        ;;
      quit) return 0 ;;
    esac
  done
}
