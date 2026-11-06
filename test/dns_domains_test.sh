#!/usr/bin/env bash
# Which domains `orgami dns` asks about when nobody named any. A record read off
# a domain is reported as an *account* of the organization, so asking about the
# wrong domain is not noise — it is a false claim. The map's host nodes are any
# URL found in code: `cognitiveservices.azure.com` reduces to azure.com, whose
# TXT records are Microsoft's own Microsoft 365 and Meta tokens, and a partner's
# API reduces to the partner's domain. Neither is this organization's.
#
# Under test:
#
#   - the website on the GitHub profile, and a host named after the org, are
#     read as owned; a provider's domain, a vendor's endpoint and a partner's
#     API are not, and each is named as left out
#   - a profile website on a blog host is a provider's domain, not the org's
#   - with no ownership signal at all, the fallback says so on stderr, still
#     reads the hosts, and keeps what they carry out of `vendors` — the list
#     every other reader takes as the organization's accounts
#
# Runs against a stub `gh` (one read-only profile, or a failure) and a stub
# `dig` reading a recorded zone off disk. No query leaves this machine.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is where the libs look for vendors.tsv
ROOT=$PWD

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/scan.sh
source lib/scan.sh
# shellcheck source=../lib/vendors.sh
source lib/vendors.sh
# shellcheck source=../lib/dns.sh
source lib/dns.sh

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

export ORGAMI_HOME="$home"
echo '{"default": "acme"}' >"$home/config.json"
mkdir -p "$home/acme/map" "$home/acme/notes" "$home/bin" "$home/zone"
echo '{"org": "acmehq"}' >"$home/acme/config.json"

# Five hosts the code calls: a vendor endpoint under a provider umbrella, a
# vendor endpoint the catalogue knows, a partner's API, and the org's own API on
# a domain named after it but on no profile.
cat >"$home/acme/map/graph.json" <<'JSON'
{"nodes": [
  {"id": "host:cognitiveservices.azure.com", "kind": "host", "name": "cognitiveservices.azure.com"},
  {"id": "host:api.stripe.com", "kind": "host", "name": "api.stripe.com"},
  {"id": "host:api.partner.fr", "kind": "host", "name": "api.partner.fr"},
  {"id": "host:api2.partner.fr", "kind": "host", "name": "api2.partner.fr"},
  {"id": "host:api.acme.io", "kind": "host", "name": "api.acme.io"}],
 "edges": []}
JSON

zone="$home/zone"
printf '"MS=ms999"\n"facebook-domain-verification=zzz"\n' >"$zone/TXT-partner.fr"
printf '1 aspmx.l.google.com.\n' >"$zone/MX-acme.com"
printf '"google-site-verification=abc"\n' >"$zone/TXT-acme.io"

cat >"$home/bin/dig" <<'STUB'
#!/usr/bin/env bash
type=""; name=""
for a in "$@"; do
  case $a in
    +*) continue ;;
    *) if [[ -z $type ]]; then type=$a; else name=$a; fi ;;
  esac
