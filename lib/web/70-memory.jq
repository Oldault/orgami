# The memory view: what the team knows, as data. Notes with their superseded
# chain folded under the note that replaced them, the decisions one section
# per week, the playbooks with the instance count map/PLAYBOOKS.md carries and
# their evidence split from their prose, and the runbooks with an anchor for
# each note tag whose section exists. Input is the sources object lib/web.sh
# builds (docs/web.md); output is one object.
#
# Every figure here is the org's figure (rule 3): the counts, the tag and repo
# tallies, the instance counts and the TODO counts are computed in this file.
# The page may count the rows it is filtering, and nothing else.
#
# Nothing is read from notes/draft/: lib/web.sh never lists it, and this file
# has no way to reach it. A drafted note is not a note anyone wrote.

# --- links --------------------------------------------------------------------
# lib/common.sh `linkify_prs` in jq, applied the same way: a link exists only
# where the reference exists — `repo#123` or `org/repo#123` becomes a link when
# `repo` is a repo node in graph.json and `org` is this org, and stays text
# otherwise. A markdown link the file already holds is kept as the link it is.
# Each bullet comes out as parts: {text} or {text, url}.
def link_parts($org; $repos):
  . as $s
  | [ match("\\[(?<label>[^\\]]+)\\]\\((?<href>https?://[^)\\s]+)\\)"
            + "|(?<pre>^|[\\s(`])(?<ref>(?:(?<o>[A-Za-z0-9_.-]+)/)?(?<r>[A-Za-z0-9_.-]+)#(?<n>[0-9]+))"; "g") ]
  | reduce .[] as $m ({parts: [], at: 0};
      ( [$m.captures[] | {key: .name, value: .string}] | from_entries ) as $c
      | .parts += (if $m.offset > .at then [{text: $s[.at:$m.offset]}] else [] end)
      | .parts += (if $c.label != null then [{text: $c.label, url: $c.href}]
                   elif ($c.o == null or $c.o == $org) and ($repos | index($c.r)) != null
                   then [{text: $c.pre}, {text: $c.ref, url: "https://github.com/\($org)/\($c.r)/pull/\($c.n)"}]
                   else [{text: $m.string}] end)
      | .at = $m.offset + $m.length)
  | .parts + (if .at < ($s | length) then [{text: $s[.at:]}] else [] end)
  | map(select(.text != ""));

