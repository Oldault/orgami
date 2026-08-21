# Deterministic weekly numbers. The model is never asked to count anything.

# What counts as a bot lives in lib/bots.jq, shared with the daily digest and the
# coupling pass. Included, so this program runs as `jq -L lib -f lib/stats.jq`.
include "bots";

def median:
  sort
  | if length == 0 then 0
    elif length % 2 == 1 then .[(length / 2) | floor]
    else ((.[length / 2 - 1] + .[length / 2]) / 2) end;

def round1: . * 10 | round | . / 10;

def tally(f): map(f) | group_by(.) | map({key: .[0], count: length})
  | sort_by(-.count) | map({(.key): .count}) | add // {};

# Bots are counted apart, not counted out: `merged` and every figure under it
# read people only, and the bot half of the week is `merged_by_bots`. An
# organization running Dependabot merges version bumps nobody opened or read, and
# left in the pile they drag the median diff down and the unreviewed count up
# until neither describes anyone's work. Same split as lib/daily.jq.
.prs as $all
| [$all[] | select(.author.login | is_human)] as $prs
| ($prs | map(((.mergedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 3600)) as $lat
| {
    week: .week,
    since: .since,
    until: .until,
    merged: ($prs | length),
    # The same number as `merged`, under a name that cannot be misread. Every
    # figure here is handed to a model that must not count, so the pair it is
    # given has to say which side of the split it is on.
    merged_by_people: ($prs | length),
    merged_by_bots: ([$all[] | select(.author.login | is_bot)] | length),
    repos_touched: ($prs | map(.repository.name) | unique | length),
    by_repo: ($prs | tally(.repository.name)),
    by_author: ($prs | tally(.author.login // "unknown")),
    by_label: ($prs | map(.labels.nodes[].name) | group_by(.)
               | map({(.[0]): length}) | add // {}),
    lines_added: ($prs | map(.additions) | add // 0),
    lines_removed: ($prs | map(.deletions) | add // 0),
    median_changed_files: ($prs | map(.changedFiles) | median | round1),
    median_diff_lines: ($prs | map(.additions + .deletions) | median | round1),
    largest_pr: ($prs | max_by(.additions + .deletions)
                 | if . == null then null
                   else {repo: .repository.name, number: .number,
                         title: .title, lines: (.additions + .deletions)} end),
    median_hours_to_merge: ($lat | median | round1),
    slowest_hours_to_merge: ($lat | max // 0 | round1),
    merged_without_review: ($prs | map(select([.reviews.nodes[]
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")] | length == 0))
      | length),
    merged_same_day: ($prs | map(select(((.mergedAt | fromdateiso8601)
      - (.createdAt | fromdateiso8601)) < 86400)) | length),
    reviewers: ($prs | map(.reviews.nodes[] | select(.state == "APPROVED"
      or .state == "CHANGES_REQUESTED") | .author.login // "unknown")
      | group_by(.) | map({(.[0]): length}) | add // {}),
    review_pairs: ($prs | map(. as $p | .reviews.nodes[]
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
      | ((.author.login // "?") + " -> " + ($p.author.login // "?")))
      | group_by(.) | map({(.[0]): length}) | add // {}),
    review_threads: ($prs | map(.reviewThreads.nodes | length) | add // 0),
    unresolved_threads: ($prs | map([.reviewThreads.nodes[]
      | select(.isResolved == false)] | length) | add // 0),
    most_commented_paths: ($prs | map(.reviewThreads.nodes[].comments.nodes[].path)
      | map(select(. != null)) | group_by(.) | map({path: .[0], threads: length})
      | sort_by(-.threads) | .[0:10])
  }
