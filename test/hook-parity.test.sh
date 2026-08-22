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
  # RESOLVE THE BASE REF ONCE, BEFORE THE LOOP -- fail-closed on the ref
  # itself, deferred per-file only on the PATH within a resolved ref.
  #
  # HISTORY: this used to `|| cp "$HOOKS/$n.sh"` as a silent fallback, so in
  # a single-branch clone (no `main` resolvable) the baseline BECAME the
  # working tree and the suite reported PASS on a published copy that LEADS
  # main. Fixed once already: refuse to compare against the working tree,
  # fail closed if no baseline resolves, say so, stop.
  #
  # REVIEWER FIX ROUND 2 (2026-08-21): that fail-closed fix regressed when
  # verify-gate-quick-chain was added to FLOOR (round 1, this same file).
  # Round 1 collapsed two different causes into one bare `continue` inside
  # the per-file loop -- (a) "the ref resolves but this ONE path is absent
  # at it" (benign: a new floor file on an unmerged branch), and (b)
  # "neither origin/main nor main resolves AT ALL" (serious: a single-
  # branch or shallow clone with no base ref) -- so in case (b) EVERY floor
  # file hit the same `continue`, comparing NOTHING while reporting each
  # one as "has no main baseline yet (new on this branch)" -- the wrong
  # cause, stated as fact, for files that are not new at all. Proven by a
  # fixture with no resolvable base ref and a reachable factory publishing
  # 5-line truncated stubs: that combination must fail loudly, not report
  # every floor script deferred and exit 0 (see ASSERTION 4 below, which
  # pins this exact scenario and fail-firsts against the round-1 defect).
  # The ref is now resolved exactly ONCE, up front: if neither resolves,
  # ASSERTION 3 fails immediately and compares nothing -- restoring the
  # SAME fail-closed invariant this HISTORY note above already established
  # once, that round 1 silently regressed. Only once a ref DOES resolve
  # does the per-file loop distinguish "absent at this ref" (deferred, one
  # file at a time, every OTHER file still fully compared) from an actual
  # published-copy mismatch.
  BASEREF=""
  if git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    BASEREF="origin/main"
  elif git -C "$ROOT" rev-parse --verify -q main >/dev/null 2>&1; then
    BASEREF="main"
  fi
  if [ -z "$BASEREF" ]; then
    notok "ASSERTION 3: cannot resolve a main baseline ref (no origin/main, no main) — refusing to compare the published copy against the working tree, which would pass a copy that LEADS main"
  else
    echo "# comparing published copies at $FACTORY against $BASEREF's hooks"
    TMPMAIN="$(mktemp -d)"; trap 'rm -rf "$TMPMAIN"' EXIT
    for n in $FLOOR; do
      # Deferred ONLY when the RESOLVED ref genuinely lacks this ONE path
      # (a legitimate, transient, self-resolving feature-branch state --
      # $BASEREF literally cannot have a file that has not merged yet).
      # Reported, never silent, never counted as a pass, and scoped to
      # just this file -- every OTHER floor script below still gets its
      # real comparison.
      if ! git -C "$ROOT" cat-file -e "$BASEREF:.claude/hooks/$n.sh" 2>/dev/null; then
        echo "# ASSERTION 3: $n.sh is absent at $BASEREF (new on this branch, not yet merged) -- its published-copy comparison is deferred until it lands on $BASEREF; every OTHER floor script is still fully compared below"
        continue
      fi
      git -C "$ROOT" show "$BASEREF:.claude/hooks/$n.sh" > "$TMPMAIN/$n.sh" 2>/dev/null
      a="$TMPMAIN/$n.sh"; b="$FACTORY/$n.sh"
      if [ ! -f "$b" ]; then
        notok "ASSERTION 3: $n.sh is NOT published in quetrex-factory — armed repos run without it"
      elif cmp -s "$a" "$b"; then
        ok "ASSERTION 3: $n.sh published copy is byte-identical"
      else
        notok "ASSERTION 3: $n.sh published copy DIFFERS (base $(wc -l <"$a" | tr -d ' ') lines, published $(wc -l <"$b" | tr -d ' ')) — armed repos and cloud routines run the published one"
      fi
    done
  fi
else
  echo "# no factory checkout reachable — ASSERTION 3 could not run (not a pass)"
  ok "ASSERTION 3: skipped, no factory checkout reachable (reported, not silent)"
fi

# ASSERTION 4 drives a full COPY of this file as a subprocess. Guard against
# unbounded self-recursion: if this invocation IS already such a fixture
# subprocess (QX_HOOK_PARITY_FIXTURE=1, set below before each subprocess
# invocation), skip building and spawning ANOTHER nested fixture entirely.
if [ "${QX_HOOK_PARITY_FIXTURE:-0}" != "1" ]; then

