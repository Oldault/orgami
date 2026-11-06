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
# shellcheck source=../lib/profile.sh
source lib/profile.sh

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

# A Pages project: `pages_build_output_dir` says so. Its pages.dev name is not
# in the file — Cloudflare suffixes it when the plain one is taken — so there
# is no host, and the tool edge cites the line that makes it Pages.
d=$(tree cf-pages)
cat >"$d/wrangler.toml" <<'TOML'
# Cloudflare Pages + D1
name = "dev-site"
pages_build_output_dir = "./dist"
compatibility_date = "2024-05-01"
TOML

# Routes and custom domains are hosts the config declares outright, each cited
# at its line; a wildcard pattern names no one host.
d=$(tree cf-routes)
cat >"$d/wrangler.toml" <<'TOML'
name = "edge-router"
main = "src/index.ts"
routes = [
  { pattern = "shop.acme.dev", custom_domain = true },
  { pattern = "*acme.dev/*", zone_name = "acme.dev" }
]

[env.production]
route = "api.acme.dev/*"
TOML
d=$(tree cf-routes-json)
cat >"$d/wrangler.json" <<'JSON'
{
  "name": "edge-json",
  "routes": [{"pattern": "app.acme.dev/*", "zone_name": "acme.dev"}]
}
JSON

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

# --- nested infra: docker/, hosts/<box>/services/<app>/, infrastructure/ ----

# A homelab: no file at the root, a compose file per service four levels down.
d=$(tree homelab)
mkdir -p "$d/hosts/dom/services/immich" "$d/hosts/dom/services/gatus" "$d/hosts/dom/services/proxy"
cat >"$d/hosts/dom/services/immich/docker-compose.yml" <<'YML'
services:
  server:
    image: ghcr.io/immich-app/immich-server:release
  database:
    image: "docker.io/tensorchord/pgvecto-rs:pg14"
  redis:
    image: docker.io/redis:6.2-alpine@sha256:abc # cache
YML
cat >"$d/hosts/dom/services/gatus/compose.yaml" <<'YML'
services:
  gatus:
    image: twinproduction/gatus
  db:
    image: postgres:16
YML
printf 'FROM nginx:1.27\n' >"$d/hosts/dom/services/proxy/Dockerfile"

# A web app keeping its Docker files in docker/, with a variant name, and a
# compose file under tests/ that is how it tests, not how it ships.
d=$(tree webapp)
mkdir -p "$d/docker" "$d/tests/integration"
cat >"$d/docker/Dockerfile.frontend" <<'DOCKER'
# syntax=docker/dockerfile:1
ARG NODE=20
FROM node:${NODE}-alpine AS build
DOCKER
printf 'node_modules\n' >"$d/docker/Dockerfile.frontend.dockerignore"
cat >"$d/docker/docker-compose.prod.yml" <<'YML'
services:
  web:
    image: acme/web
  cache:
    image: valkey/valkey:8
YML
cat >"$d/tests/integration/docker-compose.yml" <<'YML'
services:
  db:
    image: mysql:8
YML

# Terraform modules under infrastructure/, the AWS provider in one of them, and
# a Dockerfile under templates/ that the repo hands out rather than ships.
d=$(tree tf-nested)
mkdir -p "$d/infrastructure/modules/rds-database" "$d/infrastructure/env" "$d/templates/ecs/backend"
printf 'FROM python:3.12\n' >"$d/templates/ecs/backend/Dockerfile"
cat >"$d/infrastructure/env/main.tf" <<'TF'
module "db" {
  source = "../modules/rds-database"
}
TF
cat >"$d/infrastructure/modules/rds-database/providers.tf" <<'TF'
terraform {
  required_version = ">= 1.5"
}

provider "aws" {
  region = var.region
}
TF

# Five S3 names, two Postgres spellings, in the root's and a package's example
# env: one edge per service, not one per name.
d=$(tree envs)
mkdir -p "$d/apps/api"
cat >"$d/.env.example" <<'ENV'
PORT=3000
# see tarif.spec.ts; allow 10.0.0.0/8 and 10.1.1.255; the API is at api.billing.dev
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
S3_BUCKET_NAME=
ENV
cat >"$d/apps/api/.env.example" <<'ENV'
export POSTGRES_USER=app
POSTGRES_PASSWORD=
S3_ENDPOINT=
S3_REGION=
ENV

