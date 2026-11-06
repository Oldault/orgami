# shellcheck shell=bash
# What a repo *is*, read off its committed files: framework, how to run it,
# what configuration it reads, what it serves, what it calls, what it already
# tells agents. Written per repo during the scan, rendered into cards by `doc`.

PROFILE_EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor
  --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=out
  --exclude-dir=coverage --exclude-dir=__pycache__ --exclude-dir=.venv
  --exclude-dir=venv --exclude-dir=target --exclude-dir=Pods
  --exclude=*.lock --exclude=*.sum --exclude=*.min.js --exclude=*.map)

# Test paths: a route or URL declared in a test fixture is not something the
# repo serves or reaches in production. Same shape as PROFILE_EXCL so the
# grep -r calls that build the endpoints and calls lists can opt in.
PROFILE_TEST_EXCL=(--exclude-dir=test --exclude-dir=tests --exclude-dir=spec
  --exclude-dir=__tests__ --exclude-dir=e2e --exclude-dir=testdata
  --exclude-dir=fixtures --exclude-dir=mocks
  --exclude=*_test.go --exclude=*.test.ts --exclude=*.test.js
  --exclude=*.spec.ts --exclude=*.spec.js)

# The same directories as find(1) prune arguments, so a walk that has to stay
# cheap skips exactly what the greps skip: `find "$src" -type d \(
# "${PROFILE_PRUNE[@]}" \) -prune -o ...`. Derived, so the two lists cannot drift.
PROFILE_PRUNE=()
for _e in "${PROFILE_EXCL[@]}"; do
  [[ $_e == --exclude-dir=* ]] || continue
  [[ ${#PROFILE_PRUNE[@]} -gt 0 ]] && PROFILE_PRUNE+=(-o)
  PROFILE_PRUNE+=(-name "${_e#--exclude-dir=}")
done
unset _e

# Where a variable name is mentioned rather than read: a README that tells you
# to set `process.env.FOO`, a docs site, a test that stubs ACCEPTANCE_* knobs.
# None of them is configuration the running service reads.
PROFILE_ENV_EXCL=(--exclude=*.md --exclude=*.mdx --exclude-dir=docs)

# Env vars that say nothing about the system.
ENV_NOISE='^(NODE_ENV|ENV|ENVIRONMENT|PORT|HOST|DEBUG|LOG_LEVEL|TZ|HOME|PATH|USER|PWD|CI|npm_.*|NEXT_RUNTIME|VERCEL.*)$'

# make targets, just recipes and Task tasks are all free-form names in a file
# that lists everything the repo ever does, deploys included. The same handful
# of names is what somebody actually needs in order to run the thing, so all
# three branches ask the same question and it is written down once.
RUN_VOCAB='^(dev|run|start|build|test|lint|check|setup|install|migrate|debug)$'

# The script `npm init` writes. It exits 1 on purpose, so reporting it as the
# repo's test command tells a reader the one thing that is certainly wrong.
NPM_TEST_PLACEHOLDER='no test specified'

# A checkout is somebody else's tree, and a committed symlink is a file that can
# name any path on this machine. `AGENTS.md -> ../../../.config/gh/hosts.yml`
# read as the repo's agent instructions would copy the scanning user's token
# into CONVENTIONS.md, which publish pushes. So a file read out of a checkout is
# read only when its real location, every link followed, is still inside it.

# clone_realpath <path> — the physical path, every symlink in every component
# followed, or failure for a loop or a link that leads nowhere. `cd -P` and
# `pwd -P` rather than readlink -f, which BSD readlink does not have.
clone_realpath() {
  local p=$1 t d n=0
  while :; do
    d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
    p=$d/$(basename "$p")
    [[ -L $p ]] || break
    ((++n <= 40)) || return 1
    t=$(readlink "$p") || return 1
    [[ $t == /* ]] || t=$d/$t
    p=$t
  done
  [[ -e $p ]] || return 1
  if [[ -d $p ]]; then (cd -P "$p" 2>/dev/null && pwd -P); else printf '%s\n' "$p"; fi
}

# clone_inside <checkout> <path> — does <path> exist and resolve to somewhere
# inside <checkout>, outside its .git? A link into .git is refused with the
# rest: the remote URL and any credential git kept live there.
clone_inside() {
  local root real
  root=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  real=$(clone_realpath "$2") || return 1
  [[ $real == "$root" || $real == "$root"/* ]] || return 1
  [[ $real != "$root/.git" && $real != "$root"/.git/* ]]
}

# clone_file <checkout> <path> — a regular file that clone_inside allows.
clone_file() {
  [[ -f $2 ]] && clone_inside "$1" "$2"
}

# Phoenix leaves two marks and either one is enough: the dependency in mix.exs,
# or the `lib/<app>_web/` tree its generator writes. Both the framework list and
# the command list ask the question, so it is answered in one place.
profile_is_phoenix() {
  local src=$1 d
  [[ -f $src/mix.exs ]] || return 1
  grep -q '{:phoenix,' "$src/mix.exs" && return 0
  for d in "$src"/lib/*_web; do
    [[ -d $d ]] && return 0
  done
  return 1
}

# The .NET project and solution files a checkout committed. A solution keeps its
# projects a directory or two below the root and anything deeper is a vendored
# copy rather than the repo's own, so the walk stops there — and it prunes
# instead of filtering, because this runs against every repo in the scan and
# most of them have no .NET in them at all. The framework list, the command list
# and the runtime line all ask, so it is answered in one place, in path order so
# that the answer is the same on the next scan.
profile_dotnet_files() {
  find "$1" -maxdepth 3 \( -name .git -o -name node_modules \) -prune -o \
    \( -name '*.csproj' -o -name '*.sln' \) -print 2>/dev/null | sort | head -10
}

# --- workspaces ----------------------------------------------------------------
#
# A monorepo keeps its framework, its scripts and its .env.example one level or
# two below the root, and the root package.json says only "workspaces". Every
# reader that wants the packages asks the same question, so it is answered once:
#
#   profile_workspace_dirs <checkout>
#
# prints the package directories, relative to the checkout (`apps/web`, never
# `./apps/web/` and never the root itself), one per line, byte-sorted, at most
# PROFILE_WS_MAX of them, and nothing at all for a single-package repo. Status
# is always 0. Each directory holds a package.json that resolves inside the
# checkout, and its name is plain `[A-Za-z0-9._@+-/]`, so a caller can read the
# list line by line and join it to the checkout without quoting surprises.
#
# The declaration wins when there is one: pnpm-workspace.yaml `packages:`, the
# package.json `workspaces` field (array, or the object form's `packages`), and
# lerna.json `packages`. turbo.json lists nothing of its own — turbo runs on the
# package manager's workspaces. Without a declaration, or when it matches
# nothing, the fallback is every package.json two directories down at most,
# which is where a `server/` beside a root React app lives.
#
#   profile_workspace_how <checkout>
#
# prints `declared`, `found` (the fallback) or nothing, which decides whether a
# workspace command (`pnpm --filter`) or a directory command (`pnpm -C`) runs it.
#
# The scan runs this for every repo, and five readers in a row ask, so the walk
# happens once per checkout per process: the answer is kept in PROFILE_WS_*.
# `profile_workspace_scan <checkout>` fills it (call it in the parent shell
# before fanning out into $(...), or every subshell walks again), and
# `profile_workspace_forget` drops it.
PROFILE_WS_MAX=24
PROFILE_WS_FOR="" PROFILE_WS_DIRS="" PROFILE_WS_HOW=""

# The fallback walk also leaves alone what a library keeps for its readers: an
# example app's Next.js is not the repo's framework.
PROFILE_WS_FALLBACK_PRUNE=(-o -name fixtures -o -name testdata -o -name mocks
  -o -name __tests__ -o -name __fixtures__ -o -name examples -o -name example)

# The patterns a repo declares, one per line, exactly as written.
profile_workspace_globs() {
  local src=$1
  # pnpm-workspace.yaml is read as shallowly as a Taskfile, for the same reason
  # — no YAML parser: the items under a column-one `packages:`, block or flow
  # style, ending at the next column-one key.
  clone_file "$src" "$src/pnpm-workspace.yaml" &&
    awk '/^packages:[[:space:]]*\[/ {
           s = $0; sub(/^packages:[[:space:]]*\[/, "", s); sub(/\].*$/, "", s)
           n = split(s, a, ","); for (i = 1; i <= n; i++) print a[i]; next }
         /^packages:/ { in_p = 1; next }
         /^[^[:space:]#-]/ { in_p = 0 }
         in_p && /^[[:space:]]*-/ { s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); print s }' \
      "$src/pnpm-workspace.yaml" 2>/dev/null
  clone_file "$src" "$src/package.json" &&
    jq -r '.workspaces | if type == "array" then .[]
             elif type == "object" then (.packages // [])[]? else empty end | strings' \
      "$src/package.json" 2>/dev/null
  clone_file "$src" "$src/lerna.json" &&
    jq -r '(.packages // [])[]? | strings' "$src/lerna.json" 2>/dev/null
  return 0
}

# Is <dir>, relative to the checkout whose physical path is <root>, one a
# caller can use as a package? The directory is resolved once rather than the
# manifest walked link by link, because this runs for every package of every
# repo; only a manifest that is itself a link pays for clone_file.
profile_workspace_ok() {
  local src=$1 d=$2 root=$3 seg real
  [[ -n $d && $d != . && $d =~ ^[A-Za-z0-9._@+/-]+$ ]] || return 1
  # A node_modules or a dist that a glob reached is a copy, never a package.
  for seg in ${d//\// }; do
    [[ $seg == . || $seg == .. ]] && return 1
    case " ${PROFILE_PRUNE[*]} " in *" $seg "*) return 1 ;; esac
  done
  [[ -f $src/$d/package.json ]] || return 1
  real=$(cd -P "$src/$d" 2>/dev/null && pwd -P) || return 1
  [[ $real == "$root"/* && $real != "$root/.git" && $real != "$root"/.git/* ]] || return 1
  [[ ! -L $src/$d/package.json ]] || clone_file "$src" "$src/$d/package.json"
}

profile_workspace_scan() {
  local src=$1 globs p base m d neg keep
  local pos=() negs=() found=()
  PROFILE_WS_FOR=$src PROFILE_WS_DIRS="" PROFILE_WS_HOW=""
  globs=$(profile_workspace_globs "$src")
  while IFS= read -r p; do
    p=${p%%[[:space:]]#*}
    p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}
    p=${p#[\"\']}; p=${p%[\"\']}
    p=${p#./}; p=${p%/}; p=${p%/package.json}
    [[ -n $p ]] || continue
    if [[ $p == !* ]]; then negs+=("${p#!}"); continue; fi
    # A pattern is data from somebody else's tree: no absolute path, no way out
    # of it, and no glob deep enough to make the expansion the slow part.
    [[ $p != /* && $p != *..* ]] || continue
    m=${p//[!\/]/}
    ((${#m} <= 3)) || continue
    pos+=("$p")
  done <<<"$globs"

  for p in "${pos[@]}"; do
    if [[ $p == *'**'* ]]; then
      base=${p%%\*\**}; base=${base%/}
      [[ -z $base || -d $src/$base ]] || continue
      while IFS= read -r m; do
        found+=("${m#"$src"/}")
      done < <(find "$src${base:+/$base}" -mindepth 1 -maxdepth 4 -type d \( "${PROFILE_PRUNE[@]}" \) -prune \
        -o -type f -name package.json -print 2>/dev/null)
    else
      # compgen -G is pathname expansion and nothing else: a pattern cannot run
      # anything, it can only fail to match.
      while IFS= read -r m; do
        found+=("$m")
      done < <(cd "$src" 2>/dev/null && compgen -G "$p/package.json")
    fi
  done
  [[ ${#found[@]} -gt 0 ]] && PROFILE_WS_HOW=declared

  if [[ ${#found[@]} -eq 0 ]]; then
    # The root package.json is dropped after the walk. -mindepth 1 keeps find
    # from testing the checkout itself: one named build, out or examples
    # would otherwise be pruned whole and yield nothing. The same in every
    # pruned walk below.
    while IFS= read -r m; do
      found+=("${m#"$src"/}")
    done < <(find "$src" -mindepth 1 -maxdepth 3 -type d \( "${PROFILE_PRUNE[@]}" "${PROFILE_WS_FALLBACK_PRUNE[@]}" \) \
      -prune -o -type f -name package.json -print 2>/dev/null)
    PROFILE_WS_HOW=found
  fi

  local out=() root
  root=$(cd -P "$src" 2>/dev/null && pwd -P) || return 0
  for m in "${found[@]}"; do
    d=${m%package.json}; d=${d%/}; d=${d#./}
    profile_workspace_ok "$src" "$d" "$root" || continue
    keep=1
    for neg in "${negs[@]}"; do
      # shellcheck disable=SC2053 # the negation is a glob, matched as one
      [[ $d == $neg || $d == ${neg%/\*\*}/* ]] && { keep=0; break; }
    done
    ((keep)) && out+=("$d")
  done
  if [[ ${#out[@]} -gt 0 ]]; then
    PROFILE_WS_DIRS=$(printf '%s\n' "${out[@]}" | LC_ALL=C sort -u | head -"$PROFILE_WS_MAX")
  else
    PROFILE_WS_HOW=""
  fi
}

profile_workspace_dirs() {
  [[ $PROFILE_WS_FOR == "$1" ]] || profile_workspace_scan "$1"
  [[ -z $PROFILE_WS_DIRS ]] || printf '%s\n' "$PROFILE_WS_DIRS"
}

profile_workspace_how() {
  [[ $PROFILE_WS_FOR == "$1" ]] || profile_workspace_scan "$1"
  [[ -z $PROFILE_WS_HOW ]] || printf '%s\n' "$PROFILE_WS_HOW"
}

profile_workspace_forget() {
  PROFILE_WS_FOR="" PROFILE_WS_DIRS="" PROFILE_WS_HOW=""
  PROFILE_WS_FACTS_FOR="" PROFILE_WS_FACTS=""
  PROFILE_ENVF_FOR="" PROFILE_ENVF=""
}

# The frameworks a package.json names, as a jq function over the document, in
# the order the rules are written. A monorepo has a dozen manifests, so the
# rule list is one jq program run over all of them at once rather than a grep
# per rule per package. It has no apostrophe in it: it lives in single quotes.
PROFILE_JS_FW_JQ='def js_frameworks:
    ([(.dependencies // {}), (.devDependencies // {})] | add // {}) as $d
    | def dep($k): $d | has($k);
    []
    # Meta-frameworks lead the list. Each of them ships the library it is built
    # on as a dependency of its own, and the guarded `react`, `vue` and
    # `svelte` lines below only fire when nothing more specific matched — so a
    # SvelteKit repo has to reach the list before the `svelte` line reads it,
    # or it reports the library instead of the framework.
    | if dep("next") then . + ["Next.js"] else . end
    | if dep("nuxt") then . + ["Nuxt"] else . end
    | if dep("@sveltejs/kit") then . + ["SvelteKit"] else . end
    | if dep("astro") then . + ["Astro"] else . end
    | if dep("@remix-run/react") then . + ["Remix"] else . end
    # React Router is the framework only in its framework mode. As a plain
    # dependency it is the router a React SPA imports, and the repo is a React
    # repo; `@react-router/dev` is what tells the two apart.
    | if dep("react-router") and dep("@react-router/dev") then . + ["React Router"] else . end
    | if dep("@angular/core") then . + ["Angular"] else . end
    | if dep("@solidjs/start") then . + ["SolidStart"] else . end
    | if dep("@builder.io/qwik") then . + ["Qwik"] else . end
    | if dep("@nestjs/core") then . + ["NestJS"] else . end
    | if dep("express") then . + ["Express"] else . end
    | if dep("fastify") then . + ["Fastify"] else . end
    | if dep("koa") then . + ["Koa"] else . end
    | if dep("hono") then . + ["Hono"] else . end
    | if dep("elysia") then . + ["Elysia"] else . end
    | if dep("parse-server") then . + ["Parse Server"] else . end
    | if dep("parse") then . + ["Parse SDK"] else . end
    | if dep("react-native") then . + ["React Native"] else . end
    | if dep("expo") then . + ["Expo"] else . end
    | if dep("react") and length == 0 then . + ["React"] else . end
    | if dep("vue") and length == 0 then . + ["Vue"] else . end
    | if dep("svelte") and length == 0 then . + ["Svelte"] else . end
    # AdonisJS renders its pages through Inertia with React or Vue inside the
    # same package, so it is named after the guard: the front end it serves is
    # still said, where a Next.js app is not also called React.
    | if dep("@adonisjs/core") then . + ["AdonisJS"] else . end
    # These name how a repo reaches its database or its own API, not what it
    # is, so they sit beside the framework rather than instead of it — after
    # the guarded lines, never before them.
    | if dep("@trpc/server") then . + ["tRPC"] else . end
    | if dep("prisma") or dep("@prisma/client") then . + ["Prisma"] else . end
    | if dep("drizzle-orm") then . + ["Drizzle"] else . end
    | if dep("agenda") then . + ["Agenda jobs"] else . end
    | if dep("bullmq") or dep("bull") then . + ["Bull queue"] else . end
    | if dep("serverless") then . + ["Serverless"] else . end;'

# The frameworks one package.json names, one per line.
profile_js_frameworks() {
  jq -r "$PROFILE_JS_FW_JQ"' js_frameworks | .[]' "$1" 2>/dev/null || true
}

# profile_pkg_facts <checkout> <package.json>... — one JSON array, an entry per
# manifest: {dir, name, frameworks, scripts, lines}. scripts are the ones a
# workspace command is written for, lines the line of each key in the scripts
# block. One jq and one awk for the lot; a manifest jq cannot parse fails the
# batch, which profile_workspace_facts then retries one file at a time.
profile_pkg_facts() {
  local src=$1
  shift
  local lines
  lines=$(profile_script_lines_each "$@" |
    jq -Rn '[inputs | split("\t") | select(length == 3)]
      | reduce .[] as $r ({}; .[$r[0]][$r[1]] //= ($r[2] | tonumber))') || return 1
  jq -c --arg root "$src/" --arg ph "$NPM_TEST_PLACEHOLDER" --argjson lines "$lines" \
    "$PROFILE_JS_FW_JQ"'
    input_filename as $f
    | {dir: ($f | ltrimstr($root) | rtrimstr("/package.json")),
       name: (.name // "" | if type == "string" then . else "" end),
       frameworks: js_frameworks,
       scripts: ((.scripts // {}) | if type == "object" then . else {} end | to_entries
         | map(select((.key | test("^(dev|start|build|test)$"))
                      and (.value | type == "string")
                      and (.value | contains($ph) | not)))
         | .[0:4]),
       lines: ($lines[$f] // {})}' "$@" | jq -s -c '.'
}

# The facts of every workspace package, kept like the directory list: the
# framework list, the command list and the workspaces field all read them.
PROFILE_WS_FACTS_FOR="" PROFILE_WS_FACTS=""
profile_workspace_facts() {
  local src=$1 d f files=() out
  if [[ $PROFILE_WS_FACTS_FOR != "$src" ]]; then
    while IFS= read -r d; do
      [[ -n $d ]] && files+=("$src/$d/package.json")
    done < <(profile_workspace_dirs "$src")
    out='[]'
    if [[ ${#files[@]} -gt 0 ]]; then
      out=$(profile_pkg_facts "$src" "${files[@]}" 2>/dev/null) ||
        out=$(for f in "${files[@]}"; do
            profile_pkg_facts "$src" "$f" 2>/dev/null | jq -c '.[]' || true
          done | jq -s -c '.')
    fi
    PROFILE_WS_FACTS_FOR=$src PROFILE_WS_FACTS=$out
  fi
  printf '%s\n' "$PROFILE_WS_FACTS"
}

# The workspace packages of a monorepo, each with the frameworks its own
# package.json names: the evidence behind a framework the root does not show.
profile_workspaces() {
  profile_workspace_facts "$1" | jq -c 'map({dir, name, frameworks})'
}

profile_framework() {
  local src=$1
  local pkg="$src/package.json" out=() f
  if [[ -f $pkg ]]; then
    while IFS= read -r f; do out+=("$f"); done < <(profile_js_frameworks "$pkg")
  fi
  # Each package is judged on its own, so a React front end beside a Nest
  # server is both, and a Next.js app is still not also React.
  while IFS= read -r f; do
    [[ -n $f ]] && out+=("$f")
  done < <(profile_workspace_facts "$src" | jq -r '.[].frameworks[]')
  [[ -f $src/manage.py ]] && out+=("Django")
  grep -rqlE '^from fastapi import|FastAPI\(' "$src/" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null && out+=("FastAPI")
  grep -rqlE '^from flask import|Flask\(__name__\)' "$src/" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null && out+=("Flask")
  [[ -f $src/config/routes.rb ]] && out+=("Rails")
  [[ -f $src/go.mod ]] && out+=("Go module")
  [[ -f $src/Cargo.toml ]] && out+=("Cargo crate")
  [[ -f $src/pubspec.yaml ]] && out+=("Flutter")
  [[ -d $src/ios && -d $src/android ]] && out+=("Mobile app")

  # PHP. composer.json is JSON, so jq reads it — the house rule that keeps grep
  # off package.json applies here for the same reason. `artisan`, `bin/console`
  # and `wp-config.php` each name the framework on their own, so a checkout
  # that never committed its composer.json is still recognized.
  local php_start=${#out[@]} require=""
  [[ -f $src/composer.json ]] &&
    require=$(jq -r '[(.require // {}), (."require-dev" // {})] | add // {} | keys[]' \
      "$src/composer.json" 2>/dev/null || true)
  { [[ -f $src/artisan ]] || grep -qx 'laravel/framework' <<<"$require"; } && out+=("Laravel")
  { [[ -f $src/bin/console ]] || grep -qx 'symfony/framework-bundle' <<<"$require"; } && out+=("Symfony")
  { [[ -f $src/wp-config.php ]] || [[ -d $src/wp-content ]]; } && out+=("WordPress")
  # Last, and only when none of the three matched: a bare composer.json says the
  # repo is a PHP project and nothing more specific, so it is the fallback that
  # keeps such a repo from reporting nothing — not a fourth name beside them.
  [[ -f $src/composer.json && ${#out[@]} -eq $php_start ]] && out+=("Composer project")

  # Elixir. mix.exs is not JSON, so grep is the right reader here.
  if [[ -f $src/mix.exs ]]; then
    # The same shape as the guarded `react` line above: Phoenix is the concrete
    # thing to say about the repo, and "Elixir project" beside it would only
    # repeat the category it is already an instance of.
    if profile_is_phoenix "$src"; then out+=("Phoenix"); else out+=("Elixir project"); fi
    # Ecto says how the repo reaches its database rather than what it is, so it
    # is reported beside the framework the way Prisma and Drizzle are.
    grep -q '{:ecto' "$src/mix.exs" && out+=("Ecto")
  fi

  # The JVM. pom.xml is XML and a Gradle build file is its own Groovy or Kotlin
  # DSL, so grep reads them — the rule that keeps grep off package.json is about
  # JSON. The build system and the framework written on top of it are two
  # different facts about a repo, so Spring Boot is reported beside Maven or
  # Gradle rather than instead of either, the way Prisma sits beside React.
  local builds=()
  [[ -f $src/pom.xml ]] && { out+=("Maven"); builds+=("$src/pom.xml"); }
  [[ -f $src/build.gradle ]] && builds+=("$src/build.gradle")
  [[ -f $src/build.gradle.kts ]] && builds+=("$src/build.gradle.kts")
  [[ -f $src/build.gradle || -f $src/build.gradle.kts ]] && out+=("Gradle")
  [[ ${#builds[@]} -gt 0 ]] && grep -q 'spring-boot-starter' "${builds[@]}" 2>/dev/null &&
    out+=("Spring Boot")

  # .NET. A committed project or solution file is the whole signal. ASP.NET
  # names itself inside the project file, either as the web SDK the project
  # builds with or as a package it references — a class library names neither,
  # and stays plain .NET.
  local dotnet f
  dotnet=$(profile_dotnet_files "$src")
  if [[ -n $dotnet ]]; then
    out+=(".NET")
    while IFS= read -r f; do
      if grep -qE 'Microsoft\.AspNetCore|Microsoft\.NET\.Sdk\.Web' "$f" 2>/dev/null; then
        out+=("ASP.NET")
        break
      fi
    done <<<"$dotnet"
  fi

  printf '%s\n' "${out[@]:-}" | grep -v '^$' | sort -u | jq -Rn '[inputs]'
}

# profile_script_lines <package.json> — {"script": line} for the keys of its
# `scripts` block, so a command can cite the line that declares it. jq reads the
# values and knows no line numbers; this only finds where each key sits, from
# the `"scripts":` line to the first line that closes a block.
profile_script_lines() {
  profile_script_lines_each "$1" |
    jq -Rn '[inputs | split("\t") | select(length == 3) | {(.[1]): (.[2] | tonumber)}] | add // {}'
}

# The same read over several manifests in one awk: "file<TAB>key<TAB>line".
profile_script_lines_each() {
  awk 'FNR == 1 { s = 0; split("", seen) }
       s == 0 && /"scripts"[[:space:]]*:/ { s = 1; first = FNR }
       s == 1 {
         line = $0
         while (match(line, /"[^"\\]*"[[:space:]]*:/)) {
           k = substr(line, RSTART + 1, RLENGTH - 1); sub(/"[[:space:]]*:$/, "", k)
           if (!(k in seen)) { seen[k] = FNR; print FILENAME "\t" k "\t" FNR }
           line = substr(line, RSTART + RLENGTH)
         }
         if (FNR > first && $0 ~ /^[[:space:]]*}/) s = 2
       }' "$@" 2>/dev/null
}

profile_commands() {
  local src=$1
  local pkg="$src/package.json" cmds='{}' evidence='{}'

  if [[ -f $pkg ]]; then
    cmds=$(jq -c --arg ph "$NPM_TEST_PLACEHOLDER" '(.scripts // {})
      | with_entries(select(.key | test("^(dev|start|build|test|lint|typecheck|migrate|seed|e2e)")))
      | with_entries(select(.value | tostring | contains($ph) | not))
      | to_entries | .[0:8] | from_entries' "$pkg" 2>/dev/null || echo '{}')
    evidence=$(jq -c --argjson c "$cmds" --argjson l "$(profile_script_lines "$pkg")" \
      '$l | with_entries(select(.key as $k | $c | has($k)) | .value = "package.json:\(.value)")' \
      <<<'{}' 2>/dev/null || echo '{}')
  fi

  # The same question of composer.json: same vocabulary, same cap. A composer
  # script may also be a list, which composer runs in order.
  if [[ -f $src/composer.json ]]; then
    local composer_scripts
    composer_scripts=$(jq -c '(.scripts // {})
      | with_entries(select(.key | test("^(dev|start|build|test|lint|typecheck|migrate|seed|e2e)")))
      | map_values(if type == "array" then join(" && ") else . end)
      | to_entries | .[0:8] | from_entries' "$src/composer.json" 2>/dev/null || echo '{}')
    # A name both files define keeps the command package.json gave it: reading a
    # second manifest should add what the first did not say, not rewrite it.
    cmds=$(jq -c --argjson c "$composer_scripts" '$c + .' <<<"$cmds")
  fi

  # mix is the runner for every Elixir project; `mix phx.server` exists only
  # where Phoenix does.
  if [[ -f $src/mix.exs ]]; then
    cmds=$(jq -c '.test //= "mix test"' <<<"$cmds")
    profile_is_phoenix "$src" && cmds=$(jq -c '.dev //= "mix phx.server"' <<<"$cmds")
  fi

  # mvn, gradle and dotnet each run a project's tests off the build file alone,
  # with nothing anywhere in the repo declaring a script for it.
  [[ -f $src/pom.xml ]] && cmds=$(jq -c '.test //= "mvn test"' <<<"$cmds")
  if [[ -f $src/build.gradle || -f $src/build.gradle.kts ]]; then
    # The wrapper is how a Gradle project is meant to be run, and the only way
    # that works without Gradle installed — but a repo that never committed one
    # leaves plain `gradle` as what the reader actually has.
    if [[ -f $src/gradlew ]]; then
      cmds=$(jq -c '.test //= "./gradlew test"' <<<"$cmds")
    else
      cmds=$(jq -c '.test //= "gradle test"' <<<"$cmds")
    fi
  fi
  local dotnet
  dotnet=$(profile_dotnet_files "$src")
  [[ -n $dotnet ]] && cmds=$(jq -c '.test //= "dotnet test"' <<<"$cmds")

  if [[ -f $src/Makefile ]]; then
    # `name:=` is an assignment, not a target. `all` is the conventional build
    # target of a plain C or C++ project and the one bare `make` runs when it
    # comes first, so it is the build command unless a `build:` target exists.
    local targets
    # One awk over the target list, not a grep per target: a Makefile that is
    # the repo's whole task runner declares hundreds of them.
    targets=$(grep -E '^[a-z][a-z0-9_-]*:([^=]|$)' "$src/Makefile" | sed -E 's/:.*$//' |
      V=$RUN_VOCAB awk '{ t[NR] = $0; if ($0 == "build") b = 1 }
        END {
          for (i = 1; i <= NR; i++) {
            if (t[i] == "all") {
              if (!b && !seen["build"]++) print (i == 1 ? "build=make" : "build=make all")
            } else if (t[i] ~ ENVIRON["V"] && !seen[t[i]]++) print t[i] "=make " t[i]
          }
        }' | head -6 || true)
    [[ -n $targets ]] && cmds=$(jq -c --argjson t "$(jq -Rn '[inputs]' <<<"$targets")" \
      '. + ($t | map(index("=") as $i | {(.[0:$i]): .[$i + 1:]}) | add // {})' <<<"$cmds")
  fi

  # dune builds and tests an OCaml project off its dune-project alone.
  if [[ -f $src/dune-project ]]; then
    cmds=$(jq -c '.build //= "dune build" | .test //= "dune test"' <<<"$cmds")
  fi

  # just is make's shape with a different runner: recipe names read the same
  # way, so the vocabulary and the cap are the Makefile branch's. What it adds
  # is added the way composer.json's scripts are — a name package.json already
  # gave a command keeps it, because a second manifest says what the first left
  # out rather than rewriting it.
  local justfile=""
  [[ -f $src/justfile ]] && justfile="$src/justfile"
  [[ -z $justfile && -f $src/Justfile ]] && justfile="$src/Justfile"
  if [[ -n $justfile ]]; then
    local recipes
    recipes=$(grep -oE '^[a-z][a-z0-9_-]*:' "$justfile" | tr -d ':' |
      grep -E "$RUN_VOCAB" | head -6 || true)
    [[ -n $recipes ]] && cmds=$(jq -c --argjson t "$(jq -Rn '[inputs]' <<<"$recipes")" \
      '($t | map({(.): ("just " + .)}) | add // {}) + .' <<<"$cmds")
  fi

  local taskfile=""
  [[ -f $src/Taskfile.yml ]] && taskfile="$src/Taskfile.yml"
  [[ -z $taskfile && -f $src/Taskfile.yaml ]] && taskfile="$src/Taskfile.yaml"
  if [[ -n $taskfile ]]; then
    # Deliberately shallow, because orgami takes no YAML parser: the task names
    # are the two-space-indented keys under `tasks:`, the block ends at the next
    # key in column one, and everything a task itself declares — `cmds:`,
    # `desc:` — is indented deeper than that. Nesting beyond those two facts is
    # not attempted, and a Taskfile that formats itself differently reads as a
    # Taskfile with no tasks rather than as one with the wrong ones.
    local tasks
    tasks=$(awk '/^tasks:/ { in_tasks = 1; next }
                 /^[^[:space:]]/ { in_tasks = 0 }
                 in_tasks && /^  [a-z][a-z0-9_-]*:/ { sub(/:.*/, ""); sub(/^  /, ""); print }' \
      "$taskfile" | grep -E "$RUN_VOCAB" | head -6 || true)
    [[ -n $tasks ]] && cmds=$(jq -c --argjson t "$(jq -Rn '[inputs]' <<<"$tasks")" \
      '($t | map({(.): ("task " + .)}) | add // {}) + .' <<<"$cmds")
  fi

  local b
  for b in setup dev test start console migrate; do
    [[ -x $src/bin/$b ]] && cmds=$(jq -c --arg k "$b" --arg v "bin/$b" '.[$k] //= $v' <<<"$cmds")
  done

  local pm=""
  [[ -f $src/pnpm-lock.yaml ]] && pm=pnpm
  [[ -z $pm && -f $src/yarn.lock ]] && pm=yarn
  [[ -z $pm && -f $src/package-lock.json ]] && pm=npm
  [[ -z $pm && -f $src/Gemfile ]] && pm=bundler
  [[ -z $pm && -f $src/poetry.lock ]] && pm=poetry
  [[ -z $pm && -f $src/requirements.txt ]] && pm=pip
  [[ -z $pm && -f $src/go.mod ]] && pm=go
  [[ -z $pm && -f $src/Cargo.toml ]] && pm=cargo
  [[ -z $pm && -f $src/composer.lock ]] && pm=composer

  # A monorepo's own scripts live in its packages, and the root often declares
  # nothing but lint. A declared workspace runs through the package manager's
  # filter, so the command is the one somebody would type at the root; a
  # package.json the fallback found is outside any workspace and runs in its
  # own directory. Four scripts a package and sixteen in all, in file order:
  # what a reader needs to start, test and build each part, not the inventory.
  local ws how
  ws=$(profile_workspace_dirs "$src")
  how=$(profile_workspace_how "$src")
  if [[ -n $ws ]]; then
    local wpm=npm wsj
    [[ -f $src/yarn.lock ]] && wpm=yarn
    [[ -f $src/pnpm-lock.yaml || -f $src/pnpm-workspace.yaml ]] && wpm=pnpm
    wsj=$(profile_workspace_facts "$src")
    local wcmd
    wcmd=$(jq -c --arg pm "$wpm" --arg how "$how" '
      # A name that is not a plain npm package name would break the command it
      # is pasted into, so the directory stands in for it.
      def target: if .name | test("^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+$") then .name else "./" + .dir end;
      def run($s):
        if $how == "declared" then
          if $pm == "pnpm" then "pnpm --filter " + target + " " + $s
          elif $pm == "yarn" then "yarn workspace " + target + " " + $s
          else "npm run " + $s + " -w " + .dir end
        else
          if $pm == "pnpm" then "pnpm -C " + .dir + " " + $s
          elif $pm == "yarn" then "yarn --cwd " + .dir + " " + $s
          else "npm --prefix " + .dir + " run " + $s end
        end;
      [ .[] | . as $p | $p.scripts[] | .key as $s
        | {key: (.key + " (" + $p.dir + ")"), cmd: ($p | run($s)),
           at: ($p.dir + "/package.json" + (($p.lines[.key] // null) | if . then ":" + tostring else "" end))} ]
      | .[0:16]' <<<"$wsj" 2>/dev/null || echo '[]')
    cmds=$(jq -c --argjson w "$wcmd" '. + ($w | map({(.key): .cmd}) | add // {})' <<<"$cmds")
    evidence=$(jq -c --argjson w "$wcmd" '. + ($w | map({(.key): .at}) | add // {})' <<<"$evidence")
  fi

  local runtime=""
  [[ -f $src/.nvmrc ]] && runtime="node $(tr -d 'v \n' <"$src/.nvmrc" | head -c 12)"
  [[ -z $runtime && -f $pkg ]] && runtime=$(jq -r '.engines.node // empty | if . == "" then empty else "node " + . end' "$pkg" 2>/dev/null || true)
  [[ -z $runtime && -f $src/.python-version ]] && runtime="python $(head -1 "$src/.python-version")"
  [[ -z $runtime && -f $src/.ruby-version ]] && runtime="ruby $(head -1 "$src/.ruby-version")"
  [[ -z $runtime && -f $src/go.mod ]] && runtime=$(grep -m1 '^go ' "$src/go.mod" | sed 's/^go /go /' || true)
  [[ -z $runtime && -f $src/pom.xml ]] &&
    runtime=$(grep -m1 -oE '<java\.version>[^<]+' "$src/pom.xml" |
      sed -E 's|<java\.version>|java |' || true)
  # `net8.0` is already the name the toolchain uses for itself, so it is
  # reported as it stands rather than guessed into a version number — the same
  # string is `netstandard2.1` or `net48` in the repo next door.
  if [[ -z $runtime && -n $dotnet ]]; then
    local f tf
    while IFS= read -r f; do
      tf=$(grep -m1 -oE '<TargetFrameworks?>[^<]+' "$f" |
        sed -E 's|<TargetFrameworks?>||' || true)
      if [[ -n $tf ]]; then
        runtime="dotnet $tf"
        break
      fi
    done <<<"$dotnet"
  fi

  local procfile="[]"
  # A Procfile with no lowercase `name:` line (comments only, `Web:`) is not an
  # error: `grep` exits 1 on no match and pipefail would fail the assignment
  # even though jq still printed `[]`.
  [[ -f $src/Procfile ]] &&
    procfile=$(grep -oE '^[a-z]+:' "$src/Procfile" | tr -d ':' | jq -Rn '[inputs]' || true)

  # evidence is new beside the four fields that predate it: the file and line
  # behind each script read out of a package.json, keyed like scripts.
  jq -n --argjson scripts "$cmds" --arg pm "$pm" --arg runtime "$runtime" \
    --argjson procs "$procfile" --argjson evidence "$evidence" \
    '{scripts: $scripts, package_manager: $pm, runtime: $runtime, procfile: $procs,
      evidence: $evidence}'
}

# How many names the env list keeps. A repo can read three hundred; the card
# says how many there were rather than pretending sixty is all of them.
PROFILE_ENV_MAX=60

# The committed example env files, anywhere a monorepo package keeps one:
# `apps/api/.env.example` as much as the root's, and the `backend.env.example`
# spelling too. Four levels is apps/<pkg>/config/.env.example.
PROFILE_ENVF_FOR="" PROFILE_ENVF=""
profile_env_files() {
  local src=$1
  # Both the env list and the serves list read these, so the walk is kept.
  if [[ $PROFILE_ENVF_FOR != "$src" ]]; then
    PROFILE_ENVF=$(profile_env_files_walk "$src")
    PROFILE_ENVF_FOR=$src
  fi
  [[ -z $PROFILE_ENVF ]] || printf '%s\n' "$PROFILE_ENVF"
}

profile_env_files_walk() {
  local src=$1 f
  find "$src" -mindepth 1 -maxdepth 4 -type d \( "${PROFILE_PRUNE[@]}" \) -prune -o -type f \
    \( -name .env.example -o -name .env.sample -o -name .env.template -o -name .env.dist \
    -o -name '*.env.example' \) -print 2>/dev/null | LC_ALL=C sort | head -40 |
    while IFS= read -r f; do
      clone_file "$src" "$f" && printf '%s\n' "$f"
    done
  return 0
}

# Every configuration name the repo reads, ranked: first what an example env
# file declares — the variables somebody set up on purpose, secrets and service
# keys among them — then what source code reads that no example names. Each
# group is byte-sorted, so the order is the same on every machine.
profile_env_all() {
  local src=$1 f declared code
  declared=$(profile_env_files "$src" | while IFS= read -r f; do
      grep -oE '^(export[[:space:]]+)?[A-Z][A-Z0-9_]{2,}=' "$f" | sed -E 's/^export[[:space:]]+//; s/=$//'
    done 2>/dev/null | LC_ALL=C sort -u | grep -vE "$ENV_NOISE" || true)
  code=$({
    grep -rhoE 'process\.env\.[A-Z][A-Z0-9_]{2,}' "$src/" \
      "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" "${PROFILE_ENV_EXCL[@]}" 2>/dev/null |
      sed 's/process\.env\.//'
    grep -rhoE "os\.environ(\.get)?[\[(]['\"][A-Z][A-Z0-9_]{2,}" "$src/" --include='*.py' \
      "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" "${PROFILE_ENV_EXCL[@]}" 2>/dev/null |
      grep -oE "[A-Z][A-Z0-9_]{2,}$"
    grep -rhoE "ENV\[['\"][A-Z][A-Z0-9_]{2,}" "$src/" --include='*.rb' \
      "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" "${PROFILE_ENV_EXCL[@]}" 2>/dev/null |
      grep -oE "[A-Z][A-Z0-9_]{2,}$"
  } 2>/dev/null | LC_ALL=C sort -u | grep -vE "$ENV_NOISE" || true)
  [[ -z $declared ]] || printf '%s\n' "$declared"
  [[ -z $code ]] || LC_ALL=C comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$code")
  return 0
}

# The list as the profile keeps it: the first PROFILE_ENV_MAX of the ranking.
# The total lands beside it as env_total.
profile_env() {
  profile_env_all "$1" | head -"$PROFILE_ENV_MAX" | jq -Rn '[inputs | select(. != "")]'
}

# `grep -rno` hits made readable: "path:line: VERB rest". $1 is the checkout,
# taken off the front of each path; $2 a fixed label (CLOUD), or empty to name
# the verb after the call it matched — `.get(` and `@Get(` both read GET. awk,
# not sed: uppercasing a capture is GNU sed's \U, which BSD sed lacks, and the
# checkout path is data a sed program would read as syntax. ENVIRON carries
# both in untouched, where awk -v would expand backslashes in them.
profile_route_lines() {
  P="$1/" L="${2-}" awk '
    {
      line = $0
      if (index(line, ENVIRON["P"]) == 1) line = substr(line, length(ENVIRON["P"]) + 1)
      if (!match(line, /:[0-9]+:/)) next
      head = substr(line, 1, RSTART + RLENGTH - 1)
      rest = substr(line, RSTART + RLENGTH)
      if (!match(rest, /[A-Za-z_]+\([[:space:]]*/)) next
      verb = substr(rest, RSTART, RLENGTH)
      sub(/\(.*/, "", verb)
      rest = substr(rest, RSTART + RLENGTH + 1)
      print head " " (ENVIRON["L"] != "" ? ENVIRON["L"] : toupper(verb)) " " rest
    }'
}

# profile_routes_uncommented <checkout> — drops a grep hit whose line, read
# whole from the file, starts as a comment (//, /*, *, #). grep -o keeps only
# the match, so the line has to be read back; a route quoted in a doc comment
# is documentation, not an endpoint. The rule is vendors_grep's commented().
profile_routes_uncommented() {
  P="$1/" awk '
    {
      line = $0
      if (!match(line, /:[0-9]+:/)) { print; next }
      path = substr(line, 1, RSTART - 1)
      ln = substr(line, RSTART + 1, RLENGTH - 2) + 0
      if (index(path, ENVIRON["P"]) != 1) path = ENVIRON["P"] path
      if (!(path in seen)) {
        seen[path] = 1; n = 0
        while ((getline t < path) > 0) {
          n++
          sub(/^[ \t]+/, "", t)
          if (substr(t, 1, 2) == "//" || substr(t, 1, 2) == "/*" || substr(t, 1, 1) == "*" || substr(t, 1, 1) == "#")
            dead[path SUBSEP n] = 1
        }
        close(path)
      }
      if ((path SUBSEP ln) in dead) next
      print
    }'
}

# Every endpoint found, one "file:line: VERB path" per line, ranked.
profile_routes_all() {
  local src=$1 f
  {
    # Only the server side: app/router/server verbs. An axios or fetch call
    # uses the same shape and would otherwise look like a route it serves.
    # The leading class is the word boundary; `\b` is not in every grep.
    grep -rnoE "(^|[^A-Za-z0-9_])(app|router|server|routes)\.(get|post|put|patch|delete)\([[:space:]]*['\"\`][^'\"\`]{1,60}" "$src/" \
      --include='*.js' --include='*.ts' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      profile_routes_uncommented "$src" |
      profile_route_lines "$src" |
      grep -E ' (GET|POST|PUT|PATCH|DELETE) ' || true

    grep -rnoE "@(Get|Post|Put|Patch|Delete|Controller)\([[:space:]]*['\"][^'\"]{0,60}" "$src/" \
      --include='*.ts' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      profile_routes_uncommented "$src" |
      profile_route_lines "$src" || true

    grep -rnoE "Parse\.Cloud\.(define|job)\([[:space:]]*['\"][^'\"]{1,60}" "$src/" \
      --include='*.js' --include='*.ts' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      profile_routes_uncommented "$src" |
      profile_route_lines "$src" CLOUD || true

    grep -rnoE "@(app|router|blueprint)\.(route|get|post|put|patch|delete)\([[:space:]]*['\"][^'\"]{1,60}" "$src/" \
      --include='*.py' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      profile_routes_uncommented "$src" |
      profile_route_lines "$src" || true

    # Next.js file routes, wherever a Next app keeps its `app/` or `pages/`: at
    # the root, under `src/`, and in each workspace package. A `(group)`
    # segment organizes files and is not part of the URL.
    local base bases=("" src/) d
    while IFS= read -r d; do
      [[ -n $d ]] && bases+=("$d/" "$d/src/")
    done < <(profile_workspace_dirs "$src")
    for base in "${bases[@]}"; do
      if [[ -d $src/${base}pages/api ]]; then
        find "$src/${base}pages/api" -type f \( -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.jsx' \) 2>/dev/null |
          while IFS= read -r f; do
            f=${f#"$src"/}
            echo "$f:1 ROUTE /$(B=$base awk '{ print substr($0, length(ENVIRON["B"]) + 7) }' <<<"$f" |
              sed -E 's|\.[jt]sx?$||; s|/index$||')"
          done
      fi
      if [[ -d $src/${base}app ]]; then
        find "$src/${base}app" -type f \( -name route.ts -o -name route.js -o -name route.tsx \
          -o -name route.jsx -o -name route.mjs \) 2>/dev/null |
          while IFS= read -r f; do
            f=${f#"$src"/}
            echo "$f:1 ROUTE $(B=$base awk '{ print substr($0, length(ENVIRON["B"]) + 4) }' <<<"$f" |
              sed -E 's|/?route\.m?[jt]sx?$||; s|/\([^/]*\)||g; s|^/?|/|')"
          done
      fi
    done

    [[ -f $src/config/routes.rb ]] &&
      grep -nE '^[[:space:]]*(get|post|put|patch|delete|resources)[[:space:]]' "$src/config/routes.rb" |
      sed -E "s|^|config/routes.rb:|" || true
  } 2>/dev/null | sed -E 's/[[:space:]]+/ /g' | LC_ALL=C sort -u |
    # Ranked by how many routes their file declares, before any cut: a routes
    # file is where a service says what it serves, and a stray match in a
    # helper or a comment sorts after it rather than ahead of it by name.
    awk '{ l[NR] = $0; f = $0; sub(/:.*/, "", f); k[NR] = f; n[f]++ }
         END { for (i = 1; i <= NR; i++) print n[k[i]] "\t" l[i] }' |
    LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
}

# How many endpoints the profile keeps. routes_total says how many there were.
PROFILE_ROUTES_MAX=40

# The endpoints the profile keeps, back in file and line order for reading.
profile_routes_cut() {
  head -"$PROFILE_ROUTES_MAX" | LC_ALL=C sort -t: -k1,1 -k2,2n | jq -Rn '[inputs | select(. != "")]'
}

# Endpoints this repo serves, with the file they were found in.
profile_routes() {
  profile_routes_all "$1" | profile_routes_cut
}

# Hosts this repo reaches out to, from literal URLs in source.
profile_calls() {
  local src=$1
  grep -rhoE 'https?://[a-zA-Z0-9._-]+' "$src/" \
    --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' \
    --include='*.py' --include='*.rb' --include='*.go' --include='*.env*' \
    --include='*.yml' --include='*.yaml' --include='*.json' \
    "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
    sed -E 's|https?://||' | sort -u |
    grep -vE "$NOISE_DOMAINS" |
    grep -vE '^(localhost|127\.0\.0\.1|0\.0\.0\.0|example\.)' |
    head -40 | jq -Rn '[inputs]'
}

# How this repo ships: one entry per workflow, with what triggers it and which
# of them actually deploy. A repo with no deploying workflow is a fact worth
# stating in a runbook, not a gap to paper over.
profile_workflows() {
  local src=$1
  local dir="$src/.github/workflows" f name triggers env actions deploys
  [[ -d $dir ]] || { echo '[]'; return 0; }

  {
    for f in "$dir"/*.yml "$dir"/*.yaml; do
      [[ -f $f ]] || continue
      name=$(grep -m1 -E '^name:' "$f" | sed -E 's/^name:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//' || true)
      [[ -n $name ]] || name=$(basename "$f")

      triggers=$(grep -oE '^[[:space:]]{0,4}(push|pull_request|workflow_dispatch|schedule|release|workflow_call|repository_dispatch):' "$f" |
        tr -d ' :' | sort -u | paste -sd, - || true)

      env=$(grep -m1 -oE '^[[:space:]]+environment:[[:space:]]*[^[:space:]]+' "$f" | awk '{print $2}' | tr -d '"' || true)

      actions=$(grep -ohE 'uses:[[:space:]]*[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' "$f" |
        sed -E 's/uses:[[:space:]]*//' | sort -u | head -6 | paste -sd, - || true)

      # A workflow deploys if it says so in its name, or if it uses an action
      # that only exists to deploy. Merely touching aws-actions is not enough —
      # every test job configures credentials too.
      deploys=false
      if grep -qiE '(^|[-_/])(deploy|release|publish|ship)' <<<"$(basename "$f") $name"; then
        deploys=true
      elif grep -qE 'uses:[[:space:]]*(akhileshns/heroku-deploy|superfly/flyctl-actions|amondnet/vercel-action|vercel/action|aws-actions/amazon-ecs-deploy-task-definition|JamesIves/github-pages-deploy-action|peaceiris/actions-gh-pages|appleboy/ssh-action|serverless/github-action)' "$f"; then
        deploys=true
      fi

      jq -n --arg file ".github/workflows/$(basename "$f")" --arg name "$name" \
        --arg on "$triggers" --arg env "$env" --arg actions "$actions" \
        --argjson deploys "$deploys" \
        '{file: $file, name: $name, deploys: $deploys,
          on: ($on | split(",") | map(select(. != ""))),
          environment: $env,
          actions: ($actions | split(",") | map(select(. != "")))}'
    done
  } 2>/dev/null | jq -s '.'
}

# Hosts this repo declares as its own — the other half of who-calls-whom.
profile_serves() {
  local src=$1 f
  {
    [[ -f $src/CNAME ]] && head -3 "$src/CNAME"
    [[ -f $src/public/CNAME ]] && head -3 "$src/public/CNAME"
    [[ -f $src/vercel.json ]] &&
      jq -r '(.alias // []) | if type == "array" then .[] else . end' "$src/vercel.json" 2>/dev/null
    while IFS= read -r f; do
      grep -oE '^[A-Z0-9_]*(SELF|PUBLIC|SITE|APP|BASE|SERVER|FRONTEND|CLIENT)[A-Z0-9_]*_URL=[^[:space:]]+' "$f" |
        sed -E 's|^[^=]+=||; s|https?://||; s|[/:].*$||'
    done < <(profile_env_files "$src")
    [[ -f $src/app.json ]] &&
      jq -r '.name // empty | if . == "" then empty else . + ".herokuapp.com" end' "$src/app.json" 2>/dev/null
  } 2>/dev/null |
    tr -d '"\r' | grep -vE '^[[:space:]]*$' |
    grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-z]{2,}$' |
    grep -vE "$NOISE_DOMAINS" | sort -u | head -10 | jq -Rn '[inputs]'
}

PROFILE_DOC_NAMES=(AGENTS.md CLAUDE.md CONTRIBUTING.md ARCHITECTURE.md docs/ARCHITECTURE.md
  .cursorrules .github/copilot-instructions.md)

# The instruction files a checkout carries, each file once. `AGENTS.md ->
# CLAUDE.md` is the usual way to serve two tools one text, and listing both
# names would show the same instructions twice. So two names that resolve to
# the same file are one entry, under the name that is the file itself — the
# link's own blob page shows nine bytes of path, not the text — and the other
# name is kept in profile_doc_aliases.
profile_docs_scan() {
  local src=$1 f real
  local -A at=()
  local names=() reals=()
  for f in "${PROFILE_DOC_NAMES[@]}"; do
    clone_file "$src" "$src/$f" || continue
    real=$(clone_realpath "$src/$f") || continue
    names+=("$f") reals+=("$real")
  done
  local i keep=()
  # The plain file claims its real path first, so a link never displaces it.
  for i in "${!names[@]}"; do
    [[ -L $src/${names[i]} ]] && continue
    [[ -n ${at[${reals[i]}]-} ]] || at[${reals[i]}]=${names[i]}
  done
  for i in "${!names[@]}"; do
    [[ -n ${at[${reals[i]}]-} ]] || at[${reals[i]}]=${names[i]}
    if [[ ${at[${reals[i]}]} == "${names[i]}" ]]; then
      keep+=("D ${names[i]}")
    else
      keep+=("A ${names[i]} ${at[${reals[i]}]}")
    fi
  done
  [[ ${#keep[@]} -eq 0 ]] || printf '%s\n' "${keep[@]}"
}

profile_docs() {
  profile_docs_scan "$1" | awk '$1 == "D" { print $2 }' | jq -Rn '[inputs | select(. != "")]'
}

# {"AGENTS.md": "CLAUDE.md"}: a name profile_docs left out because it is the
# same file as one it kept.
profile_doc_aliases() {
  profile_docs_scan "$1" | awk '$1 == "A" { print $2 "\t" $3 }' |
    jq -Rn '[inputs | split("\t") | select(length == 2) | {(.[0]): .[1]}] | add // {}'
}

# Writes one profile JSON for a repo. $1 repo, $2 checkout, $3 the repo's meta.
#
# The fields after agent_docs are additions, so every reader of the older shape
# keeps working: env_total and routes_total are the counts before the env and
# routes lists were cut, workspaces is [{dir, name, frameworks}] per package of
# a monorepo, and agent_doc_aliases maps a left-out instruction file name to the
# kept name it is the same file as.
profile_repo() {
  local repo=$1 src=$2 meta=$3 env_all routes_all
  # Filled here, in this shell, so every $(...) below reads the one walk — or
  # reused, when the scan worker already asked for this checkout.
  profile_workspace_dirs "$src" >/dev/null
  profile_workspace_facts "$src" >/dev/null
  profile_env_files "$src" >/dev/null
  env_all=$(profile_env_all "$src")
  routes_all=$(profile_routes_all "$src")
  jq -n \
    --arg name "$repo" \
    --argjson meta "$meta" \
    --argjson frameworks "$(profile_framework "$src")" \
    --argjson commands "$(profile_commands "$src")" \
    --argjson env "$(printf '%s' "$env_all" | head -"$PROFILE_ENV_MAX" | jq -Rn '[inputs | select(. != "")]')" \
    --argjson env_total "$(printf '%s' "$env_all" | grep -c . || true)" \
    --argjson routes "$(printf '%s' "$routes_all" | profile_routes_cut)" \
    --argjson routes_total "$(printf '%s' "$routes_all" | grep -c . || true)" \
    --argjson calls "$(profile_calls "$src")" \
    --argjson serves "$(profile_serves "$src")" \
    --argjson workflows "$(profile_workflows "$src")" \
    --argjson docs "$(profile_docs "$src")" \
    --argjson aliases "$(profile_doc_aliases "$src")" \
    --argjson workspaces "$(profile_workspaces "$src")" \
    '{name: $name, meta: $meta, frameworks: $frameworks, commands: $commands,
      env: $env, routes: $routes, calls: $calls, serves: $serves,
      workflows: $workflows, agent_docs: $docs,
      env_total: $env_total, routes_total: $routes_total,
      workspaces: $workspaces, agent_doc_aliases: $aliases}' \
    >"$EMITDIR/p-$repo.json"
  profile_workspace_forget
}
