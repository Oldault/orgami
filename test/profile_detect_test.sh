#!/usr/bin/env bash
# What `profile_framework` and `profile_commands` read off a checkout today.
#
# Every framework, package manager and runtime the profile knows about arrives
# as another branch inside these two functions, and nothing pins what the
# existing branches already answer — so a branch added for one framework can
# quietly change the answer for another. This is the harness those additions
# assert against.
#
# Nine things are under test, and the third is the quiet one:
#
#   - a dependency, a `manage.py`, a `go.mod` each name the framework behind
#     them, and a tree with none of them reports an empty list rather than a
#     guess
#   - React is only reported when nothing else was: `react` sits under Next.js,
#     React Native and Expo, so reporting it beside them would say the repo is
#     two frameworks. That is the `[[ ${#out[@]} -eq 0 ]]` guard, and it is what
#     a new meta-framework branch is most likely to walk past
#   - a meta-framework outranks the library it ships — SvelteKit over Svelte,
#     Nuxt over Vue, Astro over React — while a database client or an API layer
#     is reported beside the framework instead of displacing it
#   - the caps are caps, not coincidences: eight package.json scripts and six
#     Makefile targets, taken in file order
#   - `make` contributes only targets in the vocabulary, so a `deploy:` target
#     never lands in something a reader might run
#   - package_manager follows the documented precedence all the way down, one
#     lockfile at a time
#   - a repo with no package.json is read from the manifest it does have —
#     composer.json through jq, mix.exs through grep — and the name a bare
#     composer.json earns is a fallback, not a fourth PHP framework
#   - a build system and the framework built on top of it are separate facts and
#     both are said: Maven beside Spring Boot, .NET beside ASP.NET, with the
#     runtime version read out of the same file
#   - just and Task are read the way make is, down to the vocabulary, and the
#     Taskfile read is shallow on purpose — a key nested under a task is not a
#     task, and neither is a key in the block after `tasks:`
#
# Fixture trees in a temp directory. No checkout, no network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/profile.sh
source lib/profile.sh

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail=0

# A fresh empty checkout.
tree() { mktemp -d "$root/case.XXXXXX"; }

# profile_framework ends in `grep -v '^$'`, which reports "nothing matched" for
# a tree that has no framework in it at all. Under `set -o pipefail` that is a
# non-zero return even though the JSON on stdout is right, so what is asserted
# here is the document, never the status.
framework() { profile_framework "$1" || true; }

# Each assertion is a jq predicate over the whole document, so a failure can
# print what the function actually said instead of a fragment of it.
assert() {
  local what=$1 filter=$2 json=$3
  [[ $(jq -r "$filter" <<<"$json") == true ]] && return 0
  printf 'FAIL: %s\n  got: %s\n' "$what" "$(jq -c . <<<"$json")" >&2
  fail=1
}

# --- profile_framework ---------------------------------------------------------

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"dependencies": {"next": "14.2.3", "react": "18.3.1"}}
JSON
out=$(framework "$d")
assert "next in dependencies is Next.js" '. == ["Next.js"]' "$out"
assert "react beside next is not also React" '(index("React")) == null' "$out"

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"dependencies": {"express": "4.19.2"}}
JSON
assert "express in dependencies is Express" '. == ["Express"]' "$(framework "$d")"

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"dependencies": {"react": "18.3.1", "react-dom": "18.3.1"}}
JSON
assert "react on its own is React" '. == ["React"]' "$(framework "$d")"

d=$(tree)
printf 'import sys\n' >"$d/manage.py"
assert "manage.py is Django" '. == ["Django"]' "$(framework "$d")"

d=$(tree)
printf 'module example.com/m\n\ngo 1.22\n' >"$d/go.mod"
assert "go.mod is a Go module" '. == ["Go module"]' "$(framework "$d")"

d=$(tree)
printf 'a repo with nothing to go on\n' >"$d/README.md"
assert "a tree with no framework reports none" '. == []' "$(framework "$d")"

# --- frameworks that arrive as one dependency name -----------------------------

