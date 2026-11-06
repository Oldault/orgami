# shellcheck shell=bash
# What counts as a credential is defined once, in lib/secrets.tsv, and read by
# both sides of the same promise: the note screen refuses a note that matches,
# and the session digest handed to a model has every match redacted first. Two
# separate lists used to drift apart, each letting through what the other
# caught.
#
# jq runs the patterns on both sides. It is already required, and its regex
# engine is the same everywhere; grep -E and sed -E are not — BSD sed has no
# case-insensitive substitution, and neither tool agrees with the other on \b
# or lookahead.

SECRETS_TSV=${SECRETS_TSV:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/secrets.tsv}

# The jq side, for programs that need it inline (the session digest redacts
# each message as it extracts it). Run with: --rawfile secrets_tsv "$SECRETS_TSV"
#   secrets         every row, as {name, flags, re}
#   secrets_redact  the input string with every match replaced by [redacted]
#   secrets_found   one "name<TAB>match" line per row that matches the input
secrets_jq_defs() {
  cat <<'JQ'
def secrets:
  $secrets_tsv | split("\n")[]
  | select(length > 0 and (startswith("#") | not))
  | split("\t") | select(length >= 3)
  | {name: .[0], flags: (if .[1] == "-" or .[1] == "" then null else .[1] end), re: .[2]};
def secrets_redact:
  reduce secrets as $p (.;
    if test($p.re; $p.flags) then gsub($p.re; "\(.keep // "")[redacted]"; $p.flags) else . end);
def secrets_found:
  . as $t
  | secrets | . as $p
  | ($t | [match($p.re; $p.flags)] | .[0]) as $m
  | select($m != null)
  | [$p.name, $m.string] | @tsv;
JQ
}

# secrets_find < text — one "name<TAB>match" line per kind of credential found.
# Nonzero when the screen itself could not run, which a caller must treat as a
# refusal: a note let through unscreened is what this exists to prevent.
secrets_find() {
  [[ -r $SECRETS_TSV ]] || return 2
  jq -Rsr --rawfile secrets_tsv "$SECRETS_TSV" "$(secrets_jq_defs) secrets_found"
}

# secrets_redact < text — the same text, every credential replaced. Prints
# nothing and fails when it cannot run, so nothing unredacted gets through.
secrets_redact() {
  [[ -r $SECRETS_TSV ]] || return 2
  jq -Rsj --rawfile secrets_tsv "$SECRETS_TSV" "$(secrets_jq_defs) secrets_redact"
}
