#!/usr/bin/env bash
# hook-parity.test.sh — the shipped safety floor must BE the audited safety floor.
#
# WHY THIS EXISTS
# quetrex-base's .claude/hooks/*.sh are registered only by quetrex-base's OWN
# settings.json. Every OTHER repo — and every cloud routine — gets its safety floor
# from the quetrex-factory plugin's scripts/, hand-published from a different repo.
# Those copies drifted: deny-guard 42 lines vs 253, secret-scan 106 vs 285,
# verify-gate 540 vs 663. So hardening quetrex-base changed nothing where the
# unattended build actually runs, and nothing told anyone.
#
# The manifest below is the contract. It is committed, so an edit to a hook without
# a corresponding republish shows up as a red test rather than as silence.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$ROOT/.claude/hooks"
MANIFEST="$ROOT/.claude/hooks/PARITY.sha256"

PASS=0; FAIL=0
ok()      { PASS=$((PASS+1)); echo "ok - $1"; }
notok()   { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# The five scripts that constitute the safety floor. Registered by the factory
# plugin's hooks/hooks.json via ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh.
FLOOR="deny-guard secret-scan enforce-branch merge-gate verify-gate"

sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# --- ASSERTION 1: the manifest exists and covers every floor script ------------
if [ -f "$MANIFEST" ]; then
  ok "ASSERTION 1: parity manifest exists at .claude/hooks/PARITY.sha256"
  for n in $FLOOR; do
    if grep -q "  $n\.sh\$" "$MANIFEST"; then
      ok "ASSERTION 1: manifest covers $n.sh"
    else
      notok "ASSERTION 1: manifest does NOT cover $n.sh — a floor script can drift unwatched"
    fi
  done
else
  notok "ASSERTION 1: no parity manifest — regenerate with: bin/quetrex-hook-parity --write"
fi

# --- ASSERTION 2: each hook matches its recorded digest -----------------------
# Catches "someone edited a hook and did not republish the plugin".
if [ -f "$MANIFEST" ]; then
  for n in $FLOOR; do
    f="$HOOKS/$n.sh"
    [ -f "$f" ] || { notok "ASSERTION 2: $n.sh missing from .claude/hooks/"; continue; }
    want="$(awk -v k="$n.sh" '$2==k{print $1}' "$MANIFEST")"
    got="$(sha_of "$f")"
    if [ -z "$want" ]; then
      notok "ASSERTION 2: $n.sh has no recorded digest"
    elif [ "$want" = "$got" ]; then
      ok "ASSERTION 2: $n.sh matches its recorded digest"
    else
      notok "ASSERTION 2: $n.sh CHANGED since the last publish (manifest ${want:0:12}, file ${got:0:12}) — republish quetrex-factory, then regenerate the manifest"
    fi
  done
fi

# --- ASSERTION 3: the published factory copies are byte-identical -------------
# Only runs where a factory copy is reachable. Absence is reported, never silent:
# a silent skip is exactly how the original drift survived.
FACTORY=""
for cand in \
  "$ROOT/../quetrex-plugins/plugins/quetrex-factory/scripts" \
  "$HOME/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/scripts"
do
  [ -d "$cand" ] && { FACTORY="$cand"; break; }
done

if [ -n "$FACTORY" ]; then
  echo "# comparing published copies at $FACTORY against main's hooks"
  TMPMAIN="$(mktemp -d)"; trap 'rm -rf "$TMPMAIN"' EXIT
  for n in $FLOOR; do
    git -C "$ROOT" show "main:.claude/hooks/$n.sh" > "$TMPMAIN/$n.sh" 2>/dev/null || cp "$HOOKS/$n.sh" "$TMPMAIN/$n.sh"
  done
  for n in $FLOOR; do
    # COMPARE AGAINST main, NOT THE WORKING TREE. The invariant is "what ships equals what is
    # on main" — armed repos and cloud routines run the published copy, so it must never LEAD
    # main. A feature branch that legitimately changes a hook is ahead of both, and comparing
    # the working tree here failed every such branch and, worse, tempted a premature republish
    # (which then made the published copy lead main — the exact hazard, inverted). Publishing
    # is part of landing on main, not part of the branch.
    a="$TMPMAIN/$n.sh"; b="$FACTORY/$n.sh"
    if [ ! -f "$b" ]; then
      notok "ASSERTION 3: $n.sh is NOT published in quetrex-factory — armed repos run without it"
    elif cmp -s "$a" "$b"; then
      ok "ASSERTION 3: $n.sh published copy is byte-identical"
    else
      notok "ASSERTION 3: $n.sh published copy DIFFERS (base $(wc -l <"$a" | tr -d ' ') lines, published $(wc -l <"$b" | tr -d ' ')) — armed repos and cloud routines run the published one"
    fi
  done
else
  echo "# no factory checkout reachable — ASSERTION 3 could not run (not a pass)"
  ok "ASSERTION 3: skipped, no factory checkout reachable (reported, not silent)"
fi

echo
echo "hook-parity.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
