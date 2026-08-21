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

# Env vars that say nothing about the system.
ENV_NOISE='^(NODE_ENV|ENV|ENVIRONMENT|PORT|HOST|DEBUG|LOG_LEVEL|TZ|HOME|PATH|USER|PWD|CI|npm_.*|NEXT_RUNTIME|VERCEL.*)$'

# make targets, just recipes and Task tasks are all free-form names in a file
# that lists everything the repo ever does, deploys included. The same handful
# of names is what somebody actually needs in order to run the thing, so all
# three branches ask the same question and it is written down once.
RUN_VOCAB='^(dev|run|start|build|test|lint|check|setup|install|migrate)$'

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

profile_framework() {
  local src=$1
  local pkg="$src/package.json" out=()
  if [[ -f $pkg ]]; then
    local deps
    deps=$(jq -r '[(.dependencies // {}), (.devDependencies // {})] | add // {} | keys[]' "$pkg" 2>/dev/null || true)
    # Meta-frameworks lead the list. Each of them ships the library it is built
    # on as a dependency of its own, and the guarded `react`, `vue` and
    # `svelte` lines below only fire when nothing more specific matched — so a
    # SvelteKit repo has to reach `out` before the `svelte` line reads it, or
    # it reports the library instead of the framework.
    grep -qx 'next' <<<"$deps" && out+=("Next.js")
    grep -qx 'nuxt' <<<"$deps" && out+=("Nuxt")
    grep -qx '@sveltejs/kit' <<<"$deps" && out+=("SvelteKit")
    grep -qx 'astro' <<<"$deps" && out+=("Astro")
    grep -qx '@remix-run/react' <<<"$deps" && out+=("Remix")
    # React Router is the framework only in its framework mode. As a plain
    # dependency it is the router a React SPA imports, and the repo is a React
    # repo; `@react-router/dev` is what tells the two apart.
    grep -qx 'react-router' <<<"$deps" && grep -qx '@react-router/dev' <<<"$deps" &&
      out+=("React Router")
    grep -qx '@angular/core' <<<"$deps" && out+=("Angular")
    grep -qx '@solidjs/start' <<<"$deps" && out+=("SolidStart")
    grep -qx '@builder.io/qwik' <<<"$deps" && out+=("Qwik")
    grep -qx '@nestjs/core' <<<"$deps" && out+=("NestJS")
    grep -qx 'express' <<<"$deps" && out+=("Express")
    grep -qx 'fastify' <<<"$deps" && out+=("Fastify")
    grep -qx 'koa' <<<"$deps" && out+=("Koa")
    grep -qx 'hono' <<<"$deps" && out+=("Hono")
    grep -qx 'elysia' <<<"$deps" && out+=("Elysia")
    grep -qx 'parse-server' <<<"$deps" && out+=("Parse Server")
    grep -qx 'parse' <<<"$deps" && out+=("Parse SDK")
    grep -qx 'react-native' <<<"$deps" && out+=("React Native")
    grep -qx 'expo' <<<"$deps" && out+=("Expo")
    grep -qx 'react' <<<"$deps" && [[ ${#out[@]} -eq 0 ]] && out+=("React")
    grep -qx 'vue' <<<"$deps" && [[ ${#out[@]} -eq 0 ]] && out+=("Vue")
    grep -qx 'svelte' <<<"$deps" && [[ ${#out[@]} -eq 0 ]] && out+=("Svelte")
    # These name how a repo reaches its database or its own API, not what it
    # is, so they sit beside the framework rather than instead of it — after
    # the guarded lines, never before them.
    grep -qx '@trpc/server' <<<"$deps" && out+=("tRPC")
    grep -qxE 'prisma|@prisma/client' <<<"$deps" && out+=("Prisma")
    grep -qx 'drizzle-orm' <<<"$deps" && out+=("Drizzle")
    grep -qx 'agenda' <<<"$deps" && out+=("Agenda jobs")
    # `-x` takes one whole-line pattern, and `\|` is a GNU extension to BRE
    # that BSD grep reads as a literal pipe — so on macOS this line matched
    # nothing at all. -E says alternation in the one dialect both agree on.
    grep -qxE 'bullmq|bull' <<<"$deps" && out+=("Bull queue")
    grep -qx 'serverless' <<<"$deps" && out+=("Serverless")
  fi
  [[ -f $src/manage.py ]] && out+=("Django")
  grep -rqlE '^from fastapi import|FastAPI\(' "$src" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null && out+=("FastAPI")
  grep -rqlE '^from flask import|Flask\(__name__\)' "$src" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null && out+=("Flask")
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

profile_commands() {
  local src=$1
  local pkg="$src/package.json" cmds='{}'

  if [[ -f $pkg ]]; then
    cmds=$(jq -c '(.scripts // {})
      | with_entries(select(.key | test("^(dev|start|build|test|lint|typecheck|migrate|seed|e2e)")))
      | to_entries | .[0:8] | from_entries' "$pkg" 2>/dev/null || echo '{}')
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
    local targets
    targets=$(grep -oE '^[a-z][a-z0-9_-]*:' "$src/Makefile" | tr -d ':' |
      grep -E "$RUN_VOCAB" | head -6 || true)
    [[ -n $targets ]] && cmds=$(jq -c --argjson t "$(jq -Rn '[inputs]' <<<"$targets")" \
      '. + ($t | map({(.): ("make " + .)}) | add // {})' <<<"$cmds")
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
  [[ -f $src/Procfile ]] &&
    procfile=$(grep -oE '^[a-z]+:' "$src/Procfile" | tr -d ':' | jq -Rn '[inputs]')

  jq -n --argjson scripts "$cmds" --arg pm "$pm" --arg runtime "$runtime" \
    --argjson procs "$procfile" \
    '{scripts: $scripts, package_manager: $pm, runtime: $runtime, procfile: $procs}'
}

profile_env() {
  local src=$1
  {
    grep -rhoE 'process\.env\.[A-Z][A-Z0-9_]{2,}' "$src" "${PROFILE_EXCL[@]}" 2>/dev/null |
      sed 's/process\.env\.//'
    grep -rhoE "os\.environ(\.get)?[\[(]['\"][A-Z][A-Z0-9_]{2,}" "$src" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null |
      grep -oE "[A-Z][A-Z0-9_]{2,}$"
    grep -rhoE "ENV\[['\"][A-Z][A-Z0-9_]{2,}" "$src" --include='*.rb' "${PROFILE_EXCL[@]}" 2>/dev/null |
      grep -oE "[A-Z][A-Z0-9_]{2,}$"
    for f in .env.example .env.sample .env.template; do
      [[ -f $src/$f ]] && grep -oE '^[A-Z][A-Z0-9_]{2,}=' "$src/$f" | tr -d '='
    done
  } 2>/dev/null | sort -u | grep -vE "$ENV_NOISE" | head -60 | jq -Rn '[inputs]'
}

# Endpoints this repo serves, with the file they were found in.
profile_routes() {
  local src=$1
  {
    # Only the server side: app/router/server verbs. An axios or fetch call
    # uses the same shape and would otherwise look like a route it serves.
    grep -rnoE "\b(app|router|server|routes)\.(get|post|put|patch|delete)\(\s*['\"\`][^'\"\`]{1,60}" "$src" \
      --include='*.js' --include='*.ts' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/\b(app|router|server|routes)\.(get|post|put|patch|delete)\(\s*['\"\`]/ \U\2\E /" |
      grep -E ' (GET|POST|PUT|PATCH|DELETE) ' || true

    grep -rnoE "@(Get|Post|Put|Patch|Delete|Controller)\(\s*['\"][^'\"]{0,60}" "$src" \
      --include='*.ts' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/@([A-Za-z]+)\(\s*['\"]/ \U\1\E /" || true

    grep -rnoE "Parse\.Cloud\.(define|job)\(\s*['\"][^'\"]{1,60}" "$src" \
      --include='*.js' --include='*.ts' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/Parse\.Cloud\.(define|job)\(\s*['\"]/ CLOUD /" || true

    grep -rnoE "@(app|router|blueprint)\.(route|get|post|put|patch|delete)\(\s*['\"][^'\"]{1,60}" "$src" \
      --include='*.py' "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/@[a-z_]+\.([a-z]+)\(\s*['\"]/ \U\1\E /" || true

    if [[ -d $src/pages/api ]]; then
      find "$src/pages/api" -type f \( -name '*.ts' -o -name '*.js' -o -name '*.tsx' \) 2>/dev/null |
        sed -E "s|^$src/||" | while read -r f; do
          echo "$f:1 ROUTE /$(sed -E 's|^pages/||; s|\.[jt]sx?$||; s|/index$||' <<<"$f")"
        done
    fi
    if [[ -d $src/app ]]; then
      find "$src/app" -type f -name 'route.ts' -o -path "$src/app/*" -name 'route.js' 2>/dev/null |
        sed -E "s|^$src/||" | while read -r f; do
          echo "$f:1 ROUTE /$(sed -E 's|^app/||; s|/route\.[jt]s$||' <<<"$f")"
        done
    fi

    [[ -f $src/config/routes.rb ]] &&
      grep -nE '^\s*(get|post|put|patch|delete|resources)\s' "$src/config/routes.rb" |
      sed -E "s|^|config/routes.rb:|" || true
  } 2>/dev/null | sed 's/[[:space:]]\+/ /g' | sort -u | head -40 | jq -Rn '[inputs]'
}

# Hosts this repo reaches out to, from literal URLs in source.
profile_calls() {
  local src=$1
  grep -rhoE 'https?://[a-zA-Z0-9._-]+' "$src" \
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
      name=$(grep -m1 -E '^name:' "$f" | sed -E 's/^name:\s*//; s/^["'"'"']//; s/["'"'"']$//' || true)
      [[ -n $name ]] || name=$(basename "$f")

      triggers=$(grep -oE '^\s{0,4}(push|pull_request|workflow_dispatch|schedule|release|workflow_call|repository_dispatch):' "$f" |
        tr -d ' :' | sort -u | paste -sd, - || true)

      env=$(grep -m1 -oE '^\s+environment:\s*\S+' "$f" | awk '{print $2}' | tr -d '"' || true)

      actions=$(grep -ohE 'uses:\s*[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' "$f" |
        sed -E 's/uses:\s*//' | sort -u | head -6 | paste -sd, - || true)

      # A workflow deploys if it says so in its name, or if it uses an action
      # that only exists to deploy. Merely touching aws-actions is not enough —
      # every test job configures credentials too.
      deploys=false
      if grep -qiE '(^|[-_/])(deploy|release|publish|ship)' <<<"$(basename "$f") $name"; then
        deploys=true
      elif grep -qE 'uses:\s*(akhileshns/heroku-deploy|superfly/flyctl-actions|amondnet/vercel-action|vercel/action|aws-actions/amazon-ecs-deploy-task-definition|JamesIves/github-pages-deploy-action|peaceiris/actions-gh-pages|appleboy/ssh-action|serverless/github-action)' "$f"; then
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
    for f in .env.example .env.sample .env.template; do
      [[ -f $src/$f ]] || continue
      grep -oE '^[A-Z0-9_]*(SELF|PUBLIC|SITE|APP|BASE|SERVER|FRONTEND|CLIENT)[A-Z0-9_]*_URL=\S+' "$src/$f" |
        sed -E 's|^[^=]+=||; s|https?://||; s|[/:].*$||'
    done
    [[ -f $src/app.json ]] &&
      jq -r '.name // empty | if . == "" then empty else . + ".herokuapp.com" end' "$src/app.json" 2>/dev/null
  } 2>/dev/null |
    tr -d '"\r' | grep -vE '^\s*$' |
    grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-z]{2,}$' |
    grep -vE "$NOISE_DOMAINS" | sort -u | head -10 | jq -Rn '[inputs]'
}

profile_docs() {
  local src=$1 f out=()
  for f in AGENTS.md CLAUDE.md CONTRIBUTING.md ARCHITECTURE.md docs/ARCHITECTURE.md \
    .cursorrules .github/copilot-instructions.md; do
    [[ -f $src/$f ]] && out+=("$f")
  done
  printf '%s\n' "${out[@]:-}" | grep -v '^$' | jq -Rn '[inputs]'
}

# Writes one profile JSON for a repo. $1 repo, $2 checkout, $3 the repo's meta.
profile_repo() {
  local repo=$1 src=$2 meta=$3
  jq -n \
    --arg name "$repo" \
    --argjson meta "$meta" \
    --argjson frameworks "$(profile_framework "$src")" \
    --argjson commands "$(profile_commands "$src")" \
    --argjson env "$(profile_env "$src")" \
    --argjson routes "$(profile_routes "$src")" \
    --argjson calls "$(profile_calls "$src")" \
    --argjson serves "$(profile_serves "$src")" \
    --argjson workflows "$(profile_workflows "$src")" \
    --argjson docs "$(profile_docs "$src")" \
    '{name: $name, meta: $meta, frameworks: $frameworks, commands: $commands,
      env: $env, routes: $routes, calls: $calls, serves: $serves,
      workflows: $workflows, agent_docs: $docs}' \
    >"$EMITDIR/p-$repo.json"
}
