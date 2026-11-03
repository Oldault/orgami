#!/usr/bin/env bash
# `orgami view` is one fzf command line, and fzf rejects an option it does not
# know with exit 2 — which the view used to turn into success, on the fzf that
# Debian 12 and Ubuntu 22.04/24.04 actually ship. The thresholds in lib/tui.sh
# were found against each release's own binary; this pins what each one gets,
# and, when an fzf is installed, that its own parser accepts the line built for
# it (--filter parses the full command line without a terminal).
#
# No terminal, no network, no organization.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "tui_fzf_compat: $*" >&2; exit 1; }

mkdir -p "$tmp/fake" "$tmp/acme/map"
echo '{"generated":"2026-11-01T00:00:00Z","nodes":[{"id":"repo:a","kind":"repo","name":"a"}],"edges":[]}' \
  >"$tmp/acme/map/graph.json"
cat >"$tmp/fake/fzf" <<'EOF'
#!/usr/bin/env bash
echo "$FZF_V (fake)"
EOF
chmod +x "$tmp/fake/fzf"

# args_for <path to put first> — the line tui_fzf_args builds, NUL-separated,
# since the header is several lines.
args_for() {
  PATH="$1:$PATH" bash -c '
    set -euo pipefail
    ROOT=$PWD
    source lib/common.sh; source lib/style.sh; source lib/tui.sh
    DIR=$0 COMPANY=acme ORG=acme ORGAMI_BIN=$ROOT/bin/orgami
    args=()
    tui_fzf_args args
    printf "%s\0" "${args[@]}"' "$tmp/acme"
}

has() { grep -qF -- "$2" <<<"$1"; }
lines() { args_for "$tmp/fake" | tr '\0' '\n'; }

a=$(FZF_V=0.29.0 lines)
for o in inline-right transform-header transform-prompt label: --footer --preview-border; do
  ! has "$a" "$o" || fail "fzf 0.29 was given $o"
done
has "$a" --info=inline || fail "fzf 0.29 lost --info=inline"
has "$a" "--header-first" || fail "fzf 0.29 lost --header-first"

a=$(FZF_V=0.38.0 lines)
has "$a" transform-prompt || fail "fzf 0.38 lost transform-prompt"
! has "$a" transform-header || fail "fzf 0.38 was given transform-header"

a=$(FZF_V=0.44.1 lines)
has "$a" --info=inline-right || fail "fzf 0.44 lost inline-right"
has "$a" "_tui header keys)" || fail "fzf 0.44 has no footer, so the header should carry the keys"
! has "$a" --footer || fail "fzf 0.44 was given --footer"

a=$(FZF_V=0.63.0 lines)
has "$a" --footer= || fail "fzf 0.63 lost the footer"
has "$a" "_tui header)" || fail "fzf 0.63 header still carries the keys"

FZF_V=0.27.0 PATH="$tmp/fake:$PATH" bash -c '
  ROOT=$PWD; source lib/common.sh; source lib/style.sh; source lib/tui.sh
  ! tui_fzf_at_least "$TUI_FZF_FLOOR"' || fail "fzf 0.27 passed the floor"

# The real thing, when there is one at or above the floor (below it, view
# refuses before building a line): its own parser over its own line.
if command -v fzf >/dev/null && bash -c '
  ROOT=$PWD; source lib/common.sh; source lib/style.sh; source lib/tui.sh
  tui_fzf_at_least "$TUI_FZF_FLOOR"'; then
  real=$(dirname "$(command -v fzf)")
  mapfile -d '' -t line < <(args_for "$real")
  printf 'repo:a\ta\n' | fzf "${line[@]}" --filter a >/dev/null 2>"$tmp/err" ||
    fail "fzf $(fzf --version) rejected the view's command line: $(head -1 "$tmp/err")"
fi
