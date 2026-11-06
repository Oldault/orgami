# shellcheck shell=bash
# orgami dns — the third parties an organization has an account with, read from
# its own public DNS.
#
# `orgami scan` finds what the code *calls*. That is the checkable half of the
# bill and it is also the smaller one: no repository will ever mention Google
# Workspace, Microsoft 365, Greenhouse, DocuSign or Zoom, and on most
# organizations those are the top of the invoice. DNS finds them, because a
# vendor that has been set up leaves a record behind — a verification token is
# that vendor saying *this organization proved to us that it owns this domain*.
# That is an account, not a mention.
#
# Like `orgami live`, this is deliberately not part of `orgami scan`, and for
# the same reason: the graph is committed evidence, every edge carries a
# file:line, and two people scanning the same org get the same map. A DNS
# reading has no file:line — it is a point in time. So it lives in its own file,
# `map/dns.json`, carries its own timestamp, and `orgami scan` never touches it.
#
# It differs from `live.json` in one way that matters, and the difference is why
# this one publishes by default: a DNS record is public. Anyone holding the
# report can run the same `dig` and see the same answer, which makes a DNS
# finding reproducible and checkable in a way a reading of somebody's cloud
# account never is.
#
# Nothing is authenticated, nothing is written, and nothing secret is recorded.
# The queries are the ones any resolver on the internet will answer. Only the
# records that matched a catalogue signal reach the artifact; the rest are
# counted and thrown away, so this never becomes a dump of somebody's zone.

DNS_STALE_DAYS=90

# Five is a working organization's domain count — the product, the marketing
# site, maybe a legacy brand. Past that the list is usually parked domains and
# redirects, which cost queries and tell nobody anything. `dns_max_domains` in
# the company config raises it, and whatever is left out is named out loud.
DNS_MAX_DOMAINS=5

# Seconds per query, with a single try. One unreachable resolver then costs
# three seconds rather than stalling the run.
DNS_TIMEOUT=3

# The only names asked for beyond the apex, and the only part of this that costs
# a query per name per domain — so each one has to earn its place by being a
# convention rather than a guess. Each is a name organizations actually publish,
# pointed at a vendor that bills them:
#
#   www app     the site and the product, which name the host and often the CDN
#   mail        webmail, where a workspace vendor puts its front door
#   status      Statuspage, Better Stack — bought precisely to be a subdomain
#   help support the support desk: Zendesk, Intercom, Help Scout, Freshdesk
#   docs        GitBook, Mintlify, ReadMe
#   blog        Ghost, Webflow, HubSpot
#   careers     Greenhouse, Lever, Ashby — an applicant tracker, always a seat bill
#   pay billing Stripe's hosted pages, Chargebee
#
# Anything rarer is a guess, and a guess costs a query on every domain to find
# nothing. `dig` on a specific name is one command away for whoever wants more.
DNS_SUBDOMAINS=(www app mail status help support docs blog careers pay billing)

# Domains a provider owns rather than the organization. Reading the DNS of
# `vercel.app` describes Vercel's zone and says nothing at all about this org,
# and asking looks like diligence while producing noise — so an apex that lands
# here is dropped and reported as dropped.
#
# It is matched against the name and every parent of it, so
# `cognitiveservices.azure.com` handed to `--domain` is caught by `azure.com`.
# The cloud umbrellas are here because a vendor endpoint reduces to them —
# azure.com carries Microsoft's own Microsoft 365 and Meta tokens, which are
# Microsoft's accounts and nobody else's. The blog hosts and free mail domains
# are here because the website and the contact address on a GitHub profile are
# read as ownership, and `medium.com/acme` or `acme@gmail.com` is not.
DNS_PROVIDER_DOMAINS='(^|\.)(azure\.com|azure\.net|azureedge\.net|azurefd\.net|microsoft\.com|microsoftonline\.com|office\.com|office365\.com|outlook\.com|live\.com|windows\.com|sharepoint\.com|google\.com|googleusercontent\.com|googlemail\.com|gmail\.com|cloudfunctions\.net|amazon\.com|heroku\.com|vercel\.com|cloudflare\.com|digitalocean\.com|ovh\.net|ovh\.com|scw\.cloud|scaleway\.com|medium\.com|substack\.com|linkedin\.com|twitter\.com|x\.com|facebook\.com|instagram\.com|youtube\.com|notion\.site|notion\.so|wordpress\.com|blogspot\.com|tumblr\.com|hashnode\.dev|gitlab\.io|gitlab\.com|framer\.website|framer\.app|hotmail\.com|yahoo\.com|icloud\.com|me\.com|proton\.me|protonmail\.com|gmx\.com|gmx\.de|gmx\.net|aol\.com|zoho\.com|yandex\.com|yandex\.ru|mail\.ru|laposte\.net|orange\.fr|free\.fr|wanadoo\.fr|sfr\.fr|vercel\.app|vercel-dns\.com|fly\.dev|fly\.io|herokuapp\.com|herokudns\.com|netlify\.app|netlify\.com|github\.io|githubusercontent\.com|amazonaws\.com|elasticbeanstalk\.com|cloudfront\.net|windows\.net|azurewebsites\.net|azure-dns\.com|pages\.dev|workers\.dev|onrender\.com|render\.com|railway\.app|ondigitalocean\.app|digitaloceanspaces\.com|run\.app|appspot\.com|firebaseapp\.com|firebaseio\.com|web\.app|supabase\.co|neon\.tech|planetscale\.com|psdb\.cloud|upstash\.io|now\.sh|surge\.sh|gitbook\.io|readthedocs\.io|zendesk\.com|statuspage\.io|myshopify\.com|wixsite\.com|squarespace\.com|webflow\.io|ngrok\.io|ngrok\.app|trycloudflare\.com|cloudflarestorage\.com|googleapis\.com|gstatic\.com|akamaized\.net|fastly\.net|jsdelivr\.net|unpkg\.com|cdn\.sh)$'

