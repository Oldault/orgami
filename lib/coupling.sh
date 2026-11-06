# shellcheck shell=bash
# Which repos keep changing together. Read out of the cached pull requests,
# so it grows sharper every week the timer runs. Nothing static can see this.

# Which pairs are stable enough for the graph, in one place: what cmd_coupling
# writes as `stable` and what coupling_graph turns into an edge. Seen in more
# than one week or on more than one day, and by more than one person — one lead
# merging into two client projects every week is that person's calendar, not a
# coupling between the projects.
COUPLING_STABLE='def stable: ((.weeks // 0) > 1 or (.days // 0) > 1) and ((.authors // []) | length) > 1;'

# coupling_graph <graph> <coupling.json> — the graph on stdout, its changes-with
# edges rebuilt from the pairs: the old ones go, so a pair that stopped being
# stable stops being an edge, and a pair naming a repo the map no longer holds
# is left out rather than left dangling.
coupling_graph() {
  jq -s "$COUPLING_STABLE"'
    .[0] as $g | .[1] as $c
    | ([$g.nodes[] | select(.kind == "repo") | {key: .id, value: true}] | from_entries) as $have
    | $g
    | .edges = ([.edges[] | select(.kind != "changes-with")]
        + [($c.pairs // [])[] | select(stable)
           | {from: ("repo:" + .a), to: ("repo:" + .b), kind: "changes-with",
              evidence: ((.weeks | tostring) + " weeks / " + (.days | tostring)
                         + " days, " + (.authors | join(", "))),
              confidence: "inferred"}
           | select($have[.from] and $have[.to])]
        | unique)' "$1" "$2"
}

cmd_coupling() {
  load_company

  local weeks
  weeks=$(find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null | sort)
  [[ -n $weeks ]] || die "no cached pull requests — run: orgami pull"

  local out="$DIR/map/coupling.json"

  # Same author, same week, more than one repo: those repos moved together.
  # Bots are excluded — a dependency bump across ten repos is not coupling.
  # Which logins those are is lib/bots.jq's answer, the same one the numbers use.
  echo "$weeks" | xargs cat | jq -L "$ROOT/lib" -s '
    include "bots";
    '"$COUPLING_STABLE"'
    def combos($rs; $bucket; $author):
      [range(0; ($rs | length)) as $i
       | range($i + 1; ($rs | length)) as $j
       | {a: $rs[$i], b: $rs[$j], bucket: $bucket, author: $author}];

    [.[] | .week as $w | (.prs // [])[]
     | select(.author.login | is_human)
     | select(.mergedAt != null)
     | {week: $w, day: .mergedAt[0:10],
        author: (.author.login // "unknown"), repo: .repository.name}] as $ev

    | ([$ev | group_by(.author + "|" + .day)[]
        | combos(([.[].repo] | unique); .[0].day; .[0].author)] | add // []) as $dayp
    | ([$ev | group_by(.author + "|" + .week)[]
        | combos(([.[].repo] | unique); .[0].week; .[0].author)] | add // []) as $weekp
    | ($dayp | group_by(.a + "|" + .b)
       | map({key: (.[0].a + "|" + .[0].b), value: ([.[].bucket] | unique | length)})
       | from_entries) as $days

    | {generated: (now | todate),
       weeks_observed: ([$ev[].week] | unique | length),
       pairs: ($weekp | group_by(.a + "|" + .b)
         | map({a: .[0].a, b: .[0].b,
                weeks: ([.[].bucket] | unique | length),
                days: ($days[(.[0].a + "|" + .[0].b)] // 0),
                authors: ([.[].author] | unique)})
         | map(. + {stable: stable})
         | sort_by(-.weeks, -.days, .a))}' >"$out.tmp.$$" || {
    rm -f "$out.tmp.$$"
    die "could not count the cached pull requests in $DIR/cache/prs — run: orgami pull"
  }
  mv "$out.tmp.$$" "$out"

  local pairs
  pairs=$(jq '.pairs | length' "$out")
  echo "$out  ($pairs pairs over $(jq -r .weeks_observed "$out") week(s) of history)"

  # Only stable pairs reach the graph, and even then the edge is `inferred`:
  # two repos landing changes on the same day is a correlation counted out of
  # merged pull requests, not a dependency anybody declared. There is no
  # file:line to open, so the graph must not present it as though there were.
  local graph="$DIR/map/graph.json"
  if [[ -f $graph ]]; then
    coupling_graph "$graph" "$out" >"$graph.tmp.$$" || {
      rm -f "$graph.tmp.$$"
      die "could not add the pairs to $graph — it is unchanged; check it with: jq . $graph"
    }
    mv "$graph.tmp.$$" "$graph"
  fi
}
