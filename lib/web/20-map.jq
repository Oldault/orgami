# The map view's payload: what graph.html draws, and no more. The same
# reduction html_payload makes in lib/html.sh — nodes with language,
# description, url, pushed and private; edges with their confidence; depth and
# live cut down to per-repo totals — plus the figures the page presents as the
# org's, computed here and not in the browser (rule 3): the counts by kind, the
# extracted/inferred split per edge kind, and the corners.
#
# A corner is what a picture is for and a table hides: a node with no edges at
# all, and a repo nothing points at. The third list, repos only inferred edges
# point at, is the same question asked with the inferred toggle off.

.map.graph as $g
| if $g == null then {generated: null, missing: "orgami scan"} else

# An edge's confidence, when the scan did not write one: the three kinds that
# come from matching are inferred, the rest are read from a file.
def conf: (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with"))
                           then "inferred" else "extracted" end));

# The order the edge-kind filter draws its chips in. Kinds the graph has that
# are not named here follow, sorted, so nothing in the file is left off the page.
def kind_order: ["uses", "deploys-to", "depends-on", "reaches", "references",
                 "imports", "calls", "shares-config", "changes-with", "written-in"];

($g.nodes // []) as $nodes
| [($g.edges // [])[] | {from, to, kind, evidence, confidence: conf}] as $edges
| ([$nodes[].id] | unique) as $ids
# Only edges between nodes that exist count for degrees; a dangling edge is
# not drawn, so it must not make a node look connected.
| [$edges[] | select((.from | IN($ids[])) and (.to | IN($ids[])))] as $drawn
| ([$drawn[] | .from, .to] | unique) as $touched
| ([$drawn[] | .to] | unique) as $pointed_at
| ([$drawn[] | select(.confidence == "extracted") | .to] | unique) as $pointed_at_extracted
| ([$drawn[].kind] | unique) as $kinds_present
| (kind_order | map(select(IN($kinds_present[])))
   + ($kinds_present | map(select(IN(kind_order[]) | not)) | sort)) as $kind_list

| {generated: ([$g.generated, .map.depth.generated, .map.live.generated]
               | map(select(. != null)) | max),
   command: "orgami scan",
   org: $g.org,
   nodes: [$nodes[] | {id, kind, name,
                       language: (.meta.language // null),
                       description: (.meta.description // null),
                       url: (.meta.url // null),
                       pushed: (.meta.pushed_at // null),
                       private: (.meta.private // null)}],
   edges: $edges,
   depth: (.map.depth
           | if . == null then null
             else {generated, totals, repos: (.repos // [])} end),
   live: (.map.live
          | if . == null then null
            else {generated,
                  deployments: [(.deployments // [])[]
                                | {repo, provider, name, state, urls}]} end),
   counts: {
     nodes: ($nodes | length),
     repos: ([$nodes[] | select(.kind == "repo")] | length),
     edges: ($drawn | length),
     extracted: ([$drawn[] | select(.confidence == "extracted")] | length),
     inferred: ([$drawn[] | select(.confidence == "inferred")] | length),
     by_kind: ([$nodes[].kind] | group_by(.) | map({key: .[0], value: length}) | from_entries),
     edge_kinds: [$kind_list[] as $k
                  | {kind: $k,
                     extracted: ([$drawn[] | select(.kind == $k and .confidence == "extracted")] | length),
                     inferred: ([$drawn[] | select(.kind == $k and .confidence == "inferred")] | length)}]},
   corners: {
     isolated: [$nodes[] | select(.id | IN($touched[]) | not) | .id] | sort,
     unreferenced: [$nodes[] | select(.kind == "repo")
                    | select(.id | IN($pointed_at[]) | not) | .id] | sort,
     only_inferred: [$nodes[] | select(.kind == "repo")
                     | select(.id | IN($pointed_at[]))
                     | select(.id | IN($pointed_at_extracted[]) | not) | .id] | sort}}
end
