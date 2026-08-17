#!/usr/bin/env bash
# no-duplicate-hook-owners.test.sh — one hook, one owner.
#
# WHAT WENT WRONG. This repo's .claude/settings.json registered all EIGHT of the
# hooks the two plugins already register. Both plugins are enabled here, so every
# Stop ran TWO full verify chains CONCURRENTLY. Measured on 2026-08-17: ~6m26s per
# turn, on turns where the operator only asked a question and nothing on disk
# changed. The SessionStart banner printed twice for the same reason. It also
# produced exit 124 and exit 143 kills that blocked the operator's turn outright,
# because two ~3-minute chains contending are slower than the gate's own budget.
#
#   factory 1.7.1 registers: right-size-router deny-guard secret-scan
#                            enforce-branch merge-gate format verify-gate
#   quetrex 2.5.1 registers: session-state quetrex-update-check edit-gate
#   this repo registered:    ALL EIGHT of the overlapping ones
#
# WHICH COPY GOES, AND WHY IT IS ALWAYS THIS ONE. Consumer repos (quetrex-demo,
# quetrex-web) ship no hooks of their own and depend on the plugin registration
# entirely — removing factory's copy would leave them ungated. quetrex-base is the
# only repo that both SHIPS the hooks as source and ENABLES the plugin, so it is
# the only place a duplicate can exist, and its own registration is the removable
# one. Deleting the plugin's copy is never the answer.
#
# THIS IS NOT A REPO-WIDE RULE. "A project must not register hooks" would be wrong
# for a repo with no plugin enabled — there, its own settings are the only floor.
# The rule asserted here is narrower and is the true one: do not register a script
# an ENABLED PLUGIN ALREADY OWNS.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${QX_SETTINGS_JSON:-$ROOT/.claude/settings.json}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

[ -f "$SETTINGS" ] || { echo "NOT OK - settings not found: $SETTINGS"; exit 1; }

# Plugin-owned script basenames, committed so ASSERTION 1 runs in a fresh clone and
# in CI where no plugin cache exists. ASSERTION 2 recomputes this from the real
# hooks.json files wherever they are reachable and fails on drift, so the list
# cannot rot into decoration.
#
# auto-format.sh is listed deliberately: factory ships the same role as format.sh
# under a different basename, so matching on filename alone would miss it.
OWNED='deny-guard.sh
secret-scan.sh
enforce-branch.sh
merge-gate.sh
verify-gate.sh
format.sh
auto-format.sh
right-size-router.sh
session-state.sh
quetrex-update-check.sh
edit-gate.sh'

# Every hook command this repo's settings register, across every event.
CMDS="$(node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const out=[];
  for (const [ev,groups] of Object.entries((j&&j.hooks)||{}))
    for (const g of groups||[])
      for (const h of (g&&g.hooks)||[])
        if (h&&typeof h.command==="string") out.push(ev+"\t"+h.command);
  process.stdout.write(out.join("\n"));
' "$SETTINGS" 2>/dev/null)"

# --- ASSERTION 1: no plugin-owned script is registered here ------------------
DUPES=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  hits="$(printf '%s' "$CMDS" | grep -F -- "$script" || true)"
  if [ -n "$hits" ]; then
    DUPES=$((DUPES+1))
    notok "ASSERTION 1: $script is registered by .claude/settings.json AND owned by an enabled plugin — it will run TWICE per event: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
done <<< "$OWNED"
[ "$DUPES" -eq 0 ] && ok "ASSERTION 1: this repo registers none of the $(printf '%s' "$OWNED" | grep -c .) plugin-owned hook scripts"

# --- ASSERTION 2: the owned list still matches the real plugins --------------
# Recompute from whatever plugin copies are reachable. Absence is reported, never
# silent — same convention as hook-parity.test.sh's ASSERTION 3.
FOUND=""
for cand in "$HOME"/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/hooks/hooks.json \
            "$HOME"/.claude/plugins/cache/quetrex/quetrex-factory/*/hooks/hooks.json \
            "$ROOT/../quetrex-plugins/plugins/quetrex-factory/hooks/hooks.json"; do
  [ -f "$cand" ] && FOUND="$cand"
done

if [ -n "$FOUND" ]; then
  LIVE="$(node -e '
    const fs=require("fs");
    const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const s=new Set();
    for (const [ev,groups] of Object.entries((j&&j.hooks)||{}))
      for (const g of groups||[])
        for (const h of (g&&g.hooks)||[]) {
          const m=(h&&h.command||"").match(/([A-Za-z0-9_-]+\.sh)/);
          if (m) s.add(m[1]);
        }
    process.stdout.write([...s].sort().join("\n"));
  ' "$FOUND" 2>/dev/null)"
  MISSING=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf '%s\n' "$OWNED" | grep -qxF "$s" || MISSING="$MISSING $s"
  done <<< "$LIVE"
  if [ -z "$MISSING" ]; then
    ok "ASSERTION 2: every script the live quetrex-factory registers is in the committed owned-list (checked against $(basename "$(dirname "$(dirname "$FOUND")")"))"
  else
    notok "ASSERTION 2: the live quetrex-factory registers script(s) missing from this file's committed owned-list:$MISSING — the list has drifted and ASSERTION 1 is now blind to them"
  fi
else
  echo "# no factory hooks.json reachable (fresh clone / CI runner) — ASSERTION 2 could not run"
  ok "ASSERTION 2: skipped, no factory copy reachable (reported, not silent; ASSERTION 1 still runs from committed state)"
fi

# --- ASSERTION 3: the installer must not be able to re-create the duplication -
# .claude/lib/quetrex-install-project-gates.sh writes hook registrations into a
# repo's settings.json. Nothing invokes it today, but it SHIPS inside the quetrex
# plugin, so it is one command away from putting all eight duplicates back and
# returning the operator to ~6-minute turns. Assert it cannot name a script the
# plugins already own. If this fails, either the installer is obsolete and should
# be removed, or it needs to skip plugin-owned scripts — that is an operator call,
# not something to silently "fix" by trimming this list.
INSTALLER="$ROOT/.claude/lib/quetrex-install-project-gates.sh"
if [ -f "$INSTALLER" ]; then
  DECLARED="$(sed -n 's/^GATE_SCRIPTS=["'"'"']\(.*\)["'"'"']$/\1/p' "$INSTALLER" | tr ' ' '\n' | grep -c '\.sh$' || true)"
  CLASH=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    sed -n 's/^GATE_SCRIPTS=.*/&/p' "$INSTALLER" | grep -qF -- "$s" && CLASH="$CLASH $s"
  done <<< "$OWNED"
  if [ -z "$CLASH" ]; then
    ok "ASSERTION 3: the project-gates installer declares no plugin-owned script ($DECLARED declared)"
  else
    notok "ASSERTION 3: the project-gates installer would re-register plugin-owned script(s) —$CLASH — running it re-creates the double-registration this file exists to prevent"
  fi
else
  ok "ASSERTION 3: skipped, no project-gates installer present (reported, not silent)"
fi

echo
echo "no-duplicate-hook-owners.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
