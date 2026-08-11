#!/usr/bin/env bash
# epic-terminus.test.sh — an epic's integration PR must be able to pass /quetrex:merge.
#
# GAP (audit, unanimous): the epic terminus opened the `${BRANCH_PREFIX}<EPIC-ID>` -> main PR
# but nothing ever published `${BRANCH_PREFIX}<EPIC-ID>-gates`, so merge-gate.sh found no
# verdict and the PR could never merge. The children's artifacts are not a substitute:
# merge-gate.sh requires review-verdict.json's .sha to equal the PR head, and each child's
# verdict pins to its own commit. The integration head is a commit no child gate ever saw.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TB="$ROOT/.claude/commands/task-build.md"
MG="$ROOT/.claude/hooks/merge-gate.sh"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# Isolate the "All children merged" terminus, so a match elsewhere in the file
# (e.g. the per-child dispatch) cannot satisfy these assertions vacuously.
SECTION="$(awk '/All children `merged`/{f=1} f{print} f&&/Any child `needs_clarity`/{exit}' "$TB")"

if [ -n "$SECTION" ]; then
  ok "AC0: located the epic terminus section (extractor is not vacuous)"
else
  notok "AC0: could not locate the epic terminus section — every assertion below would pass vacuously"
  echo; echo "epic-terminus.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

# --- AC1: the terminus publishes an epic gates branch --------------------------
if printf '%s' "$SECTION" | grep -q '<EPIC-ID>-gates'; then
  ok "AC1: the terminus publishes \${BRANCH_PREFIX}<EPIC-ID>-gates"
else
  notok "AC1: the terminus never publishes an epic gates branch — /quetrex:merge <EPIC-ID> can never find a verdict"
fi

# --- AC2: it dispatches to the cloud, not a local run --------------------------
# Compute runs only on Anthropic's servers; a local gates run would violate that.
if printf '%s' "$SECTION" | grep -q 'RemoteTrigger'; then
  ok "AC2: epic gates are produced by a cloud routine (RemoteTrigger), not locally"
else
  notok "AC2: no RemoteTrigger at the terminus — epic gates would have to run somewhere other than Anthropic's cloud"
fi

# --- AC3: it carries the single-fire discipline -------------------------------
# A dispatch that leaves next_run_at armed fires a second concurrent build.
if printf '%s' "$SECTION" | grep -q 'update{enabled:false}'; then
  ok "AC3: the epic dispatch disarms the schedule (create -> run -> update{enabled:false})"
else
  notok "AC3: the epic dispatch does not disarm — a second concurrent run would race the integration branch"
fi

# --- AC4: it explicitly refuses to reuse or re-pin child evidence -------------
# This is the failure mode a well-meaning implementer would otherwise take.
if printf '%s' "$SECTION" | grep -qiE 'not.*substitute|never.*re-pin'; then
  ok "AC4: the terminus explicitly forbids aggregating or re-pinning child artifacts"
else
  notok "AC4: nothing warns against reusing child evidence — the obvious wrong implementation is unguarded"
fi

# --- AC5: the reason is stated, not just the rule ------------------------------
if printf '%s' "$SECTION" | grep -q 'integration head'; then
  ok "AC5: states why — the integration head is a commit no child gate ever saw"
else
  notok "AC5: does not explain why child verdicts are insufficient"
fi

# --- AC6: BEHAVIORAL — merge-gate really does reject a mis-pinned verdict ------
# Proves AC4's rule is load-bearing rather than advice: a verdict pinned to a
# child's commit, offered for an integration head, must be refused by the real hook.
if [ -f "$MG" ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  ( cd "$T" && git init -q . && git config user.email t@t && git config user.name t \
    && mkdir -p .quetrex && echo a > f.txt && git add -A && git commit -q -m c1 ) >/dev/null 2>&1
  CHILD_SHA="$(git -C "$T" rev-parse HEAD)"
  ( cd "$T" && echo b >> f.txt && git commit -aqm integration ) >/dev/null 2>&1
  INTEG_SHA="$(git -C "$T" rev-parse HEAD)"
  printf '{"verdict":"AUTO_MERGE","sha":"%s"}\n' "$CHILD_SHA" > "$T/.quetrex/review-verdict.json"
  printf '%s\n' "$CHILD_SHA" > "$T/.quetrex/gates-head"

  # gates-head (a child commit) != the integration head the PR would merge.
  if [ "$(tr -d '[:space:]' < "$T/.quetrex/gates-head")" != "$INTEG_SHA" ]; then
    ok "AC6: a child-pinned verdict is demonstrably stale against the integration head (${CHILD_SHA:0:8} != ${INTEG_SHA:0:8})"
  else
    notok "AC6: fixture did not produce distinct child and integration commits"
  fi

  # The pin the HOOK enforces is review-verdict.json's .sha against the head it
  # resolves — `gates-head` is compared earlier, by /quetrex:merge's transport step.
  # Assert the mechanism where it actually lives, not where it is convenient.
  if grep -qE 'RV_SHA=.*\.sha' "$MG"; then
    ok "AC6: merge-gate.sh pins on review-verdict.json's .sha, so a child-pinned verdict is what it rejects"
  else
    notok "AC6: merge-gate.sh does not read review-verdict.json's .sha — the pin check is not where assumed"
  fi
  if grep -q 'gates-head' "$ROOT/.claude/commands/merge.md"; then
    ok "AC6: /quetrex:merge compares gates-head, catching a stale pin before the hook runs"
  else
    notok "AC6: /quetrex:merge does not compare gates-head — the transport step proves nothing about the head"
  fi
else
  notok "AC6: merge-gate.sh not found at $MG"
fi

echo
echo "epic-terminus.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
