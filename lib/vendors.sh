# shellcheck shell=bash
# Which third parties a repository actually uses, from committed files only.
#
# The graph already knows what a repo deploys to and what it depends on. What it
# could not say is who the organization is *paying*: a dependency on `stripe` and
# a `SENTRY_DSN` in `.env.example` are the two most reliable statements a
# codebase makes about its suppliers, and neither of them shows up as a host or a
# tool. `lib/vendors.tsv` is the catalogue; this file is the matcher.
#
# Nothing here reaches the network, reads a credential or looks at a value. It
# collects *facts* — a package name, an environment variable's name, a hostname
# in a literal URL, a terraform provider, a workflow's `uses:` line — each with
# the file and line it came from, and matches those against the catalogue. A
# vendor edge is therefore always extracted, never inferred, and always points
# at something a person can open.
#
# The facts are gathered here rather than taken from `lib/profile.sh` for one
# reason: `profile_env` and `profile_calls` deliberately throw the line number
# away and cap their lists, because a repo card wants a short list of names, not
# citations. An edge without a line is not an edge in this tool, so the same
# files get read again with `grep -n`. Everything else is reused — the exclusion
# lists that keep `node_modules` and test fixtures out are `profile.sh`'s own,
# and so is the list of a monorepo's packages.

VENDOR_CATALOG=${VENDOR_CATALOG:-${ROOT:-.}/lib/vendors.tsv}

# Where a file sits says whether the repo uses what it names. A test stubs a
# supplier, a docs tree, an example app or a playground shows a reader one,
# and a reference copy or a third-party drop is somebody else's tree saved
# here — a recovered frontend still carries the script tag of the site it was
# saved from. None of them is this organization paying anyone, so no fact is
# taken from under these directory names at any depth. The test and docs lists
# are profile.sh's own (PROFILE_TEST_EXCL, PROFILE_ENV_EXCL); these are the
# names demo material and copies of somebody else's work conventionally live
# under.
VENDOR_COPY_DIRS=(reference references third_party third-party thirdparty
  examples example samples playground demo demos
  .yarn bower_components jspm_packages __snapshots__ cypress)

# Test files profile.sh's list does not name: the other extensions, and the
# Python and Ruby spellings.
VENDOR_TEST_FILES=('*.test.*' '*.spec.*' 'test_*.py' '*_test.py' '*_spec.rb' conftest.py)

# A file this large was generated or collected, not written: a lockfile, a build
# cache, a twenty-megabyte scrape of public job boards. The URLs in it are its
# data, not calls the code makes, and a hand-written source file never gets
# near half a megabyte.
VENDOR_MAX_KB=512

# The source files a variable is read from or a URL is called in.
VENDOR_CODE=(--include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx'
  --include='*.mjs' --include='*.cjs' --include='*.mts' --include='*.cts'
  --include='*.vue' --include='*.svelte' --include='*.astro')

# Every signal kind the catalogue is allowed to use, as one alternation. A `|`
# in the signals column only opens a new signal when one of these words and a
# colon follow it, which is what lets a regex carry alternation of its own.
#
# This list is the single place a kind is declared, and it is load-bearing in a
# way that is easy to miss: a kind that is *not* here raises no error. It is
# swallowed into the previous signal's regex, and every vendor behind it stops
# matching silently — the map simply gets smaller. `test/dns_match_test.sh`
# asserts a `mx:` signal survives parsing for exactly that reason.
#
# pkg, env, host, tf, action and file are facts about committed files, gathered
# here. mx, spf, txt, cname, ns and dmarc are facts about public DNS, gathered
# by lib/dns.sh. The two sets never meet: a fact carries its kind, and a signal
# only matches a fact of the same kind, so a `host:` signal can never be
# satisfied by a CNAME and vice versa.
VENDOR_SIGNAL_KINDS='pkg|env|host|tf|action|file|mx|spf|txt|cname|ns|dmarc'

