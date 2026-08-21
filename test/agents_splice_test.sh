#!/usr/bin/env bash
# The generated block tells the user "edit above or below this block", and the
# weekly timer rewrites that file in repositories that are not orgami's, with
# `|| true` over the top. So the only things that matter here are what the
# splice leaves alone: the user's text, the user's file mode, and a file whose
# markers no longer make sense.
#
# Runs against fixture files in a temp directory. No organization, no token, no
# network, and nothing written outside the temp directory.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/agents.sh
source lib/agents.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "agents_splice: $*" >&2; exit 1; }

block="$fixture/block"
{
  echo "$MARK_START"
  echo "GENERATED LINE"
  echo "$MARK_END"
} >"$block"

# A file with a well-formed block, and user text on both sides of it.
seed() {
  local file=$1
  {
    echo "USER LINE ABOVE"
    echo "$MARK_START"
    echo "old generated"
    echo "$MARK_END"
    echo "USER LINE BELOW"
  } >"$file"
}

# --- what is above and below the block is the user's -------------------------

file="$fixture/AGENTS.md"
seed "$file"
agents_splice "$file" "$block" || fail "a well-formed block should splice"
grep -qx "USER LINE ABOVE" "$file" || fail "the line above the block was lost"
grep -qx "USER LINE BELOW" "$file" || fail "the line below the block was lost"
grep -qx "GENERATED LINE" "$file" || fail "the new block was not written"
grep -qx "old generated" "$file" && fail "the old block was left behind"

# The block is replaced, not appended to.
[[ $(grep -cF "$MARK_START" "$file") == 1 ]] ||
  fail "the block was duplicated instead of replaced"

# And it is still where it was, between the two user lines.
[[ $(cat "$file") == "USER LINE ABOVE
$MARK_START
GENERATED LINE
$MARK_END
USER LINE BELOW" ]] || fail "the block moved: $(cat "$file")"

# --- a start marker with no end marker is refused, not guessed at ------------

# `skip` used to be cleared only by the end marker, so a file missing one lost
# every line below the start marker — in a file that had just promised the user
# those lines were safe.
file="$fixture/truncated.md"
{
  echo "USER LINE ABOVE"
  echo "$MARK_START"
  echo "old generated"
  echo "USER LINE BELOW - MUST SURVIVE"
  echo "MORE USER CONTENT"
} >"$file"
before=$(cat "$file")

agents_splice "$file" "$block" 2>/dev/null &&
  fail "a block with no end marker must be refused"
[[ $(cat "$file") == "$before" ]] ||
  fail "a refused splice must leave the file exactly as it was"
grep -qx "USER LINE BELOW - MUST SURVIVE" "$file" ||
  fail "the user's content below the marker was destroyed"

# The refusal says which file and what to do about it.
why=$(agents_splice "$file" "$block" 2>&1 >/dev/null || true)
grep -qF "$file" <<<"$why" || fail "the refusal should name the file, got '$why'"
grep -qF "$MARK_END" <<<"$why" ||
  fail "the refusal should say which marker is missing, got '$why'"

# --- the user's file mode survives the rewrite -------------------------------

# The splice replaces the file by moving a temp file over it, and mktemp makes
# that temp file 0600. Every AGENTS.md the timer touched used to come out
# owner-read-only, and the mode change got committed.
file="$fixture/mode.md"
seed "$file"
chmod 644 "$file"
agents_splice "$file" "$block" || fail "a well-formed block should splice"
mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)
[[ $mode == 644 ]] || fail "the file mode changed from 644 to $mode"

# An executable-bit-free 664 stays 664 too: the mode is preserved, not pinned.
chmod 664 "$file"
agents_splice "$file" "$block" || fail "a well-formed block should splice"
mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)
[[ $mode == 664 ]] || fail "the file mode changed from 664 to $mode"

# --- nothing is left lying beside the file -----------------------------------

leftovers=$(find "$fixture" -name '*.orgami.*' | wc -l)
[[ $leftovers == 0 ]] || fail "the temp file was left beside the target"

# --- two blocks in one file are two blocks -----------------------------------

file="$fixture/twice.md"
{
  echo "$MARK_START"
  echo "old one"
  echo "$MARK_END"
  echo "BETWEEN"
  echo "$MARK_START"
  echo "old two"
  echo "$MARK_END"
} >"$file"
agents_splice "$file" "$block" || fail "two well-formed blocks should splice"
[[ $(grep -cx "GENERATED LINE" "$file") == 2 ]] ||
  fail "both blocks should have been refreshed"
grep -qx "BETWEEN" "$file" || fail "the text between two blocks was lost"

# --- no block at all means append, as before ---------------------------------

file="$fixture/none.md"
echo "USER ONLY" >"$file"
agents_splice "$file" "$block" || fail "a file with no block should be appended to"
grep -qx "USER ONLY" "$file" || fail "the user's file was overwritten"
grep -qx "GENERATED LINE" "$file" || fail "the block was not appended"

echo "agents_splice: user text and file mode preserved, an unclosed block refused"
