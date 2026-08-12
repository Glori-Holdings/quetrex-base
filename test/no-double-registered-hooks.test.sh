#!/usr/bin/env bash
# no-double-registered-hooks.test.sh — one hook, one registration.
#
# MEASURED. This repo's own .claude/settings.json registered verify-gate.sh on Stop AND
# SubagentStop, while the quetrex-factory plugin registers the same script for the same two
# events. Since the parity work made the two copies byte-identical, every turn ran the SAME
# ~90-second verify chain TWICE. The operator watched a turn spend 4m39s in stop hooks and
# said, correctly, that it "did absolutely nothing".
#
# It is not only cost. Two independent runs of a gate that writes a ledger and a self-heal
# counter means duplicated ledger lines and a self-heal budget that burns at double rate — the
# cap is 3, so a repo with a flaky command escalates in half the attempts it should.
#
# The factory plugin owns the engine guards. A project's own settings must not re-register
# them: quetrex-base has quetrex-factory enabled in committed enabledPlugins, so the plugin's
# registration always fires.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

[ -f "$SETTINGS" ] || { echo "NOT OK - $SETTINGS missing"; exit 1; }

# Guards the quetrex-factory plugin owns. A project settings file must not register these.
# auto-format is included for the same reason even though it is not a blocking gate.
ENGINE_GUARDS='verify-gate.sh
merge-gate.sh
deny-guard.sh
secret-scan.sh
enforce-branch.sh
auto-format.sh'

# Every hook command string in this repo's settings, across every event.
CMDS="$(node -e '
  const j=require(process.argv[1]);
  const out=[];
  for (const [ev,groups] of Object.entries((j&&j.hooks)||{}))
    for (const g of groups||[])
      for (const h of (g&&g.hooks)||[])
        if (h&&typeof h.command==="string") out.push(ev+"\t"+h.command);
  process.stdout.write(out.join("\n"));
' "$SETTINGS" 2>/dev/null)"

while IFS= read -r guard; do
  [ -n "$guard" ] || continue
  hits="$(printf '%s' "$CMDS" | grep -F -- "$guard" || true)"
  if [ -z "$hits" ]; then
    ok "ASSERTION 1: $guard is not registered by this repo's settings (the plugin owns it)"
  else
    notok "ASSERTION 1: $guard is registered by .claude/settings.json AND by quetrex-factory — it will run TWICE per event, doubling the verify chain and burning the self-heal budget at double rate: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
done <<< "$ENGINE_GUARDS"

# --- ASSERTION 2: no duplicate command within this repo's settings either -----
# The cross-file case above is the one that bit, but the same command listed twice under one
# event is the same defect with a shorter path.
DUPES="$(printf '%s' "$CMDS" | sort | uniq -d)"
if [ -z "$DUPES" ]; then
  ok "ASSERTION 2: no hook command is registered twice for the same event"
else
  notok "ASSERTION 2: duplicate registrations within settings.json: $(printf '%s' "$DUPES" | tr '\n' ' ')"
fi

# --- ASSERTION 3a: the guards still have an OWNER, provably from committed state --
# Deleting a duplicate must never become deleting the gate. The strong form of that check
# needs the factory's hooks.json, which does NOT exist in a fresh clone or on a CI runner —
# so it cannot be the only thing standing between this repo and an unguarded state, or the
# protection evaporates exactly where nobody is watching. This half reads only committed
# state and therefore runs everywhere: having removed the local registrations, this repo MUST
# still enable the plugin that owns them.
if node -e '
  const j=require(process.argv[1]);
  const v=(j.enabledPlugins||{})["quetrex-factory@quetrex"];
  process.exit((v===true||(Array.isArray(v)&&v.length))?0:1);
' "$SETTINGS" 2>/dev/null; then
  ok "ASSERTION 3a: quetrex-factory is enabled in committed enabledPlugins — the guards this repo stopped registering still have an owner"
else
  notok "ASSERTION 3a: this repo registers none of the engine guards AND does not enable quetrex-factory — nothing runs them; the duplicate was not removed, the gate was"
fi

