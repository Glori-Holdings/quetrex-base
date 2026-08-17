#!/usr/bin/env bash
# test/verify-gate-timeout-margin.test.sh — the fail-closed budget must always
# stay BELOW the external Stop/SubagentStop hook timeout, with real headroom.
#
# I3. verify-gate.sh's internal BUDGET_DEFAULT exists so the hook can
# self-terminate, write the red ledger line, and BLOCK before the harness
# kills it outright. A hook killed by the harness emits nothing, and for
# Stop/SubagentStop "no output" reads as ALLOW — so the whole fail-closed
# mechanism only works while BUDGET_DEFAULT stays comfortably under the
# external timeout that registers the hook.
#
# Those two numbers live in different files in different repos:
#   - the internal budget is BUDGET_DEFAULT in THIS repo's
#     .claude/hooks/verify-gate.sh (committed here).
#   - the external timeout is the verify-gate entries in quetrex-plugins'
#     plugins/quetrex-factory/hooks/hooks.json (a different repo entirely).
# They drifted once already: hooks.json shipped Stop=600s / SubagentStop=300s
# while verify-gate.sh's own budget was already 840s / 540s — ABOVE both
# timeouts, so the harness always won the race first and the fail-closed path
# was dead code. Nothing caught it because nothing compared the two files.
# This test is that comparison, made permanent.
#
# Two assertions:
#   ASSERTION 1 (runs everywhere, from committed state alone): verify-gate.sh's
#   own header documents the external timeout it assumes (currently "Stop
#   (900s) / SubagentStop (600s)"). That documented number must itself sit a
#   real margin above BUDGET_DEFAULT — not merely above it. This alone would
#   have caught nothing about the actual hooks.json drift, but it pins the
#   file's internal self-consistency so a future edit to BUDGET_DEFAULT without
#   updating the header (or vice versa) goes red immediately, everywhere,
#   including a fresh clone or CI with no factory checkout in reach.
#
#   ASSERTION 2 (runs only where a factory checkout is reachable): the REAL
#   external timeout in quetrex-plugins' hooks.json must sit at least the
#   SAME documented margin (from Assertion 1) above BUDGET_DEFAULT. This is
#   the assertion that actually catches cross-repo drift. Where no factory
#   checkout is reachable (fresh clone, CI), it is reported as a skip with a
#   stated reason — never a silent pass, and never a hard failure, per the
#   established convention in test/hook-parity.test.sh (a prior version of
#   THIS repo made ASSERTION 3 there permanently red in exactly that
#   situation, and it had to be corrected).
#
# Both assertions require margin >= the documented headroom, not merely
# external > internal. A budget sitting at 99% of the timeout is the same bug
# with better luck.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_VERIFY_GATE_HOOK:-$ROOT/.claude/hooks/verify-gate.sh}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

if [ ! -f "$HOOK" ]; then
  echo "NOT OK - verify-gate.sh not found at $HOOK"
  exit 1
fi

# --- parse the INTERNAL budgets straight out of the real hook -----------------
# BUDGET_DEFAULT=840                                    <- Stop (unconditional default)
# [ "$EVENT" = "SubagentStop" ] && BUDGET_DEFAULT=540    <- SubagentStop override
BUDGET_STOP="$(grep -oE '^BUDGET_DEFAULT=[0-9]+' "$HOOK" | head -1 | cut -d= -f2)"
BUDGET_SUBAGENT="$(grep -oE 'SubagentStop.*BUDGET_DEFAULT=[0-9]+' "$HOOK" | head -1 | grep -oE '[0-9]+$')"

if [ -z "$BUDGET_STOP" ] || [ -z "$BUDGET_SUBAGENT" ]; then
  echo "NOT OK - could not parse BUDGET_DEFAULT for Stop and SubagentStop out of $HOOK"
  exit 1
fi

# --- parse the DOCUMENTED external-timeout assumption out of the header -------
# "# The chain below runs synchronously inside a Stop (900s) / SubagentStop
#  # (600s) hook timeout ..." — spans two comment lines, so join a small
# window before extracting.
DOC_WINDOW="$(awk '/runs synchronously inside a Stop/{print; getline; print; exit}' "$HOOK" | tr '\n' ' ')"
DOC_STOP="$(printf '%s' "$DOC_WINDOW" | grep -oE 'Stop \([0-9]+s\)' | grep -oE '[0-9]+')"
DOC_SUBAGENT="$(printf '%s' "$DOC_WINDOW" | grep -oE 'SubagentStop[^0-9]*\([0-9]+s\)' | grep -oE '[0-9]+')"

if [ -z "$DOC_STOP" ] || [ -z "$DOC_SUBAGENT" ]; then
  echo "NOT OK - could not parse the documented Stop/SubagentStop timeout assumption out of $HOOK's header"
  exit 1
fi

echo "# parsed: BUDGET_DEFAULT Stop=$BUDGET_STOP SubagentStop=$BUDGET_SUBAGENT; header documents Stop=${DOC_STOP}s SubagentStop=${DOC_SUBAGENT}s"

DOC_MARGIN_STOP=$((DOC_STOP - BUDGET_STOP))
DOC_MARGIN_SUBAGENT=$((DOC_SUBAGENT - BUDGET_SUBAGENT))

# --- ASSERTION 1: the header's own documented assumption must itself sit a
#     real margin (>= 5% of the documented external timeout) above the budget
#     it is meant to protect. Runs everywhere, from committed state alone. ---
MIN_MARGIN_STOP=$((DOC_STOP / 20))
MIN_MARGIN_SUBAGENT=$((DOC_SUBAGENT / 20))

