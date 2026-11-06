#!/usr/bin/env bash
# A vendor edge says the organization pays somebody, so it has to come from the
# repo's own working code and not from anything that only looks like it. This
# runs vendors_scan over hand-written checkouts — no clone, no network — and
# covers both halves of that.
#
# Recall: a monorepo keeps its SDKs in apps/*/package.json and its .env.example
# beside them, and the root package.json says only "workspaces". Those packages
# are read, and cited at their own path:line.
#
# Precision: a commented-out line, a Markdown note, a docs tree, a test, an
# example app, a saved copy of somebody else's frontend, a twenty-megabyte data
# dump, a `// indirect` go.mod line, a Google Fonts stylesheet, an OAuth scope
# URL and a public job board are each something a repo mentions, not something
# it buys. None of them may produce an edge.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is where lib/vendors.sh looks for the catalogue
ROOT=$PWD

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/scan.sh
source lib/scan.sh
# shellcheck source=../lib/profile.sh
source lib/profile.sh
# shellcheck source=../lib/vendors.sh
source lib/vendors.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fx=$work/fx
EMIT=$work/e.ndjson
: >"$EMIT"

# --- mono: a pnpm workspace whose root names nothing ---------------------------
mkdir -p "$fx/mono/apps/api" "$fx/mono/apps/mobile" "$fx/mono/packages/mail" \
  "$fx/mono/examples/demo" "$fx/mono/svc"
cat >"$fx/mono/package.json" <<'JSON'
{
  "name": "mono",
  "private": true,
  "devDependencies": { "turbo": "^2.0.0" }
}
JSON
printf 'packages:\n  - "apps/*"\n  - "packages/*"\n  - "examples/*"\n' >"$fx/mono/pnpm-workspace.yaml"
cat >"$fx/mono/apps/api/package.json" <<'JSON'
{
  "name": "api",
  "dependencies": {
    "@sentry/node": "^8.0.0",
    "stripe": "^14.0.0",
    "@google/genai": "^1.0.0"
  }
}
JSON
printf 'DATABASE_URL=\nELEVENLABS_API_KEY=\n' >"$fx/mono/apps/api/.env.example"
cat >"$fx/mono/apps/mobile/package.json" <<'JSON'
{
  "name": "mobile",
  "dependencies": { "expo": "^51.0.0" }
}
JSON
printf '{\n  "build": { "production": {} }\n}\n' >"$fx/mono/apps/mobile/eas.json"
cat >"$fx/mono/packages/mail/package.json" <<'JSON'
{
  "name": "mail",
  "dependencies": { "@getbrevo/brevo": "^2.0.0" }
}
JSON
# An example package is declared in the workspace, and is still an example.
printf '{\n  "name": "demo",\n  "dependencies": { "@clerk/nextjs": "^5.0.0" }\n}\n' \
  >"$fx/mono/examples/demo/package.json"
# A Python service beside the JS packages, one directory down.
printf 'fastapi>=0.110\nfirecrawl-py>=1.0\n' >"$fx/mono/svc/requirements.txt"

# --- noise: everything here is a mention, none of it a use ----------------------
mkdir -p "$fx/noise/src" "$fx/noise/notes" "$fx/noise/docs" "$fx/noise/tests" \
  "$fx/noise/reference/recovered-frontend/js" "$fx/noise/data/raw" \
  "$fx/noise/.github/workflows" "$fx/noise/collectors"
cat >"$fx/noise/src/app.ts" <<'TS'
// img.src = "https://res.cloudinary.com/demo/image/upload/x";
/* const pg = new Pinecone({ host: "https://idx.svc.pinecone.io" }); */
const scopes = ["https://www.googleapis.com/auth/userinfo.email"];
const font = "https://fonts.googleapis.com/css2?family=Inter";
const tokenUrl = "https://oauth2.googleapis.com/token";
export const live = process.env.LIVE_FLAG;
TS
cat >"$fx/noise/src/server.py" <<'PY'
# client = Mistral(api_key=os.environ["MISTRAL_API_KEY"])
import os
PY
printf '```ts\nnew Stripe(process.env.STRIPE_KEY)\n```\n' >"$fx/noise/notes/di.md"
printf 'export const k = process.env.OPENAI_API_KEY;\n' >"$fx/noise/docs/sample.ts"
printf 'process.env.SLACK_TOKEN = "x";\n' >"$fx/noise/tests/slack.ts"
printf 'const k = process.env.TWILIO_SID;\n' >"$fx/noise/src/sms.test.ts"
printf "import 'https://js.stripe.com/v3';\n" >"$fx/noise/reference/recovered-frontend/js/pricing.js"
cat >"$fx/noise/collectors/ats.py" <<'PY'
BOARDS = {
    "greenhouse": "https://boards-api.greenhouse.io/v1/boards/{slug}/jobs",
    "lever": "https://api.lever.co/v0/postings/{slug}",
    "ashby": "https://api.ashbyhq.com/posting-api/job-board/{slug}",
}
PY
cat >"$fx/noise/.github/workflows/ci.yml" <<'YML'
jobs:
  scan:
    steps:
      - uses: actions/checkout@v4
      # - uses: SonarSource/sonarqube-quality-gate-action@v1
