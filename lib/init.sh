# shellcheck shell=bash
# orgami init / use / list — one directory per company.

INIT_USAGE='orgami init <company> --org <github-org> [--docs-repo <url> | --no-docs]
              [--docs-path <dir>] [--exclude <pattern,...>] [--model <model>]
              [--daily] [--daily-at HH:MM]'

# init_check_org <org> — can the current gh token read this organization? Each
# way it cannot gets its own next step, because "check gh auth status" is no help
# to someone who typed their own login, or whose token lacks one scope.
init_check_org() {
  local org=$1 err type st
  gh auth status >/dev/null 2>&1 || die "gh is not signed in — run: gh auth login"
  valid_gh_name "$org" owner ||
    die "'$org' is not a GitHub organization login (letters, digits and single hyphens)"

  if ! err=$(gh api "orgs/$org" --jq .login 2>&1 >/dev/null); then
    # orgami reads an organization's repo list and its org: searches, which a
    # personal account does not have — the same refusal scan and pull make.
    type=$(gh api "users/$org" --jq .type 2>/dev/null || true)
    [[ $type == User ]] &&
      die "orgami maps GitHub organizations — $org is a personal account. Pass the organization instead: orgami init <company> --org <github-org> (gh org list shows yours)"
    case $err in
      *"Not Found"* | *404*)
        die "no GitHub organization called '$org' — check the spelling (gh org list shows yours)" ;;
      *SAML* | *SSO*)
        die "the gh token is not authorized for $org's single sign-on — run: gh auth refresh -h github.com -s read:org, then authorize it for $org" ;;
      *)
        die "the gh token cannot read $org (${err%%$'\n'*}) — run: gh auth refresh -h github.com -s read:org" ;;
    esac
  fi

  # gh's own login asks for read:org; a hand-made classic token often lacks it,
  # and still reads the org above. Only a warning, since what it hides depends
  # on the org's settings. Fine-grained tokens print no scopes line at all.
  st=$(gh auth status --active 2>&1 || gh auth status 2>&1 || true)
  if [[ $st == *"Token scopes:"* && $st != *read:org* && $st != *admin:org* ]]; then
    log "the gh token has no read:org scope — if repositories are missing from the map: gh auth refresh -h github.com -s read:org"
  fi
  return 0
}

cmd_init() {
  local company="" org="" docs_repo="" docs_path="orgami" exclude="" model=""
  local daily=false daily_at="08:00"
  case ${1:-} in
    -h | --help) printf 'usage: %s\n' "$INIT_USAGE"; return 0 ;;
    -*) company="" ;;
    *) company=${1:-}; shift || true ;;
  esac
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help) printf 'usage: %s\n' "$INIT_USAGE"; return 0 ;;
      --org) need_arg "$1" $#; org=$2; shift 2 ;;
      --docs-repo) need_arg "$1" $#; docs_repo=$2; shift 2 ;;
      --no-docs) docs_repo=""; shift ;;
      --docs-path) need_arg "$1" $#; docs_path=$2; shift 2 ;;
      --exclude)
        need_arg "$1" $# "--exclude wants patterns, e.g. --exclude 'archived-,-sandbox'"
        exclude=$2; shift 2 ;;
      --model) need_arg "$1" $#; model=$2; shift 2 ;;
      --daily) daily=true; shift ;;
      --no-daily) daily=false; shift ;;
      --daily-at)
        need_arg "$1" $# "--daily-at wants a time, e.g. --daily-at 08:00"
        daily_at=$2; daily=true; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  # Same clock as `orgami schedule --at`: this writes the same daily_at, and the
  # config is read by every machine in the company.
  daily_at=$(hhmm "$daily_at") ||
    die "--daily-at wants HH:MM on a 24-hour clock, got '$daily_at'"

  [[ -n $company ]] || die "a company name is required — usage: $INIT_USAGE"
  [[ -n $org ]] || die "--org is required (the GitHub organization login) — usage: $INIT_USAGE"
  [[ $company != */* && $company != .* ]] ||
    die "'$company' cannot be a directory name under $ORGAMI_HOME — pick a short name like acme"

  need gh
  init_check_org "$org"

  local exclude_json="[]"
  [[ -z $exclude ]] ||
    exclude_json=$(jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))' <<<"$exclude")

  local dir
  dir=$(company_dir "$company")
  [[ -f $dir/config.json ]] && die "'$company' already exists at $dir"
  mkdir -p "$dir"/{cache/prs,cache/repos,cache/src,reports,map}

  jq -n \
    --arg company "$company" \
    --arg org "$org" \
    --arg docs_repo "$docs_repo" \
    --arg docs_path "$docs_path" \
    --argjson daily "$daily" \
    --arg daily_at "$daily_at" \
    --argjson exclude "$exclude_json" \
    --arg model "${model:-claude-sonnet-5}" \
    '{company: $company, org: $org, docs_repo: $docs_repo, docs_path: $docs_path,
      daily: $daily, daily_at: $daily_at,
      exclude: $exclude, include: [], report_model: $model}' \
    >"$dir/config.json.tmp"
  mv "$dir/config.json.tmp" "$dir/config.json"

  mkdir -p "$ORGAMI_HOME"
  [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
  local tmp
  tmp=$(mktemp)
  jq --arg c "$company" '.default = (.default // $c)' "$ORGAMI_HOME/config.json" >"$tmp"
  mv "$tmp" "$ORGAMI_HOME/config.json"

  echo "created $dir"
  if [[ $daily == true ]]; then
    ORGAMI_COMPANY=$company "$ORGAMI_BIN" schedule --daily >/dev/null 2>&1 ||
      log "could not install the daily timer — orgami schedule --daily"
  fi
  echo "next: orgami scan  (then orgami pull for the weekly numbers)"
}

cmd_use() {
  local company=${1:-}
  [[ -n $company ]] || die "usage: orgami use <company>"
  [[ -f $(company_dir "$company")/config.json ]] || die "unknown company '$company' — orgami list"
  local tmp
  tmp=$(mktemp)
  [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
  jq --arg c "$company" '.default = $c' "$ORGAMI_HOME/config.json" >"$tmp"
  mv "$tmp" "$ORGAMI_HOME/config.json"
  echo "default company: $company"
}

cmd_list() {
  local default=""
  [[ -f $ORGAMI_HOME/config.json ]] && default=$(jq -r '.default // ""' "$ORGAMI_HOME/config.json")
  local c org
  while read -r c; do
    [[ -n $c ]] || continue
    org=$(jq -r '.org' "$(company_dir "$c")/config.json")
    if [[ $c == "$default" ]]; then
      printf '* %-20s %s\n' "$c" "$org"
    else
      printf '  %-20s %s\n' "$c" "$org"
    fi
  done < <(companies)
}

# orgami claude-project — remember the Claude Project that reads the docs repo,
# so the published front page can link straight to it.
cmd_claude_project() {
  load_company
  local url=${1:-}

  if [[ -z $url ]]; then
    url=$(cfg claude_project)
    [[ -n $url ]] || die "no Claude project saved — orgami claude-project <url>"
    echo "$url"
    return 0
  fi

  [[ $url =~ ^https://claude\.ai/project/[A-Za-z0-9-]+ ]] ||
    die "that is not a Claude project link — open the project and copy the address bar"

  local tmp
  tmp=$(mktemp)
  jq --arg u "$url" '.claude_project = $u' "$DIR/config.json" >"$tmp"
  mv "$tmp" "$DIR/config.json"
  echo "saved for $COMPANY — it will appear on the front page at the next publish"
}
