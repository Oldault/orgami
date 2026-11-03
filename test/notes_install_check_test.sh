#!/usr/bin/env bash
# `orgami review --install-check` pushes a workflow to the docs repo's default
# branch and makes its check required. With no terminal and no --yes it must
# refuse instead of pushing; with --yes it adds the check to the branch's
# existing protection instead of replacing it (a PUT with
# required_pull_request_reviews: null wipes the required reviews); and the
# workflow runs the orgami that installed it, not whatever main is.
#
# A local bare repository as the docs repo, a stub `gh`. Nothing leaves the
# temp dir.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "notes_install_check: $*" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case $* in
  "api repos/acme/docs --jq .default_branch") echo main ;;
  "api repos/acme/docs/branches/main/protection")
    echo '{"required_status_checks":{"contexts":["build"]},"required_pull_request_reviews":{"required_approving_review_count":2}}' ;;
  *contexts*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls.log"
: >"$CALLS"

git init --quiet --bare -b main "$tmp/origin.git"
git clone --quiet "$tmp/origin.git" "$tmp/work" 2>/dev/null
git -C "$tmp/work" commit --quiet --allow-empty -m seed
git -C "$tmp/work" push --quiet origin main
# The slug comes from the remote URL; pushes still go to the local bare repo.
git -C "$tmp/work" remote set-url origin git@github.com:acme/docs.git
git -C "$tmp/work" remote set-url --push origin "$tmp/origin.git"

DIR="$tmp/acme"
mkdir -p "$DIR"
echo '{"org":"acme","docs_repo":"git@github.com:acme/docs.git"}' >"$DIR/config.json"

# --- no terminal, no --yes ----------------------------------------------------

if err=$( (review_install_check "$tmp/work" 0 </dev/null) 2>&1); then
  fail "with no terminal and no --yes it should refuse"
fi
grep -q -- '--yes' <<<"$err" || fail "the refusal should name --yes, got '$err'"
[[ -z $(git -C "$tmp/origin.git" log --format=%s main | grep 'ci(orgami)') ]] ||
  fail "the workflow was pushed without confirmation"

# --- --yes ----------------------------------------------------------------------

review_install_check "$tmp/work" 1 >/dev/null 2>&1 || fail "--yes should install it"
git -C "$tmp/origin.git" log --format=%s main | grep -q 'ci(orgami)' || fail "the workflow was not pushed"
grep -q 'protection -X PUT' "$CALLS" && fail "existing protection was replaced with a PUT"
grep -q 'required_status_checks/contexts -X POST' "$CALLS" ||
  fail "the check should be added through the contexts endpoint, calls: $(cat "$CALLS")"
wf=$(git -C "$tmp/origin.git" show main:.github/workflows/orgami-notes.yml)
ref=$(git rev-parse HEAD 2>/dev/null || echo "v$(jq -r .version manifest.json)")
grep -qF "Oldault/orgami $ref" <<<"$wf" || fail "the workflow should fetch orgami at $ref"
grep -q '__ORGAMI_REF__' <<<"$wf" && fail "the placeholder was left in the workflow"

echo "notes_install_check: asks unless --yes, adds to existing protection, pins orgami"