YML
cat >"$fx/noise/go.mod" <<'MOD'
module example.com/noise

go 1.22

require (
	google.golang.org/genai v1.0.0
	cloud.google.com/go/auth v0.23.3 // indirect
	github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream v1.6.0 // indirect
)
MOD
# A scraped data dump, over the size limit, full of somebody else's URLs.
{
  echo '['
  i=0
  while ((i < 12000)); do
    echo '  {"url": "https://acme.vercel.app/jobs/'"$i"'", "note": "padding padding padding"},'
    i=$((i + 1))
  done
  echo '  {}'
  echo ']'
} >"$fx/noise/data/raw/_merged.json"

# --- order: one vendor found on several lines of one kind -----------------------
mkdir -p "$fx/order/infra" "$fx/order/web"
cat >"$fx/order/go.mod" <<'MOD'
module example.com/order

require (
	github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream v1.6.0 // indirect
	github.com/aws/aws-sdk-go-v2/service/s3 v1.50.0
)
MOD
printf 'variable "x" {\n  default = "https://sqs.eu-west-1.amazonaws.com/1/q"\n}\n' >"$fx/order/infra/a.tf"
printf 'export const q = "https://sqs.eu-west-1.amazonaws.com/1/q";\n' >"$fx/order/web/q.ts"
# Cloud Run is Google Cloud; Maps, Gemini and Firebase Storage are their own rows.
printf 'export const run = "https://run.googleapis.com/v2/projects";\n' >"$fx/order/web/run.ts"
printf 'export const m = "https://maps.googleapis.com/maps/api/geocode";\n' >"$fx/order/web/map.ts"

# --- docs: a repository that is itself called `docs` ----------------------------
# grep's --exclude-dir also applies to a directory named on its command line, so
# skipping docs/ trees must not skip a checkout whose own name is docs.
mkdir -p "$fx/docs/svc"
printf 'export const k = process.env.OPENAI_API_KEY;\n' >"$fx/docs/ai.ts"
printf 'stripe>=8\n' >"$fx/docs/svc/requirements.txt"

for r in mono noise order docs; do
  vendors_scan "$r" "$fx/$r"
  profile_workspace_forget
done

emitted=$(jq -s . "$EMIT")

fail=0
check() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" <<<"$emitted")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}
edge() { # <repo> <vendor> -> evidence, or "none"
  printf '[.[] | select(.t == "edge" and .from == "repo:%s" and .to == "vendor:%s") | .evidence] | first // "none"' "$1" "$2"
}
sig() {
  printf '[.[] | select(.t == "edge" and .from == "repo:%s" and .to == "vendor:%s") | .signal] | first // "none"' "$1" "$2"
}

# --- recall: the workspace packages are read ------------------------------------
check "a workspace package's SDK is a package signal" "apps/api/package.json:4" "$(edge mono sentry)"
check "and so is Stripe there, not an env var nobody installed" "pkg" "$(sig mono stripe)"
check "@google/genai is Gemini" "apps/api/package.json:6" "$(edge mono gemini)"
check "and is not Google Cloud" "none" "$(edge mono gcp)"
check "a package's own .env.example is read" "apps/api/.env.example:2" "$(edge mono elevenlabs)"
check "a nested Brevo SDK is found" "packages/mail/package.json:3" "$(edge mono brevo)"
check "an eas.json is Expo's build service" "apps/mobile/eas.json:1" "$(edge mono expo)"
check "a Python service one level down is read" "svc/requirements.txt:2" "$(edge mono firecrawl)"
check "a declared example package is still an example" "none" "$(edge mono clerk)"