# The grep options that keep every skipped place out, built once from
# profile.sh's lists and the two above.
VENDOR_SKIP=()
vendors_skip() {
  local d
  [[ ${#VENDOR_SKIP[@]} -eq 0 ]] || return 0
  VENDOR_SKIP=("${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" "${PROFILE_ENV_EXCL[@]}")
  for d in "${VENDOR_COPY_DIRS[@]}"; do VENDOR_SKIP+=(--exclude-dir="$d"); done
  for d in "${VENDOR_TEST_FILES[@]}"; do VENDOR_SKIP+=(--exclude="$d"); done
}

# vendors_grep <kind> <checkout> <subdir> <regex> <head> <tail> <drop> [grep options]
#
# Every line under <checkout>/<subdir> that <regex> matches, as
# `<kind>\t<value>\t<rel>:<line>` — one row per match on the line, <head> and
# <tail> trimmed off each, and a match that <drop> recognises left out.
#
# A whole-line comment is skipped: `# - uses: SonarSource/…` and
# `//$(…).cloudinary.com` are code somebody switched off, and citing one says
# the opposite of what the line means. Which markers open a comment depends on
# the file, because `#` starts a private field in TypeScript and `*` an alias in
# YAML. A comment at the end of a live line is not looked for: `https://` holds
# a `//` of its own.
#
# The checkout is handed to grep with a trailing slash. --exclude-dir applies to
# a directory named on the command line too, so a repository that is itself
# called `docs` or `examples` would otherwise be skipped whole. The regexes go
# through ENVIRON, which passes backslashes through untouched where awk -v
# would expand them.
vendors_grep() {
  local kind=$1 src=${2%/} sub=$3 re=$4 head=$5 tail=$6 drop=$7
  shift 7
  vendors_skip
  grep -rnIE "$re" "$src/${sub:+$sub/}" "$@" "${VENDOR_SKIP[@]}" 2>/dev/null |
    V_KIND=$kind V_SRC="$src/" V_RE=$re V_HEAD=$head V_TAIL=$tail V_DROP=$drop awk '
    function commented(path, text,   b, e) {
      b = path; sub(/.*\//, "", b)
      e = b; if (!sub(/.*\./, "", e)) e = ""
      sub(/^[ \t]+/, "", text)
      if (b ~ /(^|\.)env(\.|$)/ || e ~ /^(py|rb|ya?ml|toml|tf|hcl|sh|bash|php|properties)$/)
        if (substr(text, 1, 1) == "#") return 1
      if (e ~ /^([cm]?[jt]sx?|vue|svelte|astro|go|php|json|jsonc|tf|hcl)$/) {
        if (substr(text, 1, 2) == "//" || substr(text, 1, 2) == "/*") return 1
        if (substr(text, 1, 1) == "*" || substr(text, 1, 3) == "{/*") return 1
      }
      if (e ~ /^(vue|svelte|astro|html?)$/ && substr(text, 1, 4) == "<!--") return 1
      return 0
    }
    BEGIN {
      kind = ENVIRON["V_KIND"]; src = ENVIRON["V_SRC"]; re = ENVIRON["V_RE"]
      head = ENVIRON["V_HEAD"]; tail = ENVIRON["V_TAIL"]; drop = ENVIRON["V_DROP"]
    }
    {
      # The split is on the first `:<digits>:` rather than on colons, because
      # the line regularly holds a URL with a colon of its own.
      if (!match($0, /:[0-9]+:/)) next
      path = substr($0, 1, RSTART - 1)
      ln = substr($0, RSTART + 1, RLENGTH - 2)
      text = substr($0, RSTART + RLENGTH)
      if (index(path, src) == 1) path = substr(path, length(src) + 1)
      # A line nobody typed: minified JS, a one-line JSON dump. Its URLs are
      # data rather than calls, and the loop below copies the rest of the line
      # after every match, so one such line of a few megabytes never finishes.
      # vendors_facts drops files over VENDOR_MAX_KB, but only after this ran.
      if (length(text) > 4096) next
      if (commented(path, text)) next
      while (match(text, re) && RLENGTH > 0) {
        tok = substr(text, RSTART, RLENGTH)
        text = substr(text, RSTART + RLENGTH)
        if (drop != "" && tok ~ drop) continue
        if (head != "") sub(head, "", tok)
        if (tail != "") sub(tail, "", tok)
        if (tok != "") printf "%s\t%s\t%s:%s\n", kind, tok, path, ln
      }
    }' || true
}

# A manifest is read only when it is a regular file that stays inside the
# checkout. scan_defuse_links already removed the links that leave it before a
# scan gets here; this is the same rule for any other caller.
vendors_readable() {
  [[ -f $2 ]] || return 1
  [[ -L $2 ]] || return 0
  clone_file "$1" "$2"
}

# Dependencies out of a JSON manifest. jq decides which keys are dependencies —
# nothing else may parse JSON — and the second pass only decides which line to
# point at, which is a lookup, not a parse.
vendors_deps_json() {
  local src=$1 rel=$2 names
  local file="$src/$rel"
  vendors_readable "$src" "$file" || return 0
  names=$(jq -r '[(.dependencies // {}), (.devDependencies // {}),
                  (.peerDependencies // {}), (.optionalDependencies // {}),
                  (.require // {}), (."require-dev" // {})]
                 | add // {} | keys[]' "$file" 2>/dev/null) || return 0
  [[ -n $names ]] || return 0
  awk -v rel="$rel" '
    NR == FNR { want[$0] = 1; next }
    {
      line = $0
      while (match(line, "\"[^\"]+\"[[:space:]]*:")) {
        key = substr(line, RSTART + 1, RLENGTH - 1)
        sub("\"[[:space:]]*:$", "", key)
        if (key in want) printf "pkg\t%s\t%s:%d\n", key, rel, FNR
        line = substr(line, RSTART + RLENGTH)
      }
    }' <(printf '%s\n' "$names") "$file"
}

# Dependencies out of the manifests that are not JSON. One awk per file, because
# each format says "this is a dependency" differently and none of them says it
# in a way the next one would recognise. $2 is the directory below the checkout
# that holds them, empty for the root.
vendors_deps_text() {
  local src=$1 dir=${2:+$2/} f rel
  for f in requirements.txt requirements-dev.txt pyproject.toml Gemfile go.mod Cargo.toml; do
    rel=$dir$f
    vendors_readable "$src" "$src/$rel" || continue
    awk -v rel="$rel" '
      function emit(name) { if (name != "") printf "pkg\t%s\t%s:%d\n", name, rel, FNR }
      # A commented-out requirement is one somebody took away.
      /^[[:space:]]*(#|\/\/)/ { next }
      rel ~ /(^|\/)requirements[^\/]*$/ {
        if (match($0, "^[[:space:]]*[A-Za-z][A-Za-z0-9._-]*")) {
          t = substr($0, RSTART, RLENGTH); sub("^[[:space:]]*", "", t); emit(t)
        }
        next
      }
      rel ~ /(^|\/)Gemfile$/ {
        if (match($0, "^[[:space:]]*gem[[:space:]]+[\"'"'"'][A-Za-z][A-Za-z0-9._-]*")) {
          t = substr($0, RSTART, RLENGTH); sub(".*[\"'"'"']", "", t); emit(t)
        }
        next
      }
      # A go module path is the only thing in go.mod shaped like a domain
      # followed by a path, which keeps the version and the directives out.
      # An `// indirect` requirement is a dependency of a dependency: genai
      # pulls in cloud.google.com/go/auth, and that is not a Google Cloud
      # account. Only what the module asked for itself is evidence.
      rel ~ /(^|\/)go\.mod$/ {
        if ($0 ~ /\/\/[[:space:]]*indirect/) next
        if (match($0, "[a-z0-9][a-z0-9.-]*\\.[a-z][a-z]*/[A-Za-z0-9._/-]+"))
          emit(substr($0, RSTART, RLENGTH))
        next
      }
      # TOML: a dependency is either a table key — poetry and cargo write
      # `stripe = "^5"` — or a quoted requirement inside an array, which is how
      # PEP 621 writes `"stripe>=5"`. Metadata keys land here too; `name` and
      # `version` are in no catalogue, so they cost nothing.
      {
        if (match($0, "^[[:space:]]*[A-Za-z][A-Za-z0-9._-]*[[:space:]]*=")) {
          t = substr($0, RSTART, RLENGTH)
          sub("^[[:space:]]*", "", t); sub("[[:space:]]*=$", "", t); emit(t)
        }
        # Every quoted requirement on the line, not just the first: a short
        # dependency array is routinely written on one.
        line = $0
        while (match(line, "\"[A-Za-z][A-Za-z0-9._-]*[\"<>=~!;,[]")) {
          t = substr(line, RSTART + 1, RLENGTH - 2); emit(t)
          line = substr(line, RSTART + RLENGTH)
        }
      }' "$src/$rel"
  done
}

# The directories below the root that hold a manifest of their own: every
# package of a declared or found JS workspace (profile.sh decides which those
# are), and a Python, Go, Ruby, Rust or PHP project two levels down at most —
# `backend/requirements.txt` beside a `web/package.json`. A monorepo keeps its
# SDKs there and its root manifest says only "workspaces", so reading the root
# alone reported Stripe as an environment variable nobody installed.
#
# The walk prunes what the greps skip. -mindepth 1 keeps the prune off the
# checkout itself, so a repository named `docs` or `build` is still walked; a
# deeper -mindepth would switch it off for the levels it skips, so the root's
# own manifests are dropped after instead.
vendors_manifest_dirs() {
  local src=${1%/} d f
  local prune=("${PROFILE_PRUNE[@]}" "${PROFILE_WS_FALLBACK_PRUNE[@]}")
  for d in "${VENDOR_COPY_DIRS[@]}" docs; do prune+=(-o -name "$d"); done
  for f in "${PROFILE_TEST_EXCL[@]}"; do
    [[ $f == --exclude-dir=* ]] && prune+=(-o -name "${f#--exclude-dir=}")
  done
  {
    profile_workspace_dirs "$src"
    find "$src" -mindepth 1 -maxdepth 3 -type d \( "${prune[@]}" \) -prune -o -type f \
      \( -name composer.json -o -name go.mod -o -name pyproject.toml -o -name Gemfile \
      -o -name Cargo.toml -o -name requirements.txt -o -name requirements-dev.txt \) \
      -print 2>/dev/null |
      while IFS= read -r f; do
        d=${f#"$src"/}; d=${d%/*}
        [[ $d != "${f#"$src"/}" && $d =~ ^[A-Za-z0-9._@+/-]+$ ]] && printf '%s\n' "$d"
      done
  } | LC_ALL=C sort -u | head -40
}

# Files whose name alone says which vendor reads them: an eas.json is an Expo
# build profile and nothing else, a fly.toml a Fly.io app. Only the names at the
# root and in each manifest directory, because that is where a tool looks for
# its own config; the catalogue's `file:` signals decide which names count. The
# evidence is the file's first line, so an empty file is passed over.
vendors_files() {
  local src=${1%/} d f
  for d in "" "${@:2}"; do
    for f in "$src/${d:+$d/}"* "$src/${d:+$d/}".[!.]*; do
      [[ -f $f && -s $f && ! -L $f ]] || continue
      printf 'file\t%s\t%s:1\n' "${f##*/}" "${d:+$d/}${f##*/}"
    done
  done
}

# Environment variable *names*. Never a value: this runs over other people's
# repositories, and a `.env` that should not have been committed is exactly the
# file this would otherwise read out loud.
#
# The example env files are profile.sh's: every one a monorepo package keeps,
# not only the root's. The reads in code are looked for in source files only —
# a `process.env.STRIPE_KEY` in a study note or an audit write-up about another
# codebase is prose, and one in a test is a stub.
vendors_env_names() {
  local src=${1%/} f rel
  local name='[A-Z][A-Z0-9_][A-Z0-9_][A-Z0-9_]*'
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    rel=${f#"$src"/}
    awk -v rel="$rel" '
      match($0, "^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*=") {
        t = substr($0, RSTART, RLENGTH)
        sub("^[[:space:]]*", "", t); sub("^export[[:space:]]+", "", t); sub("=$", "", t)
        printf "env\t%s\t%s:%d\n", t, rel, FNR
      }' "$f"
  done < <(profile_env_files "$src")
  vendors_grep env "$src" "" "(process|import\\.meta)\\.env\\.$name" '^.*\.env\.' '' '' \
    "${VENDOR_CODE[@]}"
  vendors_grep env "$src" "" "os\\.(environ(\\.get)?[[(]|getenv\\()['\"]$name" "^.*['\"]" '' '' \
    --include='*.py'
  vendors_grep env "$src" "" "ENV(\\.fetch\\()?[[(]?['\"]$name" "^.*['\"]" '' '' --include='*.rb'
  vendors_grep env "$src" "" "os\\.(Getenv|LookupEnv)\\(\"$name" '^.*"' '' '' --include='*.go'
}

# A URL that names a file, a schema or a documentation page is a reference, not
# a supplier: `"$schema": "https://anthropic.com/…​.json"` says nothing about who
# is being paid. This is the one thing NOISE_DOMAINS was doing for the host nodes
# that vendor matching still needs, and it is done on the path rather than the
# domain, so no vendor has to be blacklisted to get it.
VENDOR_URL_NOISE='\.(json|md|ya?ml|svg|png|jpe?g|gif|txt|xml|pdf|html?)([?#][^:]*)?$|/docs?/|/blog/|/schema'

# Hosts, from literal URLs. Test paths are excluded for the same reason
# `profile_calls` excludes them: a URL in a fixture is a stub, not a supplier.
# NOISE_DOMAINS itself is *not* applied — see the header of lib/vendors.tsv.
vendors_hosts() {
  local src=$1
  vendors_grep host "$src" "" "https?://[a-zA-Z0-9._-]+[^[:space:]\"'\`<>]*" \
    '^https?://' '[:/?#].*$' "$VENDOR_URL_NOISE" \
    "${VENDOR_CODE[@]}" \
    --include='*.py' --include='*.rb' --include='*.go' --include='*.php' \
    --include='*.env*' --include='*.yml' --include='*.yaml' --include='*.json' \
    --include='*.tf' --include='*.toml'
  # Connection strings carry the vendor in the host too, and are the only place
  # a managed database ever names itself.
  vendors_grep host "$src" "" '(mongodb(\+srv)?|rediss?|postgres(ql)?|amqps?)://[^[:space:]"'"'"']+' \
    '^[a-z+]*://([^@/]*@)?' '[:/?].*$' '' \
    --include='*.env*' --include='*.yml' --include='*.yaml' --include='*.json' \
    "${VENDOR_CODE[@]}" --include='*.py' --include='*.rb' --include='*.go'
}

# Terraform providers, both spellings: the `provider "x"` block and the
# `source = "hashicorp/x"` line inside required_providers.
vendors_terraform() {
  local src=$1
  vendors_grep tf "$src" "" '^[[:space:]]*provider[[:space:]]+"[a-z0-9_-]+"' \
    '^[^"]*"' '".*$' '' --include='*.tf'
  vendors_grep tf "$src" "" 'source[[:space:]]*=[[:space:]]*"[A-Za-z0-9-]+/[a-z0-9_-]+"' \
    '^[^"]*"[A-Za-z0-9-]*/' '".*$' '' --include='*.tf'
}

vendors_actions() {
  local src=$1
  [[ -d $src/.github/workflows ]] || return 0
  vendors_grep action "$src" .github/workflows 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
    '^uses:[[:space:]]*' '' ''
}

# Every fact one checkout offers, deduplicated on kind and value, each with a
# fourth column: how good a citation it is. A name can be found in several
# places and only one of them is cited, so the choice is made on purpose rather
# than left to byte order, which cited `go.mod:28 … // indirect` over the direct
# requirement on line 7. A manifest is the better citation, then the code that
# reads or calls it, then configuration; and within each, the shallower file —
# the root's package.json before a package's. The weight is
# class * 10 + depth, and vendors_match breaks a tie between two facts of the
# same kind on it. Sorted throughout so that the evidence kept is the same on
# every machine — `grep -r` walks the filesystem in whatever order it is handed.
#
# Facts are dropped here, after gathering, from the same places the greps skip:
# the manifest and env-file walks are not greps, and a workspace declared under
# `examples/*` is still an example. And from any file over VENDOR_MAX_KB.
vendors_facts() {
  local src=${1%/} big d f
  local dirs=() skipd=() skipf=()
  # The two walks profile_repo makes again later, filled here in this shell so
  # the subshells below and the profile that follows reuse them.
  profile_workspace_dirs "$src" >/dev/null
  profile_env_files "$src" >/dev/null
  while IFS= read -r d; do [[ -n $d ]] && dirs+=("$d"); done < <(vendors_manifest_dirs "$src")

  vendors_skip
  for f in "${VENDOR_SKIP[@]}"; do
    case $f in
      --exclude-dir=*) skipd+=("${f#--exclude-dir=}") ;;
      --exclude=*) skipf+=("${f#--exclude=}") ;;
    esac
  done
  big=$(mktemp) || return 0
  find "$src" -mindepth 1 -type d \( "${PROFILE_PRUNE[@]}" \) -prune -o \
    -type f -size +"$VENDOR_MAX_KB"k -print 2>/dev/null >"$big"

  {
    vendors_deps_json "$src" package.json
    vendors_deps_json "$src" composer.json
    vendors_deps_text "$src" ""
    for d in "${dirs[@]}"; do
      vendors_deps_json "$src" "$d/package.json"
      vendors_deps_json "$src" "$d/composer.json"
      vendors_deps_text "$src" "$d"
    done
    vendors_files "$src" "${dirs[@]}"
    vendors_env_names "$src"
    vendors_hosts "$src"
    vendors_terraform "$src"
    vendors_actions "$src"
  } 2>/dev/null |
    V_SRC="$src/" V_BIG=$big V_DIRS="${skipd[*]}" V_FILES="${skipf[*]}" awk -F'\t' -v OFS='\t' '
      # A glob from an --exclude option as an anchored regex. Only * and . occur
      # in them; everything else is literal.
      function glob_re(g) { gsub(/\./, "\\.", g); gsub(/\*/, ".*", g); return "^" g "$" }
      BEGIN {
        n = split(ENVIRON["V_DIRS"], a, " "); for (i = 1; i <= n; i++) dir[a[i]] = 1
        nf = split(ENVIRON["V_FILES"], a, " "); for (i = 1; i <= nf; i++) fre[i] = glob_re(a[i])
        manifest = "^(package\\.json|composer\\.json|go\\.mod|requirements[^/]*\\.txt|pyproject\\.toml|Gemfile|Cargo\\.toml)$"
        code = "\\.([cm]?[jt]sx?|vue|svelte|astro|py|rb|go|php)$"
        while ((getline p < ENVIRON["V_BIG"]) > 0) {
          if (index(p, ENVIRON["V_SRC"]) == 1) p = substr(p, length(ENVIRON["V_SRC"]) + 1)
          large[p] = 1
        }
      }
      {
        path = $3; sub(/:[0-9]+$/, "", path)
        if (path in large) next
        m = split(path, seg, "/")
        for (i = 1; i < m; i++) if (seg[i] in dir) next
        for (i = 1; i <= nf; i++) if (seg[m] ~ fre[i]) next
        cls = (seg[m] ~ manifest) ? 0 : (seg[m] ~ code) ? 1 : 2
        print $1, $2, $3, cls * 10 + (m > 9 ? 9 : m - 1)
      }' |
    LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 -k4,4n -k3,3 -u |
    awk -F'\t' '!seen[$1 FS $2]++'
  rm -f "$big"
}

# The catalogue against one set of facts, one line per matched vendor:
# <id>\t<name>\t<category>\t<portal>\t<signal-kind>\t<evidence>[\t<flags>].
#
# `flags` goes last, and is left off the line entirely when the vendor has none.
# Both halves of that matter, and neither is cosmetic. Every caller reads these
# lines with `IFS=$'\t' read -r`, and a tab is IFS *whitespace*: a run of them
# collapses into one delimiter, so an empty field in the middle of the line does
# not arrive empty — it disappears, and every field after it shifts one to the
# left. A flags column between the portal and the signal kind would therefore
# have handed the signal kind to `portal` on the ninety-five rows that carry no
# flag. A missing field at the *end* is the one case `read` handles the way
# anyone would expect: the variable is simply empty.
#
# Two modes, because the two callers want different things.
#
# `strongest` — the default, and what a repository scan wants. A vendor found by
# four signals is still one vendor, so only the strongest survives: a manifest
# entry is a commitment, a terraform provider, a workflow action and a vendor's
# own config file are configuration, a vendor's API host in source code is the
# call itself, an environment variable is a promise the deployment makes, and a
# hostname in configuration is a mention. In that order. Between two facts of
# the same kind, the better citation wins (vendors_facts).
#
# `all` — what a DNS reading wants. A domain whose MX points at Google and whose
# apex carries a google-site-verification token is saying two different things,
# and a reader checking the finding wants both records rather than whichever one
# this file happened to rank first. One row per vendor, kind and record.
vendors_match() {
  local facts=$1 mode=${2:-strongest}
  [[ -f $VENDOR_CATALOG ]] || die "no vendor catalogue at $VENDOR_CATALOG"
  awk -F'\t' -v cat="$VENDOR_CATALOG" -v mode="$mode" \
    -v kinds="^($VENDOR_SIGNAL_KINDS):" '
    function addsig(sig, id, name, category, portal, flags,   p) {
      p = index(sig, ":")
      if (p == 0) return
      ns++
      skind[ns] = substr(sig, 1, p - 1); sre[ns] = substr(sig, p + 1)
      sid[ns] = id; sname[ns] = name; scat[ns] = category; sportal[ns] = portal
      sflags[ns] = flags
    }
    BEGIN {
      rank["pkg"] = 1; rank["tf"] = 2; rank["action"] = 3; rank["file"] = 3
      rank["env"] = 4; rank["host"] = 5
      # The DNS order, on the same scale and never compared against the one
      # above: a verification token is a vendor saying this organization proved
      # it owns the domain, mail routing is where the mailboxes are, and a
      # nameserver is the weakest — it says who serves the zone, not who is
      # billed for what runs on it.
      rank["txt"] = 1; rank["mx"] = 2; rank["dmarc"] = 3
      rank["spf"] = 4; rank["cname"] = 5; rank["ns"] = 6
      while ((getline row < cat) > 0) {
        if (row ~ /^#/ || row ~ /^[[:space:]]*$/) continue
        # split() clears f, so a five-column row leaves f[6] empty rather than
        # inheriting the flags of the last row that carried some. That is the
        # whole reason `flags` is optional at the end of the row and not
        # anywhere else: every earlier column is positional, and a row that
        # stopped short of one would shift portal into signals.
        nf = split(row, f, "\t")
        if (nf < 4) continue
        # A `|` only opens a new signal when a kind and a colon follow it, so a
        # regex may use alternation without being cut in half.
        n = split(f[4], part, "|")
        cur = ""
        for (i = 1; i <= n; i++) {
          if (part[i] ~ kinds) {
            if (cur != "") addsig(cur, f[1], f[2], f[3], f[5], f[6])
            cur = part[i]
          } else if (cur != "") {
            cur = cur "|" part[i]
          }
        }
        if (cur != "") addsig(cur, f[1], f[2], f[3], f[5], f[6])
      }
      close(cat)
    }
    {
      # The optional fourth column is how good a citation the fact is (see
      # vendors_facts); DNS facts have none and all weigh the same.
      w = ($4 == "") ? 0 : $4 + 0
      for (i = 1; i <= ns; i++) {
        if (skind[i] != $1 || $2 !~ sre[i]) continue
        key = (mode == "all") ? sid[i] SUBSEP skind[i] SUBSEP $3 : sid[i]
        r = rank[skind[i]]
        # A vendor host in source code is a call the code makes: comments,
        # docs, tests, copies and public hosts never reach this far. That is
        # the integration itself, and it outranks a variable the deployment is
        # merely asked to set. A host in configuration — a CSP allow-list, a
        # monitor target — stays the mention it was.
        if ($1 == "host" && w >= 10 && w < 20) r = rank["env"] - 0.5
        if (!(key in best) || r < best[key] || (r == best[key] && w < wt[key])) {
          best[key] = r; wt[key] = w; ev[key] = $3; kd[key] = skind[i]; vid[key] = sid[i]
          nm[key] = sname[i]; ct[key] = scat[i]; pt[key] = sportal[i]
          fl[key] = sflags[i]
        }
      }
    }
    END {
      for (key in best) {
        printf "%s\t%s\t%s\t%s\t%s\t%s",
          vid[key], nm[key], ct[key], pt[key], kd[key], ev[key]
        if (fl[key] != "") printf "\t%s", fl[key]
        printf "\n"
      }
    }' "$facts" | sort
}

# One repo into $EMIT, alongside everything else scan_repo emits. Safe in
# parallel: the only file it writes outside its own temp is $EMIT, which is this
# repo's alone.
vendors_scan() {
  local repo=$1 src=$2 facts id name category portal kind ev flags
  [[ -d $src ]] || return 0
  facts=$(mktemp) || return 0
  vendors_facts "$src" >"$facts"
  while IFS=$'\t' read -r id name category portal kind ev flags; do
    [[ -n $id && -n $ev ]] || continue
    # The catalogue's flags ride into the node's meta so a map can be read
    # without the catalogue beside it. `lib/advise.jq` still falls back to
    # lib/vendors.tsv, because every map scanned before this column existed has
    # vendor nodes without it and nobody should have to rescan to get advice.
    emit_node "vendor:$id" vendor "$name" \
      "$(jq -cn --arg c "$category" --arg p "$portal" --arg f "$flags" \
         '{category: $c, portal: $p,
           flags: ($f | if . == "" then [] else split(",") end)}')"
    # The signal rides along on the edge. `lib/advise.jq` otherwise has to read
    # the kind back off the filename it was matched in, which is a guess where
    # this is a record.
    emit_edge "repo:$repo" "vendor:$id" uses "$ev" extracted "$kind"
  done < <(vendors_match "$facts")
  rm -f "$facts"
}
