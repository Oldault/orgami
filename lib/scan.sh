# shellcheck shell=bash
# orgami scan — walk every repo in the org and write map/graph.json.
# Every edge carries file:line evidence. Nothing in the graph is a model's guess.

NOISE_DOMAINS='github\.com|githubusercontent\.com|githubapp\.com|docker\.io|ghcr\.io|quay\.io|npmjs\.(org|com)|rubygems\.org|pypi\.org|crates\.io|golang\.org|k8s\.io|kubernetes\.io|apache\.org|w3\.org|schema\.org|example\.(com|org)|localhost|\.local$|\.test$|nodejs\.org|python\.org|ubuntu\.com|debian\.org|alpinelinux\.org|letsencrypt\.org|sentry\.io|json-schema\.org'

emit_node() {
  local meta=${4:-}
  [[ -n $meta ]] || meta='{}'
  jq -cn --arg id "$1" --arg kind "$2" --arg name "$3" --argjson meta "$meta" \
    '{t:"node", id:$id, kind:$kind, name:$name, meta:$meta}' >>"$EMIT"
}

# emit_edge <from> <to> <kind> [evidence] [confidence] [signal]
#
# `signal` names which kind of fact matched, where the caller knows — a vendor
# edge records whether it came from a package manifest or an environment
# variable. Every other caller leaves it empty, and readers fall back to
# classifying the evidence path.
#
# `confidence` is the same distinction graphify draws, and orgami needs it for
# the same reason: most edges here are *extracted* — a literal string sat in a
# committed file, and the evidence is the file:line you can open. A few are
# *inferred* — nothing declared them, they were resolved by matching one repo's
# reading against another's. Both are useful; only one is checkable, and a map
# that does not say which is which is quietly lying about the difference.
# Extracted is the default because every caller in this file matched a file.
emit_edge() {
  jq -cn --arg from "$1" --arg to "$2" --arg kind "$3" --arg evidence "${4-}" \
    --arg confidence "${5:-extracted}" --arg signal "${6-}" \
    '{t:"edge", from:$from, to:$to, kind:$kind, evidence:$evidence,
      confidence:$confidence}
     + (if $signal == "" then {} else {signal: $signal} end)' >>"$EMIT"
}

# emit_tool <repo> <tool> <evidence-file>
emit_tool() {
  emit_node "tool:$2" tool "$2"
  emit_edge "repo:$1" "tool:$2" uses "$3"
}

# Reads one value out of a JSON or JSONC file, with jq and only with jq.
#
# `wrangler.jsonc` is the reason this exists: JSONC is not JSON, jq cannot read
# a comment, and the file wrangler itself generates opens with a block comment.
# So the plain read is tried first, and only if that fails are comment *lines*
# removed so jq gets something it can parse. Nothing else is touched and no
# value is ever read by anything but jq. A file still not JSON after that (a
# trailing comma, say) yields nothing, and the repo keeps its tool edge without
# the host — one file's failure never aborts the scan.
read_jsonc() {
  local file=$1 filter=$2 out
  out=$(jq -r "$filter" "$file" 2>/dev/null) && { printf '%s\n' "$out"; return 0; }
  sed -E '\%^[[:space:]]*//%d; \%^[[:space:]]*/\*%,\%\*/%d' "$file" |
    jq -r "$filter" 2>/dev/null || true
}

