# What counts as a bot. The only definition — lib/stats.jq, lib/daily.jq and the
# coupling pass in lib/coupling.sh all include this file, so an account cannot be
# a bot in one figure and a person in the next.
#
# A pattern and not a list of logins, because the two generic suffixes catch the
# automation nobody thought to name: `[bot]` is what GitHub appends to every
# installed app, and `-bot` is the convention self-hosted runners follow. A list
# only ever covers the bots that were noisy enough to get added to it.
def bot_pattern:
  "dependabot|renovate|github-actions|snyk-bot|greenkeeper|-bot$|\\[bot\\]";

# Takes a login, so callers read `.author.login | is_bot`. A pull request whose
# author GitHub no longer resolves comes through as null and counts as a person:
# a deleted account was somebody.
def is_bot: (. // "unknown") | test(bot_pattern; "i");
def is_human: is_bot | not;
