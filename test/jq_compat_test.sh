#!/usr/bin/env bash
# Debian 12 ships jq 1.6; Ubuntu 24.04 and macOS 15 ship 1.7.1. Each of them
# has refused a program here that 1.8 accepts — `$label` is a keyword in 1.6,
# `capture(...)?.d` does not parse before 1.8 — and index() on a string counts
# bytes before 1.8 where slicing counts characters. On a machine with 1.8 every
# one of those is invisible, so this runs the jq-heavy paths under each older
# jq in turn: first on PATH as `jq`, through a temp directory.
#
# The old binaries come from JQ_COMPAT ("path/to/jq-1.6 path/to/jq-1.7.1"), or
# from jq-1.6 and jq-1.7.1 on PATH. With neither it says so and passes: CI
# downloads both (.github/workflows/ci.yml), a laptop usually has none.
#
# A render test that fails under an old jq is a finding only when it passes
# under the jq on PATH; failing under both, it is somebody's work in progress
# and is reported as that, not blamed on a version.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "jq-compat: $*" >&2; exit 1; }

bins=()
if [[ -n ${JQ_COMPAT:-} ]]; then
  read -r -a bins <<<"$JQ_COMPAT"
else
  for b in jq-1.6 jq-1.7.1; do
    command -v "$b" >/dev/null 2>&1 && bins+=("$(command -v "$b")")
  done
fi
if [[ ${#bins[@]} -eq 0 ]]; then
  echo "jq-compat: no jq-1.6 or jq-1.7.1 found — skipped (JQ_COMPAT=\"/path/jq-1.6 /path/jq-1.7.1\" runs it)"
  exit 0
fi

host_jq=$(command -v jq) || fail "no jq on PATH to compare against"

# A file another program includes holds only defs, which 1.7 refuses as a
# top-level program. Compiled the way it is used.
is_module() { grep -rqs "include \"$(basename "$1" .jq)\"" lib; }

same_json() { jq -n --argjson a "$1" --argjson b "$2" '$a == $b' | grep -qx true; }

checked=()
for bin in "${bins[@]}"; do
  [[ -x $bin ]] || fail "$bin is not an executable jq"
  ver=$("$bin" --version 2>/dev/null) || fail "$bin --version failed"
  shim="$tmp/$ver"
  mkdir -p "$shim"
  ln -sf "$bin" "$shim/jq"
  under() { PATH="$shim:$PATH" "$@"; }
  [[ $(under jq --version) == "$ver" ]] || fail "the shim for $bin is not the jq first on PATH"

  # --- every .jq file parses ------------------------------------------------------
  for f in lib/*.jq lib/web/*.jq; do
    # Every $name the program mentions, bound to "", so one that reads --arg
    # values compiles on its own. Extra bindings are harmless; a missing one is
    # a compile error that says nothing about the version.
    args=()
    for v in $(grep -o '\$[A-Za-z_][A-Za-z0-9_]*' "$f" | tr -d '$' | sort -u); do
      case $v in ENV | __loc__ | __prog_args) ;; *) args+=(--arg "$v" "") ;; esac
    done
    if is_module "$f"; then
      out=$(under jq -n -L lib "include \"$(basename "$f" .jq)\"; ." </dev/null 2>&1) || true
    else
      out=$(under jq -n -L lib "${args[@]}" -f "$f" </dev/null 2>&1) || true
    fi
    if grep -qE 'syntax error|compile error|is not defined' <<<"$out"; then
      fail "$f does not compile on $ver: $(head -3 <<<"$out")"
    fi
  done

  # --- the figures read the same ---------------------------------------------------
  for pair in stats.jq:week.json daily.jq:day.json; do
    prog=lib/${pair%%:*} input=test/fixtures/${pair#*:}
    want=$("$host_jq" -c -L lib -f "$prog" "$input")
    got=$(under jq -c -L lib -f "$prog" "$input") || fail "$prog failed on $ver"
    same_json "$want" "$got" || fail "$prog reads $input differently on $ver: $got, not $want"
  done

  # --- characters, not bytes ---------------------------------------------------------
  # A playbook's prose is cut where its evidence heading starts. With index()
  # that cut moved two characters per em dash on jq before 1.8, and the prose
  # ended in "## W".
  pb=$'# Broken export\n<sub>Written by `m` on 2026-08-01 from 3 recorded instances</sub>\n\nRetry the job — then check the bucket — café.\n\n---\n\n## What this was written from\n\n```\nnote a1\n```\n'
  prose=$(jq -n --arg t "$pb" '{playbooks: [{file: "map/playbooks/api--broken-export.md", text: $t}]}' |
    under jq -L lib --arg dir x --arg company x --arg org acme -f lib/web/70-memory.jq |
    jq -r '.playbooks.list[0].prose')
  [[ $prose == "Retry the job — then check the bucket — café." ]] ||
    fail "a playbook's prose is cut in the wrong place on $ver: '$prose'"

  # --- the render paths, whole -------------------------------------------------------
  for t in query_json html_render tui_recaps web_render; do
    if ! under "./test/${t}_test.sh" </dev/null >"$tmp/out" 2>&1; then
      if ! "./test/${t}_test.sh" </dev/null >/dev/null 2>&1; then
        echo "jq-compat: test/${t}_test.sh fails on $("$host_jq" --version) too — not counted against $ver" >&2
        continue
      fi
      fail "test/${t}_test.sh passes on $("$host_jq" --version) and fails on $ver: $(tail -5 "$tmp/out")"
    fi
  done
  checked+=("$ver")
done

echo "jq-compat: every .jq compiles, the figures match and the render tests pass on ${checked[*]}"