# --- precision: mentions are not uses -------------------------------------------
check "a commented-out URL is not a use" "none" "$(edge noise cloudinary)"
check "nor one in a block comment" "none" "$(edge noise pinecone)"
check "nor a commented-out Python read" "none" "$(edge noise mistral)"
check "an OAuth scope, a font and a token URL are not Google Cloud" "none" "$(edge noise gcp)"
check "a code sample in a Markdown note is not a use" "none" "$(edge noise stripe)"
check "nor a docs tree" "none" "$(edge noise openai)"
check "nor a test directory" "none" "$(edge noise slack)"
check "nor a .test.ts file" "none" "$(edge noise twilio)"
check "a commented-out workflow step is not a use" "none" "$(edge noise sonar)"
check "a public job board is not Greenhouse" "none" "$(edge noise greenhouse)"
check "nor Lever" "none" "$(edge noise lever)"
check "nor Ashby" "none" "$(edge noise ashby)"
check "a data dump over the size limit is not a use" "none" "$(edge noise vercel)"
check "an // indirect go.mod line is not evidence" "none" "$(edge noise aws)"
check "but the direct requirement beside it is" "go.mod:6" "$(edge noise gemini)"

# --- evidence order --------------------------------------------------------------
check "the direct requirement is cited, not the indirect one" "go.mod:5" "$(edge order aws)"
check "a Cloud API host is still Google Cloud" "web/run.ts:1" "$(edge order gcp)"
check "maps.googleapis.com is Maps, not Google Cloud hosting" "web/map.ts:1" "$(edge order google-maps)"

# Between two host facts for one vendor, code outranks configuration. A second
# vendor with only those two facts shows it: no manifest wins it first.
cat >"$work/cat.tsv" <<'TSV'
probe	Probe	test	host:^sqs\.eu-west-1\.amazonaws\.com$	https://probe.invalid
TSV
VENDOR_CATALOG="$work/cat.tsv" vendors_facts "$fx/order" >"$work/order.facts"
got=$(VENDOR_CATALOG="$work/cat.tsv" vendors_match "$work/order.facts" | cut -f6)
if [[ $got == "web/q.ts:1" ]]; then
  echo "ok   code is cited before configuration within one kind"
else
  echo "FAIL expected web/q.ts:1 over infra/a.tf, got '$got'" >&2
  fail=1
fi

check "a checkout named docs is still grepped" "ai.ts:1" "$(edge docs openai)"
check "and still walked for manifests" "svc/requirements.txt:1" "$(edge docs stripe)"

# --- a one-line dump: linear, not quadratic -------------------------------------
# A megabyte of JSON on one line, with thousands of URLs: the per-line match loop
# used to copy the rest of the line after every match, and a file this size
# kept a scan worker busy for minutes. It must finish in seconds and cite
# nothing, while a hand-written line beside it is still found.
mkdir -p "$fx/dump/data"
awk 'BEGIN { printf "["; for (i = 0; i < 24000; i++) printf "%s{\"u\":\"https://jobs%d.board.invalid/o/%d\"}", (i ? "," : ""), i % 50, i; print "]" }' \
  >"$fx/dump/data/scrape.json"
printf 'export const s = "https://api.stripe.com/v1/charges";\n' >"$fx/dump/pay.ts"
start=$SECONDS
hosts=$(vendors_hosts "$fx/dump" | cut -f2 | sort -u | tr '\n' ' ')
took=$((SECONDS - start))
if ((took > 10)); then
  echo "FAIL a one-line megabyte dump took ${took}s to grep for hosts" >&2
  fail=1
else
  echo "ok   a one-line megabyte dump is grepped in ${took}s"
fi
if [[ $hosts == "api.stripe.com " ]]; then
  echo "ok   its URLs are not facts, the hand-written line beside it is"
else
  echo "FAIL expected only api.stripe.com from the dump checkout, got '$hosts'" >&2
  fail=1
fi

# --- every citation opens -------------------------------------------------------
while IFS= read -r cite; do
  [[ -n $cite ]] || continue
  repo=${cite%% *}
  ref=${cite#* }
  file="$fx/$repo/${ref%:*}"
  line=${ref##*:}
  if [[ ! -f $file ]] || ((line < 1 || line > $(grep -c '' "$file"))); then
    echo "FAIL evidence does not open: $cite" >&2
    fail=1
  fi
done < <(jq -r '.[] | select(.t == "edge" and (.to | startswith("vendor:")))
                | (.from | sub("^repo:"; "")) + " " + .evidence' <<<"$emitted")
[[ $fail == 0 ]] && echo "ok   every citation points at a line that exists"

exit "$fail"