# A checkout whose whole content is a package.json declaring these dependencies.
# No version is ever read, so every one of them is "*".
deps() {
  local d
  d=$(tree)
  printf '%s\n' "$@" | jq -Rn '{dependencies: ([inputs | {(.): "*"}] | add // {})}' >"$d/package.json"
  echo "$d"
}

for f in astro:Astro nuxt:Nuxt '@sveltejs/kit:SvelteKit' '@remix-run/react:Remix' \
  '@angular/core:Angular' '@solidjs/start:SolidStart' '@builder.io/qwik:Qwik' \
  hono:Hono elysia:Elysia; do
  assert "${f%:*} in dependencies is ${f##*:}" \
    ". == [\"${f##*:}\"]" "$(framework "$(deps "${f%:*}")")"
done

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"devDependencies": {"@sveltejs/kit": "2.5.0"}}
JSON
assert "a framework declared as a devDependency counts too" \
  '. == ["SvelteKit"]' "$(framework "$d")"

# Each of these ships the library it is built on, so both names are in the
# dependency list and only the order of the branches keeps the repo from being
# reported as two things at once. This is the assertion a new meta-framework
# breaks by landing below the guarded line instead of above it.
assert "@sveltejs/kit beside svelte is SvelteKit and not Svelte" \
  '. == ["SvelteKit"]' "$(framework "$(deps @sveltejs/kit svelte)")"
assert "nuxt beside vue is Nuxt and not Vue" \
  '. == ["Nuxt"]' "$(framework "$(deps nuxt vue)")"
assert "astro beside react is Astro and not React" \
  '. == ["Astro"]' "$(framework "$(deps astro react react-dom)")"
assert "svelte on its own is still Svelte" '. == ["Svelte"]' "$(framework "$(deps svelte)")"
assert "vue on its own is still Vue" '. == ["Vue"]' "$(framework "$(deps vue)")"

# React Router is a framework only in framework mode. Every React SPA that
# routes at all has `react-router` in it, so the dependency on its own says
# nothing and `@react-router/dev` is the whole signal.
assert "react-router with @react-router/dev is React Router" \
  '. == ["React Router"]' "$(framework "$(deps react-router @react-router/dev react)")"
assert "react-router on its own leaves a React repo a React repo" \
  '. == ["React"]' "$(framework "$(deps react-router react react-dom)")"

# The other direction: a database client or an API layer says how the repo
# reaches its data, not what it is, so it is reported beside the framework
# rather than swallowing it. Sorted in jq, because the sort in the function is
# the shell's and follows the locale.
assert "a data or API library lands beside the framework, never instead of it" \
  '(sort) == ["Drizzle","Prisma","React","tRPC"]' \
  "$(framework "$(deps react react-dom prisma drizzle-orm @trpc/server)")"
assert "@prisma/client without the CLI is still Prisma" \
  '. == ["Prisma"]' "$(framework "$(deps @prisma/client)")"

# Both queue packages are named, and `-x` is what keeps the shorter one from
# matching the front of a longer package name.
assert "bull is a Bull queue" '. == ["Bull queue"]' "$(framework "$(deps bull)")"
assert "bullmq is a Bull queue" '. == ["Bull queue"]' "$(framework "$(deps bullmq)")"
assert "a package that merely starts with bull is not a queue" \
  '. == []' "$(framework "$(deps bullseye)")"

# --- PHP: a framework named by a file, or by composer.json ----------------------

# `artisan`, `bin/console` and `wp-config.php` are each the whole signal on
# their own: a WordPress site repo often has no manifest at all, and a checkout
# that never committed composer.json is still what it is.
d=$(tree)
printf '#!/usr/bin/env php\n' >"$d/artisan"
assert "artisan at the root is Laravel" '. == ["Laravel"]' "$(framework "$d")"

d=$(tree)
mkdir -p "$d/bin"
printf '#!/usr/bin/env php\n' >"$d/bin/console"
assert "bin/console is Symfony" '. == ["Symfony"]' "$(framework "$d")"

d=$(tree)
printf "<?php\ndefine('DB_NAME', 'wp');\n" >"$d/wp-config.php"
assert "wp-config.php is WordPress" '. == ["WordPress"]' "$(framework "$d")"

