#!/usr/bin/env bash
# Both generated pages get opened from a teammate's clone, so graph.json is
# untrusted. A hostile confidence, a javascript: url and a description closing
# the script tag must come out as data only: inside the inert JSON block, never
# as markup, and never reaching an href or a class attribute unchecked.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is how web.sh finds lib/web and lib/stats.jq
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/html.sh
source lib/html.sh
# shellcheck source=../lib/web.sh
source lib/web.sh

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp -r test/fixtures/company "$scratch/acme"
DIR="$scratch/acme"
# shellcheck disable=SC2034
COMPANY="acme"
# shellcheck disable=SC2034
ORG=acme-inc

evil='x"><img src=x onerror=alert(1)></script><img src=x onerror=alert(2)>'
jq --arg evil "$evil" '
  .nodes[0].meta.url = "javascript:alert(3)"
  | .nodes[0].meta.description = $evil
  | .nodes[0].name = $evil
  | .edges[0].confidence = "extracted\" onmouseover=\"alert(4)"' \
  test/fixtures/company/map/graph.json >"$DIR/map/graph.json"

html_render
web_render 2>/dev/null

fail=0
bad() { echo "FAIL $1" >&2; fail=1; }

for page in graph orgami; do
  f="$DIR/map/$page.html"
  [[ -f $f ]] || { bad "$page.html not rendered"; continue; }
  # Outside the JSON block, the hostile strings must not appear at all.
  rest=$(awk '/<script id="data"|<script id=.data./{skip=1} !skip{print} skip && /<\/script>/{skip=0}' "$f")
  grep -q 'onerror=alert' <<<"$rest" && bad "$page: hostile markup outside the data block"
  grep -q 'onmouseover=' <<<"$rest" && bad "$page: hostile confidence outside the data block"
  # Exactly one data block's worth of </script> breakage would add a script tag.
  data_close=$(grep -c '</script><img' "$f" || true)
  [[ $data_close == 0 ]] || bad "$page: raw </script> from data survived"
done

# graph.html: the confidence that reaches the page is one of two known words.
conf=$(awk '/<script id="data"/{p=1;next} p&&/<\/script>/{exit} p' "$DIR/map/graph.html" \
  | jq -r '[.edges[].confidence] | unique | join(",")')
case $conf in
  extracted | inferred | extracted,inferred) ;;
  *) bad "graph.html: confidence leaked as '$conf'" ;;
esac

# The href guard is in both pages' code, and does what it says.
grep -q 'safeUrl' "$DIR/map/graph.html" || bad "graph.html has no url guard"
grep -q 'safeAttr' "$DIR/map/orgami.html" || bad "orgami.html has no url guard"
if command -v node >/dev/null; then
  res=$(node -e '
    const safeAttr = (k, v) => (k !== "href" && k !== "src") || /^(https?:\/\/|#)/i.test(String(v).trim());
    const ok = [["href","https://a.b"],["href","#/repos"],["class","javascript:x"]].every(a => safeAttr(...a));
    const no = [["href","javascript:alert(1)"],["href"," JaVaScRiPt:1"],["src","data:text/html,x"]].every(a => !safeAttr(...a));
    process.stdout.write(ok && no ? "ok" : "bad")')
  [[ $res == ok ]] || bad "url allow-list rejects or accepts the wrong schemes"
  # And the shipped source is the one that was tested.
  grep -qF '/^(https?:\/\/|#)/i.test(String(v).trim())' lib/web/00-shell.js || bad "00-shell.js guard changed; update this test"
fi

((fail == 0)) || exit 1
echo "page_hostile: ok"
