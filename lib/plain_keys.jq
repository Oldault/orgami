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

def words: gsub("_"; " ");
# tostring of a number holds digits, a sign, a dot and an exponent; only the
# dot and the plus are special in a pattern.
def lit: tostring | gsub("[.]"; "[.]") | gsub("[+]"; "[+]");

reduce ($s[0] | to_entries[] | select(.key | test("^[a-z][a-z0-9_]*$"))) as $e (.;
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