d=$(tree)
mkdir -p "$d/wp-content/themes/site"
assert "a committed wp-content is WordPress" '. == ["WordPress"]' "$(framework "$d")"

# A checkout whose whole content is a composer.json requiring these packages.
requires() {
  local d
  d=$(tree)
  printf '%s\n' "$@" | jq -Rn '{require: ([inputs | {(.): "*"}] | add // {})}' >"$d/composer.json"
  echo "$d"
}

assert "laravel/framework in composer.json is Laravel" \
  '. == ["Laravel"]' "$(framework "$(requires php laravel/framework)")"
assert "symfony/framework-bundle in composer.json is Symfony" \
  '. == ["Symfony"]' "$(framework "$(requires php symfony/framework-bundle)")"

d=$(tree)
cat >"$d/composer.json" <<'JSON'
{"require-dev": {"symfony/framework-bundle": "^7.0"}}
JSON
assert "a framework declared under require-dev counts too" \
  '. == ["Symfony"]' "$(framework "$d")"

# The fallback, and the pair of assertions a new PHP branch is most likely to
# break: a composer.json naming none of the three is the plain project, and one
# that names a framework is that framework and not the plain project as well.
d=$(tree)
cat >"$d/composer.json" <<'JSON'
{"require": {"php": "^8.2", "guzzlehttp/guzzle": "^7.8"}}
JSON
out=$(framework "$d")
assert "a bare composer.json is a plain Composer project" \
  '. == ["Composer project"]' "$out"
assert "a plain Composer project is not Laravel or Symfony" \
  '(index("Laravel")) == null and (index("Symfony")) == null' "$out"
assert "Laravel is not reported as a plain Composer project beside itself" \
  '. == ["Laravel"]' "$(framework "$(requires laravel/framework)")"

# --- Elixir: mix.exs, and what it says ------------------------------------------

# mix.exs is Elixir source rather than JSON, so grep is its reader. A checkout
# whose whole content is a mix.exs declaring these dependency lines.
mixfile() {
  local d
  d=$(tree)
  {
    printf 'defmodule M.MixProject do\n  defp deps do\n    [\n'
    printf '      %s,\n' "$@"
    printf '    ]\n  end\nend\n'
  } >"$d/mix.exs"
  echo "$d"
}

out=$(framework "$(mixfile '{:jason, "~> 1.4"}')")
assert "mix.exs on its own is an Elixir project" '. == ["Elixir project"]' "$out"
assert "an Elixir project without phoenix is not Phoenix" \
  '(index("Phoenix")) == null' "$out"

# Same guard as SvelteKit over Svelte: Phoenix is the concrete name, and
# "Elixir project" beside it would only repeat the category.
assert "{:phoenix, in mix.exs is Phoenix and not Elixir project" \
  '. == ["Phoenix"]' "$(framework "$(mixfile '{:phoenix, "~> 1.7"}')")"

d=$(mixfile '{:jason, "~> 1.4"}')
mkdir -p "$d/lib/my_app_web/controllers"
assert "a committed lib/<app>_web is Phoenix with no dependency line to read" \
  '. == ["Phoenix"]' "$(framework "$d")"

assert "ecto lands beside the framework, never instead of it" \
  '(sort) == ["Ecto","Phoenix"]' \
  "$(framework "$(mixfile '{:phoenix, "~> 1.7"}' '{:ecto_sql, "~> 3.11"}')")"

# --- the JVM: a build file, and the framework named inside it -------------------

# pom.xml is XML and a Gradle build file is Groovy or Kotlin, so grep reads
# both. The build system and the framework are separate facts about the repo,
# which is why Spring Boot arrives beside Maven and not instead of it.
d=$(tree)
cat >"$d/pom.xml" <<'XML'
<project>
  <properties><java.version>21</java.version></properties>
  <dependencies>
    <dependency><artifactId>spring-boot-starter-web</artifactId></dependency>
  </dependencies>
</project>
XML
assert "spring-boot-starter in a pom.xml is Spring Boot, beside Maven" \
  '(sort) == ["Maven","Spring Boot"]' "$(framework "$d")"

