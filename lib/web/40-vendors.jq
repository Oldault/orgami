# lib/web/40-vendors.jq — the vendors view: what the organization pays for.
#
# Input `.` is the sources object lib/web.sh builds (docs/web.md). Output is
# one object, the page's `views.vendors`. Nothing here is fetched and no figure
# in it is written by a model: the vendors are the graph's vendor nodes and
# `uses` edges unioned with the DNS reading, the same union lib/advise.jq
# makes; the proposals, the suppressed ones and the "not proposed, on purpose"
# section are map/advise.json passed through in the order it ranks them; the
# answers are the notes tagged advise-suppressed, read with the same marker
# lib/advise.sh writes. Every count the page shows is computed here (rule 3).
#
# No money. `orgami advise` has never seen an invoice, so there is no cost
# column to compute, and the view says so in its header (rule 6). Ranking is
# confidence first, blast radius second, which is advise.json's own order.

def strip_prefix($p): if startswith($p) then .[($p | length):] else . end;

# The marker `orgami advise --reject` leaves in the note it files. Reading it
# with the same shape lib/advise.sh reads it with is what makes an answer here
# the same answer `orgami advise --all` prints.
def mark_re: "<!-- orgami advise: suppressed ([^ >]+) -->";

# The reason is the note body without the marker, one line, the way
# advise_suppressions() renders it.
def reason: gsub("<!-- orgami advise:[^>]*-->"; "")
  | gsub("^\\s+"; "") | gsub("\\s+$"; "") | gsub("\\s*\\n\\s*"; " ");

