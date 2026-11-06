# shellcheck shell=bash
# Shared helpers: paths, config access, company selection.

ORGAMI_HOME="${ORGAMI_HOME:-$HOME/.orgami}"

# --- portability -------------------------------------------------------------
# macOS ships a BSD userland. These are the places it differs from GNU in ways
# that matter here; everything else in orgami is plain POSIX.

if date -u -d @0 +%Y >/dev/null 2>&1; then
  ORGAMI_DATE=gnu
else
  ORGAMI_DATE=bsd
fi

# The absolute path of a file, following symlinks. BSD readlink has no -f.
orgami_realpath() {
  local p=$1 t
  while [[ -L $p ]]; do
    t=$(readlink "$p")
    if [[ $t == /* ]]; then p=$t; else p=$(dirname "$p")/$t; fi
  done
  (cd "$(dirname "$p")" >/dev/null 2>&1 && printf '%s/%s\n' "$PWD" "$(basename "$p")")
}

# date_shift <YYYY-MM-DD> <signed days>
date_shift() {
  if [[ $ORGAMI_DATE == gnu ]]; then
    date -u -d "$1 $2 days" +%Y-%m-%d
  else
    date -u -j -f %Y-%m-%d "$1" -v"$2"d +%Y-%m-%d
  fi
}

# date_fmt <YYYY-MM-DD> <strftime format>
date_fmt() {
  if [[ $ORGAMI_DATE == gnu ]]; then
    date -u -d "$1" +"$2"
  else
    date -u -j -f %Y-%m-%d "$1" +"$2"
  fi
}

# Directories containing a file, without GNU find's -printf.
find_dirs_containing() {
  local root=$1 name=$2 depth=${3:-5}
  find "$root" -maxdepth "$depth" -name "$name" -print 2>/dev/null |
    sed 's|/[^/]*$||'
}

# file_mtime <path> — epoch seconds of the last change, or 0 when there is no
# such file. GNU stat spells it -c %Y, BSD stat -f %m; and GNU stat reads -f as
# "file system", so the order matters and the existence test comes first.
file_mtime() {
  [[ -e $1 ]] || { echo 0; return 0; }
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# detach <log> <command> [args...] — start it outside this session and return
# at once; stdout and stderr are appended to <log> (/dev/null for neither).
# `(setsid cmd &) || (cmd &)` cannot fall back: the subshell succeeds as soon as
# it has forked, whether or not setsid exists. macOS has no setsid, so there the
# command runs under nohup, which is enough to outlive the terminal that started
# it. stdin is /dev/null so a hook's pipe is never held open by the child.
detach() {
  local log=$1
  shift
  if command -v setsid >/dev/null 2>&1; then
    (setsid "$@" </dev/null >>"$log" 2>&1 &)
  else
    (nohup "$@" </dev/null >>"$log" 2>&1 &)
  fi
  return 0
}

# subst_file <file> <placeholder> <value> [<placeholder> <value>...]
# Replaces every literal occurrence of each placeholder, in place. No sed: a
# value is data, and `s|__ORG__|$ORG|g` turns a `|`, `&`, `\` or newline in it
# into sed syntax. Matching here is quoted bash string matching, so nothing in a
# placeholder or a value is a pattern. It is one pass, left to right: text that
# came from a value is never searched again, so a company named `__ORG__` stays
# `__ORG__`. The file is rewritten through a copy that keeps its mode, then
# moved into place.
subst_file() {
  local file=$1 rest out="" pre tmp i best len
  local -a ph=() val=()
  shift
  [[ -f $file ]] || die "subst_file: no such file $file"
  (($# % 2 == 0)) || die "subst_file: placeholder without a value"
  while (($#)); do
    [[ -n $1 ]] || die "subst_file: empty placeholder"
    ph+=("$1") val+=("$2")
    shift 2
  done
  # read -d '' keeps trailing newlines, which $(cat) would strip.
  IFS= read -r -d '' rest <"$file" || true
  while :; do
    best=-1 len=0
    for i in "${!ph[@]}"; do
      [[ $rest == *"${ph[i]}"* ]] || continue
      pre=${rest%%"${ph[i]}"*}
      if ((best < 0 || ${#pre} < len)); then best=$i len=${#pre}; fi
    done
    ((best >= 0)) || break
    out+=${rest:0:len}${val[best]}
    rest=${rest:len+${#ph[best]}}
  done
  out+=$rest
  tmp=$(mktemp "$file.XXXXXX")
  cp -p "$file" "$tmp"
  printf '%s' "$out" >"$tmp"
  mv "$tmp" "$file"
}

# valid_gh_name <name> [owner|repo|slug] — does it have the shape GitHub allows?
# owner: a user or organization login, alphanumeric with single inner hyphens,
# at most 39 characters. repo: letters, digits, `.`, `_`, `-`, at most 100, and
# never `.` or `..`. slug: owner/repo. Anything read from config or typed by a
# person goes through this before it reaches a shell word, a sed program or a URL.
valid_gh_name() {
  local name=$1 kind=${2:-owner}
  case $kind in
    owner)
      ((${#name} <= 39)) && [[ $name =~ ^[A-Za-z0-9](-?[A-Za-z0-9])*$ ]]
      ;;
    repo)
      ((${#name} <= 100)) && [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != . && $name != .. ]]
      ;;
    slug)
      [[ $name == */* ]] && valid_gh_name "${name%%/*}" owner && valid_gh_name "${name#*/}" repo
      ;;
    *) return 1 ;;
  esac
}