# Hosts and domains found in a config file, minus registry/vendor noise.
# $4 is the edge kind: deploys-to for deploy targets, reaches for dependencies.
emit_hosts_from() {
  local repo=$1 file=$2 rel=$3 kind=${4:-deploys-to} tok line
  [[ -f $file ]] || return 0
  # Digit runs of any length, then the octet shape checked here: `\b` is not in
  # every grep, and without it `1234.5.6.7` would yield `234.5.6.7`.
  grep -noE '([0-9]+\.){3}[0-9]+|([a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)+\.[a-z]{2,})' "$file" 2>/dev/null |
    while IFS=: read -r line tok; do
      [[ $tok =~ ^[0-9.]+$ && ! $tok =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && continue
      [[ $tok =~ ^(0\.0\.0\.0|127\.0\.0\.1|255\.|1\.0\.0|0\.0\.0)  ]] && continue
      # 10.0.0.0 is a network (an allow-list's 10.0.0.0/8) and 192.168.1.255 a
      # broadcast address, not hosts, and `tarif.spec.ts` or `app.config.js` is
      # a file a comment names: no such top-level domain exists. Nested example
      # env files are full of all three.
      [[ $tok =~ ^[0-9.]+\.(0|255)$ ]] && continue
      [[ $tok =~ \.(ts|tsx|js|jsx|mjs|cjs|json|ya?ml|lock|txt|html?|css|scss|env|toml|map|png|jpe?g|svg)$ ]] && continue
      echo "$tok" | grep -qE "$NOISE_DOMAINS" && continue
      [[ $tok =~ ^[0-9.]+$ ]] || [[ $tok == *.* ]] || continue
      emit_node "host:$tok" host "$tok"
      emit_edge "repo:$repo" "host:$tok" "$kind" "$rel:$line"
    done || true
}

# What a deploy walk skips on top of PROFILE_PRUNE: a compose file or a
# Dockerfile under tests, fixtures, examples, templates or a playground is how
# somebody tests or shows the tool, not how this repo ships. `.terraform` holds downloaded modules.
SCAN_PRUNE=(-o -name test -o -name tests -o -name e2e -o -name spec
  -o -name .terraform -o -name fixtures -o -name testdata -o -name mocks
  -o -name __tests__ -o -name __fixtures__ -o -name examples -o -name example
  -o -name templates -o -name playground)

# scan_files <checkout> <maxdepth> <find name test...> — committed files that
# match, relative to the checkout, the root's first and then by depth and byte
# order. Infra lives in docker/, hosts/<box>/services/<app>/, infrastructure/
# and apps/<pkg>/ as often as at the root, so the walk goes five levels down;
# the order is fixed so the file a rescan cites is the file the last one cited.
scan_files() {
  local src=$1 depth=$2 f r s
  shift 2
  find "$src" -mindepth 1 -maxdepth "$depth" -type d \( "${PROFILE_PRUNE[@]}" "${SCAN_PRUNE[@]}" \) -prune \
    -o -type f \( "$@" \) -print 2>/dev/null |
    while IFS= read -r f; do
      r=${f#"$src"/}
      s=${r//[!\/]/}
      printf '%d\t%s\n' "${#s}" "$r"
    done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2 | cut -f2- | head -40 || true
}

# scan_first <tab-separated key/evidence lines> — the first evidence for each
# key, so a repo with five S3_* names or three compose files declaring postgres
# gets one edge, citing the line that said it first.
scan_first() { awk -F '\t' 'NF > 1 && !seen[$1]++'; }

# scan_wrangler <repo> <checkout> <config file>
# A Pages project (`pages_build_output_dir`) cites that line, so the edge says
# which of the two products it is. A route's pattern is a host when it names
# one: `api.example.com/*` is, `*example.com/*` is a wildcard and is not.
scan_wrangler() {
  local repo=$1 src=$2 cf=$3 line pat h
  if [[ $cf == *.toml ]]; then
    line=$(grep -n -m1 -E '^[[:space:]]*pages_build_output_dir[[:space:]]*=' "$src/$cf" | cut -d: -f1) || true
  elif [[ -n $(read_jsonc "$src/$cf" '.pages_build_output_dir // empty | strings') ]]; then
    # jq says the key is there; grep only finds the line to cite.
    line=$(grep -n -m1 -E '^[[:space:]]*"pages_build_output_dir"' "$src/$cf" | cut -d: -f1) || true
  fi
  emit_tool "$repo" cloudflare "$cf${line:+:$line}"

  if [[ $cf == *.toml ]]; then
    grep -noE '(^[[:space:]]*route|pattern)[[:space:]]*=[[:space:]]*"[^"]+"' "$src/$cf" 2>/dev/null |
      while IFS=: read -r line pat; do
        pat=${pat#*\"}
        printf '%s\t%s\n' "${pat%\"}" "$line"
      done
  else
    read_jsonc "$src/$cf" '[.route?, (.routes // [] | .[]? | if type == "object" then .pattern else . end)
      | strings] | unique | .[]' |
      while IFS= read -r pat; do
        line=$(grep -nF -m1 -- "\"$pat\"" "$src/$cf" | cut -d: -f1) || true
        [[ -n $line ]] && printf '%s\t%s\n' "$pat" "$line"
      done
  fi | while IFS=$'\t' read -r pat line; do
    h=${pat#*://}
    h=${h%%/*}
    [[ $h =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]] || continue
    printf '%s\t%s:%s\n' "$h" "$cf" "$line"
  done | scan_first | while IFS=$'\t' read -r h line; do
    emit_node "host:$h" host "$h"
    emit_edge "repo:$repo" "host:$h" deploys-to "$line"
  done || true
}

scan_deploy() {
  local repo=$1 src=$2 f line

  [[ -d $src/.github/workflows ]] && {
    emit_tool "$repo" github-actions ".github/workflows"
    grep -rhoE 'uses:[[:space:]]*[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' "$src/.github/workflows" 2>/dev/null |
      sed -E 's/uses:[[:space:]]*//' | sort -u | while read -r action; do
        case $action in
          superfly/*|*flyctl*) emit_tool "$repo" fly ".github/workflows ($action)" ;;
          amondnet/vercel-action|vercel/*) emit_tool "$repo" vercel ".github/workflows ($action)" ;;
          aws-actions/*) emit_tool "$repo" aws ".github/workflows ($action)" ;;
          google-github-actions/*) emit_tool "$repo" gcp ".github/workflows ($action)" ;;
          azure/*) emit_tool "$repo" azure ".github/workflows ($action)" ;;
          docker/build-push-action) emit_tool "$repo" docker-registry ".github/workflows ($action)" ;;
          hashicorp/setup-terraform) emit_tool "$repo" terraform ".github/workflows ($action)" ;;
          appleboy/ssh-action|appleboy/scp-action) emit_tool "$repo" ssh-deploy ".github/workflows ($action)" ;;
        esac
      done
  }

  # Dockerfile.frontend, api.Dockerfile and docker/Dockerfile count as much as
  # the root's. The evidence is the first FROM line of the first one found.
  local dockerfiles
  dockerfiles=$(scan_files "$src" 5 \( -name Dockerfile -o -name 'Dockerfile.*' \
    -o -name '*.Dockerfile' -o -name '*.dockerfile' \) ! -name '*.dockerignore')
  if [[ -n $dockerfiles ]]; then
    f=${dockerfiles%%$'\n'*}
    line=$(grep -n -m1 -iE '^[[:space:]]*FROM[[:space:]]' "$src/$f" 2>/dev/null | cut -d: -f1) || true
    emit_tool "$repo" docker "$f${line:+:$line}"
  fi
  [[ -f $src/.gitlab-ci.yml ]] && emit_tool "$repo" gitlab-ci .gitlab-ci.yml
  [[ -f $src/Jenkinsfile ]] && emit_tool "$repo" jenkins Jenkinsfile
  [[ -f $src/.circleci/config.yml ]] && emit_tool "$repo" circleci .circleci/config.yml
  [[ -f $src/netlify.toml ]] && emit_tool "$repo" netlify netlify.toml
  [[ -f $src/vercel.json ]] && emit_tool "$repo" vercel vercel.json
  [[ -f $src/render.yaml ]] && emit_tool "$repo" render render.yaml
  [[ -f $src/serverless.yml ]] && emit_tool "$repo" serverless serverless.yml
  [[ -f $src/Chart.yaml ]] && emit_tool "$repo" helm Chart.yaml
  [[ -f $src/Procfile ]] && emit_tool "$repo" procfile Procfile
  [[ -f $src/ansible.cfg ]] && emit_tool "$repo" ansible ansible.cfg
  [[ -f $src/captain-definition ]] && emit_tool "$repo" caprover captain-definition
  [[ -f $src/supabase/config.toml ]] && emit_tool "$repo" supabase supabase/config.toml

  if [[ -f $src/fly.toml ]]; then
    emit_tool "$repo" fly fly.toml
    local app
    app=$(grep -m1 -oE '^app[[:space:]]*=[[:space:]]*"?[a-z0-9-]+' "$src/fly.toml" | grep -oE '[a-z0-9-]+$' || true)
    [[ -n $app ]] && {
      emit_node "host:$app.fly.dev" host "$app.fly.dev"
      emit_edge "repo:$repo" "host:$app.fly.dev" deploys-to fly.toml
    }
  fi

  # Cloudflare Workers and Pages. Three spellings of one config, and the first
  # one found wins, so a repo carrying both never gets two edges saying the same
  # thing. The config's `name` is not a hostname: a worker is served at
  # <name>.<account subdomain>.workers.dev, and a Pages project at a pages.dev
  # name Cloudflare suffixes when the plain one is taken. Neither second half is
  # in any committed file, so the only hosts taken from here are the routes and
  # custom domains the config declares outright.
  local cf
  for cf in wrangler.toml wrangler.jsonc wrangler.json; do
    [[ -f $src/$cf ]] || continue
    scan_wrangler "$repo" "$src" "$cf"
    break
  done

  for f in railway.json railway.toml; do
    [[ -f $src/$f ]] && { emit_tool "$repo" railway "$f"; break; }
  done

  # Coolify keeps its own directory when it manages the repo. `coolify.json`
  # alone is too plain a filename to claim a deploy target on its own, so it
  # counts only next to the compose file it configures.
  if [[ -d $src/.coolify ]]; then
    emit_tool "$repo" coolify .coolify
  elif [[ -f $src/coolify.json ]]; then
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
      [[ -f $src/$f ]] && { emit_tool "$repo" coolify coolify.json; break; }
    done
  fi

  # Dokku and Heroku both read `app.json`, and profile_serves already reads it
  # for a Heroku hostname — the filename proves nothing on its own. What Dokku
  # added to the format is what counts: `scripts.dokku` (its predeploy and
  # postdeploy hooks), `healthchecks` and `cron` are Dokku's own keys, and a
  # Heroku app.json — name, env, buildpacks, formation, addons — carries none
  # of them. Failing that, a `.dokku-*` file names the platform outright.
  local dokku=""
  [[ -f $src/app.json ]] && jq -e 'type == "object"
      and (has("healthchecks") or has("cron")
           or ((.scripts | type) == "object" and (.scripts | has("dokku"))))' \
    "$src/app.json" >/dev/null 2>&1 && dokku=app.json
  if [[ -z $dokku ]]; then
    for f in "$src"/.dokku-*; do
      [[ -e $f ]] && { dokku=${f#"$src"/}; break; }
    done
  fi
  [[ -n $dokku ]] && emit_tool "$repo" dokku "$dokku"

  # AWS SAM is a CloudFormation template with the Serverless transform in it. A
  # template.yaml without that is plain CloudFormation or somebody else's
  # template, so the evidence is the line the transform is on, not the file.
  for f in template.yaml template.yml; do
    [[ -f $src/$f ]] || continue
    line=$(grep -n -m1 'AWS::Serverless::' "$src/$f" | cut -d: -f1) || true
    [[ -n $line ]] && { emit_tool "$repo" aws-sam "$f:$line"; break; }
  done

  # cdk.json is a CDK app only when it says how to run one, which is `app`.
  [[ -f $src/cdk.json ]] &&
    jq -e 'type == "object" and has("app")' "$src/cdk.json" >/dev/null 2>&1 &&
    emit_tool "$repo" aws-cdk cdk.json

  for f in config/deploy.yml deploy.yml .kamal/deploy.yml; do
    [[ -f $src/$f ]] || continue
    grep -q '^servers:' "$src/$f" || continue
    emit_tool "$repo" kamal "$f"
    emit_hosts_from "$repo" "$src/$f" "$f" deploys-to
  done

  # Terraform wherever the modules are kept: the root, terraform/, infra/,
  # infrastructure/modules/<name>/. Each provider is cited at the first line
  # that declares it.
  local tfs
  tfs=$(scan_files "$src" 4 -name '*.tf')
  if [[ -n $tfs ]]; then
    emit_tool "$repo" terraform "${tfs%%$'\n'*}"
    while IFS= read -r f; do
      grep -noE '^[[:space:]]*provider[[:space:]]+"[a-z0-9_]+"' "$src/$f" 2>/dev/null |
        while IFS=: read -r line p; do
          p=${p#*\"}
          printf '%s\t%s:%s\n' "${p%\"}" "$f" "$line"
        done
    done <<<"$tfs" | scan_first | while IFS=$'\t' read -r p line; do
      emit_tool "$repo" "$p" "$line"
    done || true
  fi

  local kf
  kf=$(grep -rlE '^kind:[[:space:]]*(Deployment|StatefulSet|Ingress)' "$src/" \
    --include='*.yaml' --include='*.yml' "${PROFILE_EXCL[@]}" 2>/dev/null | LC_ALL=C sort | head -1 || true)
  [[ -n $kf ]] && {
    emit_tool "$repo" kubernetes "${kf#"$src"/}"
    # `- host:` is how an Ingress rule spells it; each host cites its first line.
    grep -rnE '^[[:space:]]*(-[[:space:]]+)?host:[[:space:]]*[a-z0-9.-]+' "$src/" \
      --include='*.yaml' --include='*.yml' "${PROFILE_EXCL[@]}" 2>/dev/null |
      LC_ALL=C sort -t: -k1,1 -k2,2n | while IFS=: read -r f line h; do
        h=${h#*host:}
        h=${h%%#*}
        h=${h//[[:space:]\"\']/}
        [[ $h =~ ^[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+$ ]] || continue
        echo "$h" | grep -qE "$NOISE_DOMAINS" && continue
        printf '%s\t%s:%s\n' "$h" "${f#"$src"/}" "$line"
      done | scan_first | while IFS=$'\t' read -r h line; do
        emit_node "host:$h" host "$h"
        emit_edge "repo:$repo" "host:$h" deploys-to "$line"
      done || true
  }

  # Compose files wherever they sit — docker/docker-compose.prod.yml,
  # hosts/<box>/services/<app>/docker-compose.yml — one tool edge citing the
  # first, and one edge per backing service citing the image line that named it
  # first, whichever file that was in.
  local composes
  composes=$(scan_files "$src" 5 -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
    -o -name compose.yml -o -name compose.yaml -o -name 'compose.*.yml' -o -name 'compose.*.yaml')
  if [[ -n $composes ]]; then
    emit_tool "$repo" docker-compose "${composes%%$'\n'*}"
    while IFS= read -r f; do
      grep -nE '^[[:space:]]+image:' "$src/$f" 2>/dev/null | while IFS=: read -r line img; do
        img=${img#*image:}
        img=${img%%#*}
        img=${img//[[:space:]\"\']/}
        img=${img##*/}
        printf '%s\t%s:%s\n' "${img%%[:@]*}" "$f" "$line"
      done
    done <<<"$composes" | scan_first | while IFS=$'\t' read -r img line; do
      case $img in
        postgres|postgis|mysql|mariadb|redis|valkey|mongo|rabbitmq|kafka|elasticsearch|opensearch|clickhouse|minio|memcached|nats|meilisearch|typesense|qdrant)
          emit_node "service:$img" service "$img"
          emit_edge "repo:$repo" "service:$img" depends-on "$line"
          ;;
      esac
    done || true
  fi

  # Example env files at the root and in each package (profile_env_files). A
  # repo naming S3_BUCKET, S3_REGION and S3_ENDPOINT depends on S3 once, cited
  # at the first of them.
  local envs kind
  envs=$(profile_env_files "$src")
  [[ -n $envs ]] || return 0
  while IFS= read -r f; do
    grep -nE '^(export[[:space:]]+)?[A-Z0-9_]*(POSTGRES|DATABASE|REDIS|MONGO|ELASTIC|RABBIT|KAFKA|S3|SMTP)[A-Z0-9_]*=' \
      "$f" 2>/dev/null | while IFS=: read -r line kind; do
        kind=${kind%%=*}
        [[ $kind =~ (POSTGRES|DATABASE|REDIS|MONGO|ELASTIC|RABBIT|KAFKA|S3|SMTP) ]] || continue
        printf '%s\t%s:%s\n' "$(tr 'A-Z' 'a-z' <<<"${BASH_REMATCH[1]}")" "${f#"$src"/}" "$line"
      done
  done <<<"$envs" | scan_first | while IFS=$'\t' read -r kind line; do
    emit_node "service:$kind" service "$kind"
    emit_edge "repo:$repo" "service:$kind" depends-on "$line"
  done || true
  while IFS= read -r f; do
    emit_hosts_from "$repo" "$f" "${f#"$src"/}" reaches
  done <<<"$envs"
}

# Repo-to-repo edges: explicit references only.
scan_links() {
  local repo=$1 src=$2 other rel line re
  while read -r other; do
    [[ -z $other || $other == "$repo" ]] && continue
    [[ $other == .* ]] && continue
    # A repo name may hold a dot, which a pattern reads as any character. The
    # trailing class is the word boundary; `\b` is a GNU extension to BRE. A
    # hyphen or a dot continues a repo name, so neither ends one: org/honox is
    # not in org/honox-website or org/honox.dev. Only .git may follow, or the
    # full stop that ends a sentence.
    re="$ORG/${other//./\\.}(\\.git)?\\.?([^A-Za-z0-9_.-]|\$)"
    # grep -r walks in readdir order, which a fetch's reset --hard reshuffles,
    # so the file cited is the first in byte order, and the line its first match:
    # a rescan of the same commits cites the same line.
    local hit pats=(-e "github\.com[:/]$re" -e "ghcr\.io/$re" -e "@$re")
    hit=$(grep -rlE --binary-files=without-match "${pats[@]}" "$src/" \
      --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
      --exclude-dir=dist --exclude-dir=build --exclude='*.lock' --exclude='*.sum' \
      2>/dev/null | LC_ALL=C sort | head -1 || true)
    [[ -z $hit ]] || hit="$hit:$(grep -nE -m1 "${pats[@]}" "$hit" 2>/dev/null)" || true
    if [[ -z $hit ]]; then
      # A dependency manifest naming the repo counts, but only for names long
      # enough not to collide with an ordinary word. The name has to stand
      # whole: grep -w reads a hyphen or a dot as a boundary, so `honox` matched
      # `"name": "honox.dev"` and honox-website's own URL, and `hono` matched
      # the npm scope in `@hono/vite-ssg` — each a line above the dependency
      # that was the real evidence. A slash may come before the name (composer's
      # vendor/name), never after it, where the name would be a scope or a path.
      [[ ${#other} -ge 4 ]] || continue
      local mf whole="(^|[^A-Za-z0-9_.@-])${other//./\\.}([^A-Za-z0-9_./-]|\$)"
      for mf in Gemfile go.mod package.json requirements.txt pyproject.toml \
        Cargo.toml composer.json mix.exs; do
        [[ -f $src/$mf ]] || continue
        if [[ $mf == package.json ]]; then
          # Only a key inside a dependency block: `"bin": {"hono": ...}` names a
          # command, and the dependency is further down. The key is the name, or
          # the name under an npm scope, which need not be the org's:
          # `"@hono/node-server"` is honojs/node-server.
          hit=$(awk -v n="$other" '
            /"(dependencies|devDependencies|peerDependencies|optionalDependencies)"[[:space:]]*:/ { d = 1; next }
            d && /^[[:space:]]*}/ { d = 0 }
            d && (index($0, "\"" n "\"") || $0 ~ ("\"@[^\"/]+/" n "\"")) { print NR ":" $0; exit }' \
            "$src/$mf" 2>/dev/null) || true
        else
          hit=$(grep -nE -- "$whole" "$src/$mf" 2>/dev/null | head -1) || true
        fi
        [[ -n $hit ]] && { hit="$src/$mf:$hit"; break; }
      done
    fi
    [[ -n $hit ]] || continue
    rel=${hit%%:*}
    rel=${rel#"$src"/}
    line=$(echo "$hit" | cut -d: -f2)
    emit_edge "repo:$repo" "repo:$other" references "$rel:$line"
  done <"$REPOLIST"
}

# Every symlink in a checkout whose target leaves it, leads into its .git, or
# leads nowhere is removed before anything reads the tree — see clone_inside in
# profile.sh. Links that stay inside (CLAUDE.md -> AGENTS.md) are kept. This
# covers every reader at once, the grep -r walks and the jq reads alike, and
# the next fetch's reset --hard puts the links back, to be removed again.
scan_defuse_links() {
  local src=$1 link
  while IFS= read -r -d '' link; do
    clone_inside "$src" "$link" || rm -f "$link"
  done < <(find "$src" -path "$src/.git" -prune -o -type l -print0 2>/dev/null)
}

# One repo, start to finish, into its own emit file. Safe to run in parallel.
scan_repo() {
  local repo=$1
  local src="$DIR/cache/src/$repo" why="$EMITDIR/why/$repo"
  EMIT="$EMITDIR/e-$repo.ndjson"
  : >"$EMIT"

  # A job in the background has no terminal to type a password into; without
  # this, git would wait on one forever.
  export GIT_TERMINAL_PROMPT=0
  if [[ -d $src/.git ]]; then
    # The same credentials `gh repo clone` used for the first checkout. Plain
    # git has only the user's own helpers, which for a private repo means the
    # fetch fails and the map is quietly a week old. A failed fetch is still
    # mapped, from the checkout already here, and reported as stale.
    git -C "$src" -c 'credential.https://github.com.helper=' \
      -c 'credential.https://github.com.helper=!gh auth git-credential' \
      fetch --depth "$DEPTH" --quiet origin 2>"$why" &&
      git -C "$src" reset --hard --quiet FETCH_HEAD 2>>"$why" ||
      echo "$repo" >>"$EMITDIR/stale"
  else
    gh repo clone "$ORG/$repo" "$src" -- --depth "$DEPTH" --single-branch --quiet 2>"$why" || {
      echo "$repo" >>"$EMITDIR/failed"
      : >"$EMITDIR/done/$repo"
      return 0
    }
  fi
  scan_defuse_links "$src"

  local meta lang
  meta=$(jq -c --arg r "$repo" '.[] | select(.name == $r)
         | {language, description, private, pushed_at, topics,
            url: .html_url, size_kb: .size}' "$REPOSJSON")
  emit_node "repo:$repo" repo "$repo" "$meta"

  lang=$(jq -r '.language // empty' <<<"$meta")
  [[ -n $lang ]] && {
    emit_node "lang:$lang" lang "$lang"
    emit_edge "repo:$repo" "lang:$lang" written-in ""
  }

  scan_deploy "$repo" "$src"
  scan_links "$repo" "$src"
  vendors_scan "$repo" "$src"
  profile_repo "$repo" "$src" "$meta"
  : >"$EMITDIR/done/$repo"
}

# scan_cause <stderr file> — the line that says why a clone or fetch failed.
# Not simply the last one: gh repo clone ends with its own "failed to run git:
# exit status 128", and git over ssh ends with "and the repository exists.".
# The first error line names the cause; without one, the last line is used.
scan_cause() {
  local line
  [[ -s $1 ]] || return 0
  line=$(grep -m1 -E '^(fatal|error|ERROR):' "$1" ||
    grep -v -e '^failed to run git' -e '^[[:space:]]*$' "$1" | tail -1 || true)
  line=${line//[$'\r\t']/}
  printf '%s\n' "${line:0:200}"
}

# scan_report_failed <names file> <what> — one line per cause, naming the repos
# that failed that way, so sixteen clones refused for one reason read as one
# line and not sixteen.
scan_report_failed() {
  local names=$1 what=$2 repo line
  [[ -s $names ]] || return 0
  while IFS= read -r repo; do
    [[ -n $repo ]] && printf '%s\t%s\n' "$repo" "$(scan_cause "$EMITDIR/why/$repo")"
  done <"$names" |
    jq -Rsr --arg what "$what" '
      [split("\n")[] | select(. != "") | split("\t") | {r: .[0], c: (.[1] // "")}]
      | group_by(.c)[]
      | "\($what): \(map(.r) | join(" "))" + (if .[0].c == "" then "" else " (\(.[0].c))" end)' |
    while IFS= read -r line; do log "$line"; done
}

# One scan per company at a time. Two would clone and fetch into the same
# cache/src checkouts, and whichever finished last would write its map, a
# degraded one included. mkdir is the lock because it is atomic everywhere and
# needs nothing installed; the pid inside tells a live holder from one that
# died without cleaning up (kill -9, a reboot), whose lock is taken over.
scan_lock() {
  local lock="$DIR/cache/.scan.lock" pid
  mkdir -p "$DIR/cache"
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -z $pid ]]; then
      # Taken a moment ago, its pid not written yet.
      (($(date +%s) - $(file_mtime "$lock") >= 60)) ||
        die "another scan of $COMPANY is starting — wait for it to finish, then run orgami scan again"
    elif scan_lock_alive "$pid"; then
      die "another scan of $COMPANY is running (pid $pid) — wait for it to finish, then run orgami scan again"
    fi
    log "taking over the lock of a scan that is no longer running (pid ${pid:-unknown})"
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null ||
      die "another scan of $COMPANY has just started — wait for it to finish, then run orgami scan again"
  fi
  SCAN_LOCK=$lock
  echo "${BASHPID:-$$}" >"$lock/pid"
}

# scan_lock_alive <pid> — is that pid still an orgami run? After a reboot the
# number may belong to some other program, which is not a scan. Without a ps
# that understands -p (a minimal container), a live pid is taken at its word.
scan_lock_alive() {
  local cmd
  kill -0 "$1" 2>/dev/null || return 1
  cmd=$(ps -p "$1" -o command= 2>/dev/null) || return 0
  [[ $cmd == *orgami* ]]
}

scan_draw() {
  local done=$1 total=$2 cols width filled pct f="" e="" i
  cols=$(tput cols 2>/dev/null || echo 80)
  width=$((cols - 30))
  ((width > 44)) && width=44
  ((width < 8)) && width=8
  ((total > 0)) || total=1
  filled=$((done * width / total))
  pct=$((done * 100 / total))
  for ((i = 0; i < filled; i++)); do f+="█"; done
  for ((i = filled; i < width; i++)); do e+="░"; done
  printf '\r\033[2K  \033[38;5;12m%s\033[38;5;238m%s\033[0m  %3d%%  %d/%d repos' \
    "$f" "$e" "$pct" "$done" "$total" >&2
}

scan_progress() {
  local total=$1 pid=$2 finished
  while kill -0 "$pid" 2>/dev/null; do
    finished=$(find "$EMITDIR/done" -type f 2>/dev/null | wc -l)
    scan_draw "$finished" "$total"
    sleep 0.25
  done
  scan_draw "$(find "$EMITDIR/done" -type f 2>/dev/null | wc -l)" "$total"
  printf '\n' >&2
}

# Ctrl-C does not reach the clones on its own: a script's background job
# ignores SIGINT, so xargs and every git under it would keep going after the
# scan had exited. The job runs in a process group of its own (set -m below),
# and the whole group is sent TERM, on which git removes a half-made clone —
# including any child forked after the signal was sent, which a walk of the
# process tree would miss.
scan_interrupt() {
  [[ -z ${SCAN_XPID:-} ]] || kill -TERM -- "-$SCAN_XPID" 2>/dev/null || true
  exit 130
}

# One edge per (from, to, kind). A repo whose workflow and terraform both say
# AWS, or whose example env names five S3_* variables, uses AWS once and depends
# on S3 once. The edge kept is the one a reader can open — extracted before
# inferred, a file:line before a description — then the first in byte order, so
# a rescan keeps the same one.
SCAN_ONE_EDGE='def one_edge: group_by([.from, .to, .kind])
  | map(sort_by([(if .confidence == "inferred" then 1 else 0 end),
                 (if (.evidence // "" | test(":[0-9]+$")) then 0 else 1 end),
                 (.evidence // "")]) | .[0]);'

# scan_merge <previous graph> <new graph> <names to keep, JSON array>
# The new graph, plus what the previous one held for repos that were not
# rescanned: their nodes, the edges they declared, and the nodes those edges
# point at. `calls` and `shares-config` are left behind because
# scan_infer_links derives them again from every profile, and `changes-with`
# and `imports` because scan_owned_edges rebuilds them from coupling.json and
# depth.json.
scan_merge() {
  jq -n --slurpfile old "$1" --slurpfile new "$2" --argjson keep "$3" '
    $old[0] as $o | $new[0] as $n
    | ($keep | map({("repo:" + .): true}) | add // {}) as $k
    | [$o.edges[] | select($k[.from])
       | select(.kind | IN("calls", "shares-config", "changes-with", "imports") | not)] as $edges
    | (($edges | map({(.to): true}) | add // {}) + $k) as $want
    | [$o.nodes[] | select($want[.id])] as $nodes
    | $n
    | .edges = ((.edges + $edges) | unique)
    | .nodes = (($nodes + .nodes) | group_by(.id) | map(.[0] + {meta: (map(.meta) | add)}))'
}

# Edges other commands own, put back from their own records, so a manual scan
# between two weekly runs does not drop them without a word: `changes-with`
# from coupling.json, into the new graph before it is written, and `imports`
# from depth.json, which depth_merge_graph can only add to the written map.
scan_owned_edges() {
  local graph=$1 c="$DIR/map/coupling.json"
  [[ -f $c ]] || return 0
  # shellcheck source=coupling.sh
  source "$ROOT/lib/coupling.sh"
  if coupling_graph "$graph" "$c" >"$graph.cw" 2>/dev/null; then
    mv "$graph.cw" "$graph"
  else
    rm -f "$graph.cw"
    log "could not read $c, so the map has no changes-with edges — run: orgami coupling"
  fi
}

scan_depth_edges() {
  [[ -f $DIR/map/depth.json ]] || return 0
  # shellcheck source=depth.sh
  source "$ROOT/lib/depth.sh"
  depth_merge_graph
}

# Writes <file> from <tmp> only when jq agrees it is <test>, so a failed run
# never leaves a file the next one parses. The copy is staged beside <file>
# because the temp dir may be another file system, where mv is not atomic.
scan_commit() {
  local tmp=$1 file=$2 test=$3
  jq -e "$test" "$tmp" >/dev/null 2>&1 || die "refusing to write $file: the new copy is not valid — the old one is kept"
  SCAN_STAGE="$file.tmp.$$"
  cat "$tmp" >"$SCAN_STAGE"
  mv "$SCAN_STAGE" "$file"
  SCAN_STAGE=""
}

cmd_scan() {
  load_company
  need gh
  need git

  local only="" depth=1 jobs=8
  while [[ $# -gt 0 ]]; do
    case $1 in
      --only) need_arg "$1" $#; only=$2; shift 2 ;;
      --depth) need_arg "$1" $#; depth=$2; shift 2 ;;
      --jobs | -j) need_arg "$1" $#; jobs=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -z $only ]] || valid_gh_name "$only" repo || die "not a repository name: '$only'"
  # Both go straight into arithmetic and into xargs -P and git --depth, where a
  # word or a negative number fails with somebody else's message.
  [[ $jobs =~ ^[1-9][0-9]*$ ]] || die "--jobs wants a positive whole number, e.g. --jobs 4 (got '$jobs')"
  [[ $depth =~ ^[1-9][0-9]*$ ]] || die "--depth wants a positive whole number of commits, e.g. --depth 1 (got '$depth')"

  # Everything this run writes outside the map lives here, and goes on any exit.
  SCAN_TMP=$(mktemp -d)
  SCAN_XPID="" SCAN_STAGE="" SCAN_LOCK=""
  trap 'rm -rf "$SCAN_TMP" ${SCAN_STAGE:+"$SCAN_STAGE"} ${SCAN_LOCK:+"$SCAN_LOCK"}' EXIT
  trap scan_interrupt INT TERM
  scan_lock

  local repos="$DIR/cache/repos/list.json" err="$SCAN_TMP/gh.err"
  log "listing repos in $ORG"
  if ! gh api "orgs/$ORG/repos?per_page=100&type=all" --paginate \
    --jq '[.[] | {name, description, language, archived, private, fork,
                  pushed_at, default_branch, topics, html_url,
                  size, open_issues_count}]' 2>"$err" |
    jq -s 'add // []' >"$SCAN_TMP/list.json"; then
    # A rejected token, a 404 and a dropped network each have their own next
    # step; only the 404 is about the org in config.json.
    gh_auth_die "$(cat "$err")"
    source "$ROOT/lib/pull.sh"
    gh_refuse_personal
    case $(cat "$err") in
      *"Not Found"* | *404*)
        die "GitHub has no organization '$ORG' this token can see — check the org in $DIR/config.json (gh org list shows yours)" ;;
      *SAML* | *SSO*)
        die "the gh token is not authorized for $ORG's single sign-on — run: gh auth refresh -h github.com -s read:org, then authorize it for $ORG" ;;
    esac
    die "could not list the repositories in $ORG ($(head -1 "$err")) — check the network, then: gh auth status"
  fi
  scan_commit "$SCAN_TMP/list.json" "$repos" 'type == "array"'

  local excl incl bad
  excl=$(jq -c '.exclude // [] | if type == "array" then . else [.] end' "$DIR/config.json")
  incl=$(jq -c '.include // [] | if type == "array" then . else [.] end' "$DIR/config.json")
  source "$ROOT/lib/init.sh"
  bad=$(exclude_bad "$excl")
  [[ -z $bad ]] ||
    die "exclude pattern ${bad%%$'\n'*} in $DIR/config.json is not a regular expression — patterns are regexes matched against repo names, e.g. \"-infra\$\" rather than \"*-infra\""

  # Why each listed repo is read or not, in one place, so the counts given when
  # nothing is left agree with the list that is read.
  local why='def why($incl; $excl): .name as $n
    | if .archived then "archived" elif .fork then "fork"
      elif ($incl | length) > 0 and ($incl | index($n) | not) then "include"
      elif any($excl[]; . as $p | $n | test($p)) then "exclude"
      else "active" end;'

  # REPOLIST is every active repo, because scan_links looks for references to
  # all of them even when only one is being read. The scan list is what is read.
  REPOLIST="$SCAN_TMP/repolist"
  jq -r --argjson excl "$excl" --argjson incl "$incl" \
    "$why"'.[] | select(why($incl; $excl) == "active") | .name' "$repos" >"$REPOLIST"
  local skipped
  skipped=$(jq -r --argjson excl "$excl" --argjson incl "$incl" "$why"'
    map(why($incl; $excl)) as $w
    | [[["fork", "fork", "forks"], ["archived", "archived", "archived"],
        ["exclude", "matched by exclude", "matched by exclude"],
        ["include", "not in include", "not in include"]][]
       | .[0] as $k | ([$w[] | select(. == $k)] | length) as $c
       | select($c > 0)
       | "\($c) \(if $c == 1 then .[1] else .[2] end)"]
    | join(", ")' "$repos")

  local docs_repo
  docs_repo=$(cfg docs_repo)
  if [[ -n $docs_repo ]]; then
    local docs_name=${docs_repo##*/}
    docs_name=${docs_name%.git}
    grep -qxF "$docs_name" "$REPOLIST" && skipped+="${skipped:+, }the docs repo"
    grep -vxF "$docs_name" "$REPOLIST" >"$REPOLIST.keep" || true
    mv "$REPOLIST.keep" "$REPOLIST"
  fi

  local scanlist="$SCAN_TMP/scanlist"
  if [[ -n $only ]]; then
    grep -qxF -- "$only" "$REPOLIST" ||
      die "no active repo '$only' in $ORG (archived repos, forks, excluded ones and the docs repo are not mapped) — the list is in $repos"
    echo "$only" >"$scanlist"
  else
    cp "$REPOLIST" "$scanlist"
  fi

  local total
  total=$(grep -c . "$scanlist" || true)
  if [[ $total -eq 0 ]]; then
    local listed msg
    listed=$(jq 'length' "$repos")
    [[ $listed -gt 0 ]] ||
      die "gh lists no repositories in $ORG — if it has private ones, the token cannot see them: gh auth status"
    msg="no repositories to scan in $ORG — gh lists $listed, and skipped $skipped"
    [[ $skipped != *fork* && $skipped != *archived* ]] || msg+=" (forks and archived repos are never mapped)"
    [[ $skipped != *include* && $skipped != *exclude* ]] || msg+=" — include and exclude are in $DIR/config.json"
    die "$msg"
  fi
  ((jobs > total)) && jobs=$total
  if [[ -z $only && -n $skipped ]]; then
    log "$total active repos (skipped $skipped)"
  else
    log "$total active repos"
  fi

  EMITDIR="$SCAN_TMP/emit"
  mkdir -p "$EMITDIR/done" "$EMITDIR/why"
  : >"$EMITDIR/failed"
  : >"$EMITDIR/stale"
  DEPTH=$depth
  REPOSJSON=$repos
  export EMITDIR DEPTH ORG DIR REPOLIST REPOSJSON ROOT

  set -m
  xargs -P "$jobs" -I{} bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/scan.sh"
    source "$ROOT/lib/profile.sh"
    source "$ROOT/lib/vendors.sh"
    scan_repo "$1"' _ {} <"$scanlist" &
  SCAN_XPID=$!
  set +m
  if [[ -t 2 ]]; then
    scan_progress "$total" "$SCAN_XPID"
  fi
  wait "$SCAN_XPID" 2>/dev/null || true
  SCAN_XPID=""

  scan_report_failed "$EMITDIR/stale" "could not fetch, mapped from the last checkout"
  scan_report_failed "$EMITDIR/failed" "could not clone"

  local out="$DIR/map/graph.json" profiles="$DIR/map/repos.json"
  local new="$SCAN_TMP/graph.json" newp="$SCAN_TMP/repos.json"
  # Read in name order, not readdir order, so the node a merge keeps first is
  # the same on every run.
  find "$EMITDIR" -name 'e-*.ndjson' | LC_ALL=C sort | while IFS= read -r f; do cat "$f"; done |
    jq -s --arg company "$COMPANY" --arg org "$ORG" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$SCAN_ONE_EDGE"'{company: $company, org: $org, generated: $at,
        nodes: ([.[] | select(.t == "node") | del(.t)]
                | group_by(.id) | map(.[0] + {meta: (map(.meta) | add)})),
        edges: ([.[] | select(.t == "edge") | del(.t)] | one_edge)}' \
      >"$new"
  find "$EMITDIR" -name 'p-*.json' | LC_ALL=C sort | while IFS= read -r f; do cat "$f"; done |
    jq -s '.' >"$newp"

  # Nothing read is not an empty organization, it is a broken run — a token
  # gone stale, the network down. The map from the last good run stays.
  [[ $(jq '[.nodes[] | select(.kind == "repo")] | length' "$new") -gt 0 ]] ||
    die "no repository could be read, so $out is unchanged — fix the clones above, then run orgami scan again"

  # Repos this run did not read keep what the last map said about them: with
  # --only, every other repo; otherwise the ones whose clone failed, so one bad
  # clone does not drop a repo from the map. A repo no longer active in the org
  # is not carried over.
  local keep='[]'
  if [[ -f $out ]] &&
    jq -e '(.nodes | type) == "array" and (.edges | type) == "array"' "$out" >/dev/null 2>&1; then
    if [[ -n $only ]]; then
      keep=$(jq -Rn --arg only "$only" '[inputs | select(. != "" and . != $only)]' <"$REPOLIST")
    else
      keep=$(jq -Rn '[inputs | select(. != "")]' <"$EMITDIR/failed")
    fi
  fi
  if [[ $keep != '[]' ]]; then
    scan_merge "$out" "$new" "$keep" >"$new.merged"
    # The map as a whole is as old as the oldest part of it, so a single-repo
    # rescan does not make the rest look fresh.
    if [[ -n $only ]]; then
      jq --slurpfile old "$out" '.generated = ($old[0].generated // .generated)' \
        "$new.merged" >"$new"
    else
      mv "$new.merged" "$new"
    fi
    if [[ -f $profiles ]] && jq -e 'type == "array"' "$profiles" >/dev/null 2>&1; then
      jq -s --argjson keep "$keep" \
        '.[0] + [.[1][] | select(.name | IN($keep[]))]' \
        "$newp" "$profiles" >"$newp.merged"
      mv "$newp.merged" "$newp"
    fi
  fi
  jq 'sort_by(.name)' "$newp" >"$newp.sorted"
  mv "$newp.sorted" "$newp"

  scan_infer_links "$new" "$newp"
  scan_owned_edges "$new"

  scan_commit "$new" "$out" '(.nodes | type) == "array" and (.edges | type) == "array"'
  scan_commit "$newp" "$profiles" 'type == "array"'
  scan_depth_edges

  rm -rf "$SCAN_TMP" "$SCAN_LOCK"
  trap - EXIT INT TERM
  echo "$out  ($(jq '.nodes | length' "$out") nodes, $(jq '.edges | length' "$out") edges)"
}

# Edges no single repo can declare: who calls whom, and who shares configuration.
# Neither is written down anywhere — they are resolved by matching one repo's
# literal URLs against the hosts another repo claims, and one repo's environment
# names against another's. Both are marked `inferred`, and everything that reads
# the graph says so.  A URL in `evidence` is the thing that was matched, not a
# line anybody can open.
scan_infer_links() {
  local graph=$1 profiles=$2 tmp
  tmp=$(mktemp)
  jq -s --slurpfile links /dev/null \
    '.[0] as $g | .[1] as $rs
     # How many repos declare each name. from_entries reads `value`, nothing
     # else: a {key, n} pair gave every name null, `null < 6` held, and the cap
     # never dropped a name, so six DATABASE_URLs made a fifteen-edge clique.
     | ($rs | map(.env // [] | unique | .[]) | group_by(.)
        | map({key: .[0], value: length}) | from_entries) as $freq
     # Inside the select `.` is the edge, which has no name: the repo name is
     # bound first, or no deploys-to host would ever count as owned.
     | ([$rs[] | .name as $n | {name, hosts: ((.serves // [])
          + [$g.edges[] | select(.kind == "deploys-to" and .from == ("repo:" + $n)) | .to | sub("^host:"; "")])
          | unique}]
        | map(select((.hosts | length) > 0))) as $servers
     | ([$servers[] | .name as $n | .hosts[] | {host: ., name: $n}]
        | group_by(.host) | map(select(length == 1)) | map(.[0])
        | map({(.host): .name}) | add // {}) as $owner
     | ($rs | map(.calls // [] | unique | .[]) | group_by(.) | map({(.[0]): length}) | add // {}) as $callfreq
     # Two hosts of one repo are still one calls edge, naming both.
     | [$rs[] as $r
        | [$r.calls // [] | unique | .[]
           | select($owner[.] != null and $callfreq[.] <= 3 and $owner[.] != $r.name)
           | {h: ., to: $owner[.]}]
        | group_by(.to)[]
        | {from: ("repo:" + $r.name), to: ("repo:" + .[0].to), kind: "calls",
           evidence: (map("https://" + .h) | .[0:3] | join(", ")), confidence: "inferred"}] as $calls
     # A name every scaffold writes — DATABASE_URL, DB_HOST, API_URL,
     # NEXT_PUBLIC_API_URL — says two repos use the same framework, not that
     # they share anything. A name is distinctive when, past a public prefix,
     # some word before its suffix is not one of these.
     | ["DB", "DATABASE", "PG", "POSTGRES", "POSTGRESQL", "MYSQL", "MONGO", "MONGODB",
        "REDIS", "CACHE", "API", "APP", "BASE", "SITE", "WEB", "FRONTEND", "BACKEND",
        "SERVER", "CLIENT", "HOST", "URL", "S3", "AWS", "SMTP", "MAIL", "EMAIL",
        "BUCKET", "QUEUE", "PUBLIC", "PRIVATE", "INTERNAL", "EXTERNAL"] as $generic
     | def distinctive: sub("^(NEXT_PUBLIC|NUXT_PUBLIC|EXPO_PUBLIC|REACT_APP|VITE|PUBLIC)_"; "")
         | split("_") | map(select(. != "")) | .[0:-1]
         | any(.[]; IN($generic[]) | not);
       ([$rs[] | {name, env: [.env // [] | unique | .[]
         | select(test("_(URL|ENDPOINT|API|HOST|BASE|BUCKET|QUEUE|TOPIC|DB|DATABASE)$"))
         | select($freq[.] < 6)
         | select(distinctive)]}]) as $e
     | [$e[] as $a | $e[] as $b | select($a.name < $b.name)
        | ($a.env - ($a.env - $b.env)) as $shared
        | select(($shared | length) > 0)
        | {from: ("repo:" + $a.name), to: ("repo:" + $b.name), kind: "shares-config",
           evidence: ($shared | sort | .[0:3] | join(", ")), confidence: "inferred"}] as $cfg
     | $g | .edges = ((.edges + $calls + $cfg) | unique)' \
    "$graph" "$profiles" >"$tmp"
  mv "$tmp" "$graph"
}
