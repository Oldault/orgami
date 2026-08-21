# Every number in the daily digest. The model is handed these and told to write
# around them, never to count. Same rule as lib/stats.jq.

# What counts as a bot lives in lib/bots.jq, shared with lib/stats.jq and the
# coupling pass. Included, so this program is run as `jq -L lib -f lib/daily.jq`.
include "bots";

def tally(f): map(f) | group_by(.) | map({key: .[0], count: length})
  | sort_by(-.count) | map({(.key): .count}) | add // {};
def hours($from; $to): (($to | fromdateiso8601) - ($from | fromdateiso8601)) / 3600;

.date as $date
| ((.date + "T23:59:59Z") | fromdateiso8601) as $eod
| [.merged[] | select(.author.login | is_human)] as $merged
| [.opened[] | select(.author.login | is_human)] as $opened
| [.open[] | select(.author.login | is_human)] as $open
| [.commits[] | select(.author.login | is_human)] as $commits
# A commit that belongs to a merged pull request is already counted as that pull
# request. What merges cannot see is the rest: work pushed to a branch with no
# pull request behind it.
| [$commits[] | select(.pull_request == null)] as $loose
| ([$merged[].repository.name] + [$loose[].repository.name] | unique) as $repos
| {
    date: $date,
    org: .org,

    merged: ($merged | length),
    merged_by_bots: ([.merged[] | select(.author.login | is_bot)] | length),
    opened: ($opened | length),
    open_touched: ($open | length),

    commits: ($commits | length),
    commits_outside_prs: ($loose | length),
    commits_by_bots: ([.commits[] | select(.author.login | is_bot)] | length),
    repos_touched: ($repos | length),
    by_repo: ($repos | map(. as $r
              | {($r): (([$merged[] | select(.repository.name == $r)] | length)
                        + ([$loose[] | select(.repository.name == $r)] | length))})
              | add // {}),
    authors: ((([$merged[].author.login] + [$loose[].author.login]) | unique | length)),
    by_author: (($merged + $loose) | tally(.author.login // "unknown")),

    lines_added: ([$merged[].additions] | add // 0),
    lines_removed: ([$merged[].deletions] | add // 0),

    merged_without_review: ([$merged[]
      | select([.reviews.nodes[] | select(.state == "APPROVED"
                or .state == "CHANGES_REQUESTED")] | length == 0)] | length),

    median_hours_to_merge: ([$merged[] | hours(.createdAt; .mergedAt)]
      | sort | if length == 0 then 0
        elif length % 2 == 1 then .[(length / 2) | floor]
        else ((.[length / 2 - 1] + .[length / 2]) / 2) end
      | . * 10 | round | . / 10),

    # An open pull request nobody has reviewed, ranked by how long it has sat.
    waiting: ([$open[]
      | select([.reviews.nodes[] | select(.state == "APPROVED"
                or .state == "CHANGES_REQUESTED")] | length == 0)
      | {repo: .repository.name, number, title,
         author: (.author.login // "unknown"),
         days: (($eod - (.createdAt | fromdateiso8601)) / 86400 | floor)}]
      | sort_by(-.days) | .[0:5]),

    loose_repos: ([$loose[].repository.name] | unique)
  }
