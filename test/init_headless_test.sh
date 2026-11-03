#!/usr/bin/env bash
# `orgami init` is how a coding agent, a script or a CI job sets orgami up, and
# none of them has a terminal. So: init with flags writes the config without
# asking anything; init or setup without enough flags, and the menu, die at once
# naming the flags instead of waiting on gum; and each way the gh token can fail
# to read the organization gets its own reason. A personal account is refused,
# as scan and pull refuse it.
#
# Also the pieces of the wizard that decide what reaches GitHub: the clone URL
# follows gh's git_protocol rather than assuming ssh, and a public docs repo is
# only created after an explicit yes.
#
# Fake gh and gum earlier on PATH; scripted answers pop off a queue file. No
# network, no token, no terminal, nothing written outside the temp directory.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "init_headless: $*" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/home"
# GH_STATE picks the account the fake gh pretends to be talking to.
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$1 $2" in
  "auth status")
    [[ $GH_STATE == signed-out ]] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }
    if [[ $GH_STATE == no-read-org ]]; then
      echo "  - Token scopes: 'gist', 'repo'"
    else
      echo "  - Token scopes: 'gist', 'read:org', 'repo'"
    fi
    exit 0 ;;
  "config get") [[ ${GH_PROTO:-} == ssh ]] && echo ssh; exit 0 ;;
  "repo create") exit 0 ;;
