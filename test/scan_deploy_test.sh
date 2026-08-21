#!/usr/bin/env bash
# What `scan_deploy` claims a repository deploys with, and what it refuses to
# claim. Every one of these edges says an organization runs its software
# somewhere, so it may only exist where a committed file says so, and the
# evidence has to open.
#
# The near misses are the point. Three files here look like a deploy target and
# are not one:
#
#   - a Heroku `app.json`, which is the same filename Dokku reads and which
#     `profile_serves` already reads for a Heroku hostname
#   - a plain CloudFormation `template.yaml`, which is not AWS SAM until the
#     Serverless transform is in it
#   - a `cdk.json` with no `app` key, which does not run a CDK app
#
# Fixture checkouts in a temp directory. No clone, no network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/scan.sh
source lib/scan.sh

fixture=$(mktemp -d)
EMITDIR=$(mktemp -d)
trap 'rm -rf "$fixture" "$EMITDIR"' EXIT
EMIT="$EMITDIR/e.ndjson"
: >"$EMIT"

# One fixture checkout per repo name, built from `path=content` heredocs.
tree() { mkdir -p "$fixture/$1"; echo "$fixture/$1"; }

# --- cloudflare: a toml, and the jsonc wrangler itself writes -----------------

d=$(tree cf-toml)
cat >"$d/wrangler.toml" <<'TOML'
name = "edge-api"
main = "src/index.ts"
compatibility_date = "2024-05-01"
TOML

d=$(tree cf-jsonc)
cat >"$d/wrangler.jsonc" <<'JSONC'
/**
 * For more details on how to configure Wrangler, refer to:
 * https://developers.cloudflare.com/workers/wrangler/configuration/
 */
{
  "$schema": "node_modules/wrangler/config-schema.json",
  // the worker's name is also its subdomain
  "name": "queue-worker",
  "main": "src/index.ts",
  "compatibility_date": "2024-05-01"
}
JSONC

# A wrangler config with no name at all: the tool is still there, the host is
# not, and nothing is invented to fill the gap.
d=$(tree cf-nameless)
cat >"$d/wrangler.toml" <<'TOML'
main = "src/index.ts"
compatibility_date = "2024-05-01"
TOML

# --- railway, caprover, supabase: the filename is the whole claim -------------

d=$(tree rail)
cat >"$d/railway.json" <<'JSON'
{
  "$schema": "https://railway.app/railway.schema.json",
  "deploy": {"startCommand": "npm start", "restartPolicyType": "ON_FAILURE"}
}
JSON

d=$(tree cap)
cat >"$d/captain-definition" <<'JSON'
{"schemaVersion": 2, "dockerfilePath": "./Dockerfile"}
JSON

d=$(tree supa)
mkdir -p "$d/supabase"
cat >"$d/supabase/config.toml" <<'TOML'
project_id = "storefront"

[api]
port = 54321
TOML

# --- coolify: its own directory, or a coolify.json beside a compose file ------

d=$(tree cool-dir)
mkdir -p "$d/.coolify"
cat >"$d/.coolify/config.yml" <<'YML'
type: application
YML

d=$(tree cool-compose)
cat >"$d/coolify.json" <<'JSON'
{"type": "docker-compose", "domains": ["app.example.com"]}
JSON
cat >"$d/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx:1.25
YML

# The near miss: coolify.json with nothing it could be configuring.
d=$(tree cool-alone)
cat >"$d/coolify.json" <<'JSON'
{"note": "a file named after the tool, and nothing it deploys"}
JSON

# --- dokku, and the Heroku app.json it must not be confused with -------------

d=$(tree dokku-json)
cat >"$d/app.json" <<'JSON'
{
  "name": "internal-tools",
  "scripts": {
    "dokku": {"predeploy": "bundle exec rake db:migrate"}
  },
  "healthchecks": {"web": [{"type": "startup", "path": "/up"}]}
}
JSON

d=$(tree dokku-file)
cat >"$d/.dokku-monorepo" <<'CONF'
appname=api
CONF

# The near miss: a Heroku app.json, the same filename with none of Dokku's keys.
d=$(tree heroku)
cat >"$d/app.json" <<'JSON'
{
  "name": "billing",
  "description": "a Heroku app.json, which is not a Dokku one",
  "env": {"RACK_ENV": {"value": "production"}},
  "buildpacks": [{"url": "heroku/ruby"}],
  "formation": {"web": {"quantity": 1, "size": "standard-1x"}},
  "scripts": {"postdeploy": "bundle exec rake db:seed"},
  "addons": ["heroku-postgresql"]
}
JSON

# --- aws sam and cdk, each against the file that only looks like it ----------

d=$(tree sam)
cat >"$d/template.yaml" <<'YML'
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31
Resources:
  Api:
    Type: AWS::Serverless::Function
    Properties:
      Handler: app.handler
YML

# The near miss: CloudFormation without the Serverless transform.
d=$(tree cfn)
cat >"$d/template.yaml" <<'YML'
AWSTemplateFormatVersion: "2010-09-09"
Resources:
  Bucket:
    Type: AWS::S3::Bucket
YML

d=$(tree cdk)
cat >"$d/cdk.json" <<'JSON'
{"app": "npx ts-node --prefer-ts-exts bin/infra.ts", "context": {}}
JSON

# The near miss: a cdk.json that does not say how to run a CDK app.
d=$(tree cdk-empty)
cat >"$d/cdk.json" <<'JSON'
{"context": {"@aws-cdk/core:enableStackNameDuplicates": true}}
JSON