# gh_clone_url <owner> <repo> — the clone URL in whichever protocol the person
# told gh to use. https unless gh says ssh, because an https URL works through
# gh's credential helper with no key on the machine.
gh_clone_url() {
  local owner=$1 repo=$2 proto=""
  valid_gh_name "$owner" owner || die "not a GitHub owner name: '$owner'"
  valid_gh_name "$repo" repo || die "not a GitHub repository name: '$repo'"
  if command -v gh >/dev/null 2>&1; then
    proto=$(gh config get git_protocol -h github.com 2>/dev/null || true)
    [[ -n $proto ]] || proto=$(gh config get git_protocol 2>/dev/null || true)
  fi
  if [[ $proto == ssh ]]; then
    echo "git@github.com:$owner/$repo.git"
  else
    echo "https://github.com/$owner/$repo.git"
  fi
}

# need_tty <headless hint> — for a step that asks questions. A coding agent runs
# orgami through a Bash tool with no terminal, where a prompt would wait forever
# for an answer nobody can type; fail at once and name the flag that skips it.
need_tty() {
  [[ -t 0 && -t 2 ]] || die "this step asks questions and there is no terminal — $1"
}

# Every model call orgami makes reads text it did not write: pull request
# bodies, commit messages, notes, session transcripts. So the model is given
# nothing to act with, and none of the person's own Claude Code setup.
#   --tools ""                 no built-in tool at all: it can only write text.
#   --setting-sources ""       no user, project or local settings, so none of
#                              their hooks, permissions or enabled plugins.
#   --strict-mcp-config        no MCP server, since none is passed with it.
# Added when the installed claude knows them (older ones reject unknown flags):
#   --safe-mode                hooks, plugins, skills and CLAUDE.md off — the
#                              plugin's own SessionStart hook would otherwise
#                              fire inside every call and recurse into
#                              orgami autosync and update.
#   --no-session-persistence   the call leaves no transcript, so note-sweep
#                              never reads orgami's own prompts back as a session.
# Not --bare: it never reads OAuth or the keychain, which breaks everyone on a
# Claude subscription rather than an API key.
ORGAMI_MODEL_FLAGS=(--tools "" --setting-sources "" --strict-mcp-config)
ORGAMI_MODEL_OPTIONAL_FLAGS=(--safe-mode --no-session-persistence)

# model_call <model> — the prompt on stdin, the reply on stdout. claude's own
# stderr is left alone; the caller decides whether to keep it.
model_call() {
  local model=$1 help f
  if [[ -z ${_ORGAMI_MODEL_FLAGS_PROBED:-} ]]; then
    help=$(claude --help 2>/dev/null || true)
    for f in "${ORGAMI_MODEL_OPTIONAL_FLAGS[@]}"; do
      [[ $help == *"$f"* ]] && ORGAMI_MODEL_FLAGS+=("$f")
    done
    _ORGAMI_MODEL_FLAGS_PROBED=1
  fi
  claude -p --model "$model" --output-format text "${ORGAMI_MODEL_FLAGS[@]}"
}

die() {
  echo "orgami: $*" >&2
  exit 1
}

log() { echo "  $*" >&2; }

need() {
  command -v "$1" >/dev/null || die "$1 is not on PATH${2:+ ($2)}"
}

# need_arg <flag> <argc> [message] — guard for `--flag) x=$2; shift 2` parse
# arms. bin/orgami runs under `set -u`, so a value-taking flag typed as the
# last argument reads an unset $2 and aborts with bash's own "unbound
# variable" — a message that names neither orgami nor the flag. Call it
# before touching $2:  --week) need_arg "$1" $#; week=$2; shift 2 ;;
need_arg() {
  [[ $2 -ge 2 ]] || die "${3:-$1 wants a value after it}"
}

