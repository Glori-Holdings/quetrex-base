#!/usr/bin/env bash
# test/plugin-one-copy.test.sh — ONE COPY, generalized to the WHOLE
# setup-plugin split (AC23 of .quetrex/plan/GLOBAL.json): every command,
# hook, lib script and bin/ tool that GLOBAL.json's split touched must be
# tracked in exactly ONE place across .claude/, plugins/quetrex-factory/,
# plugins/quetrex-setup/, bin/ and hooks/ — never left behind at its old path
# AND moved, never duplicated at both.
#
# WHY A SEPARATE FILE FROM floor-one-copy.test.sh. That file pins the ONE-COPY
# task's narrower floor-script/agent-contract property. This task moves a
# DIFFERENT set of files (login/init/update commands, two SessionStart hooks,
# a lib script, a statusline renderer, five bin/ tools) into a THIRD plugin
# directory (plugins/quetrex-setup/) that did not exist when that file was
# written. Rather than keep widening an unrelated file's scope, this task
# gets its own one-copy proof, walking the full set of directories the split
# actually touches.
#
# WHY BASENAME, NOT FULL PATH. A `git mv` that left a stray copy behind (or a
# `cp` that was meant to be a `mv`) produces two DIFFERENT full paths for the
# SAME basename — grouping by basename is what catches that; grouping by path
# would just confirm each individual path is unique, which is never in
# question.
#
# ALLOWED_MULTIPLE exists because per-plugin manifests (plugin.json,
# hooks.json) and per-skill/per-directory docs (SKILL.md, reference.md,
# CLAUDE.md, README.md) are LEGITIMATELY one-per-directory — a real duplicate
# basename, not a leftover. Each entry on that list is itself asserted to
# occur more than once, so the list can never rot into unused decoration that
# silently widens what this test tolerates.
#
# FAIL-FIRST (mechanical): `cp` any one of the files this task moved back to
# its pre-split path (e.g. a duplicate `.claude/commands/init.md` alongside
# the real plugins/quetrex-setup/commands/init.md) and this file prints >= 1
# NOT OK line and exits non-zero. Demonstrated below by construction rather
# than only asserted in prose: this test is driven by `git ls-files`, so any
# such duplicate — committed under either path — is caught the same way a
# real regression would be.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# Basenames legitimately tracked more than once: per-plugin manifests and
# per-directory docs. Anything else appearing twice is a leftover, not a
# feature.
#
# README.md is deliberately NOT on this list: this repo has zero README.md
# files under the walked directories today, so listing it would itself be
# the stale-decoration failure mode this test exists to catch (see the loop
# below that asserts every entry actually occurs more than once). Add it back
# the day a second one is genuinely, legitimately committed.
ALLOWED_MULTIPLE="plugin.json hooks.json SKILL.md reference.md CLAUDE.md"

WALK_DIRS=".claude plugins/quetrex-factory plugins/quetrex-setup bin hooks"

TRACKED="$(git ls-files -- $WALK_DIRS)"

if [ -z "$TRACKED" ]; then
  notok "git ls-files over ($WALK_DIRS) returned 0 files — the walk is broken, not the tree"
else
  ok "git ls-files over ($WALK_DIRS) returned $(printf '%s\n' "$TRACKED" | grep -c .) tracked file(s)"
fi

# --- group by basename, report every basename tracked more than once -------
DUP_BASENAMES="$(printf '%s\n' "$TRACKED" | xargs -n1 basename 2>/dev/null | sort | uniq -d)"

UNEXPECTED_DUPS=0
if [ -n "$DUP_BASENAMES" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    allowed=0
    for a in $ALLOWED_MULTIPLE; do
      [ "$b" = "$a" ] && allowed=1 && break
    done
    if [ "$allowed" -eq 1 ]; then
      continue
    fi
    UNEXPECTED_DUPS=$((UNEXPECTED_DUPS + 1))
    PATHS="$(printf '%s\n' "$TRACKED" | grep -E "(^|/)$(printf '%s' "$b" | sed 's/[.[\*^$]/\\&/g')\$")"
    notok "basename '$b' is tracked more than once, and is NOT on ALLOWED_MULTIPLE: $(printf '%s' "$PATHS" | tr '\n' ' ')"
  done <<EOF
$DUP_BASENAMES
EOF
fi
[ "$UNEXPECTED_DUPS" -eq 0 ] && ok "0 unexpected duplicate basenames across ($WALK_DIRS)"

# --- ALLOWED_MULTIPLE cannot rot into decoration: each entry must actually
# occur more than once, or the exemption is stale and should be removed -----
for a in $ALLOWED_MULTIPLE; do
  n="$(printf '%s\n' "$DUP_BASENAMES" | grep -cx "$a" || true)"
  if [ "$n" -ge 1 ]; then
    ok "ALLOWED_MULTIPLE entry '$a' genuinely occurs more than once — not stale decoration"
  else
    notok "ALLOWED_MULTIPLE entry '$a' does NOT occur more than once anywhere under ($WALK_DIRS) — remove it, a stale allow-list entry hides a real regression"
  fi
done

# --- specific regression coverage: the files THIS task moved must each be
# tracked in exactly the ONE new location, never the old one too -----------
declare -a MOVED=(
  ".claude/commands/login.md|plugins/quetrex-setup/commands/login.md"
  ".claude/commands/init.md|plugins/quetrex-setup/commands/init.md"
  ".claude/commands/update.md|plugins/quetrex-setup/commands/update.md"
  ".claude/hooks/quetrex-update-check.sh|plugins/quetrex-setup/scripts/quetrex-update-check.sh"
  ".claude/hooks/quetrex-bound-version-guard.sh|plugins/quetrex-setup/scripts/quetrex-bound-version-guard.sh"
  ".claude/lib/quetrex-legacy-cleanup.sh|plugins/quetrex-setup/lib/quetrex-legacy-cleanup.sh"
  ".claude/statusline-command.sh|plugins/quetrex-setup/statusline-command.sh"
  "bin/quetrex-api|plugins/quetrex-setup/bin/quetrex-api"
  "bin/quetrex-arm|plugins/quetrex-setup/bin/quetrex-arm"
  "bin/quetrex-cleanup|plugins/quetrex-setup/bin/quetrex-cleanup"
  "bin/quetrex-env-derive|plugins/quetrex-setup/bin/quetrex-env-derive"
  "bin/quetrex-version|plugins/quetrex-setup/bin/quetrex-version"
)

for pair in "${MOVED[@]}"; do
  old_path="${pair%%|*}"
  new_path="${pair##*|}"
  old_tracked=0; new_tracked=0
  git ls-files --error-unmatch "$old_path" >/dev/null 2>&1 && old_tracked=1
  git ls-files --error-unmatch "$new_path" >/dev/null 2>&1 && new_tracked=1
  if [ "$new_tracked" -eq 1 ] && [ "$old_tracked" -eq 0 ]; then
    ok "$new_path is tracked, and the pre-split path $old_path is not (real move, not a duplicate)"
  elif [ "$old_tracked" -eq 1 ] && [ "$new_tracked" -eq 1 ]; then
    notok "$old_path AND $new_path are BOTH tracked — this is a copy, not a move (one-copy violation)"
  else
    notok "expected $new_path to be tracked (old path: $old_path tracked=$old_tracked, new path tracked=$new_tracked)"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "plugin-one-copy.test.sh: all checks passed"
else
  echo "plugin-one-copy.test.sh: FAILURES above"
fi
exit "$FAIL"