# --- ASSERTION 3b: and the owner really does register the gate ----------------
# The live cross-check, wherever a factory copy is reachable. Absence is REPORTED, never
# silent — same convention as hook-parity.test.sh, whose ASSERTION 3 has the identical shape.
PLUGIN_HOOKS=""
for cand in "$HOME"/.claude/plugins/cache/quetrex/quetrex-factory/*/hooks/hooks.json \
            "$ROOT/../quetrex-plugins/plugins/quetrex-factory/hooks/hooks.json"; do
  [ -f "$cand" ] && PLUGIN_HOOKS="$cand"
done
if [ -n "$PLUGIN_HOOKS" ]; then
  for ev in Stop SubagentStop; do
    if node -e '
      const j=require(process.argv[1]); const ev=process.argv[2];
      const found=((j.hooks||{})[ev]||[]).some(g=>(g.hooks||[]).some(h=>/verify-gate\.sh/.test(h.command||"")));
      process.exit(found?0:1);
    ' "$PLUGIN_HOOKS" "$ev" 2>/dev/null; then
      ok "ASSERTION 3b: the plugin still registers verify-gate for $ev — removing the duplicate did not remove the gate"
    else
      notok "ASSERTION 3b: the reachable quetrex-factory does NOT register verify-gate for $ev — the gate is gone, not deduplicated"
    fi
  done
else
  echo "# no factory hooks.json reachable (fresh clone / CI runner) — ASSERTION 3b could not run"
  ok "ASSERTION 3b: skipped, no factory copy reachable (reported, not silent; ASSERTION 3a still proves the guards have an owner)"
fi

# --- ASSERTION 4: the startup diagnostic must agree with the ownership model --
# session-state.sh warns "the merge boundary is unenforced" when it cannot find
# merge-gate.sh. Once the plugin owns the guards, a check that greps only the
# repo's settings fires on EVERY startup of a correctly configured repo. This
# drives the REAL hook against fixture repos, not a lifted sub-expression.
HOOK="$ROOT/.claude/hooks/session-state.sh"
WARN='merge boundary is unenforced'

# fixture: a Quetrex repo whose settings delegate the guards to the plugin
mk_repo() {  # $1=dir  $2=enabledPlugins-value-for-quetrex-factory ("true" or "absent")
  mkdir -p "$1/.claude" "$1/.quetrex"
  if [ "$2" = "true" ]; then
    printf '{"enabledPlugins":{"quetrex-factory@quetrex":true},"hooks":{}}\n' > "$1/.claude/settings.json"
  else
    printf '{"enabledPlugins":{},"hooks":{}}\n' > "$1/.claude/settings.json"
  fi
  git -C "$1" init --quiet 2>/dev/null
}
mk_home() {  # $1=dir  $2="withplugin"|"noplugin"
  mkdir -p "$1/.claude"
  if [ "$2" = "withplugin" ]; then
    mkdir -p "$1/.claude/plugins/cache/quetrex/quetrex-factory/9.9.9/hooks"
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/scripts/merge-gate.sh\\""}]}]}}\n' \
      > "$1/.claude/plugins/cache/quetrex/quetrex-factory/9.9.9/hooks/hooks.json"
  fi
}
run_hook() {  # $1=repo $2=home -> stdout of the real hook at startup
  ( cd "$1" && HOME="$2" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" startup </dev/null 2>/dev/null )
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_repo "$TMP/delegating" true;   mk_home "$TMP/home-ok" withplugin
mk_repo "$TMP/orphan"     absent; mk_home "$TMP/home-bare" noplugin

if printf '%s' "$(run_hook "$TMP/delegating" "$TMP/home-ok")" | grep -qF "$WARN"; then
  notok "ASSERTION 4: the gate IS owned by the enabled quetrex-factory, yet session-state.sh still calls the merge boundary unenforced — a false alarm on every startup of a correct repo"
else
  ok "ASSERTION 4: no false alarm when the enabled quetrex-factory owns merge-gate"
fi

if printf '%s' "$(run_hook "$TMP/orphan" "$TMP/home-bare")" | grep -qF "$WARN"; then
  ok "ASSERTION 4: still warns when NEITHER the repo settings nor a plugin wires merge-gate — silencing the false alarm did not silence the real one"
else
  notok "ASSERTION 4: no owner wires merge-gate anywhere and session-state.sh said nothing — the warning was silenced, not corrected"
fi

echo
echo "no-double-registered-hooks.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
