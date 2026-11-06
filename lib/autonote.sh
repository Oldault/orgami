# shellcheck shell=bash
# Notes nobody had to remember to write. A session ends, what was said is read
# back, and anything durable is drafted for review. Drafts never reach the team
# until a person keeps them.

AUTONOTE_DAILY_CAP=${ORGAMI_AUTONOTE_CAP:-5}

# The conversation, minus the noise: what was asked, and what was answered.
# Tool calls and their output are left out — they are already in git.
autonote_digest() {
  local transcript=$1
  declare -F secrets_redact >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
  jq -r '
    select(.type == "user" or .type == "assistant")
    | .message.content
    | if type == "string" then .
      else ([.[]? | select(.type == "text") | .text] | join("\n"))
      end' "$transcript" 2>/dev/null |
    grep -v '^$' |
    # Only the last 60000 characters are sent. Redacting a wider window keeps a
    # credential the first cut splits in half far outside what is kept, and
    # keeps a long session from costing a jq pass over all of it.
    tail -c 240000 |
    # Anything that looks like a credential never leaves this machine. The list
    # is lib/secrets.tsv, the one the note screen refuses notes with; if the
    # redaction cannot run, nothing is sent at all.
    secrets_redact 2>/dev/null |
    tail -c 60000
}

# Cheap test for whether a session was substantive enough to be worth a model
# call: real work happened, or something went wrong.
autonote_worth_reading() {
  local transcript=$1
  [[ -f $transcript ]] || return 1
  [[ $(wc -l <"$transcript") -ge 40 ]] || return 1
  grep -qiE '"name":"(Edit|Write|Bash|NotebookEdit)"' "$transcript" || return 1
  return 0
}

autonote_cap_reached() {
  local stamp
  stamp="$DIR/cache/autonote-$(date -u +%Y-%m-%d).count"
  local n=0
  [[ -f $stamp ]] && n=$(<"$stamp")
  [[ $n -lt $AUTONOTE_DAILY_CAP ]] || return 0
  echo $((n + 1)) >"$stamp"
  return 1
}

# autonote_id <dir> <stamp-author> <first line> — an id no draft in <dir> has.
# The slug is ASCII and can come out empty (a line with no Latin letters in
# it); two sweeps can draft in the same second, and folding accents can turn
# two different first lines into one slug. A file written under an id that
# exists would replace a note nobody has seen.
autonote_id() {
  local dir=$1 base=$2 slug id n=2
  slug=$(notes_slug "$3")
  id="$base${slug:+-$slug}"
  local try=$id
  while [[ -e $dir/$try.md || -e $DIR/notes/$try.md ]]; do
    try="$id-$n"
    n=$((n + 1))
  done
  echo "$try"
}

