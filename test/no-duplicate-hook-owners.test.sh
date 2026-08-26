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

# Plugin-owned script basenames, PER OWNING PLUGIN, committed so ASSERTION 1 runs
# in a fresh clone and in CI where no plugin cache exists. ASSERTION 2 recomputes
# these from the real hooks.json files wherever they are reachable and fails on
# drift, so the lists cannot rot into decoration.
#
# auto-format.sh is listed deliberately: factory ships the same role as format.sh
# under a different basename, so matching on filename alone would miss it.
FACTORY_OWNED='deny-guard.sh
secret-scan.sh
enforce-branch.sh
merge-gate.sh
verify-gate.sh
format.sh
auto-format.sh
right-size-router.sh'
# quetrex-update-check.sh and quetrex-bound-version-guard.sh MOVED to
# quetrex-setup with the setup-plugin split (GLOBAL.json) — they are no
# longer registered by `quetrex`'s own hooks.json. See SETUP_OWNED below.
QUETREX_OWNED='session-state.sh
edit-gate.sh
protected-files-guard.sh'
# quetrex-setup is enabled MACHINE-WIDE (every repo, armed or not), so its
# three SessionStart hooks are just as much a duplication hazard here as
# quetrex's or quetrex-factory's.
SETUP_OWNED='unarmed-offer.sh
quetrex-update-check.sh
quetrex-bound-version-guard.sh'