d=$(tree)
printf '<project><modelVersion>4.0.0</modelVersion></project>\n' >"$d/pom.xml"
out=$(framework "$d")
assert "a bare pom.xml is Maven" '. == ["Maven"]' "$out"
assert "a bare pom.xml is not Spring Boot" '(index("Spring Boot")) == null' "$out"

d=$(tree)
printf 'plugins { id "java" }\n' >"$d/build.gradle"
assert "build.gradle is Gradle" '. == ["Gradle"]' "$(framework "$d")"

d=$(tree)
printf 'dependencies { implementation("org.springframework.boot:spring-boot-starter-web") }\n' \
  >"$d/build.gradle.kts"
assert "the Kotlin build file is read for both facts too" \
  '(sort) == ["Gradle","Spring Boot"]' "$(framework "$d")"

# --- .NET: a project or solution file, and the SDK it builds with --------------

# A solution keeps its projects a directory or two down, so the fixture puts one
# there. ASP.NET is named twice over in a web project — the SDK and the package
# reference — and either one on its own is the signal.
d=$(tree)
mkdir -p "$d/src/Api"
cat >"$d/src/Api/Api.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup>
  <ItemGroup><PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" /></ItemGroup>
</Project>
XML
assert "a .csproj naming Microsoft.AspNetCore is ASP.NET, beside .NET" \
  '(sort) == [".NET","ASP.NET"]' "$(framework "$d")"

d=$(tree)
cat >"$d/Lib.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>netstandard2.1</TargetFramework></PropertyGroup>
</Project>
XML
out=$(framework "$d")
assert "a class library is .NET" '. == [".NET"]' "$out"
assert "a class library is not ASP.NET" '(index("ASP.NET")) == null' "$out"

d=$(tree)
printf 'Microsoft Visual Studio Solution File, Format Version 12.00\n' >"$d/App.sln"
assert "a solution file with no project beside it is still .NET" \
  '. == [".NET"]' "$(framework "$d")"

# --- profile_commands ----------------------------------------------------------

# Ten scripts match the vocabulary and three do not. Eight is the cap, and the
# eight are the first eight of the ten in file order. The three that do not
# match lead the file deliberately: further down, the cap alone would hide them
# and the filter could rot without anything noticing.
d=$(tree)
cat >"$d/package.json" <<'JSON'
{"scripts": {
  "deploy": "./deploy.sh",
  "postinstall": "patch-package",
  "release": "np",
  "dev": "next dev",
  "start": "next start",
  "build": "next build",
  "test": "vitest run",
  "test:watch": "vitest",
  "lint": "eslint .",
  "typecheck": "tsc --noEmit",
  "migrate": "prisma migrate deploy",
  "seed": "node seed.js",
  "e2e": "playwright test"
}}
JSON
out=$(profile_commands "$d")
assert "the first eight matching scripts survive, in file order" \
  '(.scripts | keys_unsorted) == ["dev","start","build","test","test:watch","lint","typecheck","migrate"]' \
  "$out"
assert "a script outside the vocabulary never lands" \
  '(.scripts | has("deploy") or has("postinstall") or has("release")) | not' "$out"
assert "a script keeps the command it runs" '.scripts.dev == "next dev"' "$out"

# Nine targets grep as targets, eight of them are in the vocabulary, six is the
# cap. `deploy` leads the file for the same reason it leads package.json: only
# the vocabulary keeps it out, so only a leading position tests the vocabulary.
# `Deploy` is not a target at all.
d=$(tree)
printf 'deploy:\n\t./deploy.sh\nDeploy:\ndev:\n\techo dev\nrun:\nstart:\nbuild:\ntest:\nlint:\ncheck:\nsetup:\n.PHONY: dev\n' >"$d/Makefile"
out=$(profile_commands "$d")
assert "six Makefile targets, in file order, prefixed with make" \
  '.scripts == {"dev":"make dev","run":"make run","start":"make start","build":"make build","test":"make test","lint":"make lint"}' \
  "$out"
assert "the seventh target is over the cap" '(.scripts | has("check")) | not' "$out"
assert "a target outside the vocabulary never lands" '(.scripts | has("deploy")) | not' "$out"

