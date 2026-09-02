#!/usr/bin/env bash
# `orgami cost` is the one place money enters the map, and it may only enter
# against a vendor the map or the DNS reading already knows, with who typed it
# and when. What is pinned:
#
#   - a figure lands as one row per vendor: amount as a number, period and
#     currency defaulted, the author and an ISO date beside it, the note kept
#   - a second figure for the same vendor replaces the row, never doubles it
#   - a vendor only DNS names is accepted; a name nothing knows is refused
#     with the nearest names, and a typo is answered with the spelling meant
#   - a bad amount, period or currency is refused before anything is written
#   - --list prints the rows, --remove drops one and refuses one that is not
#     there, --json prints the file
#   - the file is replaced whole: no partial write is ever left behind
#
# Runs against a copy of test/fixtures/company — no org, no token, no network,
# no gh call (the author comes from the config, git or $USER).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

export ORGAMI_HOME="$scratch"
export ORGAMI_COMPANY=acme
cp -r test/fixtures/company "$scratch/acme"
rm -f "$scratch/acme/map/costs.json"
# A fixed author, so the row is deterministic and no `git config` is consulted.
jq -n '{author: "dana"}' >"$scratch/config.json"

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}
orgami() { "$ROOT/bin/orgami" "$@"; }
costs="$scratch/acme/map/costs.json"

# --- a figure lands with who and when --------------------------------------------

out=$(orgami cost stripe 1240.50 2>/dev/null)
check "recording prints the row and nothing else on stdout" \
  "$(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}$/DATE/' <<<"$out")" "stripe  1240.5 EUR/month  dana, DATE"
check "the row carries amount as a number, the defaults, the author and an ISO date" \
  "$(jq -r '.costs[0] | [.vendor, (.amount | type), .amount, .period, .currency, .who, (.when | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")), has("note")] | join(" ")' "$costs")" \
  "stripe number 1240.5 month EUR dana true false"
check "the file says when it was last written" \
  "$(jq -r '.generated == .costs[0].when' "$costs")" "true"

orgami cost DocuSign 480 --per year --currency usd --note "one seat, renewed each June" >/dev/null 2>&1
check "a vendor only DNS names is accepted, by its display name, with period, currency and note" \
  "$(jq -r '.costs[] | select(.vendor == "docusign") | [.amount, .period, .currency, .note] | join(" ")' "$costs")" \
  "480 year USD one seat, renewed each June"
check "rows are one per vendor, sorted" \
  "$(jq -r '[.costs[].vendor] | join(" ")' "$costs")" "docusign stripe"

orgami cost stripe 990 >/dev/null 2>&1
check "a second figure for the same vendor replaces the row" \
  "$(jq -r '[.costs[] | select(.vendor == "stripe")] | "\(length) \(.[0].amount)"' "$costs")" \
  "1 990"

# --- what it refuses, and how --------------------------------------------------------

before=$(cksum <"$costs")
refuse() { # refuse <what> <expected error fragment> <args...>
  local what=$1 want=$2; shift 2
  local err rc=0
  err=$(orgami cost "$@" 2>&1 >/dev/null) || rc=$?
  check "$what dies with 1" "$rc" "1"
  grep -qF -- "$want" <<<"$err" && echo "ok   $what names the problem" ||
    { echo "FAIL $what should say '$want', got '$err'" >&2; fail=1; }
}
refuse "a vendor nothing knows" "nearest names: stripe" stripey 12
refuse "a name that is nowhere near" "no vendor 'zzqqxx'" zzqqxx 12
refuse "an amount that is not a number" "an amount is a number" stripe "12 EUR"
refuse "a period that is not month or year" "--per takes month or year" stripe 12 --per week
refuse "a currency that is not a code" "--currency takes a three-letter code" stripe 12 --currency euros
refuse "a vendor with no amount" "what does stripe cost" stripe
refuse "no vendor at all" "orgami cost <vendor> <amount>"
refuse "an unknown flag" "unknown flag: --nope" stripe 12 --nope
refuse "removing a vendor with no figure" "no cost recorded for 'paddle'" --remove paddle
check "nothing refused touched the file" "$(cksum <"$costs")" "$before"

# --- the nearest names are the ones meant ------------------------------------------

err=$(orgami cost sendgird 5 2>&1 >/dev/null || true)
check "a transposed name is answered with the vendor meant first" \
  "$(sed -n 's/.*nearest names: \([a-z-]*\).*/\1/p' <<<"$err")" "sendgrid"

# --- --list, --json, --remove --------------------------------------------------------

check "--list prints one aligned line per row, the note last" \
  "$(orgami cost --list 2>/dev/null | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/DATE/')" \
  "docusign  480 USD/year  dana, DATE  — one seat, renewed each June
stripe    990 EUR/month  dana, DATE"
check "--json prints the file" "$(orgami cost --json 2>/dev/null | cksum)" "$(cksum <"$costs")"

orgami cost --remove docusign >/dev/null 2>&1
check "--remove drops the row and keeps the rest" \
  "$(jq -r '[.costs[].vendor] | join(" ")' "$costs")" "stripe"

# --- with no map there is nothing to file against ---------------------------------------

mkdir -p "$scratch/empty/map"
jq -n '{org: "empty"}' >"$scratch/empty/config.json"
err=$(ORGAMI_COMPANY=empty orgami cost stripe 12 2>&1 >/dev/null || true)
check "with no map or DNS reading the command says which to run" \
  "$(head -1 <<<"$err")" "orgami: no vendor in the map yet — run: orgami scan (or orgami dns)"
check "--list with nothing recorded prints nothing on stdout" \
  "$(ORGAMI_COMPANY=empty orgami cost --list 2>/dev/null)" ""
check "--json with nothing recorded is an empty file, not an error" \
  "$(ORGAMI_COMPANY=empty orgami cost --json 2>/dev/null | jq -c .)" '{"generated":null,"costs":[]}'

# --- the write is atomic -----------------------------------------------------------------
# Config and artefacts are written to a temp file and moved into place, so an
# interrupted run never leaves a half-written file. Pinned on the pattern: every
# write of costs.json in lib/cost.sh is a `mv` onto it, never a redirect.

check "costs.json is only ever moved into place, never written in place" \
  "$(grep -cE '>\s*"?\$DIR/map/costs\.json' lib/cost.sh || true)" "0"
check "and there is a mv onto it" "$(grep -cE 'mv "\$tmp" "\$DIR/map/costs\.json"' lib/cost.sh)" "1"

exit "$fail"