if [ "$DOC_MARGIN_STOP" -ge "$MIN_MARGIN_STOP" ] && [ "$DOC_MARGIN_STOP" -gt 0 ]; then
  ok "ASSERTION 1: documented Stop timeout (${DOC_STOP}s) sits ${DOC_MARGIN_STOP}s above BUDGET_DEFAULT (${BUDGET_STOP}s) — real margin, not just a positive gap"
else
  notok "ASSERTION 1: documented Stop timeout (${DOC_STOP}s) does not sit a real margin above BUDGET_DEFAULT (${BUDGET_STOP}s) — margin ${DOC_MARGIN_STOP}s, needed >= ${MIN_MARGIN_STOP}s"
fi

if [ "$DOC_MARGIN_SUBAGENT" -ge "$MIN_MARGIN_SUBAGENT" ] && [ "$DOC_MARGIN_SUBAGENT" -gt 0 ]; then
  ok "ASSERTION 1: documented SubagentStop timeout (${DOC_SUBAGENT}s) sits ${DOC_MARGIN_SUBAGENT}s above BUDGET_DEFAULT (${BUDGET_SUBAGENT}s) — real margin, not just a positive gap"
else
  notok "ASSERTION 1: documented SubagentStop timeout (${DOC_SUBAGENT}s) does not sit a real margin above BUDGET_DEFAULT (${BUDGET_SUBAGENT}s) — margin ${DOC_MARGIN_SUBAGENT}s, needed >= ${MIN_MARGIN_SUBAGENT}s"
fi

# --- ASSERTION 2: the REAL published timeout in quetrex-plugins' hooks.json
#     must sit at least the SAME documented margin above the internal budget.
#     This is the assertion that actually catches cross-repo drift. -----------
FACTORY_HOOKS_JSON="${QX_FACTORY_HOOKS_JSON:-}"
if [ -z "$FACTORY_HOOKS_JSON" ]; then
  for cand in \
    "$ROOT/../quetrex-plugins/plugins/quetrex-factory/hooks/hooks.json" \
    "$HOME/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/hooks/hooks.json"
  do
    [ -f "$cand" ] && { FACTORY_HOOKS_JSON="$cand"; break; }
  done
fi

if [ -n "$FACTORY_HOOKS_JSON" ] && [ -f "$FACTORY_HOOKS_JSON" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    notok "ASSERTION 2: jq unavailable, cannot parse $FACTORY_HOOKS_JSON"
  else
    REAL_STOP="$(jq -r '.hooks.Stop[]?.hooks[]? | select(.command | contains("verify-gate.sh")) | .timeout' "$FACTORY_HOOKS_JSON" 2>/dev/null | head -1)"
    REAL_SUBAGENT="$(jq -r '.hooks.SubagentStop[]?.hooks[]? | select(.command | contains("verify-gate.sh")) | .timeout' "$FACTORY_HOOKS_JSON" 2>/dev/null | head -1)"

    echo "# comparing against published factory hooks.json at $FACTORY_HOOKS_JSON (Stop=${REAL_STOP:-?} SubagentStop=${REAL_SUBAGENT:-?})"

    case "$REAL_STOP" in
      ''|*[!0-9]*)
        notok "ASSERTION 2: could not parse a Stop timeout for verify-gate.sh out of $FACTORY_HOOKS_JSON"
        ;;
      *)
        REAL_MARGIN_STOP=$((REAL_STOP - BUDGET_STOP))
        if [ "$REAL_MARGIN_STOP" -ge "$DOC_MARGIN_STOP" ]; then
          ok "ASSERTION 2: published Stop timeout (${REAL_STOP}s) sits ${REAL_MARGIN_STOP}s above BUDGET_DEFAULT (${BUDGET_STOP}s) — at least the documented ${DOC_MARGIN_STOP}s headroom"
        else
          notok "ASSERTION 2: published Stop timeout (${REAL_STOP}s) does NOT clear BUDGET_DEFAULT (${BUDGET_STOP}s) with the documented ${DOC_MARGIN_STOP}s headroom (actual margin ${REAL_MARGIN_STOP}s) — the fail-closed budget can never fire; the harness kills the hook first, which reads as ALLOW"
        fi
        ;;
    esac

    case "$REAL_SUBAGENT" in
      ''|*[!0-9]*)
        notok "ASSERTION 2: could not parse a SubagentStop timeout for verify-gate.sh out of $FACTORY_HOOKS_JSON"
        ;;
      *)
        REAL_MARGIN_SUBAGENT=$((REAL_SUBAGENT - BUDGET_SUBAGENT))
        if [ "$REAL_MARGIN_SUBAGENT" -ge "$DOC_MARGIN_SUBAGENT" ]; then
          ok "ASSERTION 2: published SubagentStop timeout (${REAL_SUBAGENT}s) sits ${REAL_MARGIN_SUBAGENT}s above BUDGET_DEFAULT (${BUDGET_SUBAGENT}s) — at least the documented ${DOC_MARGIN_SUBAGENT}s headroom"
        else
          notok "ASSERTION 2: published SubagentStop timeout (${REAL_SUBAGENT}s) does NOT clear BUDGET_DEFAULT (${BUDGET_SUBAGENT}s) with the documented ${DOC_MARGIN_SUBAGENT}s headroom (actual margin ${REAL_MARGIN_SUBAGENT}s) — the fail-closed budget can never fire; the harness kills the hook first, which reads as ALLOW"
        fi
        ;;
    esac
  fi
else
  echo "# no factory hooks.json reachable (checked \$QX_FACTORY_HOOKS_JSON, ../quetrex-plugins, and the marketplace checkout) — ASSERTION 2 could not run"
  ok "ASSERTION 2: skipped, no factory checkout reachable (reported, not silent — same convention as test/hook-parity.test.sh)"
fi

echo
echo "verify-gate-timeout-margin.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
