#!/usr/bin/env bash
# session-state-gate-liveness.test.sh — the "merge boundary is unenforced" banner
# must key off a LIVE plugin, not a leftover cache directory.
#
# WHY. quetrex-base no longer registers the engine guards itself — quetrex-factory
# owns them. That makes the startup banner the compensating detector for "the
# plugin did not load": if it stays silent in a repo where factory cannot load,
# the repo is ungated AND says nothing. That is the dealerq-2026 shape (factory
# disabled, hooks unwired, no floor, silent about it).
#
# THE BUG THIS PINS. factory_owns_merge_gate() originally accepted any hooks.json
# reachable under plugins/cache/*/quetrex-factory/*/ as proof the gate was live.
# A cache dir only records that a version was once downloaded. Measured on the
# author's machine: 12 cached factory version dirs across 4 marketplace dirs,
# 3 of them already orphaned (quetrex.gone27700, quetrex.old26856,
# quetrex.stale.0). Any of those silenced the banner permanently.

set -uo pipefail

# ONE-COPY round 2 hygiene (reviewer-reported): this session's ambient
# environment can carry QUETREX_UNLOCK_FLOOR=1 from unrelated prior work in
# the SAME shell (it is not cleared between unrelated commands), and every
# floor script honors it as the intentional operator unlock. A test that
# asserts a floor DENY without isolating this var silently asserts nothing
# once that happens - unset it here so this file's own "locked" assertions
# are never contaminated by ambient state; any assertion that WANTS the
# unlocked case still sets QUETREX_UNLOCK_FLOOR=1 explicitly on that one
# invocation, which overrides this.
unset QUETREX_UNLOCK_FLOOR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_SESSION_STATE_HOOK:-$ROOT/.claude/hooks/session-state.sh}"
WARN='merge boundary is unenforced'

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A Quetrex repo that enables factory and registers merge-gate NOWHERE itself —
# i.e. exactly the shape this PR puts quetrex-base into.
REPO="$TMP/repo"; mkdir -p "$REPO/.claude" "$REPO/.quetrex"
printf '{"enabledPlugins":{"quetrex-factory@quetrex":true},"hooks":{}}\n' > "$REPO/.claude/settings.json"
# ARMED: session-state.sh now gates on .quetrex/project.json specifically
# (not merely -d .quetrex) — without this the hook would print the unarmed
# offer and exit before ever reaching the liveness banner this file tests.
echo '{}' > "$REPO/.quetrex/project.json"
git -C "$REPO" init --quiet 2>/dev/null

hooks_json() { printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/scripts/merge-gate.sh\\""}]}]}}\n'; }

run() {  # run <home> -> hook stdout
  ( cd "$REPO" && HOME="$1" CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" startup </dev/null 2>/dev/null )
}
warned() { printf '%s' "$1" | grep -qF "$WARN"; }

# 1. nothing installed at all -> MUST warn
H1="$TMP/h-none"; mkdir -p "$H1/.claude"
warned "$(run "$H1")" \
  && ok "nothing installed: WARNED — a repo with no plugin anywhere is ungated and says so" \
  || notok "nothing installed: SILENT — an ungated repo was told nothing"

# 2. ORPHANED cache only (tombstoned marketplace) -> MUST warn
H2="$TMP/h-orphan"; mkdir -p "$H2/.claude/plugins/cache/quetrex.gone27700/quetrex-factory/0.1.0/hooks"
hooks_json > "$H2/.claude/plugins/cache/quetrex.gone27700/quetrex-factory/0.1.0/hooks/hooks.json"
warned "$(run "$H2")" \
  && ok "orphaned cache only: WARNED — a tombstoned cache dir is not a live plugin" \
  || notok "orphaned cache only: SILENT — a dead cache dir silenced the banner; the repo is ungated"

# 3. real cache, NO marketplace (ordinary version churn) -> MUST warn
H3="$TMP/h-cache"; mkdir -p "$H3/.claude/plugins/cache/quetrex/quetrex-factory/1.7.1/hooks"
hooks_json > "$H3/.claude/plugins/cache/quetrex/quetrex-factory/1.7.1/hooks/hooks.json"
warned "$(run "$H3")" \
  && ok "cache without marketplace: WARNED — a downloaded version is not a loaded one" \
  || notok "cache without marketplace: SILENT — the repo cannot load the plugin and was told nothing"

# 4. live marketplace install -> MUST stay silent
H4="$TMP/h-live"; mkdir -p "$H4/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/hooks"
hooks_json > "$H4/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/hooks/hooks.json"
warned "$(run "$H4")" \
  && notok "live marketplace install: WARNED — false alarm on a correctly configured repo, the cry-wolf failure this helper exists to avoid" \
  || ok "live marketplace install: silent — factory genuinely owns the gate here"

echo
echo "session-state-gate-liveness.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