# The documented precedence, one lockfile at a time: each round asserts the top
# of the list wins, then removes it so the next one is on top.
d=$(tree)
touch "$d/pnpm-lock.yaml" "$d/yarn.lock" "$d/package-lock.json" "$d/Gemfile" \
  "$d/poetry.lock" "$d/requirements.txt"
touch "$d/composer.lock"
printf 'module example.com/m\n\ngo 1.22\n' >"$d/go.mod"
printf '[package]\nname = "m"\n' >"$d/Cargo.toml"
for m in pnpm-lock.yaml:pnpm yarn.lock:yarn package-lock.json:npm Gemfile:bundler \
  poetry.lock:poetry requirements.txt:pip go.mod:go Cargo.toml:cargo \
  composer.lock:composer; do
  assert "${m#*:} wins while ${m%%:*} is there" \
    ".package_manager == \"${m#*:}\"" "$(profile_commands "$d")"
  rm "$d/${m%%:*}"
done

d=$(tree)
printf 'v20.11.0\n' >"$d/.nvmrc"
assert ".nvmrc is the runtime, without its leading v" \
  '.runtime == "node 20.11.0"' "$(profile_commands "$d")"

d=$(tree)
cat >"$d/Procfile" <<'PROC'
web: node server.js
worker: node worker.js
release: ./bin/migrate
PROC
assert "every Procfile process is named, in file order" \
  '.procfile == ["web","worker","release"]' "$(profile_commands "$d")"

# composer.json scripts are read the way package.json scripts are: same
# vocabulary, same cap. A composer script may also be a list, which composer
# runs in order.
d=$(tree)
cat >"$d/composer.json" <<'JSON'
{"scripts": {
  "post-install-cmd": "@php artisan package:discover",
  "test": "phpunit",
  "lint": ["php-cs-fixer fix --dry-run", "phpstan analyse"],
  "migrate": "@php artisan migrate"
}}
JSON
out=$(profile_commands "$d")
assert "a composer script keeps the command it runs" '.scripts.test == "phpunit"' "$out"
assert "a composer script that is a list is joined in file order" \
  '.scripts.lint == "php-cs-fixer fix --dry-run && phpstan analyse"' "$out"
assert "a composer script outside the vocabulary never lands" \
  '(.scripts | has("post-install-cmd")) | not' "$out"

# Both manifests in one repo — a Laravel front end is the common case. composer
# fills what package.json did not say and never rewrites what it did.
d=$(tree)
printf '{"scripts": {"test": "vitest run"}}\n' >"$d/package.json"
printf '{"scripts": {"test": "phpunit", "migrate": "@php artisan migrate"}}\n' >"$d/composer.json"
out=$(profile_commands "$d")
assert "package.json keeps a name both manifests define" \
  '.scripts.test == "vitest run"' "$out"
assert "composer still contributes the names package.json left out" \
  '.scripts.migrate == "@php artisan migrate"' "$out"

# mix runs the tests of every Elixir project; phx.server exists only where
# Phoenix does.
d=$(tree)
printf 'defmodule M.MixProject do\nend\n' >"$d/mix.exs"
out=$(profile_commands "$d")
assert "mix.exs contributes mix test" '.scripts.test == "mix test"' "$out"
assert "a project with no Phoenix in it gets no server command" \
  '(.scripts | has("dev")) | not' "$out"

d=$(tree)
printf 'defmodule M.MixProject do\n  {:phoenix, "~> 1.7"}\nend\n' >"$d/mix.exs"
assert "a Phoenix project also gets mix phx.server" \
  '.scripts == {"dev": "mix phx.server", "test": "mix test"}' "$(profile_commands "$d")"

# mvn, gradle and dotnet run a project's tests with no script declaring it, and
# the same file carries the runtime version.
d=$(tree)
printf '<project><properties><java.version>21</java.version></properties></project>\n' >"$d/pom.xml"
out=$(profile_commands "$d")
assert "a pom.xml contributes mvn test" '.scripts.test == "mvn test"' "$out"
assert "<java.version> is the runtime" '.runtime == "java 21"' "$out"