# gh_auth_die <gh error text> — die with the next step when <text> is gh
# failing to authenticate, and return when it is some other failure, which the
# caller words itself. A token in GH_TOKEN or GITHUB_TOKEN wins over gh's
# stored login, so when that token is the bad one `gh auth login` changes
# nothing, and the message names the variable instead.
gh_auth_die() {
  local text=$1 var=""
  if [[ -n ${GH_TOKEN:-} ]]; then var=GH_TOKEN; elif [[ -n ${GITHUB_TOKEN:-} ]]; then var=GITHUB_TOKEN; fi
  case $text in
    *"The token in "*" is invalid"* | *"Bad credentials"* | *"HTTP 401"*)
      [[ -z $var ]] || die "GitHub rejected the token in $var — replace it, or unset $var to use gh's own login (gh auth login)"
      die "GitHub rejected gh's stored token — run: gh auth login -h github.com" ;;
    *"not logged into"* | *"gh auth login"*)
      die "gh is not signed in — run: gh auth login" ;;
  esac
  return 0
}

# gh_auth_check — die, with the next step, unless gh can authenticate to
# github.com. --active is gh 2.40 and later; an older gh refuses the flag and
# is asked again without it.
gh_auth_check() {
  local st why
  st=$(gh auth status --active -h github.com 2>&1) || st=$(gh auth status -h github.com 2>&1) || {
    gh_auth_die "$st"
    # The first line is the host name; the reason is on the line marked X.
    why=$(grep -m1 'X ' <<<"$st" || head -1 <<<"$st")
    why=${why#"${why%%[![:space:]]*}"}
    die "gh could not check its sign-in (${why#X }) — check the network, then: gh auth status"
  }
  return 0
}

company_dir() { echo "$ORGAMI_HOME/$1"; }

current_company() {
  if [[ -n ${ORGAMI_COMPANY:-} ]]; then
    echo "$ORGAMI_COMPANY"
    return
  fi
  local root="$ORGAMI_HOME/config.json"
  [[ -f $root ]] || die "no company selected — run: orgami init <company> --org <github-org>"
  jq -re '.default // empty' "$root" 2>/dev/null ||
    die "no default company — run: orgami use <company>"
}

# Sets COMPANY, DIR, ORG for the rest of a subcommand.
# shellcheck disable=SC2034  # ORG is read by the other libs sourced alongside this one
load_company() {
  COMPANY=$(current_company)
  DIR=$(company_dir "$COMPANY")
  [[ -f $DIR/config.json ]] || die "unknown company '$COMPANY' — orgami list"
  ORG=$(cfg org)
  # $ORG goes into gh arguments, URLs and generated pages from here on, so a
  # config edited by hand or by somebody else's commit is checked once, here.
  valid_gh_name "$ORG" owner ||
    die "'$COMPANY' has org '$ORG' in $DIR/config.json, which is not a GitHub organization name — fix it, or run: orgami init $COMPANY --org <github-org>"
  mkdir -p "$DIR"/{cache/prs,cache/repos,cache/src,reports,map}
}

# cfg <jq-path> [default]
cfg() {
  local val
  val=$(jq -r --arg d "${2-}" ".$1 // \$d" "$DIR/config.json")
  echo "$val"
}

companies() {
  [[ -d $ORGAMI_HOME ]] || return 0
  find "$ORGAMI_HOME" -mindepth 2 -maxdepth 2 -name config.json -print 2>/dev/null |
    sed 's|/config.json$||' | while read -r d; do basename "$d"; done | sort
}

iso_week() { date -u +%G-W%V; }

# A time of day on a 24-hour clock, for the daily digest. The hour is 00-23:
# `[0-2][0-9]` reads as 24 hours but matches 29, and `24:00` reaches
# `OnCalendar=` as a time systemd cannot parse — a timer that never fires, from
# a config every machine in the company agrees on.
#
# A single-digit hour is accepted, because `8:00` is what a person types, and
# normalised to two digits here so that one shape reaches all three schedulers
# rather than each one's own tolerance for `8:00`.
#
# Echoes the normalised HH:MM, or returns 1 and echoes nothing.
hhmm() {
  [[ $1 =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || return 1
  printf '%02d:%s\n' "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
}

# Monday of the week containing $1 weeks ago (0 = this week). Computed from the
# day of week rather than "last monday", which means different things per date
# implementation and is wrong midweek.
week_start() {
  local weeks=${1:-0} dow back
  dow=$(date -u +%u)
  back=$((dow - 1 + weeks * 7))
  date_shift "$(date -u +%Y-%m-%d)" "-$back"
}

# Turns a pull request reference in the model's text into a GitHub link — the
# long `org/repo#123` form or the short `repo#123` one, backticked or bare. It
# runs after the fact over text that already exists, so the URL is derived from
# a reference mechanically rather than written by the model.
#
# Deriving is not enough on its own. `acme/totally-invented#99999` has the shape
# of a reference without being one, and a pattern that reads only the shape
# turns it into a live link to an arbitrary organization — a link the model did
# invent, one rewrite removed. So the repository has to be one the scan actually
# saw, by name out of map/graph.json, and the organization has to be $ORG.
#
# Everything else is left exactly as it was written. That includes a genuine
# upstream pull request in somebody else's organization: it is a real thing a
# recap may mention, but nothing here has seen it, and a cross-org link needs
# its own evidence path rather than a wider regex. Plain text promises nothing;
# dropping the reference instead would hide that the model said it.
#
# linkify_prs <org> <path to graph.json>, text on stdin.
linkify_prs() {
  local org=$1 graph=$2 names esc
  [[ -f $graph ]] || { cat; return 0; }
  # gsub("[.]") keeps a dot in a repository name a dot: `docs.example` may not
  # match `docsXexample`. Every name arrives through it, so an edit here cannot
  # quietly turn a repository name into a wildcard.
  # The names become sed program text, and graph.json can arrive from the docs
  # repo through `orgami join`: a name holding `%` would end the s command and
  # GNU sed's `e` would run the rest as a shell command. GitHub names are
  # limited to [A-Za-z0-9._-], so anything else is not a repository and is
  # dropped before it reaches sed; inside that charset only the dot is special.
  [[ $org =~ ^[A-Za-z0-9._-]+$ ]] || { cat; return 0; }
  names=$(jq -r '[.nodes[] | select(.kind == "repo") | .name | strings
                   | select(test("^[A-Za-z0-9._-]+$"))]
                 | map(gsub("[.]"; "[.]")) | join("|")' "$graph" 2>/dev/null)
  [[ -n $names ]] || { cat; return 0; }
  esc=${org//./[.]}
  # The long form first: once it has become `[org/repo#1](...)` the repository
  # name is preceded by a `/`, which the short-form patterns below do not match,
  # so a link is never rewritten twice.
  sed -E \
    -e "s%\`$esc/($names)#([0-9]+)\`%[$org/\1#\2](https://github.com/$org/\1/pull/\2)%g" \
    -e "s%(^|[[:space:](])$esc/($names)#([0-9]+)%\1[$org/\2#\3](https://github.com/$org/\2/pull/\3)%g" \
    -e "s%\`($names)#([0-9]+)\`%[\1#\2](https://github.com/$org/\1/pull/\2)%g" \
    -e "s%(^|[[:space:](])($names)#([0-9]+)%\1[\2#\3](https://github.com/$org/\2/pull/\3)%g"
}

# A model call can die mid-response and hand back an error string. Anything
# stored as content has to look like what was asked for, or it is thrown away.
# $1 the text, $2 a grep -E pattern the text must contain somewhere.
model_output_ok() {
  local text=$1 shape=${2:-.}
  [[ -n ${text// /} ]] || return 1
  grep -qiE '^(API Error|Error:|Execution error|Credit balance|Overloaded)' <<<"$text" && return 1
  grep -qiE 'API Error: (Connection lost|Request timed out|Internal server error)' <<<"$text" && return 1
  grep -qE "$shape" <<<"$text" || return 1
  return 0
}

# A STATS key the model quotes ("`merged_by_bots` (13)") is a variable name in
# the team's recap. The prompt forbids it, but a rule the model may ignore is
# not a guarantee, so the key is rewritten after the call the way references are
# linked after it: lib/plain_keys.jq says how. $1 the STATS file; text on stdin.
# If jq fails the text passes through unchanged rather than being lost.
plain_stat_keys() {
  local stats=$1 text out
  text=$(cat)
  if out=$(jq -Rsj --slurpfile s "$stats" -f "$ROOT/lib/plain_keys.jq" <<<"$text" 2>/dev/null); then
    [[ $out == "$text" ]] || log "the model quoted STATS key names — rewritten as words"
    printf '%s\n' "$out"
  else
    printf '%s\n' "$text"
  fi
}

# Embed branding so exported pages remain a single file, including their favicon.
#
# From assets/, not docs/brand/: the approved logo there is 1254 px and the
# favicon wraps it whole, which made 1.5 MB of every page base64 for an image
# drawn at 32 px. assets/logo-64.png is that logo cut once to 64 px (sharp at
# 2x), and assets/favicon.svg the same paper square around it — 3 and 5 KB.
# Cut again from docs/brand/logo.png if the logo changes.
orgami_brand_head() {
  printf '<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,%s">\n' "$(base64 <"$(dirname "${BASH_SOURCE[0]}")/../assets/favicon.svg" | tr -d '\r\n')"
  printf '<style>.orgami-logo{display:inline-block;width:32px;height:32px;vertical-align:middle;flex-shrink:0;background:#f7f5ef;border-radius:4px;object-fit:contain}</style>\n'
}

orgami_brand_image() {
  printf '<img class="orgami-logo" width="32" height="32" alt="orgami" src="data:image/png;base64,%s">\n' "$(base64 <"$(dirname "${BASH_SOURCE[0]}")/../assets/logo-64.png" | tr -d '\r\n')"
}
