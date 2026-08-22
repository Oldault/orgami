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

company_dir() { echo "$ORGAMI_HOME/$1"; }

current_company() {
  if [[ -n ${ORGAMI_COMPANY:-} ]]; then
    echo "$ORGAMI_COMPANY"
    return
  fi
  local root="$ORGAMI_HOME/config.json"
  [[ -f $root ]] || die "no company selected — run: orgami init <company> --org <github-org>"
  jq -re '.default' "$root" 2>/dev/null ||
    die "no default company — run: orgami use <company>"
}

# Sets COMPANY, DIR, ORG for the rest of a subcommand.
# shellcheck disable=SC2034  # ORG is read by the other libs sourced alongside this one
load_company() {
  COMPANY=$(current_company)
  DIR=$(company_dir "$COMPANY")
  [[ -f $DIR/config.json ]] || die "unknown company '$COMPANY' — orgami list"
  ORG=$(cfg org)
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
  names=$(jq -r '[.nodes[] | select(.kind == "repo") | .name]
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
