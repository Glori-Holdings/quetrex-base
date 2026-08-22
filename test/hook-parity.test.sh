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

# The safety-floor scripts. Registered by the factory plugin's
# hooks/hooks.json via ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh.
#
# REVIEWER FIX (2026-08-21): verify-gate.sh now `source`s verify-gate-
# quick-chain.sh and exit-2 blocks EVERY turn if it cannot load (fail-
# closed by design -- see verify-gate.sh's own SEC-8 comment). PARITY.sha256
# already carried its digest, but FLOOR here still named only the original
# five, so none of this file's three assertions ever looked at it --
# ASSERTION 3 in particular ("<name>.sh is NOT published in quetrex-factory
# -- armed repos run without it") was structurally blind to the one file
# verify-gate.sh cannot run without. A publish that copies only the
# original five scripts into quetrex-factory's scripts/ therefore hard-
# blocks every turn in every armed repo, and this suite would have reported
# green. verify-gate-quick-chain.sh is now first-class FLOOR, exactly like
# the file that sources it.
FLOOR="deny-guard secret-scan enforce-branch merge-gate verify-gate verify-gate-quick-chain"

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
    # NO SILENT FALLBACK TO THE WORKING TREE. This used to `|| cp "$HOOKS/$n.sh"`, so in a
    # single-branch clone (where `main` does not resolve) the baseline BECAME the branch — and
    # the test reported 16/16 PASS on a published copy that leads main, while printing
    # "comparing against main's hooks". Fail-closed: if no baseline resolves, say so and stop.
    #
    # REVIEWER FIX (2026-08-21): a single missing baseline used to zero a
    # GLOBAL BASELINE_OK flag, which then skipped the SECOND loop's actual
    # comparison for EVERY floor file, not just the one that was missing --
    # so adding a brand-new floor script (verify-gate-quick-chain.sh, not
    # yet on main because this branch has not merged) would have silently
    # cancelled drift detection for ALL FIVE already-published scripts too.
    # Scoped per-file now: a floor script with no main baseline yet is a
    # legitimate, transient, self-resolving feature-branch state (main
    # literally cannot have it before this branch lands) -- reported, never
    # silent, and never counted as a false pass, but it no longer disables
    # verification of any OTHER floor script in the same run.
    if ! git -C "$ROOT" show "origin/main:.claude/hooks/$n.sh" > "$TMPMAIN/$n.sh" 2>/dev/null \
    && ! git -C "$ROOT" show "main:.claude/hooks/$n.sh" > "$TMPMAIN/$n.sh" 2>/dev/null; then
      echo "# ASSERTION 3: $n.sh has no main baseline yet (new on this branch, not yet merged) -- its published-copy comparison is deferred until it lands on main; every OTHER floor script is still fully compared below"
      continue
    fi
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