# =============================================================================
# ASSERTION 4 (reviewer fixture, round 2, 2026-08-21): a single-branch/
# shallow clone with NO resolvable origin/main or main, plus a REACHABLE
# factory publishing truncated stubs, must fail loudly -- never report
# green while comparing nothing. THE DEFECT THIS PINS: round 1's per-file
# `continue` collapsed "the ref resolves but this ONE path is absent"
# (benign) and "neither ref resolves AT ALL" (serious) into the same
# bare skip, so in the second case EVERY floor file hit `continue`,
# ASSERTION 3 compared nothing, and the suite reported green over six
# 5-line truncated stubs. Drives the SHIPPED test file end to end, as its
# own subprocess, against a fixture this file builds itself.
# =============================================================================
build_no_baseref_fixture() {  # build_no_baseref_fixture <dir> -> writes a
  # single-branch git repo with no main/origin-main, the 6 CURRENT floor
  # scripts + a matching PARITY.sha256, and (in <dir>/fake-home) a
  # reachable "factory" whose 6 published copies are 5-line truncated
  # stubs -- the reviewer's exact reproduction shape.
  local dir="$1" n
  mkdir -p "$dir/.claude/hooks" "$dir/test"
  git -C "$dir" init -q -b onlybranch
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  for n in $FLOOR; do
    cp "$HOOKS/$n.sh" "$dir/.claude/hooks/$n.sh"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -qm "single commit, no main/origin-main"
  ( cd "$dir/.claude/hooks" && shasum -a 256 $(for n in $FLOOR; do printf '%s.sh ' "$n"; done) > PARITY.sha256 )
  git -C "$dir" add -A
  git -C "$dir" commit -qm "regen parity"
  mkdir -p "$dir/fake-home/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/scripts"
  for n in $FLOOR; do
    printf '#!/usr/bin/env bash\necho stub\necho stub\necho stub\necho stub\n' \
      > "$dir/fake-home/.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/scripts/$n.sh"
  done
  cp "$ROOT/test/hook-parity.test.sh" "$dir/test/hook-parity.test.sh"
}

A4_FIXTURE="$(mktemp -d)"
build_no_baseref_fixture "$A4_FIXTURE"
A4_OUT="$(HOME="$A4_FIXTURE/fake-home" QX_HOOK_PARITY_FIXTURE=1 bash "$A4_FIXTURE/test/hook-parity.test.sh" 2>&1)"
A4_CODE=$?
rm -rf "$A4_FIXTURE"

if [ "$A4_CODE" -ne 0 ] && printf '%s' "$A4_OUT" | grep -q "cannot resolve a main baseline ref"; then
  ok "ASSERTION 4: no-resolvable-base-ref fixture with truncated published stubs correctly EXITS non-zero, naming the ref-resolution cause"
else
  notok "ASSERTION 4: expected a non-zero exit naming 'cannot resolve a main baseline ref', got exit=$A4_CODE (out: [$A4_OUT])"
fi
if printf '%s' "$A4_OUT" | grep -q "is absent at"; then
  notok "ASSERTION 4: the wrong-cause message (the per-file 'is absent at \$BASEREF' deferral) appeared for a fixture where the REF ITSELF never resolved -- the two causes are still collapsed"
else
  ok "ASSERTION 4: the fixture never reports the per-file deferral message -- the ref-resolution failure and the per-file-absent case stay distinct"
fi

# --- ASSERTION 4 FAIL-FIRST: the identical fixture against 753c3f2 (round 1
# of this same file, before the base-ref-once restructure) genuinely
# reports green while comparing nothing.
A4_BASELINE_SHA="753c3f2"
if git -C "$ROOT" cat-file -e "${A4_BASELINE_SHA}:test/hook-parity.test.sh" 2>/dev/null; then
  A4B_FIXTURE="$(mktemp -d)"
  build_no_baseref_fixture "$A4B_FIXTURE"
  git -C "$ROOT" show "${A4_BASELINE_SHA}:test/hook-parity.test.sh" > "$A4B_FIXTURE/test/hook-parity.test.sh"
  A4B_OUT="$(HOME="$A4B_FIXTURE/fake-home" QX_HOOK_PARITY_FIXTURE=1 bash "$A4B_FIXTURE/test/hook-parity.test.sh" 2>&1)"
  A4B_CODE=$?
  rm -rf "$A4B_FIXTURE"
  if [ "$A4B_CODE" -eq 0 ]; then
    ok "ASSERTION 4 FAIL-FIRST: the pre-fix baseline ($A4_BASELINE_SHA) WRONGLY EXITS 0 over the identical no-base-ref, truncated-stubs fixture -- proving this restructure is a genuine, deliberate fix"
  else
    notok "ASSERTION 4 FAIL-FIRST: the pre-fix baseline did not exit 0 either (exit=$A4B_CODE) -- cannot demonstrate the fix is real"
  fi
else
  echo "SKIP: commit ${A4_BASELINE_SHA} not reachable — ASSERTION 4 fail-first proof could not run"
fi

fi  # end QX_HOOK_PARITY_FIXTURE guard (ASSERTION 4)

echo
echo "hook-parity.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
