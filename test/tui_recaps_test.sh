#!/usr/bin/env bash
# The recaps tab reads a label off every file under reports/: the first `# `
# heading, or failing that the first line that starts with a letter. A recap
# with neither — one opening on a number, a bullet or a code fence — used to
# take the whole list down: `grep` exits 1 on no match, the rows renderer runs
# under `set -euo pipefail`, and the odd file sorts first, so fzf's reload got
# no rows at all and the tab drew empty. The right outcome is every recap
# listed, that one with an empty label.
#
# Runs `orgami _tui rows` — the exact callback fzf's reload binding runs — with
# the state file pointed at the recaps tab. No fzf, no tty, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

mkdir -p "$home/acme/reports"
echo '{"default":"acme"}' >"$home/config.json"
echo '{"org":"acme"}' >"$home/acme/config.json"
printf '# A good week\n- something happened\n' >"$home/acme/reports/2026-W33.md"
printf '123 deploys and not one word first\n' >"$home/acme/reports/2026-W34.md"

# Tab index 3 is recaps — TUI_TABS=(map repos notes recaps) in lib/tui.sh.
state="$home/state"
echo 3 >"$state"

fail() { echo "tui_recaps: $*" >&2; exit 1; }

rows=$(ORGAMI_HOME=$home ORGAMI_TUI_STATE=$state ./bin/orgami _tui rows) ||
  fail "the rows renderer exited $? on a recap with no readable heading"
grep -q '2026-W34' <<<"$rows" ||
  fail "the headingless recap lost its row"
grep -q '2026-W33.*A good week' <<<"$rows" ||
  fail "the recap sorted after the headingless one lost its row"

echo "tui_recaps: a recap with no readable heading gets an empty label, not an abort"
