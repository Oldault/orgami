#!/usr/bin/env bash
# One credential definition, lib/secrets.tsv, guards both ways a secret could
# leave the machine: the note screen refuses it, and the session digest sent to
# a model has it redacted. The two used to be separate lists, and each let
# through shapes the other caught. What this pins:
#   - every shape the field test tried is refused by the screen and redacted
#     from a digest, and prose that only talks about tokens and passwords, a
#     commit sha, a UUID and plain placeholders still pass;
#   - `orgami note` refuses, and `orgami screen` (the CI gate) fails a note
#     whose secret sits only in its file name or front matter;
#   - a screen that cannot run refuses instead of passing;
#   - a slug is ASCII, folded rather than mangled, and never ends on a dash.
#
# Under a temp HOME and ORGAMI_HOME. No organization, no token, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "secrets: $*" >&2; exit 1; }

export HOME="$tmp/home" ORGAMI_HOME="$tmp/orgami" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$ORGAMI_HOME/acme/notes" "$ORGAMI_HOME/acme/map"
echo '{"default":"acme","author":"tester"}' >"$ORGAMI_HOME/config.json"
echo '{"org":"acme"}' >"$ORGAMI_HOME/acme/config.json"
echo '[{"name":"api"}]' >"$ORGAMI_HOME/acme/map/repos.json"

source "$ROOT/lib/secrets.sh"

# Fixed strings, not random ones: a value drawn at random can come out all
# letters and test a different rule each run. Built from parts so this file
# carries no literal key a scanner would flag.
a20=AbCdEfGh1JkLmNoPqRsT
a40=$a20$a20
pos=(
  "sk-ant-api03-$a40$a40"
  "sk-proj-$a40"
  "OPENAI key sk-$a40"
  "npm_$a40"
  "glpat-$a20"
  "sk_test_$a20"
  "sk_live_$a20"
  "rk_live_$a20"
  "whsec_$a20"
  "AWS_SECRET_ACCESS_KEY=$a40"
  "aws_secret_access_key = $a40"
  "export TOKEN=$a20"
  "MY_SERVICE_API_KEY=$a20"
  "token: $a20"
  "password=Hunter2pass"
  "Authorization: Bearer $a40"
  "curl -H 'Authorization: token $a40'"
  "https://hooks.slack.com/services/T0000/B0000/$a20"
  "the staging password is Xk9vQ2mPz7Lw"
  "the password was hunter22"
  "AKIA$(tr a-z A-Z <<<"$a20" | cut -c1-16)"
  "ASIA$(tr a-z A-Z <<<"$a20" | cut -c1-16)"
  "ghp_$a40" "gho_$a40" "ghs_$a40" "ghu_$a40" "ghr_$a40"
  "github_pat_11$a40"
  "xoxb-1234-$a20"
  "-----BEGIN OPENSSH PRIVATE KEY----- b3Blbn"
  "-----BEGIN RSA PRIVATE KEY-----"
  "https://u:hunter2pass@host.example.com/x"
  "postgres://app:$a20@db.internal:5432/app"
  "AIza$a40"
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.$a20"
)
neg=(
  "Rotate the token in the dashboard; the password is stored in 1Password."
  "Use a GitHub token with repo scope, never a password."
  "fixed in commit a3f5c9e2b1d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2"
  "request id 123e4567-e89b-12d3-a456-426614174000"
  "max_tokens: 4096, TOKEN_TTL=3600 and SESSION_TOKEN_EXPIRY=86400000"
  "set API_KEY=\$API_KEY and DATABASE_PASSWORD=\${DATABASE_PASSWORD} from the env"
  "password: <your password here>"
  "PRIVATE_KEY_PATH=/etc/keys/app.pem"
  "tokenizer=bert-base-uncased"
  "the API key is in Vault under secret/data/app"
  "git clone git@github.com:acme/api.git, or ssh://git@host:22/repo"
  "Bearer authentication is used; Basic auth with htpasswd"
  "-----BEGIN PUBLIC KEY-----"
  "the password is Stored in vault"
  "https://x-access-token:\${TOKEN}@github.com/acme/api.git"
  "token: required"
  "the secret is that nobody reads the logs"
  "a disk-cleanup-of-the-temporary-directory task"
)

for t in "${pos[@]}"; do
  [[ -n $(secrets_find <<<"$t") ]] || fail "the screen let through: ${t:0:24}…"
  red=$(secrets_redact <<<"$t")
  [[ $red == *"[redacted]"* ]] || fail "the redaction let through: ${t:0:24}…"
done
for t in "${neg[@]}"; do
  got=$(secrets_find <<<"$t")
  [[ -z $got ]] || fail "plain prose refused: '$t' as $(cut -f1 <<<"$got")"
done