# Public suffixes of more than one label, so `acme.co.uk` is not read as
# `co.uk`. This is a hand-kept list and not the Public Suffix List: orgami has
# no build step and will not download and parse a file to split a domain name.
# It covers the country second-levels an organization plausibly sits under.
DNS_MULTI_SUFFIXES='co.uk org.uk ac.uk gov.uk me.uk net.uk sch.uk ltd.uk plc.uk
co.jp ne.jp or.jp ac.jp go.jp co.nz net.nz org.nz com.au net.au org.au edu.au
gov.au id.au co.za org.za web.za com.br net.br org.br com.mx com.ar com.co
com.pe com.uy com.ve com.ec com.bo com.py com.sg com.hk com.tw com.cn net.cn
org.cn co.in net.in org.in co.kr or.kr co.il org.il net.il ac.il com.tr com.ua
com.my com.ph com.vn co.id co.th in.th com.pl net.pl org.pl com.ng com.eg
com.sa com.kw com.qa co.ke co.tz co.ug co.zw com.pk com.bd com.np co.ma com.tn
com.es com.pt com.gr com.cy co.at or.at com.hr com.ru net.ru org.ru'

# The generic words a country's second level is made of. See dns_apex: these are
# how a suffix this list has never heard of is caught rather than queried.
DNS_SUFFIX_WORDS='com co net org gov edu ac ne or go web id sch ltd plc mil
info biz name gob gouv'

dns_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Recorded rather than printed: cmd_dns reports every error once, at the end,
# the way cmd_live does. A domain that will not resolve is a line on the report,
# never a failed run.
dns_err() {
  jq -cn --arg d "$1" --arg m "$2" '{domain:$d, message:$m}' >>"$DNS_ERRORS"
}

# --- one query ----------------------------------------------------------------

# `dig` once per (type, name) for the whole run, cached on disk. Five domains
# following SPF will ask three different zones for `_spf.google.com`, and the
# cache is also how the run reports how many queries it actually made.
#
# The answers are normalised here so nothing downstream has to know what dig's
# output looks like: a long TXT record is split into several quoted strings on
# the wire, and dig prints them as `"part one" "part two"`.
dns_query() {
  local type=$1 name=$2 f
  f="$DNS_CACHE/$type-$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')"
  if [[ ! -f $f ]]; then
    dig +short "+time=$DNS_TIMEOUT" +tries=1 "$type" "$name" 2>/dev/null |
      sed -e 's/" "//g' -e 's/^"//' -e 's/"$//' -e 's/[[:space:]]*$//' |
      awk 'NF' >"$f" 2>/dev/null || : >"$f"
  fi
  cat "$f"
}

