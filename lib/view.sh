# shellcheck shell=bash
# orgami query — one node as text, rendered by the same code that draws the
# TUI's preview pane, so the two can never say different things. The browser
# itself lives in lib/tui.sh.

# Resolves "api", "repo:api", "host:1.2.3.4" to a node id present in the graph.
resolve_id() {
  local g=$1 want=$2
  jq -r --arg w "$want" '
    [.nodes[] | select(.id == $w or .name == $w
                       or (.id | endswith(":" + $w)))] | .[0].id // empty' "$g"
}

# The same node and the same two directions of edges as the text pane, as one
# JSON object, for anything reading the map programmatically — a dashboard, a
# CI screen, another agent's tool — so none of them has to parse the pane or
# re-implement the lookup against map/graph.json.
#
# `confidence` is defaulted the way every other reader defaults it, rather than
# passed through as null: an edge nobody declared must not arrive at a consumer
# looking like one somebody did. That is the distinction the emit_edge comment
# in lib/scan.sh exists for, and it is worth nothing if it stops at the text.
query_json() {
  local g=$1 id=$2
  jq --arg id "$id" '
    def conf: (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with"))
                               then "inferred" else "extracted" end));
    def edge: {kind, evidence: (.evidence // ""), confidence: conf}
              + (if (.signal // "") == "" then {} else {signal} end);
    . as $g
    | first($g.nodes[] | select(.id == $id)) as $n
    | {id: $n.id, kind: $n.kind, name: $n.name, meta: ($n.meta // {}),
       edges: {
         out: [$g.edges[] | select(.from == $id) | {to} + edge],
         in: [$g.edges[] | select(.to == $id) | {from} + edge]}}' "$g"
}

cmd_query() {
  load_company
  style_init
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no map yet — run: orgami scan"
  local want="" json=0 a
  for a in "$@"; do
    case $a in
      --json) json=1 ;;
      -*) die "unknown flag '$a' — usage: orgami query <repo|host|tool|service|vendor> [--json]" ;;
      # The first positional is the node; later ones were ignored before the
      # flag existed and still are.
      *) [[ -n $want ]] || want=$a ;;
    esac
  done
  [[ -n $want ]] || die "usage: orgami query <repo|host|tool|service|vendor> [--json]"
  local id
  id=$(resolve_id "$g" "$want")
  [[ -n $id ]] || die "nothing called '$want' in the map — orgami view to browse"
  if [[ $json == 1 ]]; then query_json "$g" "$id"; else tui_preview "$id"; fi
}

# Kept because earlier versions bound the fzf preview to it.
cmd_show() {
  load_company
  ORGAMI_COLOR=1 tui_preview "$1"
}

cmd_open() {
  load_company
  tui_open "$1"
}