# --- run it ------------------------------------------------------------------

for r in cf-toml cf-jsonc cf-nameless rail cap supa cool-dir cool-compose \
  cool-alone dokku-json dokku-file heroku sam cfn cdk cdk-empty; do
  scan_deploy "$r" "$fixture/$r"
done

emitted=$(jq -s . "$EMIT")

fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" <<<"$emitted")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}

# The evidence a repo's edge to a tool carries, which is the only reason the
# edge is worth reading.
ev() {
  printf '[.[] | select(.t == "edge" and .from == "repo:%s" and .to == "tool:%s")
          | .evidence] | first' "$1" "$2"
}
count() {
  printf '[.[] | select(.t == "edge" and .from == "repo:%s" and .to == "tool:%s")] | length' \
    "$1" "$2"
}

# --- each new tool, found, and cited ------------------------------------------

assert "a wrangler.toml is Cloudflare" "wrangler.toml" "$(ev cf-toml cloudflare)"
assert "and its name is the workers.dev host" "wrangler.toml" \
  '[.[] | select(.t == "edge" and .from == "repo:cf-toml"
                 and .to == "host:edge-api.workers.dev" and .kind == "deploys-to")
   | .evidence] | first'
assert "a commented wrangler.jsonc is read by jq all the same" "queue-worker.workers.dev" \
  '[.[] | select(.t == "edge" and .from == "repo:cf-jsonc" and .kind == "deploys-to")
   | .to | sub("^host:"; "")] | first'
assert "a wrangler config with no name still names the tool" "wrangler.toml" \
  "$(ev cf-nameless cloudflare)"
assert "and invents no host to go with it" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:cf-nameless" and .kind == "deploys-to")] | length'

assert "a railway.json is Railway" "railway.json" "$(ev rail railway)"
assert "a captain-definition is CapRover" "captain-definition" "$(ev cap caprover)"
assert "a supabase/config.toml is Supabase" "supabase/config.toml" "$(ev supa supabase)"

assert "a .coolify directory is Coolify" ".coolify" "$(ev cool-dir coolify)"
assert "so is a coolify.json beside a compose file" "coolify.json" \
  "$(ev cool-compose coolify)"

assert "app.json with Dokku's own keys is Dokku" "app.json" "$(ev dokku-json dokku)"
assert "and so is a .dokku-* file" ".dokku-monorepo" "$(ev dokku-file dokku)"

assert "a Serverless transform makes it SAM" "template.yaml:5" "$(ev sam aws-sam)"
assert "a cdk.json that runs an app is CDK" "cdk.json" "$(ev cdk aws-cdk)"

# --- the near misses ----------------------------------------------------------

assert "a Heroku app.json is not Dokku" "0" "$(count heroku dokku)"
assert "and it claims no deploy tool at all" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:heroku")] | length'
assert "plain CloudFormation is not SAM" "0" "$(count cfn aws-sam)"
assert "a coolify.json alone is not a deploy target" "0" "$(count cool-alone coolify)"
assert "a cdk.json with no app is not CDK" "0" "$(count cdk-empty aws-cdk)"

# --- the shape every edge here has to have -----------------------------------

assert "every tool edge carries evidence" "0" \
  '[.[] | select(.t == "edge" and (.to | startswith("tool:")))
   | select((.evidence // "") == "")] | length'
assert "every deploy edge is extracted, never inferred" "0" \
  '[.[] | select(.t == "edge" and .kind == "deploys-to")
   | select(.confidence != "extracted")] | length'

# One edge per tool per repo: a repo carrying two spellings of one config says
# one thing about itself, not two.
d=$(tree both)
cat >"$d/wrangler.toml" <<'TOML'
name = "both-ways"
TOML
cat >"$d/wrangler.json" <<'JSON'
{"name": "both-ways"}
JSON
cat >"$d/railway.json" <<'JSON'
{"deploy": {"startCommand": "npm start"}}
JSON
cat >"$d/railway.toml" <<'TOML'
[deploy]
startCommand = "npm start"
TOML
scan_deploy both "$fixture/both"
emitted=$(jq -s . "$EMIT")
assert "two wrangler configs are still one Cloudflare edge" "1" "$(count both cloudflare)"
assert "two railway configs are still one Railway edge" "1" "$(count both railway)"

# --- the whole point: every citation opens ------------------------------------
#
# Not "the file exists" — where the evidence names a line, the line exists too.
while IFS= read -r cite; do
  [[ -n $cite ]] || continue
  repo=${cite%% *}
  ref=${cite#* }
  line=""
  [[ $ref == *:[0-9]* ]] && { line=${ref##*:}; ref=${ref%:*}; }
  file="$fixture/$repo/$ref"
  if [[ ! -e $file ]]; then
    echo "FAIL evidence names a file that is not there: $cite" >&2
    fail=1
  elif [[ -n $line ]] && { [[ $line -lt 1 ]] || [[ $line -gt $(grep -c '' "$file") ]]; }; then
    echo "FAIL evidence names a line that is not there: $cite" >&2
    fail=1
  fi
done < <(jq -r '.[] | select(.t == "edge" and (.evidence // "") != "")
                | (.from | sub("^repo:"; "")) + " " + .evidence' <<<"$emitted")
[[ $fail == 0 ]] && echo "ok   every citation points at a file, and a line, that exists"

exit "$fail"