# Redaction keeps what names the value and drops only the value.
red=$(secrets_redact <<<"export TOKEN=$a20 and https://u:hunter2pass@host.example.com/x")
[[ $red == "export TOKEN=[redacted] and https://u:[redacted]@host.example.com/x" ]] ||
  fail "redaction should keep the name and the host, got: $red"
# A private key goes whole, body and all.
red=$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\nafter\n' | secrets_redact)
[[ $red == $'[redacted]\nafter' ]] || fail "a private key block should go whole, got: $red"

# --- the session digest -----------------------------------------------------------

(
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/autonote.sh"
  jq -cn --arg t "use ghp_$a40 and github_pat_11$a40 and https://u:hunter2pass@host.example.com/x and AKIA$(tr a-z A-Z <<<"$a20" | cut -c1-16)" \
    '{type: "user", message: {content: $t}}' >"$tmp/t.jsonl"
  out=$(autonote_digest "$tmp/t.jsonl")
  [[ $out == "use [redacted] and [redacted] and https://u:[redacted]@host.example.com/x and [redacted]" ]] ||
    fail "the digest sent to a model still carries a credential: $out"
  # Nothing is sent when the redaction cannot run.
  out=$(SECRETS_TSV=$tmp/missing.tsv autonote_digest "$tmp/t.jsonl")
  [[ -z $out ]] || fail "with no credential list the digest should be empty, got: $out"
) || exit 1

# --- orgami note and orgami screen -------------------------------------------------

for t in "sk-ant-api03-$a40" "AWS_SECRET_ACCESS_KEY=$a40" "the staging password is Xk9vQ2mPz7Lw"; do
  if err=$(./bin/orgami note --repo api "$t" </dev/null 2>&1); then
    fail "orgami note wrote a note carrying: ${t:0:20}…"
  fi
  grep -q 'looks like a credential' <<<"$err" || fail "the refusal should say why, got: $err"
  # The refusal is printed; the credential must not be.
  ! grep -q "$a20" <<<"$err" || fail "the refusal quoted the credential back: $err"
done
[[ -z $(ls "$ORGAMI_HOME/acme/notes") ]] || fail "a refused note left a file behind"

./bin/orgami note --repo api "The token rotates weekly; the password is stored in 1Password." \
  </dev/null >/dev/null 2>&1 || fail "a note about tokens with none in it was refused"

# A secret only in the file name, then only in the front matter: the body is
# clean, and both are pushed with it.
notes="$ORGAMI_HOME/acme/notes"
printf -- '---\nid: x\nauthor: tester\n---\n\nclean body\n' >"$notes/20260101-000000-tester-ghp_$a40.md"
if ./bin/orgami screen "$notes/20260101-000000-tester-ghp_$a40.md" >/dev/null 2>&1; then
  fail "orgami screen passed a note with a token in its file name"
fi
rm -f "$notes/20260101-000000-tester-ghp_$a40.md"
printf -- '---\nid: x\nauthor: tester\ntopic: sk-ant-api03-%s\n---\n\nclean body\n' "$a40" >"$notes/front.md"
if ./bin/orgami screen "$notes/front.md" >/dev/null 2>&1; then
  fail "orgami screen passed a note with a key in its front matter"
fi
printf -- '---\nid: y\nauthor: tester\n---\n\nclean body\n' >"$notes/clean.md"
./bin/orgami screen "$notes/clean.md" >/dev/null 2>&1 || fail "orgami screen failed a clean note"

# A screen that cannot run refuses.
if SECRETS_TSV=$tmp/missing.tsv ./bin/orgami screen "$notes/clean.md" >/dev/null 2>&1; then
  fail "with no credential list the screen passed instead of refusing"
fi

# --- slugs ------------------------------------------------------------------------

(
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/notes.sh"
  for c in "Case on the billing: générer une facture — ÉTÉ|case-on-the-billing-generer-une-facture" \
    "Œuvre, straße, café|oeuvre-strasse-cafe" \
    "a long first line that runs past fortyx next|a-long-first-line-that-runs-past-fortyx" \
    "日本語のノート|"; do
    got=$(notes_slug "${c%|*}")
    [[ $got == "${c#*|}" ]] || fail "slug of '${c%|*}': want '${c#*|}', got '$got'"
    LC_ALL=C grep -q '[^a-z0-9-]' <<<"$got" && fail "slug '$got' is not ASCII"
  done
  # Under a UTF-8 locale too, where GNU sed's [a-z] matches accented letters.
  got=$(LC_ALL=C.UTF-8 notes_slug "générer")
  [[ $got == generer ]] || fail "slug under a UTF-8 locale: want 'generer', got '$got'"
) || exit 1

echo "secrets: every field-test shape refused and redacted, prose passes, file names screened, fails closed, slugs ASCII"