# Kubernetes manifests: an Ingress rule spells its host `- host:`, and the
# manifest cited is the first in byte order, on every run.
d=$(tree k8s)
mkdir -p "$d/deploy/k8s"
cat >"$d/deploy/k8s/web.yaml" <<'YML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
YML
cat >"$d/deploy/k8s/ingress.yaml" <<'YML'
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  rules:
    - host: app.acme.dev
    - host: "app.acme.dev"
YML

# --- run it ------------------------------------------------------------------

for r in cf-toml cf-jsonc cf-pages cf-routes cf-routes-json cf-nameless rail cap supa \
  cool-dir cool-compose cool-alone dokku-json dokku-file heroku sam cfn cdk cdk-empty \
  homelab webapp tf-nested envs k8s; do
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

hosts() {
  printf '[.[] | select(.t == "edge" and .from == "repo:%s" and .kind == "deploys-to")
          | (.to | sub("^host:"; "")) + " " + .evidence] | sort | join(",")' "$1"
}

assert "a wrangler.toml is Cloudflare" "wrangler.toml" "$(ev cf-toml cloudflare)"
# A worker is served at <name>.<account subdomain>.workers.dev, and the account
# subdomain is in no committed file: the name alone is not a host.
assert "and its name is not made into a workers.dev host" "" "$(hosts cf-toml)"
assert "a commented wrangler.jsonc is read by jq all the same" "wrangler.jsonc" \
  "$(ev cf-jsonc cloudflare)"
assert "and invents no host either" "" "$(hosts cf-jsonc)"
assert "a Pages project cites the line that makes it Pages" "wrangler.toml:3" \
  "$(ev cf-pages cloudflare)"
assert "and gets no workers.dev or pages.dev host" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:cf-pages" and (.to | startswith("host:")))] | length'
assert "routes and custom domains are hosts, each cited at its line" \
  "api.acme.dev wrangler.toml:9,shop.acme.dev wrangler.toml:4" "$(hosts cf-routes)"
assert "and a wrangler.json route too" "app.acme.dev wrangler.json:3" "$(hosts cf-routes-json)"
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

# --- nested infra ------------------------------------------------------------

services() {
  printf '[.[] | select(.t == "edge" and .from == "repo:%s" and .kind == "depends-on")
          | (.to | sub("^service:"; "")) + " " + .evidence] | sort | join(",")' "$1"
}

assert "a compose file four levels down is Compose, citing the shallowest" \
  "hosts/dom/services/gatus/compose.yaml" "$(ev homelab docker-compose)"
assert "its backing images are services, each cited at its image line" \
  "postgres hosts/dom/services/gatus/compose.yaml:5,redis hosts/dom/services/immich/docker-compose.yml:7" \
  "$(services homelab)"
assert "a nested Dockerfile is Docker, cited at its FROM line" \
  "hosts/dom/services/proxy/Dockerfile:1" "$(ev homelab docker)"
assert "Dockerfile.frontend in docker/ is Docker, past its ARG" \
  "docker/Dockerfile.frontend:3" "$(ev webapp docker)"
assert "docker/docker-compose.prod.yml is Compose" "docker/docker-compose.prod.yml" \
  "$(ev webapp docker-compose)"
assert "and the compose file under tests/ adds no service" "valkey docker/docker-compose.prod.yml:5" \
  "$(services webapp)"
assert "terraform in infrastructure/ is Terraform" "infrastructure/env/main.tf" \
  "$(ev tf-nested terraform)"
assert "a Dockerfile under templates/ is not Docker" "0" "$(count tf-nested docker)"
assert "and its provider is cited at the line that declares it" \
  "infrastructure/modules/rds-database/providers.tf:5" "$(ev tf-nested aws)"
assert "five S3 names and two Postgres ones are two edges, cited at the first of each" \
  "postgres apps/api/.env.example:1,s3 .env.example:3" "$(services envs)"
assert "an example env names a host it reaches, not a file or a network" \
  "api.billing.dev .env.example:2" \
  '[.[] | select(.t == "edge" and .from == "repo:envs" and .kind == "reaches")
   | (.to | sub("^host:"; "")) + " " + .evidence] | join(",")'

assert "the first manifest in byte order is the Kubernetes evidence" "deploy/k8s/ingress.yaml" \
  "$(ev k8s kubernetes)"
assert "an Ingress rule's host is a deploy target, once, at its first line" \
  "app.acme.dev deploy/k8s/ingress.yaml:5" "$(hosts k8s)"

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