# orgami note-auto <transcript> [<cwd>] — runs detached from the hook.
cmd_note_auto() {
  local transcript=${1:-} where=${2:-$PWD}
  [[ -f $transcript ]] || die "usage: orgami note-auto <transcript> [<dir>]"
  autonote_is_sidechain "$transcript" && return 0

  source "$ROOT/lib/card.sh"
  context_pick_company "$(card_repo_here "$where" 2>/dev/null || true)" 2>/dev/null || true
  load_company 2>/dev/null || return 0

  # A session held in a checkout belonging to somebody else's organization must
  # not leave a note in this one. `orgami note` refuses that outright; here,
  # where nobody asked for a note in the first place, it is a silent no.
  # A positive match is required: a session with no remote (a scratch dir, a
  # personal project) used to pass and was drafted into the default company.
  # It now has to be a checkout of this organization, or sit under a workspace
  # root the company configured.
  local here_url here_org ok=0 w
  here_url=$(git -C "$where" remote get-url origin 2>/dev/null || true)
  if [[ -n $here_url ]]; then
    here_org=$(sed -E 's|.*[:/]([^/]+)/[^/]+$|\1|' <<<"$here_url")
    [[ $(printf '%s' "$here_org" | tr '[:upper:]' '[:lower:]') == \
      $(printf '%s' "$ORG" | tr '[:upper:]' '[:lower:]') ]] && ok=1
  else
    while IFS= read -r w; do
      w=${w/#\~/$HOME}
      [[ -n $w && ( $where == "$w" || $where == "$w"/* ) ]] && ok=1
    done < <(jq -r '(.workspaces // [])[]' "$DIR/config.json" 2>/dev/null)
  fi
  [[ $ok == 1 ]] || return 0

  autonote_worth_reading "$transcript" || return 0
  # 3, not 0: the sweep has to tell "there was nothing in it" from "not today",
  # so that a session held back by the cap is read tomorrow instead of lost.
  autonote_cap_reached && return 3

  need claude
  local model
  model=$(cfg note_model claude-sonnet-5)

  local digest out
  digest=$(autonote_digest "$transcript")
  [[ ${#digest} -gt 400 ]] || return 0

  out=$( {
    cat "$ROOT/prompts/autonote.md"
    printf '\n\nTHE SESSION\n"""\n%s\n"""\n' "$digest"
  } | model_call "$model" 2>/dev/null || true)

  [[ $out == NONE* ]] && return 0
  model_output_ok "$out" '^NOTE:' || return 0

  local repo tag topic body
  repo=$(sed -n 's/^REPO:[[:space:]]*//p' <<<"$out" | head -1 | tr -d ' ')
  tag=$(sed -n 's/^TAG:[[:space:]]*//p' <<<"$out" | head -1 | tr -d ' ')
  topic=$(sed -n 's/^TOPIC:[[:space:]]*//p' <<<"$out" | head -1 | tr -d ' ')
  # A pattern note keeps its blank lines: it is a sequence, and the steps in it
  # have to stay apart. A fact is a paragraph either way.
  body=$(sed -n '/^NOTE:/,$p' <<<"$out" | tail -n +2 | sed '/^```$/d')
  [[ $tag == "$PLAYBOOK_TAG" ]] || body=$(sed '/^$/d' <<<"$body")
  body=$(sed -e '/./,$!d' <<<"$body" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')

  [[ -n ${body// /} ]] || return 0

  # The same screen that guards anything published by hand. A drafted note that
  # cannot pass it is thrown away rather than left for someone to find.
  notes_screen "$body" "$COMPANY" >/dev/null 2>&1 || return 0
  [[ $repo == "-" ]] && repo=""
  # A repository the map has never heard of is a hallucinated one.
  if [[ -n $repo ]] && ! jq -e --arg r "$repo" 'any(.[]; .name == $r)' \
    "$DIR/map/repos.json" >/dev/null 2>&1; then
    repo=""
  fi
  case $tag in
    gotcha | incident | setup | deploy | rollback | alert | "$PLAYBOOK_TAG") ;;
    *) tag=gotcha ;;
  esac

  # A pattern with no topic cannot join anything, and a topic on anything else
  # means nothing. Slugged here, because the model writes prose when asked for
  # a name.
  if [[ $tag == "$PLAYBOOK_TAG" ]]; then
    [[ -n $topic ]] || topic=$(head -1 <<<"$body")
    topic=$(notes_slug "$topic")
    [[ -n $topic ]] || tag=gotcha
  else
    topic=""
  fi

  source "$ROOT/lib/notes.sh"

  # notes_autopublish sends what was drafted straight to the team. Off by
  # default: a note carries the user's name, so publishing one unattended is
  # their call to make, not the tool's.
  local publish=0 dest="$DIR/notes/draft"
  if [[ $(cfg notes_autopublish false) == true ]]; then
    publish=1
    dest="$DIR/notes"
  fi
  mkdir -p "$dest"

  local author stamp id file
  author=$(notes_author)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  id=$(autonote_id "$dest" "$(date -u +%Y%m%d-%H%M%S)-$author" "$(head -1 <<<"$body")")
  file="$dest/$id.md"

  {
    echo "---"
    echo "id: $id"
    echo "author: $author"
    echo "date: $stamp"
    [[ -n $repo ]] && echo "repo: $repo"
    [[ -n $topic ]] && echo "topic: $topic"
    echo "tags: [$tag]"
    echo "auto: true"
    echo "---"
    echo
    echo "$body"
  } >"$file"

  echo "$file"

  # The instance that completes a procedure writes the procedure. Only from a
  # kept note — a draft nobody has looked at yet is not evidence of anything.
  if [[ -n $repo && -n $topic && $publish == 1 ]]; then
    source "$ROOT/lib/playbook.sh"
    playbook_maybe "$repo" "$topic" || true
  fi

  # Straight out to the docs repo — as a pull request when the company asks for
  # review, as a push when it does not.
  [[ $publish == 1 ]] || return 0
  cmd_sync --quiet >/dev/null 2>&1 || true
}

# Sessions do not reliably end. A terminal window closed, a laptop shut, a
# window manager restarted, a crash — `SessionEnd` never fires, and everything
# that session learned goes with it. In practice that is most sessions, which is
# why a machine can run for a week and record nothing.
#
# So the next session sweeps. Any transcript that has gone quiet and was never
# read is read now, newest first. The marker file is the same one the end-of-
# session hook writes, so a session is never read twice.
AUTONOTE_SWEEP_WINDOW=${ORGAMI_AUTONOTE_WINDOW:-2880} # minutes back to look
AUTONOTE_SWEEP_QUIET=${ORGAMI_AUTONOTE_QUIET:-20}     # minutes of silence before a session counts as over
AUTONOTE_SWEEP_MAX=${ORGAMI_AUTONOTE_SWEEP_MAX:-3}    # transcripts read per sweep

autonote_state_dir() {
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/orgami"
  mkdir -p "$d" 2>/dev/null || return 1
  echo "$d"
}

# A subagent's transcript is a fragment of the session that spawned it, written
# under <session>/subagents/ and marked isSidechain. Read as sessions of their
# own, one workflow fan-out spent the day's cap on pieces of one conversation
# and left a draft per piece.
autonote_transcripts() {
  local root files
  root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [[ -d $root ]] || return 0
  files=$(find "$root" -name '*.jsonl' ! -path '*/subagents/*' \
    -mmin +"$AUTONOTE_SWEEP_QUIET" -mmin -"$AUTONOTE_SWEEP_WINDOW" 2>/dev/null)
  [[ -n $files ]] || return 0
  printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null
}

# Whether a transcript is a subagent's rather than a session's. The path is the
# cheap test; the first record that carries isSidechain settles the rest, and
# jq stops reading there. No `?` inside first(): jq 1.6 lets a try swallow the
# break that ends it.
autonote_is_sidechain() {
  [[ $1 == */subagents/* ]] && return 0
  [[ $(jq -n 'first(inputs | select(type == "object" and has("isSidechain")) | .isSidechain) // false' \
    "$1" 2>/dev/null) == true ]]
}

# orgami note-sweep [--background] — read back whatever nobody closed.
cmd_note_sweep() {
  [[ ${ORGAMI_AUTONOTE:-1} == 0 ]] && return 0

  # Detached, so a session never waits on a model reading the last one.
  if [[ ${1:-} == --background || ${1:-} == --detach ]]; then
    detach /dev/null "$ORGAMI_BIN" note-sweep
    return 0
  fi

  local state
  state=$(autonote_state_dir) || return 0

  local f id cwd did=0
  while read -r f; do
    [[ -f $f ]] || continue
    [[ $did -lt $AUTONOTE_SWEEP_MAX ]] || break
    id=$(basename "$f" .jsonl)
    # The session doing the sweeping is still going. Its own end reads it.
    [[ -n ${CLAUDE_SESSION_ID:-} && $id == "${CLAUDE_SESSION_ID:-}" ]] && continue
    [[ -e $state/autonote-$id ]] && continue

    { ! autonote_is_sidechain "$f" && autonote_worth_reading "$f"; } || {
      : >"$state/autonote-$id"
      continue
    }

    cwd=$(jq -r 'select(.cwd != null) | .cwd' "$f" 2>/dev/null | head -1)
    [[ -n $cwd && -d $cwd ]] || {
      : >"$state/autonote-$id"
      continue
    }

    : >"$state/autonote-$id"
    did=$((did + 1))
    # Contained: `load_company` exits rather than returns when there is no
    # company to load, and one unmappable checkout must not end the sweep.
    local rc=0
    (cmd_note_auto "$f" "$cwd" >/dev/null 2>&1) || rc=$?
    # Held back by the day's cap rather than read. Take the mark off and stop:
    # nothing else will be read today either.
    if [[ $rc == 3 ]]; then
      rm -f "$state/autonote-$id"
      break
    fi
  done < <(autonote_transcripts)

  # A marker is only useful for as long as the transcript it names could still
  # turn up in a sweep.
  find "$state" -name 'autonote-*' -mtime +30 -delete 2>/dev/null || true
  return 0
}

autonote_pending() {
  [[ -d $DIR/notes/draft ]] || return 1
  compgen -G "$DIR/notes/draft/*.md" >/dev/null 2>&1
}

decisions_pending() {
  [[ -d $DIR/map/decisions/draft ]] || return 1
  compgen -G "$DIR/map/decisions/draft/*.md" >/dev/null 2>&1
}

# The bullets of one decisions fragment, one record each, a wrapped bullet's
# continuation lines kept with it. Records end in \x1e so a caller can
# `read -d $'\x1e'` them back whole.
decision_bullets() {
  awk '
    /^- / { if (b != "") printf "%s\x1e", b; b = $0; next }
    /^ /  { if (b != "") b = b "\n" $0; next }
    END   { if (b != "") printf "%s\x1e", b }
  ' "$1"
}

# One bullet, kept: appended to the week's fragment in map/decisions/, which
# `orgami doc` assembles into DECISIONS.md. The heading is written once.
decision_keep() {
  local week=$1 bullet=$2
  local out="$DIR/map/decisions/$week.md"
  if [[ ! -f $out ]]; then
    printf '## %s\n\n' "$week" >"$out"
  fi
  printf '%s\n' "$bullet" >>"$out"
}

# A decision bullet has no id of its own. Its week and a checksum of its text
# give it one that holds while the bullets around it are kept or dropped, which
# a position in the list would not.
decision_id() {
  printf '%s.%s\n' "$1" "$(printf '%s' "$2" | cksum | awk '{print $1}')"
}

# A decisions draft rewritten with what is left of it, or removed when nothing
# is. Written beside the draft and moved over it, so an interrupted review never
# leaves half a week behind.
decision_draft_rewrite() {
  local f=$1 week=$2 rest=$3 tmp
  if [[ -s $rest ]]; then
    tmp=$(mktemp "$f.XXXXXX")
    { printf '## %s\n\n' "$week"; cat "$rest"; } >"$tmp"
    mv "$tmp" "$f"
  else
    rm -f "$f"
  fi
}

# One note draft, kept: screened again, because the screen may have learned a
# shape since it was drafted, then moved in with the published notes.
drafts_keep_note() {
  local f=$1 kept kr kt
  notes_screen_file "$f" "$COMPANY" || return 1
  kept="$DIR/notes/$(basename "$f")"
  mv "$f" "$kept" || return 1
  # Kept, so it counts as evidence now — and it may be the one that completes
  # a procedure.
  kr=$(sed -n 's/^repo: //p' "$kept" | head -1)
  kt=$(sed -n 's/^topic: //p' "$kept" | head -1)
  if [[ -n $kr && -n $kt ]]; then
    source "$ROOT/lib/playbook.sh"
    playbook_spawn "$kr" "$kt" || true
  fi
  return 0
}

# orgami drafts, the decisions half: every held fragment, bullet by bullet.
# What is skipped stays in the draft; a draft with nothing left is removed.
drafts_decisions() {
  local f week bullet choice kept=0 dropped=0 stop=0
  for f in "$DIR/map/decisions/draft"/*.md; do
    [[ -f $f ]] || continue
    [[ $stop == 1 ]] && break
    week=$(basename "$f" .md)
    local rest
    rest=$(mktemp)
    while IFS= read -r -d $'\x1e' bullet; do
      if [[ $stop == 1 ]]; then
        printf '%s\n' "$bullet" >>"$rest"
        continue
      fi
      echo
      if command -v gum >/dev/null; then
        gum style --foreground 4 --bold "decision · $week"
      else
        echo "--- decision · $week ---"
      fi
      printf '%s\n' "$bullet"
      echo
      if command -v gum >/dev/null; then
        choice=$(gum choose --header "" "keep it" "throw it away" "leave it for later" "stop here") || choice="stop here"
      else
        read -rp "keep / drop / skip / stop? " choice
      fi
      case $choice in
        keep*) decision_keep "$week" "$bullet" && kept=$((kept + 1)) ;;
        throw* | drop*) dropped=$((dropped + 1)) ;;
        stop*) stop=1; printf '%s\n' "$bullet" >>"$rest" ;;
        *) printf '%s\n' "$bullet" >>"$rest" ;;
      esac
    done < <(decision_bullets "$f")
    decision_draft_rewrite "$f" "$week" "$rest"
    rm -f "$rest"
  done
  echo
  echo "$kept decision(s) kept, $dropped discarded"
  [[ $kept -gt 0 ]] &&
    echo "they land in DECISIONS.md at the next 'orgami doc'"
  return 0
}

# Every draft waiting, notes then decisions, as one JSON array. What --list
# prints, and what an agent reads to put the choice to the user.
drafts_json() {
  local f week bullet
  {
    for f in "$DIR/notes/draft"/*.md; do
      [[ -f $f ]] || continue
      jq -n --arg id "$(basename "$f" .md)" --arg file "$f" \
        --arg repo "$(sed -n 's/^repo: //p' "$f" | head -1)" \
        --arg tags "$(sed -n 's/^tags: //p' "$f" | head -1)" \
        --arg topic "$(sed -n 's/^topic: //p' "$f" | head -1)" \
        --arg date "$(sed -n 's/^date: //p' "$f" | head -1)" \
        --arg text "$(notes_body "$f" | sed '/./,$!d')" \
        '{id: $id, kind: "note", repo: $repo, topic: $topic, date: $date,
          tags: ($tags | ltrimstr("[") | rtrimstr("]") | split(",")
                 | map(sub("^ +"; "") | sub(" +$"; "")) | map(select(length > 0))),
          text: $text, file: $file}'
    done
    for f in "$DIR/map/decisions/draft"/*.md; do
      [[ -f $f ]] || continue
      week=$(basename "$f" .md)
      while IFS= read -r -d $'\x1e' bullet; do
        jq -n --arg id "$(decision_id "$week" "$bullet")" --arg week "$week" \
          --arg text "$bullet" --arg file "$f" \
          '{id: $id, kind: "decision", week: $week, text: $text, file: $file}'
      done < <(decision_bullets "$f")
    done
  } | jq -s .
}

# drafts_act keep|drop <id> — one draft, by the id --list printed. A path or a
# file name is taken down to its id, so nothing outside the draft folders can
# be named.
drafts_act() {
  local act=$1 id=${2##*/} f week bullet rest found=0
  id=${id%.md}
  if [[ -z $id || $id == .* ]]; then
    log "not a draft id: '$2'"
    return 1
  fi

  f="$DIR/notes/draft/$id.md"
  if [[ -f $f ]]; then
    if [[ $act == keep ]]; then
      drafts_keep_note "$f" || { log "kept nothing: $id does not pass screening"; return 1; }
      echo "kept $id — in the runbooks at the next 'orgami doc', with the team at the next 'orgami sync'"
    else
      rm -f "$f"
      echo "dropped $id"
    fi
    return 0
  fi

  week=${id%.*}
  f="$DIR/map/decisions/draft/$week.md"
  if [[ $id == *.* && -f $f ]]; then
    rest=$(mktemp)
    while IFS= read -r -d $'\x1e' bullet; do
      if [[ $found == 0 && $(decision_id "$week" "$bullet") == "$id" ]]; then
        found=1
        [[ $act == keep ]] && decision_keep "$week" "$bullet"
        continue
      fi
      printf '%s\n' "$bullet" >>"$rest"
    done < <(decision_bullets "$f")
    [[ $found == 1 ]] && decision_draft_rewrite "$f" "$week" "$rest"
    rm -f "$rest"
    if [[ $found == 1 ]]; then
      if [[ $act == keep ]]; then
        echo "kept $id — in DECISIONS.md at the next 'orgami doc'"
      else
        echo "dropped $id"
      fi
      return 0
    fi
  fi

  log "no draft '$id'"
  return 1
}

drafts_usage() {
  cat <<'USAGE'
usage: orgami drafts [--list [--json] | --keep <id>... | --drop <id>... | --count]

Notes drafted from earlier sessions and decisions mined from pull requests wait
here until a person keeps or drops them. With no flag, each one is shown in turn
and asked about, which needs a terminal. The flags do the same without one.

  --list         every draft waiting, with the id to act on
  --json         the same list as JSON
  --keep <id>    keep one: a note joins the team's notes, a decision its week
  --drop <id>    throw one away
  --count        how many are waiting

--keep and --drop repeat, and mix: orgami drafts --keep <id> --drop <id>
USAGE
}

# orgami drafts — keep or discard what was drafted while you worked.
cmd_drafts() {
  local list=0 json=0 count=0 acts=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help) drafts_usage; return 0 ;;
      --count) count=1; shift ;;
      --list) list=1; shift ;;
      --json) list=1; json=1; shift ;;
      --keep | --drop) need_arg "$1" $#; acts+=("${1#--}" "$2"); shift 2 ;;
      *) die "unknown argument: $1 — see: orgami drafts --help" ;;
    esac
  done

  # Inside a checkout, the drafts of the company that owns it: the session hook
  # counts them beside that company's brief, and must not count another's.
  source "$ROOT/lib/card.sh"
  context_pick_company 2>/dev/null || true
  load_company

  if [[ $count == 1 ]]; then
    local n=0 f
    autonote_pending && n=$(find "$DIR/notes/draft" -name '*.md' | wc -l)
    if decisions_pending; then
      for f in "$DIR/map/decisions/draft"/*.md; do
        [[ -f $f ]] && n=$((n + $(grep -c '^- ' "$f")))
      done
    fi
    echo "$((n))"
    return 0
  fi

  if [[ ${#acts[@]} -gt 0 ]]; then
    local i bad=0
    for ((i = 0; i < ${#acts[@]}; i += 2)); do
      drafts_act "${acts[i]}" "${acts[i + 1]}" || bad=$((bad + 1))
    done
    [[ $bad == 0 ]] || die "$bad of $((${#acts[@]} / 2)) not done — see what is waiting with: orgami drafts --list"
    return 0
  fi

  if [[ $list == 1 ]]; then
    local all
    all=$(drafts_json)
    if [[ $json == 1 ]]; then
      printf '%s\n' "$all"
    elif [[ $(jq length <<<"$all") == 0 ]]; then
      echo "nothing waiting"
    else
      jq -r '
        def place: (if .kind == "note" then [.repo, (.tags | join(","))] else [.week] end)
                   | map(select(. != "")) | join(" · ");
        .[] | "\(.id)\n  \(.kind)\(place | if . == "" then "" else " · " + . end)\n  \(
          .text | split("\n") | map(select(test("[^ ]"))) | (.[0] // "") | .[0:110])\n"' <<<"$all"
      echo "keep or drop one with: orgami drafts --keep <id> | --drop <id>"
    fi
    return 0
  fi

  local hint="list them with: orgami drafts --list, then --keep <id> or --drop <id>"
  if ! autonote_pending; then
    if decisions_pending; then
      need_tty "$hint"
      drafts_decisions
    else
      echo "nothing waiting"
    fi
    return 0
  fi

  need_tty "$hint"
  local f n=0 kept=0 dropped=0
  for f in "$DIR/notes/draft"/*.md; do
    [[ -f $f ]] || continue
    n=$((n + 1))
    echo
    if command -v gum >/dev/null; then
      gum style --foreground 4 --bold "$(sed -n 's/^repo: //p' "$f" | head -1) · $(sed -n 's/^tags: //p' "$f" | head -1)"
    else
      echo "--- $(basename "$f") ---"
    fi
    sed -n '/^---$/,/^---$/!p' "$f" | sed '/^$/d'
    echo

    local choice
    if command -v gum >/dev/null; then
      choice=$(gum choose --header "" "keep it" "throw it away" "leave it for later" "stop here") || choice="stop here"
    else
      read -rp "keep / drop / skip / stop? " choice
    fi

    case $choice in
      keep*) drafts_keep_note "$f" && kept=$((kept + 1)) ;;
      throw* | drop*) rm -f "$f" && dropped=$((dropped + 1)) ;;
      stop*) break ;;
      *) : ;;
    esac
  done

  echo
  echo "$kept kept, $dropped discarded"
  [[ $kept -gt 0 ]] &&
    echo "they land in the runbooks at the next 'orgami doc', and reach the team at the next 'orgami sync'"
  decisions_pending && drafts_decisions
  return 0
}

# orgami autonote [on|off|publish|drafts] — how much of this happens by itself.
cmd_autonote() {
  load_company
  local want=${1:-}
  local tmp

  case $want in
    "")
      local on="on" mode="drafts for review"
      [[ ${ORGAMI_AUTONOTE:-1} == 0 ]] && on="off (ORGAMI_AUTONOTE=0)"
      [[ $(cfg notes_autopublish false) == true ]] && mode="published straight to the team"
      echo "$COMPANY: $on, $mode"
      return 0
      ;;
    publish)
      tmp=$(mktemp)
      jq '.notes_autopublish = true' "$DIR/config.json" >"$tmp" && mv "$tmp" "$DIR/config.json"
      echo "notes written at the end of a session now go to the team without review,"
      echo "and so do the decisions 'orgami report' mines from the week's pull requests."
      [[ $(cfg notes_review false) == true ]] &&
        echo "They open as pull requests, because notes_review is on." ||
        echo "They are pushed directly. Turn on notes_review to have them open as pull requests instead."
      ;;
    drafts | review)
      tmp=$(mktemp)
      jq '.notes_autopublish = false' "$DIR/config.json" >"$tmp" && mv "$tmp" "$DIR/config.json"
      echo "notes and mined decisions now wait in 'orgami drafts' until you keep them."
      ;;
    on)
      echo "on by default — nothing to do. ORGAMI_AUTONOTE=0 in the environment turns it off."
      ;;
    off)
      echo "set ORGAMI_AUTONOTE=0 in your shell profile to stop reading sessions back."
      ;;
    *) die "usage: orgami autonote [publish|drafts|off]" ;;
  esac
}