# WHICH PLUGINS ARE ACTUALLY ENABLED HERE. This is the whole point, and getting it
# wrong inverts the test into a hazard. A script is only a DUPLICATE if the plugin
# that owns it is enabled in THIS repo. In a repo with the plugin disabled, that
# same registration is not a duplicate — it is the only safety floor there is, and
# a test that demanded its removal would be telling the operator to disarm the repo.
# dealerq-2026 is exactly that shape today: factory disabled, hooks unwired, no
# floor at all. Never let this file argue for more of that.
enabled() {  # enabled <plugin-key>  -> 0 enabled, 1 not enabled, 2 unparseable
  node -e '
    const fs=require("fs");
    // exit 0 = enabled, 1 = not enabled, 2 = could not parse (NOT the same thing).
    let j; try { j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch(e) { process.exit(2); }
    const v=((j||{}).enabledPlugins||{})[process.argv[2]];
    // ONLY boolean true. A version-pin array makes the plugin fail to load, so in
    // a pinned repo the local registrations are the real floor, not duplicates;
    // calling a pin enabled would make this test demand their deletion.
    process.exit(v===true?0:1);
  ' "$SETTINGS" "$1" 2>/dev/null
}

enabled "quetrex-factory@quetrex"; RC_F=$?
if [ "$RC_F" -eq 2 ]; then
  notok "ASSERTION 0: $SETTINGS could not be parsed — this test cannot tell 'plugin disabled' from 'file broken', and a broken settings file means NOTHING is registered. Fix the JSON before trusting any result below."
  echo; echo "no-duplicate-hook-owners.test.sh: $PASS passed, $FAIL failed"; exit 1
fi
OWNED=""
if [ "$RC_F" -eq 0 ]; then OWNED="$FACTORY_OWNED"; FACTORY_ON=yes; else FACTORY_ON=no; fi
if enabled "quetrex@quetrex"; then OWNED="$(printf '%s\n%s' "$OWNED" "$QUETREX_OWNED" | grep -v '^$')"; QUETREX_ON=yes; else QUETREX_ON=no; fi
if enabled "quetrex-setup@quetrex"; then OWNED="$(printf '%s\n%s' "$OWNED" "$SETUP_OWNED" | grep -v '^$')"; SETUP_ON=yes; else SETUP_ON=no; fi
echo "# enabled here: quetrex-factory=$FACTORY_ON quetrex=$QUETREX_ON quetrex-setup=$SETUP_ON"

NO_PLUGIN_ENABLED=0
[ -z "$OWNED" ] && NO_PLUGIN_ENABLED=1

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

# --- ASSERTION 1: no ENABLED-plugin-owned script is registered here ----------
if [ "$NO_PLUGIN_ENABLED" -eq 1 ]; then
  ok "ASSERTION 1: no Quetrex plugin is enabled here, so nothing it ships can be a duplicate — this repo's own registrations are its only floor and must NOT be removed"
else
  DUPES=0
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    # Anchor on the path separator so a repo's OWN distinctly-named guard
    # (repo-secret-scan.sh, company-deny-guard.sh) is not misread as a plugin
    # duplicate — telling an operator to delete their own guard would be the
    # exact inverse of this file's purpose.
    hits="$(printf '%s' "$CMDS" | grep -E -- "[/\"']${script%.sh}\.sh" || true)"
    if [ -n "$hits" ]; then
      DUPES=$((DUPES+1))
      notok "ASSERTION 1: $script is registered by .claude/settings.json AND owned by an ENABLED plugin — it will run TWICE per event: $(printf '%s' "$hits" | tr '\n' ' ')"
    fi
  done <<< "$OWNED"
  [ "$DUPES" -eq 0 ] && ok "ASSERTION 1: this repo registers none of the $(printf '%s' "$OWNED" | grep -c .) scripts owned by the plugins enabled here"
fi

# --- ASSERTION 2: the owned list still matches the real plugins --------------
# Recompute from whatever plugin copies are reachable, and from THIS repo's
# own shipped source (quetrex-base ships the quetrex-setup source directly,
# so that copy is always reachable, unlike factory's which may live only in a
# machine's plugin cache). Absence is reported, never silent — same
# convention as hook-parity.test.sh's ASSERTION 3.
live_hook_basenames() {  # live_hook_basenames <hooks.json path> -> newline-separated basenames
  node -e '
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
  ' "$1" 2>/dev/null
}

# Compare against the FULL committed catalogue, never the enabled-filtered
# $OWNED. Drift in what a plugin ships is a fact about that plugin, not about
# whether this particular repo happens to enable it — checking the filtered
# list would report phantom drift in every repo with the plugin switched off.
ALL_OWNED_CATALOGUES="$(printf '%s\n%s\n%s' "$FACTORY_OWNED" "$QUETREX_OWNED" "$SETUP_OWNED")"

assert_no_drift() {  # assert_no_drift <label> <live-basenames>
  local label="$1" live="$2" missing=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf '%s\n' "$ALL_OWNED_CATALOGUES" | grep -qxF "$s" || missing="$missing $s"
  done <<< "$live"
  if [ -z "$missing" ]; then
    ok "ASSERTION 2: every script $label registers is in the union of the committed owned-lists"
  else
    notok "ASSERTION 2: $label registers script(s) missing from the committed owned-lists:$missing — the list has drifted and ASSERTION 1 is now blind to them"
  fi
}

FOUND=""
for cand in "$HOME"/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/hooks/hooks.json \
            "$HOME"/.claude/plugins/cache/quetrex/quetrex-factory/*/hooks/hooks.json \
            "$ROOT/../quetrex-plugins/plugins/quetrex-factory/hooks/hooks.json"; do
  [ -f "$cand" ] && FOUND="$cand"
done
if [ -n "$FOUND" ]; then
  assert_no_drift "the live quetrex-factory (checked against $(basename "$(dirname "$(dirname "$FOUND")")"))" "$(live_hook_basenames "$FOUND")"
else
  echo "# no factory hooks.json reachable (fresh clone / CI runner) — ASSERTION 2 (factory) could not run"
  ok "ASSERTION 2: skipped for factory, no copy reachable (reported, not silent; ASSERTION 1 still runs from committed state)"
fi

# quetrex-setup's own hooks.json is this repo's committed source, so it is
# ALWAYS reachable here — no fresh-clone caveat applies.
SETUP_HOOKS_JSON="$ROOT/plugins/quetrex-setup/hooks/hooks.json"
if [ -f "$SETUP_HOOKS_JSON" ]; then
  assert_no_drift "quetrex-setup's own hooks/hooks.json" "$(live_hook_basenames "$SETUP_HOOKS_JSON")"
else
  notok "ASSERTION 2: plugins/quetrex-setup/hooks/hooks.json not found at $SETUP_HOOKS_JSON — cannot verify SETUP_OWNED against the real manifest"
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

# --- FAIL-FIRST (mechanical, AC28): a deliberate re-registration of
# unarmed-offer.sh (a SETUP_OWNED script) in .claude/settings.json must make
# ASSERTION 1's duplicate-detection logic go red — proving SETUP_OWNED is
# actually wired into the check, not just declared and never consulted.
# Never mutates the real committed settings.json: builds a throwaway copy.
# A trailing suffix after the X-run in a mktemp template is a GNU-only
# feature; BSD/macOS mktemp leaves it un-substituted (see-once portability
# bug: `mktemp foo.XXXXXX.json` on macOS literally returns that fixed
# non-random path). Make a private dir instead and name the file inside it —
# the pattern every other fixture in this repo already uses.
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qx-nodupe-fixture.XXXXXX")"
FIXTURE_SETTINGS="$FIXTURE_DIR/settings.json"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  j.hooks = j.hooks || {};
  j.hooks.SessionStart = j.hooks.SessionStart || [];
  j.hooks.SessionStart.push({
    matcher: "startup|resume|compact",
    hooks: [{ type: "command", command: "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/unarmed-offer.sh\"" }],
  });
  fs.writeFileSync(process.argv[2], JSON.stringify(j));
' "$SETTINGS" "$FIXTURE_SETTINGS"

FIXTURE_CMDS="$(node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const out=[];
  for (const [ev,groups] of Object.entries((j&&j.hooks)||{}))
    for (const g of groups||[])
      for (const h of (g&&g.hooks)||[])
        if (h&&typeof h.command==="string") out.push(ev+"\t"+h.command);
  process.stdout.write(out.join("\n"));
' "$FIXTURE_SETTINGS")"

FIXTURE_DUPES=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  hits="$(printf '%s' "$FIXTURE_CMDS" | grep -E -- "[/\"']${script%.sh}\.sh" || true)"
  [ -n "$hits" ] && FIXTURE_DUPES=$((FIXTURE_DUPES + 1))
done <<< "$(printf '%s\n%s\n%s' "$FACTORY_OWNED" "$QUETREX_OWNED" "$SETUP_OWNED")"

if [ "$FIXTURE_DUPES" -ge 1 ]; then
  ok "FAIL-FIRST (AC28): planting a duplicate unarmed-offer.sh registration in a settings.json fixture makes the duplicate-detection logic report >= 1 hit — SETUP_OWNED is actually consulted, not decorative"
else
  notok "FAIL-FIRST (AC28): planting a duplicate unarmed-offer.sh registration was NOT detected — SETUP_OWNED is declared but never actually consulted by the detection logic"
fi

echo
echo "no-duplicate-hook-owners.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