# --- dates --------------------------------------------------------------------
# An ISO week's Sunday, so a decisions fragment named by its week can say how
# old it is the way every other reading does. January 4th is always in week 1.
def week_end:
  (capture("^(?<y>[0-9]{4})-W(?<n>[0-9]{2})$") // null) as $c
  | if $c == null then null else
      ($c.y + "-01-04T00:00:00Z" | fromdateiso8601) as $jan4
      | ($jan4 | gmtime | .[6]) as $wd
      | (if $wd == 0 then 7 else $wd end) as $iso
      | ($jan4 - (($iso - 1) * 86400) + ((($c.n | tonumber) - 1) * 7 + 6) * 86400)
      | todateiso8601
    end;

def newest: map(select(. != null)) | if length == 0 then null else max end;

# --- notes --------------------------------------------------------------------
# A note's body, the way `orgami notes` prints it: the marker an advise
# rejection leaves is read off into its own field and the comment dropped.
def note_body: gsub("<!--[^>]*-->"; "") | gsub("^\\n+"; "") | gsub("\\n+$"; "");
def note_answers: (capture("<!-- orgami advise: suppressed (?<id>[^ ]+) -->") // null) | if . == null then null else .id end;

def note_row:
  {id, author, date, repo, tags, topic, supersedes, superseded_by, archived, file,
   answers: (.body | note_answers),
   body: (.body | note_body),
   supersede_command: ("orgami note --supersede " + .id + " \"what is true now\"")};

# The chain a note replaced, oldest last, nested: a note that superseded
# another carries it under `replaced`, and that one carries its own.
def replaced($all):
  . as $n
  | .replaced = [ $all[] | select(.id == $n.supersedes and $n.supersedes != "") | note_row | replaced($all) ];

# --- playbooks ----------------------------------------------------------------
# lib/playbook.sh writes a title, a <sub> saying which model wrote it and when,
# the prose, a rule, then "## What this was written from" with the evidence in
# one fence. The prose and the evidence are split here so the page can never
# draw one as the other.
def playbook_parts:
  . as $t
  | (index("\n## What this was written from") // ($t | length)) as $cut
  | ($t[:$cut]
     | sub("^# [^\n]*\n"; "")
     | sub("<sub>[^<]*</sub>"; "")
     | sub("\n---\\s*$"; "")
     | gsub("^\\n+"; "") | gsub("\\n+$"; "")) as $prose
  | ($t[$cut:] | capture("```\n(?<ev>[\\s\\S]*?)\n```") // {ev: null}) as $e
  | {prose: $prose, evidence: $e.ev,
     todos: ([ $prose | scan("TODO — the evidence does not say how[^\n]*") ] | length)};

def playbook_header:
  capture("<sub>Written by `(?<model>[^`]+)` on (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2}) from (?<n>[0-9]+) recorded") // null;

# map/PLAYBOOKS.md, one row per playbook: the instance count and the date it
# was written are read off the table, keyed by the file the row links to.
def playbook_index($pages):
  ([ $pages[] | select(.file == "map/PLAYBOOKS.md") | .text ] | first) as $t
  | if $t == null then null else
      [ $t | scan("\\| *([^|]*?) *\\| *\\[[^\\]]*\\]\\(playbooks/([^)]+)\\) *\\| *([0-9]+) *\\| *([0-9-]*) *\\|")
        | {repo: .[0], file: ("map/playbooks/" + .[1]), instances: (.[2] | tonumber), written: (.[3] | select(. != ""))} ]
    end;

# --- runbooks -----------------------------------------------------------------
# The tags lib/runbook.sh files a note under, and the heading each becomes.
# An anchor is emitted only where the heading is in the page.
def runbook_tags:
  [ {tag: "setup", heading: "Getting it running"},
    {tag: "deploy", heading: "Deploying it"},
    {tag: "rollback", heading: "Rolling it back"},
    {tag: "incident", heading: "When it broke before"},
    {tag: "alert", heading: "When an alert fires"},
    {tag: "gotcha", heading: "Traps"},
    {tag: "oncall", heading: "Who to reach"} ];

# ------------------------------------------------------------------------------
(.notes // []) as $notes
| (.decisions // []) as $decisions
| (.playbooks // []) as $playbooks
| (.runbooks // []) as $runbooks
| (.pages // []) as $pages
| ([ (.map.graph.nodes // [])[] | select(.kind == "repo") | .name ]) as $repo_names

# notes: the ones still standing, newest first, each carrying what it replaced;
# the archived ones apart, reachable but not listed.
| ([ $notes[] | select(.archived | not) ]) as $live
| ([ $live[] | .id ]) as $live_ids
| ([ $live[] | .superseded_by as $by
             | select($by == null or ($live_ids | index($by)) == null)
             | note_row | replaced($live) ]
   | sort_by(.date, .id) | reverse) as $listed
| ([ $notes[] | select(.archived) | note_row ] | sort_by(.date, .id) | reverse) as $archived
| ($listed | [ .[] | .tags[] ] | group_by(.) | map({tag: .[0], count: length}) | sort_by(-.count, .tag)) as $tags
| ($listed | [ .[] | select(.repo != "") | .repo ] | group_by(.) | map({repo: .[0], count: length}) | sort_by(-.count, .repo)) as $repos
| {generated: ([ $notes[] | .date ] | newest),
   command: "orgami note",
   list: $listed,
   archived: $archived,
   tags: $tags,
   repos: $repos,
   counts: {listed: ($listed | length),
            replaced: ([ $listed[] | .. | objects | select(has("replaced")) | .replaced[] ] | length),
            archived: ($archived | length),
            answers: ([ $listed[] | select(.answers != null) ] | length)},
   note_command: "orgami note --repo <repo> --tag <tag> \"what you learned\"",
   list_command: "orgami notes --repo <repo> --tag <tag>"} as $n

# decisions: one section per week, newest first, every bullet tokenised so the
# page draws a link only where the reference is one.
| ([ $decisions[]
     | (.file | capture("map/decisions/(?<week>[^/]+)\\.md").week) as $week
     | {week: $week, file,
        generated: ($week | week_end),
        bullets: [ .text | split("\n")[] | select(startswith("- ")) | .[2:]
                   | {text: ., parts: link_parts($org; $repo_names)} ]} ]
   | sort_by(.week) | reverse) as $weeks
| {generated: ([ $weeks[] | .generated ] | newest),
   command: "orgami report",
   weeks: $weeks,
   counts: {weeks: ($weeks | length),
            decisions: ([ $weeks[] | .bullets | length ] | add // 0),
            linked: ([ $weeks[] | .bullets[] | .parts[] | select(.url != null) ] | length)},
   page: ([ $pages[] | select(.file == "map/DECISIONS.md") | .file ] | first)} as $d

# playbooks: one row per file, the instance count from map/PLAYBOOKS.md, the
# prose apart from the evidence, and the holes counted.
| (playbook_index($pages)) as $index
| ([ $playbooks[]
     | .file as $f
     | (.file | capture("map/playbooks/(?<repo>.+?)--(?<topic>.+)\\.md")) as $name
     | (.text | playbook_header) as $hdr
     | (if $index == null then null else ([ $index[] | select(.file == $f) ] | first) end) as $row
     | (.text | playbook_parts) as $parts
     | {file: $f, repo: $name.repo, topic: $name.topic,
        title: ($name.topic | gsub("-"; " ")),
        model: ($hdr.model // null),
        written: ($hdr.date // null),
        instances: (if $row == null then null else $row.instances end),
        written_from: (if $hdr == null then null else ($hdr.n | tonumber) end),
        prose: $parts.prose,
        evidence: $parts.evidence,
        todos: $parts.todos,
        record_command: ("orgami note --repo " + $name.repo + " --tag pattern --topic " + $name.topic + " \"…\""),
        rewrite_command: ("orgami playbook " + $name.repo + " --topic " + $name.topic)} ]
   | sort_by(.repo, .topic)) as $plist
| {generated: ([ $plist[] | .written | select(. != null) | . + "T00:00:00Z" ] | newest),
   command: "orgami playbook <repo> --topic <topic>",
   index: (if $index == null then {missing: "orgami doc"} else {file: "map/PLAYBOOKS.md", rows: ($index | length)} end),
   list: $plist,
   counts: {playbooks: ($plist | length),
            repos: ([ $plist[] | .repo ] | unique | length),
            instances: ([ $plist[] | .instances | select(. != null) ] | add // 0),
            todos: ([ $plist[] | .todos ] | add // 0)}} as $p

# runbooks: the index, and each page with the anchors its headings allow.
| ([ $runbooks[]
     | .file as $f
     | (.file | capture("map/runbooks/(?<repo>.+)\\.md").repo) as $repo
     | (.text | capture("Derived from the scan of (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})") // null) as $scan
     | (.text | capture("^# [^\n]*\n\n(?<line>[^\n]*)") // null) as $line
     | .text as $text
     | {file: $f, repo: $repo,
        in_map: (($repo_names | index($repo)) != null),
        scan: (if $scan == null then null else $scan.d end),
        summary: (if $line == null then null else $line.line end),
        anchors: [ runbook_tags[] | select(("## " + .heading) as $h | $text | contains($h)) ],
        sections: [ .text | split("\n")[] | select(startswith("## ")) | .[3:] ],
        text} ]
   | sort_by(.repo)) as $rlist
| {generated: ([ $rlist[] | .scan | select(. != null) | . + "T00:00:00Z" ] | newest),
   command: "orgami doc",
   list: $rlist,
   tags: runbook_tags,
   org_page: ([ $pages[] | select(.file == "map/RUNBOOK.md") | .file ] | first),
   counts: {runbooks: ($rlist | length),
            with_notes: ([ $rlist[] | select((.anchors | length) > 0) ] | length)}} as $r

# The view. Nothing recorded anywhere is the panel naming the first command
# that writes memory; otherwise the newest date among the four, and each
# section carrying its own.
| if ($notes | length) == 0 and ($decisions | length) == 0 and ($playbooks | length) == 0 and ($runbooks | length) == 0
  then {generated: null, missing: "orgami note"}
  else
    {generated: ([ $n.generated, $d.generated, $p.generated, $r.generated ] | newest),
     sources: {notes: (if ($notes | length) == 0 then {generated: null, missing: "orgami note"} else {generated: $n.generated, command: $n.command} end),
               decisions: (if ($decisions | length) == 0 then {generated: null, missing: "orgami report"} else {generated: $d.generated, command: $d.command} end),
               playbooks: (if ($playbooks | length) == 0 then {generated: null, missing: "orgami playbook"} else {generated: $p.generated, command: $p.command} end),
               runbooks: (if ($runbooks | length) == 0 then {generated: null, missing: "orgami doc"} else {generated: $r.generated, command: $r.command} end)},
     counts: {notes: $n.counts.listed, decisions: $d.counts.decisions,
              playbooks: $p.counts.playbooks, runbooks: $r.counts.runbooks},
     notes: $n, decisions: $d, playbooks: $p, runbooks: $r}
  end
