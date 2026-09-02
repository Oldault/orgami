# shellcheck shell=bash
# orgami cost — the one place money enters the map, and a person types it.
#
# Nothing else in orgami has seen an invoice, and nothing here changes that: a
# figure in map/costs.json is a human's claim, filed with who typed it and
# when, the way a note is. The tool never prices a vendor, never converts a
# currency, never guesses a seat count. `orgami advise` and the vendors view of
# map/orgami.html show the figure beside the vendor it names and keep ranking
# by confidence and blast radius — money on the page is a claim to check, not
# a number the tool computed.
#
# One row per vendor, and the vendor has to be one the map or the DNS reading
# already knows. A cost against a name nothing else can find would be the first
# fact on the page with no evidence beneath it.
#
#   orgami cost <vendor> <amount> [--per month|year] [--currency EUR] [--note "…"]
#   orgami cost --list
#   orgami cost --remove <vendor>
#
# The file is replaced atomically, like every other artefact. It leaves the
# machine only when the company config says `publish_costs: true` — a docs
# repo may be public (lib/publish.sh).

COST_DEFAULT_PERIOD=month
COST_DEFAULT_CURRENCY=EUR

# The vendors a figure may be filed against: the graph's vendor nodes unioned
# with the DNS reading's, as [{id, name}]. Empty when neither file exists.
cost_known_vendors() {
  local g="$DIR/map/graph.json" d="$DIR/map/dns.json"
  [[ -f $g ]] || g=/dev/null
  [[ -f $d ]] || d=/dev/null
  jq -n --slurpfile g "$g" --slurpfile d "$d" '
    ([($g[0].nodes // [])[] | select(.kind == "vendor")
      | {id: (.id | sub("^vendor:"; "")), name: (.name // "")}]
     + [($d[0].vendors // [])[] | {id, name: (.name // "")}])
    | group_by(.id) | map({id: .[0].id, name: (map(.name) | map(select(. != "")) | first // .[0].id)})
    | sort_by(.id)'
}

# cost_resolve <name> — the id of the one vendor the name means, on stdout.
# Exact id first, then id or display name ignoring case. Anything else dies
# with the nearest names, so a typo is answered with the spelling that would
# have worked rather than with a list of everything.
cost_resolve() {
  local q=$1 known
  known=$(cost_known_vendors)
  [[ $(jq 'length' <<<"$known") -gt 0 ]] ||
    die "no vendor in the map yet — run: orgami scan (or orgami dns)"

  local id
  id=$(jq -r --arg q "$q" '
    (map(select(.id == $q)) + map(select((.id | ascii_downcase) == ($q | ascii_downcase)
                                        or (.name | ascii_downcase) == ($q | ascii_downcase))))
    | first // empty | .id' <<<"$known")
  if [[ -n $id ]]; then echo "$id"; return 0; fi

  # Nearest by shared letter pairs, with a bonus when one name contains the
  # other. Cheap, and right often enough to name the vendor that was meant.
  local near
  near=$(jq -r --arg q "$q" '
    def bigrams: ascii_downcase | [range(0; length - 1) as $i | .[$i:$i + 2]] | unique;
    ($q | ascii_downcase) as $lq | ($q | bigrams) as $qb
    | map(. as $v
          | (($v.id + " " + $v.name) | bigrams) as $b
          | (($qb | map(select(. as $x | $b | index($x) != null)) | length)
             + (if (($v.id | ascii_downcase) | contains($lq)) or ($lq | contains($v.id | ascii_downcase))
                then 10 else 0 end)) as $score
          | {id: $v.id, score: $score})
    | map(select(.score > 0)) | sort_by(-.score, .id) | .[0:5] | map(.id) | join(", ")' <<<"$known")
  if [[ -n $near ]]; then
    die "no vendor '$q' in the map or the DNS reading — nearest names: $near"
  fi
  die "no vendor '$q' in the map or the DNS reading — known vendors: $(jq -r 'map(.id) | join(", ")' <<<"$known")"
}

# Who is typing. The author the notes already carry when one is configured,
# else the git identity, else the login — never a network call.
cost_author() {
  local a
  a=$(jq -r '.author // empty' "$ORGAMI_HOME/config.json" 2>/dev/null || true)
  [[ -n $a ]] || a=$(git config user.name 2>/dev/null || true)
  [[ -n $a ]] || a=${USER:-unknown}
  echo "$a"
}

# cost_write <jq-filter> [jq args...] — `.` is the current rows array (empty
# when there is no file yet); the filter emits the new one. The file is
# replaced atomically, `generated` stamped with the moment of the write.
cost_write() {
  local filter=$1 f="$DIR/map/costs.json" tmp
  shift
  [[ -f $f ]] || f=/dev/null
  tmp=$(mktemp)
  jq -n --slurpfile cur "$f" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" \
    "(\$cur[0].costs // []) | ($filter) | sort_by(.vendor) | {generated: \$now, costs: .}" >"$tmp" ||
    { rm -f "$tmp"; die "could not write $DIR/map/costs.json"; }
  mv "$tmp" "$DIR/map/costs.json"
}

# The rows as a person reads them: one line per vendor, aligned, the note last.
cost_list() {
  local f="$DIR/map/costs.json"
  [[ -f $f ]] || { log "no cost recorded yet — orgami cost <vendor> <amount>"; return 0; }
  jq -r --arg only "${1-}" '
    .costs | map(select($only == "" or .vendor == $only))
    | if length == 0 then empty else
      (map(.vendor | length) | max) as $w
      | .[]
      | "\(.vendor)\(" " * ($w - (.vendor | length)) // "")  \(.amount) \(.currency)/\(.period)  \(.who), \(.when[0:10])"
        + (if (.note // "") != "" then "  — " + .note else "" end)
      end' "$f"
}

cmd_cost() {
  load_company

  local list=0 as_json=0 remove="" per="" currency="" note="" vendor="" amount=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --list | -l) list=1; shift ;;
      --json) as_json=1; shift ;;
      --remove | --rm) need_arg "$1" $#; remove=$2; shift 2 ;;
      --per) need_arg "$1" $#; per=$2; shift 2 ;;
      --currency) need_arg "$1" $#; currency=$2; shift 2 ;;
      --note) need_arg "$1" $#; note=$2; shift 2 ;;
      -*) die "unknown flag: $1" ;;
      *)
        if [[ -z $vendor ]]; then vendor=$1
        elif [[ -z $amount ]]; then amount=$1
        else die "one vendor and one amount — orgami cost <vendor> <amount>"
        fi
        shift ;;
    esac
  done

  if [[ $as_json == 1 ]]; then
    if [[ -f $DIR/map/costs.json ]]; then cat "$DIR/map/costs.json"
    else echo '{"generated": null, "costs": []}'; fi
    return 0
  fi
  if [[ $list == 1 ]]; then
    cost_list
    return 0
  fi

  if [[ -n $remove ]]; then
    [[ -f $DIR/map/costs.json ]] || die "no cost recorded yet — nothing to remove"
    jq -e --arg v "$remove" '[.costs[] | select(.vendor == $v)] | length > 0' "$DIR/map/costs.json" >/dev/null ||
      die "no cost recorded for '$remove' — orgami cost --list shows the vendors that have one"
    cost_write 'map(select(.vendor != $v))' --arg v "$remove"
    log "removed the figure for $remove"
    log "$DIR/map/costs.json"
    return 0
  fi

  [[ -n $vendor ]] ||
    die "orgami cost <vendor> <amount> [--per month|year] [--currency $COST_DEFAULT_CURRENCY] [--note \"…\"]
     orgami cost --list             the figures recorded
     orgami cost --remove <vendor>  drop one"
  [[ -n $amount ]] ||
    die "what does $vendor cost? orgami cost $vendor <amount> [--per month|year]"
  [[ $amount =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] ||
    die "an amount is a number like 120 or 49.99, not '$amount' — the currency goes in --currency"
  [[ -n $per ]] || per=$COST_DEFAULT_PERIOD
  [[ $per == month || $per == year ]] || die "--per takes month or year, not '$per'"
  [[ -n $currency ]] || currency=$(cfg currency "$COST_DEFAULT_CURRENCY")
  [[ $currency =~ ^[A-Za-z]{3}$ ]] || die "--currency takes a three-letter code like EUR or USD, not '$currency'"
  currency=$(printf '%s' "$currency" | tr '[:lower:]' '[:upper:]')

  local id who
  id=$(cost_resolve "$vendor")
  who=$(cost_author)

  cost_write '
    map(select(.vendor != $v))
    + [{vendor: $v, amount: ($amount + 0), period: $per, currency: $currency, who: $who, when: $now}
       + (if $note == "" then {} else {note: $note} end)]' \
    --arg v "$id" --argjson amount "$amount" --arg per "$per" --arg currency "$currency" \
    --arg who "$who" --arg note "$note"

  log "$DIR/map/costs.json"
  cost_list "$id"
}
