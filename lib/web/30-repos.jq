# The repos view: one row per repo for the table, and everything the per-repo
# page shows — what lib/card.sh prints for `orgami context`, as data. Input is
# the sources object lib/web.sh builds (docs/web.md); output is one object.
#
# Every figure here is the org's figure (rule 3): the counts at the top and the
# per-repo edge and note counts are computed in this file, never in the page.
# The page may count the rows it is filtering, and nothing else.

def bare: sub("^[a-z-]+:"; "");
def kind_of: split(":")[0];
# An edge written before `confidence` existed still reads correctly — the same
# rule lib/card.sh and lib/html.sh apply.
def conf: (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with")) then "inferred" else "extracted" end));
# "src/orders/orders.controller.ts:12 GET /orders" — the line, and the route.
def route_of:
  if test("^\\S+:[0-9]+ ") then capture("^(?<at>\\S+:[0-9]+) (?<route>.*)$")
  else {at: null, route: .} end;

.map.repos as $repos
| .map.graph as $g
| .map.coupling as $c
| .map.live as $live
| (.notes // []) as $notes
| (.runbooks // []) as $runbooks
| (.playbooks // []) as $playbooks
| if $repos == null then {generated: null, missing: "orgami scan"} else
  ($g.edges // []) as $edges
  | [ $repos[]
      | .name as $r
      | ("repo:" + $r) as $id
      # Both directions of every edge that touches this repo, deduplicated.
      | ([ $edges[]
           | select(.from == $id or .to == $id)
           | (.from == $id) as $out
           | (if $out then .to else .from end) as $peer
           | {dir: (if $out then "out" else "in" end),
              kind,
              peer: ($peer | bare),
              peer_kind: ($peer | kind_of),
              evidence: (.evidence // ""),
              confidence: conf,
              signal: (.signal // null)} ]
         | unique) as $links
      # shares-config carries the variable names in its evidence, so an env var
      # can be marked with the repos that read the same name.
      | ([ $links[] | select(.kind == "shares-config")
           | .peer as $p
           | (.evidence | split(", ") | map(select(. != ""))[])
           | {var: ., peer: $p} ]) as $shared
      | {name: $r,
         description: (.meta.description // ""),
         language: (.meta.language // null),
         frameworks: (.frameworks // []),
         runtime: (.commands.runtime // null),
         package_manager: (.commands.package_manager // null),
         procfile: (.commands.procfile // []),
         scripts: ((.commands.scripts // {}) | to_entries | map({name: .key, command: .value})),
         private: (.meta.private // false),
         url: (.meta.url // null),
         default_branch: (.meta.default_branch // "main"),
         pushed_at: (.meta.pushed_at // null),
         topics: (.meta.topics // []),
         size_kb: (.meta.size_kb // null),
         agent_docs: (.agent_docs // []),
         workflows: (.workflows // []),
         serves: (.serves // []),
         routes: [ (.routes // [])[] | route_of ],
         env: [ (.env // [])[] | . as $v
                | {name: $v, shared_with: ([ $shared[] | select(.var == $v) | .peer ] | unique)} ],
         edges: $links,
         edge_count: ($links | length),
         deploys_to: [ $links[] | select(.kind == "deploys-to" and .dir == "out") ],
         live: [ ($live.deployments // [])[] | select(.repo == $r) ],
         coupling: ([ ($c.pairs // [])[]
                      | select(.a == $r or .b == $r)
                      | {other: (if .a == $r then .b else .a end), weeks, days, authors: (.authors // [])} ]
                    | sort_by(-.days, -.weeks, .other)),
         notes: [ $notes[] | select(.repo == $r)
                  | {id, author, date, tags, topic, supersedes, superseded_by, archived, body} ],
         note_count: ([ $notes[] | select(.repo == $r and (.archived | not)) ] | length),
         runbook: ([ $runbooks[] | select(.file == "map/runbooks/" + $r + ".md") | .text ] | first // null),
         playbooks: [ $playbooks[] | select(.file | startswith("map/playbooks/" + $r + "--"))
                      | {file, topic: (.file | ltrimstr("map/playbooks/" + $r + "--") | rtrimstr(".md")), text} ]}
    ]
  | sort_by(.name) as $rows
  | {generated: ($g.generated // null),
     command: "orgami scan",
     counts: {repos: ($rows | length),
              private: ([ $rows[] | select(.private) ] | length),
              edges: ($edges | length),
              deployed: ([ $rows[] | select((.live | length) > 0) ] | length),
              notes: ([ $rows[] | .note_count ] | add // 0)},
     # How old each other reading is, for the sections that draw from them.
     sources: {coupling: (if $c == null then {generated: null, missing: "orgami coupling"}
                          else {generated: ($c.generated // null), weeks_observed: ($c.weeks_observed // null)} end),
               live: (if $live == null then {generated: null, missing: "orgami live"}
                      else {generated: ($live.generated // null)} end)},
     repos: $rows}
  end