# The wrapper is the command where the repo committed one, and only there.
d=$(tree)
printf 'plugins { id "java" }\n' >"$d/build.gradle"
assert "a Gradle project with no wrapper committed runs plain gradle" \
  '.scripts.test == "gradle test"' "$(profile_commands "$d")"
printf '#!/bin/sh\nexec gradle "$@"\n' >"$d/gradlew"
assert "a committed wrapper is what the command uses" \
  '.scripts.test == "./gradlew test"' "$(profile_commands "$d")"

d=$(tree)
mkdir -p "$d/src/Api"
cat >"$d/src/Api/Api.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
  <TargetFramework>net8.0</TargetFramework>
</PropertyGroup></Project>
XML
out=$(profile_commands "$d")
assert "a .csproj contributes dotnet test" '.scripts.test == "dotnet test"' "$out"
assert "<TargetFramework> is the runtime, as the toolchain writes it" \
  '.runtime == "dotnet net8.0"' "$out"

# just is read the way make is: the same vocabulary, the same cap, and a
# `deploy` recipe leading the file so only the vocabulary can keep it out.
d=$(tree)
cat >"$d/justfile" <<'JUST'
deploy:
    ./deploy.sh
_private:
    @echo hidden
test:
    cargo test
build:
    cargo build --release
JUST
out=$(profile_commands "$d")
assert "a justfile recipe becomes just <recipe>" \
  '.scripts.test == "just test" and .scripts.build == "just build"' "$out"
assert "a recipe outside the vocabulary never lands" \
  '(.scripts | has("deploy") or has("_private")) | not' "$out"

d=$(tree)
printf 'test:\n    pytest\n' >"$d/Justfile"
assert "a capitalized Justfile is read too" \
  '.scripts.test == "just test"' "$(profile_commands "$d")"

# The rule composer.json follows: a second file says what the first left out
# rather than rewriting it.
d=$(tree)
printf '{"scripts": {"test": "vitest run"}}\n' >"$d/package.json"
printf 'test:\n    just-test\nlint:\n    just-lint\n' >"$d/justfile"
out=$(profile_commands "$d")
assert "package.json keeps a name the justfile also defines" \
  '.scripts.test == "vitest run"' "$out"
assert "the justfile still contributes what package.json left out" \
  '.scripts.lint == "just lint"' "$out"

# The Taskfile read is two facts wide and no wider: two-space-indented keys
# under `tasks:`, ending at the next key in column one. `desc:` and `cmds:` are
# a task's own keys, and the `includes:` block deliberately follows `tasks:` so
# that a name in the vocabulary sits outside it.
d=$(tree)
cat >"$d/Taskfile.yml" <<'YAML'
version: '3'

vars:
  BIN: ./out/app

tasks:
  build:
    desc: compile the binary
    cmds:
      - go build -o {{.BIN}} .
  test:
    cmds:
      - go test ./...
  deploy:
    cmds:
      - ./deploy.sh

includes:
  lint: ./lint/Taskfile.yml
YAML
out=$(profile_commands "$d")
assert "a Taskfile task becomes task <name>" \
  '.scripts.build == "task build" and .scripts.test == "task test"' "$out"
assert "a task outside the vocabulary never lands" '(.scripts | has("deploy")) | not' "$out"
assert "a key nested under a task is not a task" \
  '(.scripts | has("cmds") or has("desc")) | not' "$out"
assert "the block after tasks: is not read as more tasks" \
  '(.scripts | has("lint")) | not' "$out"

d=$(tree)
printf "version: '3'\ntasks:\n  check:\n    cmds:\n      - ./script/check\n" >"$d/Taskfile.yaml"
assert "the .yaml spelling of the file is read too" \
  '.scripts.check == "task check"' "$(profile_commands "$d")"

d=$(tree)
printf 'a repo with nothing to run\n' >"$d/README.md"
assert "a tree with nothing to run says so in every field" \
  '. == {scripts: {}, package_manager: "", runtime: "", procfile: []}' \
  "$(profile_commands "$d")"

if [[ $fail -eq 0 ]]; then
  echo "profile_framework/profile_commands: read what is committed, capped and in order"
else
  exit 1
fi