done
f="$ZONE/$type-$name"
[[ -f $f ]] && cat "$f"
exit 0
STUB
# The profile comes from $PROFILE: a JSON body to answer orgs/acmehq with, or
# empty to fail the way an offline or signed-out gh does. Anything but a GET of
# that one profile is refused, so the test also proves nothing else is asked.
cat >"$home/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
[[ $1 == api && $# == 2 ]] || { echo "unexpected gh call: $*" >&2; exit 2; }
if [[ $2 == orgs/acmehq && -n ${PROFILE:-} ]]; then
  printf '%s\n' "$PROFILE"
  exit 0
fi
echo "HTTP 401: Bad credentials" >&2
exit 1
STUB
chmod +x "$home/bin/dig" "$home/bin/gh"
export ZONE="$zone" GH_LOG="$home/gh.log"
PATH="$home/bin:$PATH"

fail=0
check() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" "$home/acme/map/dns.json")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}
logged() {
  if grep -qF -- "$2" "$home/run.log"; then
    echo "ok   $1"
  else
    echo "FAIL $1: stderr does not say '$2'" >&2
    sed 's/^/     /' "$home/run.log" >&2
    fail=1
  fi
}
run() {
  rm -f "$home/acme/map/dns.json"
  (cmd_dns --yes >/dev/null 2>"$home/run.log") ||
    { cat "$home/run.log" >&2; echo "FAIL: orgami dns did not run" >&2; exit 1; }
}

# --- the provider list, on its own ---------------------------------------------

provider() {
  local what=$1 want=$2 got=no
  if dns_is_provider "$3"; then got=yes; fi
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: dns_is_provider '$3' expected $want, got $got" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}
provider "azure.com is Microsoft's" yes azure.com
provider "and so is every name under it" yes cognitiveservices.azure.com
provider "a blog host is not the org's site" yes medium.com
provider "nor is a free mail domain" yes gmail.com
provider "an org's own domain is not a provider's" no acme.com
provider "a short provider name does not swallow a longer domain" no box.com
provider "nor one that only ends in its letters" no home.com

# --- with a website on the profile ---------------------------------------------

export PROFILE='{"login": "acmehq", "blog": "https://www.acme.com/about", "email": "hello@gmail.com"}'
run
check "the website on the profile is queried" true '.domains | index("acme.com") != null'
check "so is a host named after the org" true '.domains | index("acme.io") != null'
check "and nothing else" 2 '.domains | length'
check "both are owned, so nothing is unverified" 0 '.unverified | length'
check "the origin says where they came from" true \
  '.origin | test("website on the acmehq GitHub profile") and test("named after acmehq")'
check "a provider's domain is left out, and said to be" true \
  '[.skipped[] | select(startswith("azure.com — owned by a provider"))] | length == 1'
check "a vendor's endpoint is left out as the vendor's" true \
  '[.skipped[] | select(startswith("stripe.com — the endpoint of Stripe"))] | length == 1'
check "a partner's API is left out as not known to be the org's" true \
  '[.skipped[] | select(startswith("partner.fr — the code calls it"))] | length == 1'
check "a free mail contact address is not read as the org's domain" false \
  '.domains | index("gmail.com") != null'
# acme.com's MX is Workspace; acme.io's lone token is only a verification.
check "the owned domains' records are accounts" "google-site-verification,google-workspace" \
  '[.vendors[].id] | join(",")'
grep -qx 'api orgs/acmehq' "$GH_LOG" ||
  { echo "FAIL: the profile must be read with one GET of orgs/<org>" >&2; fail=1; }

# A website on a blog host belongs to the blog host.
export PROFILE='{"login": "acmehq", "blog": "medium.com/acmehq"}'
run
check "a website on medium.com is not queried" false '.domains | index("medium.com") != null'
check "and is said to be a provider's" true \
  '[.skipped[] | select(startswith("medium.com — the website on the acmehq GitHub profile, but owned by a provider"))] | length == 1'

# --- with no ownership signal at all -------------------------------------------

export PROFILE=""
jq '.nodes |= map(select(.name != "api.acme.io"))' "$home/acme/map/graph.json" >"$home/g.json"
mv "$home/g.json" "$home/acme/map/graph.json"
run
logged "the profile failure is said, not fatal" "could not read the acmehq GitHub profile"
logged "the fallback is said on stderr" "nothing says which domains acmehq owns"
logged "with the way out" "name the organization's own with --domain"
check "the fallback still reads the hosts the code calls" "partner.fr" '.domains | join(",")'
check "and marks every one of them unverified" "partner.fr" '.unverified | join(",")'
check "it never queries a vendor's domain, even then" 0 \
  '[.domains[] | select(. == "azure.com" or . == "stripe.com")] | length'
check "what it finds there is no account of the org's" 0 '.vendors | length'
check "it is kept apart, for whoever checks" "meta-business,microsoft-domain-verification" \
  '[.unverified_vendors[].id] | join(",")'
check "and counted apart" "0 2" '"\(.counts.vendors) \(.counts.unverified_vendors)"'
grep -qF "## On domains not known to be the organization's" "$home/acme/map/DNS.md" ||
  { echo "FAIL: DNS.md must say its records are on domains nobody said are the org's" >&2; fail=1; }
overview=$(DIR="$home/acme" dns_overview)
[[ -z $overview ]] ||
  { echo "FAIL: the map overview must not list an unverified domain's vendors as paid for" >&2; fail=1; }

# --- and a written-down list still wins ----------------------------------------

jq '.domains = ["partner.fr"]' "$home/acme/config.json" >"$home/c.json"
mv "$home/c.json" "$home/acme/config.json"
: >"$GH_LOG"
run
check "a configured domain is the organization's" "microsoft-domain-verification" \
  '[.vendors[] | select(.id == "microsoft-domain-verification") | .id] | join(",")'
check "and nothing is unverified" 0 '.unverified | length'
[[ ! -s $GH_LOG ]] ||
  { echo "FAIL: with a domains list, the profile must not be read" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "dns-domains: only domains something says are the org's are read as its accounts"
else
  exit 1
fi