# The evidence line. It has to let a reader run the same check and see the same
# thing, so it carries the record type, the exact name queried, the record text
# and the day it was read.
#
# A TXT record runs to 255 characters and a DKIM key runs well past that. The
# head of a record is what identifies a vendor, so a long one is cut rather than
# poured into the artifact whole — the full record is one `dig` away.
dns_evidence() {
  local type=$1 name=$2 rec=$3
  [[ ${#rec} -le 110 ]] || rec="${rec:0:110}…"
  printf '%s %s "%s" (dig %s)' "$type" "$name" "$rec" "$DNS_DATE"
}

# --- which domains are the organization's -------------------------------------

# The registrable apex of a hostname: `api.staging.acme.co.uk` is `acme.co.uk`.
# Prints nothing, and says nothing, when it cannot be certain — an address, a
# bare label, or a suffix DNS_MULTI_SUFFIXES has never heard of.
#
# That last case is the one worth being careful about, because the failure is
# asymmetric: guessing `com.br` for `shop.acme.com.br` would send queries at a
# public suffix and attribute whatever came back to this organization. So when
# the last label is two characters — a country, which is where the multi-label
# suffixes live — and the label in front of it is one of the generic words those
# suffixes are built from, this refuses to answer instead of guessing. Passing
# the domain with `--domain` is the way through.
dns_apex() {
  local host n last2 first
  host=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  host=${host%.}
  case $host in
    *[a-z]*) ;;
    *) return 0 ;;
  esac
  [[ $host == *.* ]] || return 0

  local IFS=. parts
  read -ra parts <<<"$host"
  n=${#parts[@]}
  [[ $n -ge 2 ]] || return 0

  last2="${parts[n - 2]}.${parts[n - 1]}"
  case " $(printf '%s' "$DNS_MULTI_SUFFIXES" | tr '\n' ' ') " in
    *" $last2 "*)
      [[ $n -ge 3 ]] || return 0
      printf '%s.%s\n' "${parts[n - 3]}" "$last2"
      return 0
      ;;
  esac

  first=${parts[n - 2]}
  if [[ ${#parts[n - 1]} -eq 2 ]]; then
    case " $(printf '%s' "$DNS_SUFFIX_WORDS" | tr '\n' ' ') " in
      *" $first "*) return 0 ;;
    esac
  fi
  printf '%s\n' "$last2"
}

dns_is_provider() {
  local d=$1
  if printf '%s' "$d" | grep -qiE "$DNS_PROVIDER_DOMAINS"; then return 0; fi
  # Whatever the scanner already refuses to make a host node out of is not a
  # domain worth asking about either. NOISE_DOMAINS is only defined when
  # lib/scan.sh has been sourced, which the `dns` arm does.
  if [[ -n ${NOISE_DOMAINS:-} ]] && printf '%s' "$d" | grep -qE "$NOISE_DOMAINS"; then
    return 0
  fi
  return 1
}

# The `domains` array in the company config, which is authoritative: somebody
# wrote down what this organization owns, and that beats anything derived.
dns_domains_configured() { cfg 'domains[]?'; }

# A bare hostname out of whatever a profile field holds: `acme.com`,
# `https://www.acme.com/blog` and `http://me@acme.com:8080/` all give one.
dns_host_of() {
  local h
  h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  h=${h#*://}
  h=${h%%[/?#]*}
  h=${h##*@}
  h=${h%%:*}
  printf '%s\n' "${h%.}"
}

# The organization's own word on where it lives: the website and the public
# contact address on its GitHub profile, as `<field>\t<value>`. One read-only
# GET, asked of `users/` when the owner is a personal account. A failure is
# said and survived — it costs this one source, never the run.
dns_github_profile() {
  local raw
  command -v gh >/dev/null 2>&1 || {
    log "gh is not on PATH, so the website on the $ORG GitHub profile was not read"
    return 0
  }
  raw=$(gh api "orgs/$ORG" 2>/dev/null) || raw=$(gh api "users/$ORG" 2>/dev/null) || {
    log "could not read the $ORG GitHub profile (offline, or gh is signed out), so its website was not used"
    return 0
  }
  printf '%s' "$raw" | jq -r '
    select(type == "object")
    | [["website", (.blog // "")],
       ["contact address",
        ((.email // "") | split("@") | if length == 2 then .[1] else "" end)]]
    | .[] | select(.[1] != "") | @tsv' 2>/dev/null || true
}

# The names this organization goes by, squashed to letters and digits — the
# login and the company name, each again without the affix a GitHub login so
# often carries (`acmeteam` is also `acme`). Under four characters a
# name matches too many domains to mean anything, so it is not used.
dns_name_tokens() {
  local n t a
  for n in "$ORG" "${COMPANY:-}"; do
    t=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    printf '%s\n' "$t"
    for a in team hq inc labs app dev io org official group tech corp; do
      if [[ $t == *"$a" ]]; then printf '%s\n' "${t%"$a"}"; fi
    done
    for a in get try use the; do
      if [[ $t == "$a"* ]]; then printf '%s\n' "${t#"$a"}"; fi
    done
  done | awk 'length >= 4' | sort -u
}

# With nothing written down, the domains the evidence says are the
# organization's own. One line per apex, `<state>\t<domain>\t<why>`, the most
# reliable first:
#
#   owned   the website or contact address on the GitHub profile, or a host in
#           the map whose registrable name is the organization's own name
#   called  a host the code calls that nothing says the organization owns
#   drop    a provider's domain, or one the catalogue knows as a vendor's
#           endpoint
#
# Being called is not being owned, and that is the whole reason for the split.
# A host node is any URL found in code, so the most-referenced one is as often a
# partner's API or a vendor's endpoint as the organization's own service — and
# `cognitiveservices.azure.com` reduces to azure.com, whose records are
# Microsoft's own accounts. Read as this organization's, they become a
# Microsoft 365 subscription nobody here pays for.
dns_domains_default() {
  local g="$DIR/map/graph.json" kind val a h n n2 label why hosts facts ends apexes seen=" " undecided
  local -a toks=()
  while IFS=$'\t' read -r kind val; do
    a=$(dns_apex "$(dns_host_of "$val")")
    [[ -n $a ]] || continue
    case $seen in *" $a "*) continue ;; esac
    seen+="$a "
    if dns_is_provider "$a"; then
      printf 'drop\t%s\t%s\n' "$a" "the $kind on the $ORG GitHub profile, but owned by a provider, not by this organization"
    else
      printf 'owned\t%s\t%s\n' "$a" "the $kind on the $ORG GitHub profile"
    fi
  done < <(dns_github_profile)

  [[ -f $g ]] || return 0
  while IFS= read -r n; do
    if [[ -n $n ]]; then toks+=("$n"); fi
  done < <(dns_name_tokens)
  hosts=$(mktemp)
  facts=$(mktemp)
  ends=$(mktemp)
  apexes=$(mktemp)
  jq -r '.nodes[]? | select(.kind == "host") | .name' "$g" 2>/dev/null >"$hosts" || :
  # The same matcher a repository scan uses, on the hostnames alone: a host one
  # of the catalogue's `host:` signals recognises is that vendor's endpoint.
  awk 'NF { printf "host\t%s\t%s\n", $0, $0 }' "$hosts" >"$facts"
  vendors_match "$facts" all 2>/dev/null | awk -F'\t' '{ print $6 "\t" $2 }' >"$ends" || :
  while IFS= read -r h; do
    [[ -n $h ]] || continue
    a=$(dns_apex "$h")
    printf '%s\t%s\n' "${a:--}" "$h" >>"$apexes"
  done <"$hosts"
  undecided=$(awk -F'\t' '$1 == "-"' "$apexes" | grep -c '' || true)
  [[ ${undecided:-0} -eq 0 ]] ||
    log "$undecided host(s) in the map gave no registrable domain — an address, a single label, or a public suffix orgami will not split"

  # Most-referenced first, as `<apex>\t<first host>\t<vendor or empty>`.
  while IFS=$'\t' read -r a h n; do
    case $seen in *" $a "*) continue ;; esac
    seen+="$a "
    label=$(printf '%s' "${a%%.*}" | tr -cd 'a-z0-9')
    why=""
    for n2 in ${toks[@]+"${toks[@]}"}; do
      if [[ $label == "$n2" ]]; then why="a host in map/graph.json named after $ORG ($h)"; fi
    done
    if [[ -n $why ]]; then
      printf 'owned\t%s\t%s\n' "$a" "$why"
    elif dns_is_provider "$a"; then
      printf 'drop\t%s\t%s\n' "$a" "owned by a provider, not by this organization"
    elif [[ -n $n ]]; then
      printf 'drop\t%s\t%s\n' "$a" "the endpoint of $n ($h, lib/vendors.tsv), not this organization's"
    else
      printf 'called\t%s\t%s\n' "$a" "$h"
    fi
  done < <(awk -F'\t' 'FILENAME == ARGV[1] { vendor[$1] = $2; next }
                       $1 == "-" { next }
                       { n[$1]++; if (!($1 in first)) first[$1] = $2
                         if (($2 in vendor) && !($1 in v)) v[$1] = vendor[$2] }
                       END { for (a in n) printf "%d\t%s\t%s\t%s\n", n[a], a, first[a], v[a] }' \
             "$ends" "$apexes" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2-)
  rm -f "$hosts" "$facts" "$ends" "$apexes"
}

# --- what the records say ------------------------------------------------------

# Every `include:` and `redirect=` in one SPF record, and then one level down —
# but only into the organization's own zone.
#
# Both halves of that rule are the point. An SPF record is routinely split, so
# the apex says `include:_spf.acme.com` and every vendor the organization
# actually invited is one name further along. Not following would miss all of
# them. Following anywhere else would find the wrong thing: `sendgrid.net`'s own
# record includes SendGrid's netblocks and whatever SendGrid resells, and none
# of that is a supplier this organization chose — it would attribute a vendor's
# vendors to the customer.
#
# So the follow is one level, and only where the target sits under the apex
# being read. Everything past that belongs to somebody else, and the RFC's own
# limit of ten lookups exists for the same reason: this fans out fast.
dns_spf_facts() {
  local apex=$1 name=$2 rec=$3 depth=$4 tok target sub ev followed=0
  local -a toks
  ev=$(dns_evidence TXT "$name" "$rec")
  read -ra toks <<<"$rec"
  for tok in ${toks[@]+"${toks[@]}"}; do
    case $tok in
      include:*) target=${tok#include:} ;;
      redirect=*) target=${tok#redirect=} ;;
      *) continue ;;
    esac
    target=${target%.}
    [[ -n $target && $target == *.* ]] || continue
    printf 'spf\t%s\t%s\n' "$target" "$ev"
    [[ $depth -lt 2 ]] || continue
    [[ $target == "$apex" || $target == *".$apex" ]] || continue
    followed=$((followed + 1))
    [[ $followed -le 6 ]] || continue
    while IFS= read -r sub; do
      case $sub in v=spf1*) ;; *) continue ;; esac
      dns_spf_facts "$apex" "$target" "$sub" $((depth + 1))
    done < <(dns_query TXT "$target")
  done
}

# One domain's records as facts, in the `<kind>\t<value>\t<evidence>` shape
# `vendors_match` reads.
#
# Every record read becomes a fact, matching or not. The ones the catalogue
# recognises reach the artifact; the rest are only ever counted. That is what
# keeps this a list of findings rather than a copy of somebody's zone file, and
# it is why the count of unmatched records is reported — a domain where nothing
# matched and nothing was read are two different facts.
dns_facts() {
  local d=$1 rec host sub m ev

  # In value order: a verification token first, because it is the only record
  # here that is a vendor's own statement about this organization.
  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    case $rec in
      v=spf1*) dns_spf_facts "$d" "$d" "$rec" 1 ;;
      *) printf 'txt\t%s\t%s\n' "$rec" "$(dns_evidence TXT "$d" "$rec")" ;;
    esac
  done < <(dns_query TXT "$d")

  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    # `10 aspmx.l.google.com.` — the exchanger is the last field.
    host=${rec##* }
    printf 'mx\t%s\t%s\n' "${host%.}" "$(dns_evidence MX "$d" "$rec")"
  done < <(dns_query MX "$d")

  # DMARC aggregate reports go somewhere, and that somewhere is a vendor:
  # nobody reads their own DMARC XML by hand.
  while IFS= read -r rec; do
    case $rec in v=DMARC1*) ;; *) continue ;; esac
    ev=$(dns_evidence TXT "_dmarc.$d" "$rec")
    while IFS= read -r m; do
      [[ -n $m ]] || continue
      printf 'dmarc\t%s\t%s\n' "${m%.}" "$ev"
      # Split on the separators DMARC uses, so a second destination after a
      # comma is its own line rather than the tail of the first.
    done < <(printf '%s\n' "$rec" | tr ',; ' '\n\n\n' |
      sed -n -e 's/^ru[af]=mailto:[^@]*@\([A-Za-z0-9.-]*\).*/\1/p' \
        -e 's/^mailto:[^@]*@\([A-Za-z0-9.-]*\).*/\1/p')
  done < <(dns_query TXT "_dmarc.$d")

  for sub in "${DNS_SUBDOMAINS[@]}"; do
    while IFS= read -r rec; do
      [[ -n $rec ]] || continue
      printf 'cname\t%s\t%s\n' "${rec%.}" "$(dns_evidence CNAME "$sub.$d" "$rec")"
    done < <(dns_query CNAME "$sub.$d")
  done

  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    printf 'ns\t%s\t%s\n' "${rec%.}" "$(dns_evidence NS "$d" "$rec")"
  done < <(dns_query NS "$d")
}

# One domain, from the queries to the matched rows. Appends ndjson to $DNS_ROWS
# and one summary line to $DNS_SEEN.
dns_domain_scan() {
  local d=$1 facts read_n matched_n=0 id name category portal kind ev flags
  facts=$(mktemp)
  dns_facts "$d" >"$facts"
  read_n=$(grep -c '' "$facts" 2>/dev/null || true)
  read_n=${read_n:-0}
  if [[ $read_n -eq 0 ]]; then
    dns_err "$d" "nothing came back — no NS, MX or TXT record, so either it does not resolve or nothing is published on it"
    rm -f "$facts"
    return 0
  fi
  # `flags` is last and usually absent — see the shape `vendors_match` documents
  # — so it is read into a name of its own rather than left to fall into `ev`.
  # It is carried into the row for the same reason `portal` is: a DNS reading is
  # read back on its own, without the catalogue beside it.
  while IFS=$'\t' read -r id name category portal kind ev flags; do
    [[ -n $id && -n $ev ]] || continue
    matched_n=$((matched_n + 1))
    jq -cn --arg d "$d" --arg id "$id" --arg name "$name" --arg c "$category" \
      --arg p "$portal" --arg f "$flags" --arg k "$kind" --arg ev "$ev" \
      '{domain:$d, id:$id, name:$name, category:$c, portal:$p,
        flags: ($f | if . == "" then [] else split(",") end),
        signal:$k, at:$ev}' >>"$DNS_ROWS"
  done < <(vendors_match "$facts" all)
  jq -cn --arg d "$d" --argjson r "$read_n" --argjson m "$matched_n" \
    '{domain:$d, records:$r, matched:$m}' >>"$DNS_SEEN"
  rm -f "$facts"
}

# --- the command ---------------------------------------------------------------

cmd_dns() {
  load_company

  local yes=0 as_json=0 maxd="" d s
  local -a want=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain | -d) need_arg "$1" $#; want+=("$2"); shift 2 ;;
      --max-domains) need_arg "$1" $#; maxd=$2; shift 2 ;;
      --yes | -y) yes=1; shift ;;
      --json) as_json=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  # After the flags, so a typo in one is reported as a typo rather than as a
  # missing dependency.
  need dig "the package is called bind on Arch, bind-tools on Alpine, dnsutils on Debian and Ubuntu"

  # Where the list comes from, in the order that puts the most reliable source
  # first. `--domain` is a one-off and stands alone: somebody asking about one
  # domain does not want four others queried alongside it.
  local origin="" unverified=0 state why
  local -a domains=() called=() keep=() dropped=()
  if [[ ${#want[@]} -gt 0 ]]; then
    domains=("${want[@]}")
    origin="--domain"
  else
    while IFS= read -r d; do [[ -n $d ]] && domains+=("$d"); done \
      < <(dns_domains_configured)
    if [[ ${#domains[@]} -gt 0 ]]; then
      origin="the domains list in $DIR/config.json"
    else
      while IFS=$'\t' read -r state d why; do
        case $state in
          owned)
            domains+=("$d")
            case "; $origin; " in *"; $why; "*) ;; *) origin+="${origin:+; }$why" ;; esac
            ;;
          called) called+=("$d") ;;
          drop) dropped+=("$d — $why") ;;
        esac
      done < <(dns_domains_default)
      if [[ ${#domains[@]} -gt 0 ]]; then
        for d in ${called[@]+"${called[@]}"}; do
          dropped+=("$d — the code calls it, but nothing says this organization owns it (orgami dns --domain $d if it does)")
        done
      elif [[ ${#called[@]} -gt 0 ]]; then
        # Said rather than refused: on an organization whose own domain is
        # nowhere in its code, the hosts it calls are all there is to go on.
        # The reading is still taken, and kept apart from the accounts.
        domains=("${called[@]}")
        unverified=1
        origin="the host nodes in map/graph.json, none of them known to be the organization's"
        log "nothing says which domains $ORG owns: no domains list in $DIR/config.json, no website read off its GitHub profile, no host in the map named after it"
        log "falling back to the hosts the code calls, which are as often a partner's or a vendor's — map/dns.json keeps what they carry apart from the accounts, and orgami advise leaves it out"
        log "name the organization's own with --domain, or a \"domains\" array in $DIR/config.json"
      fi
    fi
  fi

  for d in ${domains[@]+"${domains[@]}"}; do
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    d=${d%.}
    [[ -n $d && $d == *.* ]] || { dropped+=("$d — not a domain name"); continue; }
    if dns_is_provider "$d"; then
      dropped+=("$d — owned by a provider, not by this organization")
      continue
    fi
    case " ${keep[*]-} " in *" $d "*) continue ;; esac
    keep+=("$d")
  done

  [[ -n $maxd ]] || maxd=$(cfg dns_max_domains "$DNS_MAX_DOMAINS")
  [[ $maxd =~ ^[0-9]+$ ]] || die "--max-domains takes a number of domains, not '$maxd'"
  local capped=0
  if [[ ${#keep[@]} -gt $maxd ]]; then
    local i
    for ((i = maxd; i < ${#keep[@]}; i++)); do
      dropped+=("${keep[i]} — past the cap of $maxd domains")
      capped=$((capped + 1))
    done
    keep=("${keep[@]:0:maxd}")
  fi

  # A truncated list that says nothing reads as "that was everything", so this
  # one always says what it left out and how to get it back.
  for s in ${dropped[@]+"${dropped[@]}"}; do log "not querying $s"; done
  [[ $capped -eq 0 ]] ||
    log "raise the cap with dns_max_domains in $DIR/config.json, or name one with --domain"

  [[ ${#keep[@]} -gt 0 ]] ||
    die "no domain to ask about — orgami dns --domain <domain>, or add a \"domains\" array to $DIR/config.json"

  echo "public DNS for ${#keep[@]} domain(s), from $origin:" >&2
  printf '  %s\n' "${keep[@]}" >&2
  if [[ $yes == 0 ]]; then
    need_tty "pass --yes to query without asking"
    local ans
    read -rp "query these? [y/N] " ans
    [[ $(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]') == y* ]] || die "aborted"
  fi

  DNS_CACHE=$(mktemp -d)
  DNS_ROWS=$(mktemp)
  DNS_SEEN=$(mktemp)
  DNS_ERRORS=$(mktemp)
  DNS_DATE=$(date -u +%Y-%m-%d)

  for d in "${keep[@]}"; do
    log "asking about $d"
    dns_domain_scan "$d"
  done

  local queries
  queries=$(find "$DNS_CACHE" -type f 2>/dev/null | grep -c '' || true)

  local out="$DIR/map/dns.json" tmp
  tmp=$(mktemp)
  jq -n --arg company "$COMPANY" --arg org "$ORG" \
    --arg at "$(dns_now)" --argjson epoch "$(date -u +%s)" \
    --argjson queries "${queries:-0}" \
    --arg origin "$origin" \
    --argjson domains "$(printf '%s\n' "${keep[@]}" |
      jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson skipped "$(printf '%s\n' ${dropped[@]+"${dropped[@]}"} |
      jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --slurpfile rows "$DNS_ROWS" \
    --slurpfile seen "$DNS_SEEN" \
    --slurpfile errors "$DNS_ERRORS" \
    --argjson unverified "$(if [[ $unverified == 1 ]]; then printf '%s\n' "${keep[@]}"; fi |
      jq -Rsc 'split("\n") | map(select(. != ""))')" \
    '# One vendor per id, out of whichever rows it is handed.
     def by_vendor:
       group_by(.id)
       | map(([group_by(.domain + " " + .signal)[] | sort_by(.at)[0:3][]]) as $kept
             | {id: .[0].id, name: .[0].name, category: .[0].category,
                portal: .[0].portal, flags: (.[0].flags // []),
                domains: (map(.domain) | unique),
                signals: (map(.signal) | unique | sort),
                # A domain carrying five google-site-verification tokens is
                # carrying five copies of one finding. Three of each domain and
                # record kind is enough for anyone to check it; the rest are
                # counted, which is also what keeps this off being a zone dump.
                evidence: ($kept | map({domain, signal, at})
                           | sort_by(.domain, .signal, .at)),
                evidence_omitted: (length - ($kept | length))})
       | sort_by(.id);
     # A record on a domain nothing says the organization owns is an account of
     # whoever does own it, so it never joins `vendors`, which every reader of
     # this file takes as the organization itself. It is kept, apart, for
     # whoever wants to check what the fallback found.
     ($rows | map(select(.domain as $d | ($unverified | index($d)) == null))
      | by_vendor) as $vendors
     | ($rows | map(select(.domain as $d | ($unverified | index($d)) != null))
        | by_vendor) as $uvendors
     | {company: $company, org: $org,
        generated: $at, generated_epoch: $epoch,
        origin: $origin,
        domains: $domains,
        unverified: $unverified,
        skipped: $skipped,
        counts: {domains: ($domains | length),
                 skipped: ($skipped | length),
                 queries: $queries,
                 vendors: ($vendors | length),
                 unverified_vendors: ($uvendors | length),
                 records: ([$seen[].records] | add // 0),
                 records_matched: ([$seen[].matched] | add // 0),
                 records_unmatched: (([$seen[].records] | add // 0)
                                     - ([$seen[].matched] | add // 0))},
        read: $seen,
        vendors: $vendors,
        unverified_vendors: $uvendors,
        errors: $errors}' >"$tmp" || {
    rm -f "$tmp"
    die "could not write $out"
  }
  mv "$tmp" "$out"

  rm -rf "$DNS_CACHE"
  rm -f "$DNS_ROWS" "$DNS_SEEN" "$DNS_ERRORS"

  local page="$DIR/map/DNS.md"
  dns_render "$out" >"$page"

  if [[ $as_json == 1 ]]; then
    cat "$out"
    return 0
  fi

  jq -r '.vendors[]
    | "  " + .name + "  " + (.signals | join(",")) + "  " + (.domains | join(" "))' "$out"
  [[ $(jq '.counts.vendors' "$out") -gt 0 ]] && echo

  log "$out"
  log "$page"
  jq -r '"\(.counts.vendors) vendor(s) across \(.counts.domains) domain(s), from "
         + "\(.counts.queries) quer\(if .counts.queries == 1 then "y" else "ies" end) — "
         + "\(.counts.records_matched) of \(.counts.records) records matched the catalogue"
         + (if (.counts.unverified_vendors // 0) > 0
            then "\n\(.counts.unverified_vendors) more on domains not known to be the "
                 + "organization'"'"'s, kept apart in unverified_vendors and left out of the count"
            else "" end)' "$out"
  [[ $(jq '.errors | length' "$out") -eq 0 ]] ||
    jq -r '.errors[] | "  " + .domain + ": " + .message' "$out"
  return 0
}

# --- reading it back -----------------------------------------------------------

# How old the reading is, in whole days. A DNS record changes far less often
# than a running deployment, so the threshold is months rather than a week — but
# a reading from before the last renewal season is still worth labelling.
dns_age_days() {
  local f="$DIR/map/dns.json" was now
  [[ -f $f ]] || return 1
  was=$(jq -r '.generated_epoch // empty' "$f" 2>/dev/null)
  [[ -n $was ]] || return 1
  now=$(date -u +%s)
  echo $(((now - was) / 86400))
}

dns_age_phrase() {
  local age=${1:-}
  if [[ -z $age || $age == "?" ]]; then echo "at some point"
  elif [[ $age -le 0 ]]; then echo "today"
  elif [[ $age == 1 ]]; then echo "yesterday"
  elif [[ $age -lt 60 ]]; then echo "$age days ago"
  else echo "$((age / 30)) months ago"
  fi
}

# --- the page ------------------------------------------------------------------

# One `### vendor` block per vendor in the list named by $2, with the records
# behind it. A `no-bill` vendor's portal is where to see who verified the
# domain, not a bill, and its block says so rather than offering a price.
dns_render_vendors() {
  jq -r --arg list "$2" '
    [(.[$list] // [])[]
     | ((.flags // []) | index("no-bill") != null) as $nobill
     | "### \(.name)",
       "",
       "`vendor:\(.id)` · \(.category) · \(.domains | join(", "))"
         + (if .portal == "" then ""
            elif $nobill then " · [who verified it](\(.portal))"
            else " · [what it costs](\(.portal))" end),
       "",
       (if $nobill
        then "A verification token, and nothing more: a service of this vendor"
             + " verified the domain. It does not say which one, or that anybody"
             + " pays for it.", ""
        else empty end),
       "| Record | Evidence |",
       "|---|---|",
       (.evidence[] | "| `\(.signal)` | `\(.at)` |"),
       (if (.evidence_omitted // 0) > 0
        then "", "<sub>\(.evidence_omitted) further record(s) of the same kind matched"
             + " the same signals and are not repeated here.</sub>"
        else empty end),
       ""]
    | .[]' "$1"
}

dns_render() {
  local f=$1 age
  age=$(dns_age_days 2>/dev/null || echo "?")

  echo "# $COMPANY — what the DNS says the org has an account with"
  echo
  echo "Read from public DNS $(dns_age_phrase "$age"), from $(jq -r '.origin' "$f")."
  echo
  cat <<'EOF'
Every line below is a record anyone can look up. Re-run the `dig` in the
evidence column and you will see the same thing, which is what makes this
checkable in a way a reading of somebody's cloud account is not.

What a record proves is narrow and worth being exact about. A verification
token is the vendor stating that this organization proved it owns the domain —
that is an account. An MX record says where the mail goes. An SPF `include:`
says a service was given permission to send as the organization. A CNAME says a
subdomain was pointed somewhere on purpose. None of them is an invoice, and
none of them says what anything costs.

A vendor that does not appear here was **not found in this organization's
public DNS**, which is not the same fact as not being in use.
EOF
  echo

  if [[ $(jq -r '(.domains - (.unverified // [])) | length' "$f") == 0 ]]; then
    echo "None of the domains read is known to be this organization's — see the"
    echo "section below — so nothing here is counted as an account of its own."
    echo
  elif [[ $(jq -r '.counts.vendors' "$f") == 0 ]]; then
    jq -r '"Nothing in the \(.counts.records) record(s) read across "
           + "\(.counts.domains) domain(s) matched the catalogue."' "$f"
    echo
  else
    dns_render_vendors "$f" vendors
  fi

  if [[ $(jq -r '(.unverified_vendors // []) | length' "$f") -gt 0 ]]; then
    echo "## On domains not known to be the organization's"
    echo
    jq -r '"Read from " + ((.unverified // []) | join(", ")) + "."' "$f"
    cat <<'EOF'
Nothing said these are the organization's own: no domains list in its
config, no website read off its GitHub profile, no host in the map named
after it.
They were taken from hosts the code calls, which are as often a partner's API
or a vendor's endpoint, so a record here is an account of whoever owns the
domain. They are not counted above and `orgami advise` leaves them out. Name
the organization's own domains with `orgami dns --domain`, or a `domains`
array in its config.
EOF
    echo
    dns_render_vendors "$f" unverified_vendors
  fi

  jq -r '"Read \(.counts.records) record(s) across \(.counts.domains) domain(s) in "
         + "\(.counts.queries) quer\(if .counts.queries == 1 then "y" else "ies" end). "
         + "\(.counts.records_unmatched) matched nothing in the catalogue and were not "
         + "recorded — only the records behind a finding are kept."' "$f"
  echo

  if [[ $(jq -r '.skipped | length' "$f") -gt 0 ]]; then
    echo "Not queried:"
    echo
    jq -r '.skipped[] | "- " + .' "$f"
    echo
  fi

  if [[ $(jq -r '.errors | length' "$f") -gt 0 ]]; then
    echo "Did not answer:"
    echo
    jq -r '.errors[] | "- **" + .domain + "** — " + .message' "$f"
    echo
  fi

  if [[ $age != "?" && $age -ge $DNS_STALE_DAYS ]]; then
    echo "**Read $(dns_age_phrase "$age") and not since** — a domain can be moved to a"
    echo "different provider in an afternoon. Re-run \`orgami dns\`."
    echo
  fi
}

# The org-level block, for whatever renders the whole map. Silent until somebody
# has run the command.
dns_overview() {
  local f="$DIR/map/dns.json" age n
  [[ -f $f ]] || return 0
  # A no-bill vendor is a verification, not a bill, so it is left off a list
  # headed "paid for" — DNS.md still carries it with its record.
  n=$(jq -r '[.vendors[] | select((.flags // []) | index("no-bill") | not)] | length' \
    "$f" 2>/dev/null || echo 0)
  [[ ${n:-0} -gt 0 ]] || return 0
  age=$(dns_age_days || echo "?")

  echo "## What the DNS says is paid for"
  echo
  jq -r '.vendors[] | select((.flags // []) | index("no-bill") | not)
    | "- **" + .name + "** — " + .category + " · " + (.domains | join(", "))
      + " · " + (.signals | join(", "))' "$f"
  echo
  echo "Read from public DNS $(dns_age_phrase "$age") with \`orgami dns\`. These are"
  echo "records anybody can look up, so unlike a cloud reading they can be checked"
  echo "afterwards — but a record is evidence of an account, never of a price."
  echo
}
