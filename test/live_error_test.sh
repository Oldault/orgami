#!/usr/bin/env bash
# A provider's error is shown to the person who has to fix it. aws CLI v2 opens
# its error output with a blank line, so keeping only line one left the message
# "aws: " with nothing after it. The first line with something on it is the
# reason. Runs against stub output; no credentials, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/live.sh
source lib/live.sh

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

check "a leading blank line is skipped" \
  "$(live_first_line $'\n\naws: [ERROR]: Your session has expired.\nsecond')" \
  "aws: [ERROR]: Your session has expired."
check "indentation is dropped" "$(live_first_line $'  \n   boom\nx')" "boom"
check "one line is kept whole" "$(live_first_line 'only')" "only"
check "nothing at all stays empty" "$(live_first_line $'\n \n')" ""

# And through the reader: an aws that fails the way v2 does.
LIVE_ROWS=$(mktemp)
LIVE_ERRORS=$(mktemp)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture" "$LIVE_ROWS" "$LIVE_ERRORS"' EXIT
DIR="$fixture"
mkdir -p "$DIR/map" "$fixture/bin"
echo '{"aws_region": "eu-west-3"}' >"$DIR/config.json"
echo '[]' >"$DIR/map/repos.json"
echo '{"nodes": [], "edges": []}' >"$DIR/map/graph.json"
cat >"$fixture/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '\naws: [ERROR]: Your session has expired. Please reauthenticate using aws login\n' >&2
exit 255
STUB
chmod +x "$fixture/bin/aws"
PATH="$fixture/bin:$PATH" live_aws >/dev/null 2>&1 || true
msg=$(jq -r 'select(.provider == "aws") | .message' "$LIVE_ERRORS" | head -1)
case $msg in
  *"session has expired"*) echo "ok   the reader reports why aws failed" ;;
  *) echo "FAIL the reader reported '$msg'" >&2; fail=1 ;;
esac

check "a reason is kept over the fallback" "$(live_reason $'\nboom' 'fallback')" "boom"
check "an empty output gives the fallback" "$(live_reason '' 'fallback')" "fallback"

# An aws that exits 255 and prints nothing: the report still says what to run.
: >"$LIVE_ERRORS"
cat >"$fixture/bin/aws" <<'STUB'
#!/usr/bin/env bash
exit 255
STUB
chmod +x "$fixture/bin/aws"
PATH="$fixture/bin:$PATH" live_aws >/dev/null 2>&1 || true
check "a silent aws failure says how it exited and what to run" \
  "$(jq -r 'select(.provider == "aws") | .message' "$LIVE_ERRORS" | head -1)" \
  "aws exited 255 with no message — run: aws sts get-caller-identity --region eu-west-3"

exit "$fail"
