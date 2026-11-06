# The model's markdown, read raw as one string, with every STATS key name it
# quoted turned back into words. $s[0] is the STATS object it was handed.
#
# Beside its own value the key collapses to the value, so "`merged_by_bots`
# (13) bot pull requests" reads "13 bot pull requests" and "(`merged_without_review`
# is 62)" reads "(62)". Anywhere else it becomes the words it is made of. A key
# is matched unquoted only when it holds an underscore: `merged` or `reviewers`
# without backticks is English, `merged_by_bots` never is.
#
# Only numbers collapse, and only to the exact figure jq computed: a key next to
# some other number is left as words beside that number, never silently
# reconciled with it.
#
# The name of the document goes too. Told to cite the figure an item rests on,
# a model writes "(STATS: `merged_without_review`)": the key became words and
# the label stayed, so the reader met a source they have never seen. `unlabel`
# runs first and strips the label wherever it is used as one — a parenthesis of
# its own, a `STATS:` prefix, a `STATS.key` path — so the key behind it is then
# rewritten like any other. PULL_REQUESTS and ACTIVITY are the other documents
# a prompt hands over, and are cited the same way.

def words: gsub("_"; " ");

def unlabel:
  "`?(?<![A-Za-z0-9_])(?:STATS|PULL_REQUESTS|ACTIVITY)(?![A-Za-z0-9_])`?" as $doc
  | gsub("[ \\t]*\\(\\s*(?:(?:per|from|see|in)\\s+)?" + $doc + "\\s*\\)"; "")
  | gsub("`(?:STATS|PULL_REQUESTS|ACTIVITY)[.](?<k>[a-z][a-z0-9_]*)`"; "`" + .k + "`")
  | gsub($doc + "(?:[.](?=[a-z])|\\s*:\\s*)"; "");
# tostring of a number holds digits, a sign, a dot and an exponent; only the
# dot and the plus are special in a pattern.
def lit: tostring | gsub("[.]"; "[.]") | gsub("[+]"; "[+]");

unlabel
| reduce ($s[0] | to_entries[] | select(.key | test("^[a-z][a-z0-9_]*$"))) as $e (.;
  ("`" + $e.key + "`") as $q
  | (if ($e.value | type) == "number" then
       ($e.value | tostring) as $n
       | ($e.value | lit) as $v
       | gsub($q + "\\s*\\(\\s*" + $v + "\\s*\\)"; $n)
       | gsub($q + "(?:\\s+(?:is|was|of)|\\s*[:=])\\s*" + $v + "(?![0-9]|[.][0-9])"; $n)
     else . end)
  | gsub($q; $e.key | words)
  | if ($e.key | test("_")) then
      gsub("(?<![A-Za-z0-9_])" + $e.key + "(?![A-Za-z0-9_])"; $e.key | words)
    else . end)