esac
case "$GH_STATE:$2" in
  personal:orgs/*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  personal:users/*) echo User ;;
  missing:orgs/* | missing:users/* | *:repos/*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  saml:orgs/*) echo "gh: Resource protected by organization SAML enforcement (HTTP 403)" >&2; exit 1 ;;
  saml:users/*) echo Organization ;;
  *:orgs/*) echo acme-inc ;;
esac
EOF
cat >"$tmp/bin/gum" <<'EOF'
#!/usr/bin/env bash
echo "gum $*" >>"$GH_LOG"
pop() {
  [[ -s $GUM_QUEUE ]] || { echo "gum: queue empty for: $*" >&2; exit 2; }
  head -1 "$GUM_QUEUE"
  sed -i.bak 1d "$GUM_QUEUE"
}
case $1 in
  confirm) [[ $(pop "$@") == yes ]] ;;
  input | choose | filter) pop "$@" ;;
  style) echo "${@: -1}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/gum"

export PATH="$tmp/bin:$PATH" ORGAMI_HOME="$tmp/home" GH_LOG="$tmp/gh.log" GUM_QUEUE="$tmp/queue"
: >"$GH_LOG"

# init <args...> — stdout and stderr together in $out, the status in $rc.
init() {
  rc=0
  out=$(./bin/orgami init "$@" </dev/null 2>&1) || rc=$?
}

# --- headless with every flag: the config, and nothing asked
GH_STATE=org init acme --org acme-inc --no-docs --exclude 'archived-, -sandbox' --model claude-haiku-4-5
[[ $rc == 0 ]] || fail "init with flags exited $rc: $out"
cfg="$tmp/home/acme/config.json"
[[ $(jq -r .org "$cfg") == acme-inc ]] || fail "org not written"
[[ $(jq -r .docs_repo "$cfg") == "" ]] || fail "--no-docs left a docs repo"
[[ $(jq -c .exclude "$cfg") == '["archived-","-sandbox"]' ]] || fail "--exclude not split: $(jq -c .exclude "$cfg")"
[[ $(jq -r .report_model "$cfg") == claude-haiku-4-5 ]] || fail "--model not written"
[[ $(jq -r .default "$tmp/home/config.json") == acme ]] || fail "first company is not the default"
! grep -q '^gum' "$GH_LOG" || fail "init with flags called gum"

# --- not enough flags and no terminal: the flags, not a hang
init
[[ $rc == 1 && $out == *"--org <github-org>"* && $out == *"--no-docs"* ]] ||
  fail "bare init without a terminal did not list the flags: $out"
init beta
[[ $rc == 1 && $out == *"--org is required"* ]] || fail "init without --org: $out"
for cmd in setup menu; do
  rc=0
  out=$(GH_STATE=org ./bin/orgami "$cmd" </dev/null 2>&1) || rc=$?
  [[ $rc == 1 && $out == *"no terminal"* ]] || fail "$cmd without a terminal did not die: $out"
done

# --- each way the org cannot be read
GH_STATE=signed-out init beta --org acme-inc
[[ $rc == 1 && $out == *"gh auth login"* ]] || fail "signed out: $out"
GH_STATE=personal init beta --org somebody
[[ $rc == 1 && $out == *"somebody is a personal account"* ]] || fail "personal account: $out"
GH_STATE=missing init beta --org nobody-here
[[ $rc == 1 && $out == *"no GitHub organization called 'nobody-here'"* ]] || fail "missing org: $out"
GH_STATE=saml init beta --org acme-inc
[[ $rc == 1 && $out == *"single sign-on"* ]] || fail "SAML: $out"
init beta --org 'acme;rm'
[[ $rc == 1 && $out == *"not a GitHub organization login"* ]] || fail "bad login: $out"
[[ ! -e $tmp/home/beta ]] || fail "a refused init left a company directory"

GH_STATE=no-read-org init beta --org acme-inc
[[ $rc == 0 && $out == *"no read:org scope"* ]] || fail "missing read:org was not warned about: $out"

# --- the wizard's pieces: clone URL and the public-repo question
wiz() {
  bash -c '
    set -euo pipefail
    ROOT=$PWD
    source lib/common.sh; source lib/style.sh; source lib/init.sh; source lib/tui.sh; source lib/ui.sh
    "$@"' wiz "$@"
}

printf '%s\n' orgami-reports public no >"$GUM_QUEUE"
: >"$GH_LOG"
url=$(GH_STATE=org wiz ui_create_docs_repo acme-inc 2>/dev/null) || fail "ui_create_docs_repo failed"
[[ $url == https://github.com/acme-inc/orgami-reports.git ]] || fail "https gh user got $url"
grep -q 'repo create acme-inc/orgami-reports --private' "$GH_LOG" ||
  fail "public declined, but the repo was not created private: $(grep 'repo create' "$GH_LOG")"

printf '%s\n' orgami-reports public yes >"$GUM_QUEUE"
: >"$GH_LOG"
url=$(GH_STATE=org GH_PROTO=ssh wiz ui_create_docs_repo acme-inc 2>/dev/null) || fail "ui_create_docs_repo failed"
[[ $url == git@github.com:acme-inc/orgami-reports.git ]] || fail "ssh gh user got $url"
grep -q 'repo create acme-inc/orgami-reports --public' "$GH_LOG" || fail "public confirmed, not created public"
grep -q 'gum confirm --default=no' "$GH_LOG" || fail "the public question does not default to no"

[[ $(wiz ui_repo_slug https://github.com/acme-inc/handbook.git) == acme-inc/handbook ]] || fail "slug from https"
[[ $(wiz ui_repo_slug git@github.com:acme-inc/handbook.git) == acme-inc/handbook ]] || fail "slug from ssh"
! wiz ui_repo_slug https://gitlab.com/acme/handbook.git >/dev/null || fail "a non-GitHub URL got a slug"

# --- help is help, everywhere an agent is likely to ask for it
for cmd in "init --help" "view --help" "agents --help" "card --help" "context --help"; do
  # shellcheck disable=SC2086  # the words of $cmd are separate arguments
  ./bin/orgami $cmd </dev/null >/dev/null 2>&1 || fail "orgami $cmd exited non-zero"
done

# Run by a person, this shell has a terminal and view would open on it. A new
# session has no controlling terminal; without setsid (macOS) it is only safe
# where there was none to begin with.
detached=()
if command -v setsid >/dev/null; then
  detached=(setsid -w)
elif { : </dev/tty; } 2>/dev/null; then
  exit 0
fi
rc=0
out=$("${detached[@]}" ./bin/orgami view </dev/null 2>&1) || rc=$?
[[ $rc == 1 && $out == *"orgami query"* ]] || fail "view without a terminal: rc $rc, $out"
