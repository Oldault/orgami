# The activity view's payload: the weeks, the days and the coupling.
#
# Every figure here was computed before this program ran — lib/stats.jq over
# each cache/prs/<week>.json and lib/daily.jq over each cache/daily/<date>.json,
# by lib/web.sh, and lib/coupling.sh's own jq for map/coupling.json. This file
# only chooses, orders and labels what the page draws; the one thing it adds is
# a maximum per figure so a bar knows how tall the tallest is. The browser draws
# the bars and never counts.

# What counts as a bot is lib/bots.jq's answer, the one stats.jq counted with,
# so a row the page marks as a bot is one the figures left out of `merged`.
# Included, so this program runs as `jq -L lib`, the way lib/web.sh runs it.
include "bots";

# The figures worth a small multiple, in the order they are drawn. Anything else
# numeric stats.jq emits follows, so a figure added there shows up here without
# this file changing. `merged_by_people` is `merged` under a second name and is
# left out rather than drawn twice.
def preferred: [
  {key: "merged", label: "merged by people"},
  {key: "merged_by_bots", label: "merged by bots"},
  {key: "repos_touched", label: "repos touched"},
  {key: "authors", label: "authors"},
  {key: "merged_without_review", label: "merged without review"},
  {key: "merged_same_day", label: "merged the same day"},
  {key: "median_hours_to_merge", label: "median hours to merge"},
  {key: "slowest_hours_to_merge", label: "slowest hours to merge"},
  {key: "lines_added", label: "lines added"},
  {key: "lines_removed", label: "lines removed"},
  {key: "median_diff_lines", label: "median diff lines"},
  {key: "median_changed_files", label: "median changed files"},
  {key: "review_threads", label: "review threads"},
  {key: "unresolved_threads", label: "unresolved threads"}
];

# A recap is `reports/<week>.md`; a digest is `reports/daily/<date>.md`.
def text_of($list; $file): ([$list[] | select(.file == $file)][0] | .text) // null;

# The reviewers stats.jq counts are the ones who approved or asked for changes;
# a pull request with none of those is the `merged_without_review` figure. The
# same reduction lib/web.sh already made per pull request, kept as a flag.
def pr_row: {number, title, url, repo, author, mergedAt,
             lines: ((.additions // 0) + (.deletions // 0)),
             reviewed: ((.reviewers // []) | length > 0),
             bot: (.author | is_bot)};

# ---- weeks --------------------------------------------------------------------
# Newest first. A week whose figures stats.jq could not read keeps null figures
# and is still listed, so the page can say the file exists and cannot be read.
# `authors` is the one figure added: stats.jq tallies by author and never
# counts the tally, and the page wants the count beside `repos_touched`.
(.reports // []) as $reports
| (.daily // []) as $digests
| ([(.weeks // [])[] | select(.week != null)] | sort_by(.week) | reverse
   | map({week, since, until, file,
          stats: (if .stats == null then null
                  else .stats + {authors: (.stats.by_author // {} | length)} end),
          recap: text_of($reports; "reports/" + .week + ".md"),
          prs: [(.prs // [])[] | pr_row]})) as $weeks

# The figures drawn as small multiples: the preferred ones that at least one
# week carries, then whatever else numeric the newest readable week emits.
| ([$weeks[].stats | select(. != null)] ) as $stats
| (if ($stats | length) == 0 then []
   else
     ([preferred[] | select(.key as $k | any($stats[]; has($k)))]
      + [$stats[0] | to_entries[]
         | select(.value | type == "number")
         | select(.key as $k | (preferred | map(.key) + ["merged_by_people"] | index($k)) == null)
         | {key, label: (.key | gsub("_"; " "))}])
     | map(.key as $k
           | .max = ([$stats[][$k] | select(type == "number")] | max // 0))
   end) as $figures

# ---- days ---------------------------------------------------------------------
# A quiet day is one lib/daily.sh writes no digest for: nothing merged, nothing
# opened, nothing pushed outside a pull request. Same rule, so the page and the
# digests agree on which days exist. Newest first, the last fourteen.
| ([(.days // [])[] | select(.date != null and .stats != null)
    | select(((.stats.merged // 0) + (.stats.opened // 0) + (.stats.commits_outside_prs // 0)) > 0)]
   | sort_by(.date) | reverse | .[0:14]
   | map({date, file, stats,
          digest: text_of($digests; "reports/daily/" + .date + ".md")})) as $days

# ---- coupling -----------------------------------------------------------------
# map/coupling.json as lib/coupling.sh wrote it: pairs of repos with the same
# author merging in both in the same week, and in the same day, bots excluded.
# The repo list is every name in a pair, sorted, so the matrix is the same
# order on both axes and the same order every render.
| .map.coupling as $c
| (if $c == null then {generated: null, missing: "orgami coupling"}
   else {generated: ($c.generated // null),
         command: "orgami coupling",
         weeks_observed: ($c.weeks_observed // 0),
         repos: ([($c.pairs // [])[] | .a, .b] | unique),
         pairs: [($c.pairs // [])[] | {a, b, weeks: (.weeks // 0), days: (.days // 0),
                                        authors: (.authors // [])}],
         max: {weeks: ([($c.pairs // [])[].weeks] | max // 0),
               days: ([($c.pairs // [])[].days] | max // 0)}}
   end) as $coupling

# ---- the object ----------------------------------------------------------------
# The cache carries no `generated` of its own: a week is dated by the last day
# it covers, a day by its date. The view's own freshness is the newest of the
# three readings it draws.
| ($weeks | map(.until // .week) | max) as $weeks_through
| ($days | map(.date) | max) as $days_through
| ([$weeks_through, $days_through, $coupling.generated] | map(select(. != null)) | max) as $newest
| if $newest == null then {generated: null, missing: "orgami pull"}
  else
  {generated: $newest,
   command: "orgami pull",
   weeks: (if ($weeks | length) == 0 then {generated: null, missing: "orgami pull"}
           else {generated: $weeks_through, command: "orgami pull", count: ($weeks | length)} end),
   figures: $figures,
   list: $weeks,
   days: (if ($days | length) == 0 then {generated: null, missing: "orgami daily"}
          else {generated: $days_through, command: "orgami daily", count: ($days | length),
                list: $days} end),
   coupling: $coupling}
  end