# One repo's or one domain's worth of evidence, as the page draws it.
def code_row: {repo, at, confidence: (.confidence // "extracted"), signal: (.signal // null), source: "code"};
def dns_row: {domain, signal: (.signal // null), at, source: "dns"};

.map.graph as $g
| .map.dns as $dns
| .map.advise as $adv
| (.notes // []) as $notes
| if $g == null then {generated: null, missing: "orgami scan"} else

# --- the two sources, unioned per vendor ----------------------------------------
  ([$g.nodes[]? | select(.kind == "vendor")]) as $vnodes
| ([$g.edges[]? | select(.kind == "uses" and ((.to // "") | startswith("vendor:")))
    | {vendor: (.to | strip_prefix("vendor:")),
       repo: (.from | strip_prefix("repo:")),
       at: (.evidence // ""),
       confidence: (.confidence // "extracted"),
       signal: (.signal // null)}]) as $uses
| ([($dns.vendors // [])[] | . as $v | ($v.evidence // [])[]
    | {vendor: $v.id, domain: .domain, signal: .signal, at: .at,
       name: ($v.name // ""), category: ($v.category // ""),
       portal: ($v.portal // ""), flags: ($v.flags // [])}]) as $dnsrows

| (($adv.vendors // []) | map({key: .id, value: .}) | from_entries) as $advv
| ($adv.excluded.substitutable_categories // null) as $subst
| ($adv.proposals // []) as $props
| ($adv.suppressed // []) as $supp
| ($adv.excluded.duplicate_category // []) as $exdup
| ($adv.excluded.ghost_env_var // []) as $exghost

| (((([$vnodes[] | .id | strip_prefix("vendor:")]) + [$uses[].vendor] + [$dnsrows[].vendor]) | unique)) as $ids
| ([$ids[] as $id
    | ([$vnodes[] | select((.id | strip_prefix("vendor:")) == $id)] | first // {}) as $n
    | ([$dnsrows[] | select(.vendor == $id)] | first // {}) as $d
    | ($advv[$id] // {}) as $a
    | {id: $id,
       name: (($n.name // "") | if . == "" then ($d.name // $a.name // $id) else . end),
       # The node's category is what the scan wrote from lib/vendors.tsv; the
       # DNS reading and advise.json carry the same column for a vendor the
       # code never named.
       category: (($n.meta.category? // "") | if . == "" then ($d.category // $a.category // "") else . end),
       portal: (($n.meta.portal? // "") | if . == "" then ($d.portal // $a.portal // "") else . end),
       flags: (($n.meta.flags? // []) | if length == 0 then ($d.flags // []) else . end),
       code: ([$uses[] | select(.vendor == $id) | code_row] | sort_by(.repo, .at)),
       dns: ([$dnsrows[] | select(.vendor == $id) | dns_row] | sort_by(.domain, .at))}
    | .repos = (.code | map(.repo) | unique)
    | .domains = (.dns | map(.domain) | unique)
    | .source = (if (.code | length) > 0 and (.dns | length) > 0 then "both"
                 elif (.code | length) > 0 then "code"
                 elif (.dns | length) > 0 then "dns"
                 else "none" end)
    # null until `orgami advise` has run: the allow-list is advice policy and
    # lives in lib/advise.jq, so the page reads it back rather than copying it.
    | .category as $c
    | .substitutable = (if $subst == null then null else (($subst | index($c)) != null) end)
    | .advise = {proposals: [$props[] | select((.vendors // []) | index($id)) | {id, kind, rank, confidence}],
                 answered: [$supp[] | select((.vendors // []) | index($id)) | {id, kind, confidence}],
                 excluded: ([$exdup[] | select((.vendors // []) | index($id)) | {id, kind, reason}]
                            + [$exghost[] | select(.vendor == $id) | {id, kind, reason}])}]
   | sort_by((.name | ascii_downcase), .id)) as $vendors

| ($vendors | group_by(.category)
   | map({category: .[0].category,
          substitutable: .[0].substitutable,
          vendors: (map(.id))})
   | sort_by(.category)) as $categories

# --- what a human already answered ------------------------------------------------
#
# Read from the notes, not from advise.json, because the note is the record:
# `orgami advise --reject` files an ordinary note tagged advise-suppressed, and
# whoever changes their mind supersedes it like any other note. The latest note
# per proposal id is the answer that stands, as in advise_suppressions(); the
# ones it superseded, and anything that later superseded it, are the chain.
| ($notes | map({key: .id, value: .}) | from_entries) as $byid
| def note_ref: {id, author, date: (.date[0:10]), repo, file, archived, body: (.body | reason)};
  def forward($id; $depth):
    if $depth > 20 or $id == null or $id == "" or $byid[$id] == null then []
    else [$byid[$id] | note_ref] + forward($byid[$id].superseded_by; $depth + 1) end;
  ([$notes[] | select(((.tags // []) | index("advise-suppressed")) != null and (.archived | not))
    | . as $n
    | ([.body | scan(mark_re)] | flatten)[]?
    | {id: ., reason: ($n.body | reason), author: $n.author, date: ($n.date[0:10]),
       note: ($n | note_ref),
       superseded_by: forward($n.superseded_by; 0),
       supersedes: ($n.supersedes | if . == "" then null else . end)}]
   | group_by(.id) | map(sort_by(.date, .note.id) | last)
   | map(. as $s
     | ([$supp[] | select(.id == $s.id)] | first) as $p
     | $s + {proposed: ($p != null),
             proposal: (if $p == null then null
                        else ($p | {id, kind, confidence, claim,
                                    category: (.category // null), candidate: (.candidate // null),
                                    vendors: (.vendors // []), repos: (.repos // []),
                                    repo_count: (.repo_count // 0), domains: (.domains // []),
                                    sources: (.sources // [])}) end),
             # A code row's confidence is the graph edge's; a DNS row is a reading.
             evidence: [($p.evidence // [])[] | . as $e
                        | if .source == "dns" then {kind: "reading", at: .at, domain: .domain, vendor: .vendor}
                          else {kind: ([$uses[] | select(.vendor == $e.vendor and .repo == $e.repo and .at == $e.at)]
                                       | first | .confidence // "extracted"),
                                at: .at, repo: .repo, vendor: .vendor} end]})
   | sort_by(.date, .id) | reverse) as $answered

# --- the proposals, as advise ranks them --------------------------------------------
| ([$props[] | . as $p
    | {rank, id, kind, confidence,
       category: (.category // null), vendors: (.vendors // []), candidate: (.candidate // null),
       repos: (.repos // []), repo_count: (.repo_count // 0), domains: (.domains // []),
       sources: (.sources // []), signals: (.signals // null),
       last_push: (.last_push // null), days_since_push: (.days_since_push // null),
       claim, suppressed: false,
       evidence: [(.evidence // [])[] | . as $e
                  | if .source == "dns" then {kind: "reading", at: .at, domain: .domain, vendor: .vendor}
                    else {kind: ([$uses[] | select(.vendor == $e.vendor and .repo == $e.repo and .at == $e.at)]
                                 | first | .confidence // "extracted"),
                          at: .at, repo: .repo, vendor: .vendor} end],
       # Rule 8: the page changes nothing, so the answer is a command to copy.
       command: ("orgami advise --reject " + .id + " \"<reason>\"")}]) as $proposals

# --- the reading's own freshness, per source ---------------------------------------
| {graph: {generated: ($g.generated // null), command: "orgami scan"},
   dns: (if $dns == null then {generated: null, missing: "orgami dns"}
         else {generated: ($dns.generated // null), command: "orgami dns",
               domains: ($dns.domains // []),
               stale: ($adv.dns.stale // false),
               age_days: ($adv.dns.age_days // null)} end),
   advise: (if $adv == null then {generated: null, missing: "orgami advise"}
            else {generated: ($adv.generated // null), command: "orgami advise",
                  scanned: ($adv.scanned // null), stale_days: ($adv.stale_days // null)} end)} as $sources

# ISO timestamps sort as text, so max is the newest of what was read.
| {generated: ([$sources.graph.generated, $sources.dns.generated, $sources.advise.generated]
               | map(select(. != null)) | max),
   sources: $sources,
   counts: {vendors: ($vendors | length),
            categories: ([$categories[] | select(.category != "")] | length),
            repos: ([$uses[].repo] | unique | length),
            domains: ([$dnsrows[].domain] | unique | length),
            from_code: ([$vendors[] | select(.source == "code" or .source == "both")] | length),
            from_dns: ([$vendors[] | select(.source == "dns" or .source == "both")] | length),
            from_both: ([$vendors[] | select(.source == "both")] | length),
            dns_only: ([$vendors[] | select(.source == "dns")] | length),
            not_found: ([$vendors[] | select(.source == "none")] | length),
            proposals: ($proposals | length),
            high: ([$proposals[] | select(.confidence == "high")] | length),
            medium: ([$proposals[] | select(.confidence == "medium")] | length),
            answered: ($answered | length),
            excluded: (($exdup | length) + ($exghost | length))},
   repos: ([$uses[].repo] | unique | sort),
   categories: $categories,
   substitutable: $subst,
   vendors: $vendors,
   advise: (if $adv == null then {missing: "orgami advise"}
            else {generated: ($adv.generated // null), stale_days: ($adv.stale_days // null),
                  counts: ($adv.counts // null)} end),
   proposals: $proposals,
   answered: $answered,
   excluded: (if $adv == null then null
              else {duplicate_category: $exdup, ghost_env_var: $exghost,
                    substitutable_categories: ($subst // []),
                    policy: ($adv.excluded.policy // null)} end)}
  end
