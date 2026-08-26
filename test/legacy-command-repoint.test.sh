#!/usr/bin/env bash
# test/legacy-command-repoint.test.sh — AC20 of .quetrex/plan/GLOBAL.json: the
# repo-wide prose repoint (54 files, 197 references — the full inventory is
# recorded in .quetrex/plan/GLOBAL.json's notes.prose_repoint_inventory) is
# COMPLETE. `git grep -nE '/quetrex:(login|init|update)'` over the merged
# branch must hit ONLY an explicit, committed allow-list — never anything
# unlisted.
#
# THE ALLOW-LIST IS CURRENTLY EMPTY, and that is the correct, verified state:
# every one of the 197 references was either (a) a live user-facing string,
# now repointed to /quetrex-setup:<verb>, or (b) already excluded from the
# repoint because it lives ONLY in git history (a `git show <sha>:<path>`
# fail-first comparison fetches the OLD file's bytes at test-run time — the
# literal old string is never present in any file this grep walks) — so
# there is nothing in the current working tree that legitimately still reads
# the login, init or update verbs under the old `quetrex:` namespace.
#
# THE TEST STILL EARNS ITS KEEP WITH AN EMPTY LIST: it is the mechanism that
# would catch a REGRESSION (an old string resurfacing, a rebase reintroducing
# a superseded line) and the mechanism a future, deliberate exception would
# extend — "empty allow-list, zero hits" is itself the invariant being
# pinned, not a placeholder waiting to be filled in.
#
# BOTH DIRECTIONS ARE CHECKED, per AC20's own measure: a hit NOT on the
# allow-list is red (a repoint was missed or a regression landed), AND an
# allow-list entry that no longer matches anything is ALSO red (the list
# rotted into decoration nobody is checking against reality).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# The committed allow-list. Each entry is a `file:line` pair, exactly as
# `git grep -n` would print it (minus the matched text), for a hit this repo
# deliberately keeps. Empty today — see header.
ALLOWLIST=()

HITS_RAW="$(git grep -nE '/quetrex:(login|init|update)' -- . 2>/dev/null | grep -v '^\.quetrex-backups/\|^\.quetrex/plan/' || true)"

# Reduce each hit to `file:line` (drop the matched text) so it can be
# compared against ALLOWLIST regardless of the exact matched substring.
HITS=()
if [ -n "$HITS_RAW" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    HITS+=("$(printf '%s' "$line" | cut -d: -f1,2)")
  done <<< "$HITS_RAW"
fi

echo "# ${#HITS[@]} hit(s) for /quetrex:(login|init|update) outside .quetrex-backups/ and .quetrex/plan/"
if [ "${#HITS[@]}" -gt 0 ]; then
  printf '#   %s\n' "${HITS[@]}"
fi

# --- direction 1: every real hit must be on the allow-list ------------------
UNLISTED=0
for h in "${HITS[@]:-}"; do
  [ -n "$h" ] || continue
  found=0
  for a in "${ALLOWLIST[@]:-}"; do
    [ "$h" = "$a" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    UNLISTED=$((UNLISTED + 1))
    notok "unlisted hit: $h still reads /quetrex:(login|init|update) and is not on the committed allow-list — repoint it to /quetrex-setup:<verb> or add it to ALLOWLIST with a stated reason"
  fi
done
[ "$UNLISTED" -eq 0 ] && ok "every real hit (${#HITS[@]}) is on the committed allow-list"

# --- direction 2: every allow-list entry must still be a real hit ----------
STALE=0
for a in "${ALLOWLIST[@]:-}"; do
  [ -n "$a" ] || continue
  found=0
  for h in "${HITS[@]:-}"; do
    [ "$h" = "$a" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    STALE=$((STALE + 1))
    notok "stale allow-list entry: $a no longer matches any real hit — remove it, a stale entry hides a real regression"
  fi
done
[ "$STALE" -eq 0 ] && ok "every allow-list entry (${#ALLOWLIST[@]}) still matches a real hit"

# --- the hit SET equals the allow-list SET, exactly (belt and suspenders) --
if [ "${#HITS[@]}" -eq "${#ALLOWLIST[@]}" ] && [ "$UNLISTED" -eq 0 ] && [ "$STALE" -eq 0 ]; then
  ok "the hit set equals the committed allow-list exactly (${#HITS[@]} entries)"
else
  notok "the hit set (${#HITS[@]}) does not equal the committed allow-list (${#ALLOWLIST[@]}) exactly"
fi

echo
echo "legacy-command-repoint.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
