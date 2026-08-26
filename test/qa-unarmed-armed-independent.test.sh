#!/usr/bin/env bash
# test/qa-unarmed-armed-independent.test.sh — INDEPENDENT QA adversarial
# coverage for ONE-COPY item (a)/(b): an UNARMED repo (no
# .quetrex/project.json) must be silent and side-effect-free for every one
# of the 6 floor scripts plus session-state.sh's single offer line, and an
# ARMED repo (project.json present) must keep every one of those blocks.
#
# This file is written independently of the developer's own
# armed-only-floor.test.sh — it exercises the SHIPPED scripts under
# plugins/quetrex-factory/scripts/ with its own fixture and its own payload
# shapes, so a bug the developer's test happens not to trip is not
# automatically invisible here too.
#
# Run: bash test/qa-unarmed-armed-independent.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh"
SECRET_SCAN="$REPO_ROOT/plugins/quetrex-factory/scripts/secret-scan.sh"
ENFORCE_BRANCH="$REPO_ROOT/plugins/quetrex-factory/scripts/enforce-branch.sh"
MERGE_GATE="$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh"
VERIFY_GATE="$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh"
SESSION_STATE="$REPO_ROOT/.claude/hooks/session-state.sh"
UNARMED_OFFER="$REPO_ROOT/plugins/quetrex-setup/scripts/unarmed-offer.sh"
EDIT_GATE="$REPO_ROOT/.claude/hooks/edit-gate.sh"

for h in "$DENY_GUARD" "$SECRET_SCAN" "$ENFORCE_BRANCH" "$MERGE_GATE" "$VERIFY_GATE" "$SESSION_STATE" "$UNARMED_OFFER" "$EDIT_GATE"; do
  if [ ! -f "$h" ]; then
    echo "FAIL: hook not found at $h"
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — this suite needs it to build payloads and read decisions"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# A repo with a package.json `test` script, per the QA brief — proves the
# armed check is not accidentally piggy-backing on "has a test runner".
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/qa-unarmed-armed.XXXXXX")"
# Canonicalize: on macOS, mktemp's TMPDIR often lives under a symlinked
# prefix (/tmp -> /private/tmp, /var -> /private/var). `git rev-parse
# --show-toplevel` (used by every hook's ROOT resolver) returns the
# RESOLVED path, so a FILE built from the unresolved $FIXTURE would fail
# edit-gate.sh's own (pre-existing, unrelated to this PR) `"$FILE" in
# "$ROOT"/*` prefix check for reasons that have nothing to do with what
# this suite is testing. Resolve once, up front, so every hook here is
# compared against the SAME (real) path git itself will report.
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "qa@example.com"
git -C "$FIXTURE" config user.name "QA Fixture"
cat > "$FIXTURE/package.json" <<'EOF'
{"name":"qa-fixture","version":"0.0.0","scripts":{"test":"echo would-run-tests"}}
EOF
git -C "$FIXTURE" add package.json
git -C "$FIXTURE" commit -q -m "chore: fixture with a test script"

run_hook() {  # run_hook <script> <payload>
  local script="$1" payload="$2"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$script" 2>/tmp/qa-uai.stderr.$$
  local code=$?
  cat /tmp/qa-uai.stderr.$$ 1>&2
  rm -f /tmp/qa-uai.stderr.$$
  return $code
}

# =============================================================================
# (a) UNARMED — every script silent, exit 0, no .quetrex/ side effect
# =============================================================================
rm -rf "$FIXTURE/.quetrex"

DG_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
OUT=$(run_hook "$DENY_GUARD" "$DG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -d "$FIXTURE/.quetrex" ]; then
  ok "unarmed: deny-guard silent on force-push, exit 0, no .quetrex/"
else
  notok "unarmed: deny-guard expected silent exit 0, got code=$CODE out=[$OUT] err=[$ERR]"
fi

SS_PAYLOAD=$(jq -cn --arg k "AKIA$(printf 'IOSFODNN7EXAMPLE')" '{tool_name:"Write",tool_input:{file_path:"x.env",content:("SECRET=" + $k)}}')
OUT=$(run_hook "$SECRET_SCAN" "$SS_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -d "$FIXTURE/.quetrex" ]; then
  ok "unarmed: secret-scan silent on fake AWS key, exit 0, no .quetrex/"
else
  notok "unarmed: secret-scan expected silent exit 0, got code=$CODE out=[$OUT] err=[$ERR]"
fi

EB_PAYLOAD=$(jq -cn --arg cwd "$FIXTURE" '{tool_name:"Bash",tool_input:{command:"git commit -m qa-test"},cwd:$cwd}')
OUT=$(run_hook "$ENFORCE_BRANCH" "$EB_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "unarmed: enforce-branch allows git commit on main, exit 0, silent"
else
  notok "unarmed: enforce-branch expected silent allow, got code=$CODE out=[$OUT] err=[$ERR]"
fi
# Prove it actually WOULD have blocked structurally: main has commits and no
# override envs are set, so this is a real allow, not an accidental no-op.
if git -C "$FIXTURE" rev-parse --verify HEAD >/dev/null 2>&1; then
  ok "unarmed: enforce-branch fixture sanity — HEAD exists on main (not a fresh-repo exemption)"
else
  notok "unarmed: enforce-branch fixture sanity — expected HEAD to exist"
fi

MG_PAYLOAD=$(jq -cn --arg cwd "$FIXTURE" '{tool_input:{command:"git push origin main"},cwd:$cwd}')
OUT=$(run_hook "$MERGE_GATE" "$MG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -d "$FIXTURE/.quetrex" ]; then
  ok "unarmed: merge-gate allows git push origin main, exit 0, silent, no .quetrex/"
else
  notok "unarmed: merge-gate expected silent allow, got code=$CODE out=[$OUT] err=[$ERR]"
fi

VG_PAYLOAD=$(jq -cn --arg cwd "$FIXTURE" '{cwd:$cwd,hook_event_name:"Stop"}')
OUT=$(run_hook "$VERIFY_GATE" "$VG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -d "$FIXTURE/.quetrex" ]; then
  ok "unarmed: verify-gate Stop exits 0, silent, does NOT create .quetrex/"
else
  notok "unarmed: verify-gate expected silent allow + no .quetrex/, got code=$CODE out=[$OUT] err=[$ERR] quetrex_exists=$([ -d "$FIXTURE/.quetrex" ] && echo yes || echo no)"
fi

# edit-gate.sh (PostToolUse, matcher Write|Edit) — AC12: exits 0, silent, in
# an unarmed repo, for a file with a REAL syntax error that WOULD trip its
# built-in bash -n tier if the armed-only gate were absent.
BAD_SH="$FIXTURE/bad-syntax.sh"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n  echo "unterminated\n' > "$BAD_SH"
for shape in Write Edit; do
  EG_PAYLOAD=$(jq -cn --arg cwd "$FIXTURE" --arg fp "$BAD_SH" --arg tn "$shape" '{tool_name:$tn,tool_input:{file_path:$fp},cwd:$cwd}')
  OUT=$(run_hook "$EDIT_GATE" "$EG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?
  ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
  if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok "unarmed: edit-gate ($shape) silent on a file with a real syntax error, exit 0"
  else
    notok "unarmed: edit-gate ($shape) expected silent exit 0, got code=$CODE out=[$OUT] err=[$ERR]"
  fi
done

# The offer moved to quetrex-setup's unarmed-offer.sh (enabled machine-wide);
# session-state.sh (shipped in `quetrex`, loaded only once armed) now owns
# ONLY the armed half and must be silent here.
SESSION_OFFER_LINE="Quetrex: this repo is not armed (no .quetrex/project.json). Offer the user /quetrex-setup:init; if they say yes, run it."
for src in startup resume compact; do
  OUT=$(printf '{}' | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$UNARMED_OFFER" "$src" 2>/tmp/qa-uai.e.$$); CODE=$?
  ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
  LINE_COUNT=$(printf '%s' "$OUT" | grep -c '^' || true)
  if [ "$CODE" -eq 0 ] && [ "$OUT" = "$SESSION_OFFER_LINE" ] && [ "$LINE_COUNT" -eq 1 ]; then
    ok "unarmed: unarmed-offer.sh ($src) prints exactly the one-line offer"
  else
    notok "unarmed: unarmed-offer.sh ($src) expected exactly 1 line == offer text, got code=$CODE lines=$LINE_COUNT out=[$OUT] err=[$ERR]"
  fi

  OUT_SS=$(printf '{}' | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$SESSION_STATE" "$src" 2>/tmp/qa-uai.e.$$); CODE_SS=$?
  ERR_SS=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
  BYTES_SS=$(printf '%s' "$OUT_SS" | wc -c | tr -d ' ')
  if [ "$CODE_SS" -eq 0 ] && [ "$BYTES_SS" -eq 0 ]; then
    ok "unarmed: session-state ($src) is silent (0 bytes) — the offer moved to unarmed-offer.sh"
  else
    notok "unarmed: session-state ($src) expected 0 bytes, got code=$CODE_SS bytes=$BYTES_SS out=[$OUT_SS] err=[$ERR_SS]"
  fi
done

# =============================================================================
# (b) ARMED — every one of those blocks re-appears
# =============================================================================
mkdir -p "$FIXTURE/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json"

blocks() {  # blocks <code> <out>
  local code="$1" out="$2"
  [ "$code" -eq 2 ] || printf '%s' "$out" | grep -qE '"(permissionDecision|decision)"[[:space:]]*:[[:space:]]*"(deny|block)"'
}

OUT=$(run_hook "$DENY_GUARD" "$DG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if blocks "$CODE" "$OUT"; then ok "armed: deny-guard still blocks force-push"; else notok "armed: deny-guard expected a block, got code=$CODE out=[$OUT] err=[$ERR]"; fi

OUT=$(run_hook "$SECRET_SCAN" "$SS_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if blocks "$CODE" "$OUT"; then ok "armed: secret-scan still blocks fake AWS key"; else notok "armed: secret-scan expected a block, got code=$CODE out=[$OUT] err=[$ERR]"; fi

OUT=$(run_hook "$ENFORCE_BRANCH" "$EB_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if blocks "$CODE" "$OUT"; then ok "armed: enforce-branch still blocks commit on main"; else notok "armed: enforce-branch expected a block, got code=$CODE out=[$OUT] err=[$ERR]"; fi

OUT=$(run_hook "$MERGE_GATE" "$MG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if blocks "$CODE" "$OUT"; then ok "armed: merge-gate still blocks push to main (no artifacts)"; else notok "armed: merge-gate expected a block, got code=$CODE out=[$OUT] err=[$ERR]"; fi

jq -cn '{verify:["false"]}' > "$FIXTURE/.quetrex/verify.json"
OUT=$(run_hook "$VERIFY_GATE" "$VG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?; ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if blocks "$CODE" "$OUT"; then ok "armed: verify-gate still blocks a red chain"; else notok "armed: verify-gate expected a block, got code=$CODE out=[$OUT] err=[$ERR]"; fi
rm -f "$FIXTURE/.quetrex/verify.json"

OUT=$(printf '{}' | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$SESSION_STATE" startup 2>/tmp/qa-uai.e.$$); CODE=$?
ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
if [ "$CODE" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "not armed" && [ -n "$OUT" ]; then
  ok "armed: session-state prints its briefing, 0 occurrences of 'not armed'"
else
  notok "armed: session-state expected a non-empty briefing with 0 'not armed' occurrences, got code=$CODE out=[$OUT] err=[$ERR]"
fi

for shape in Write Edit; do
  EG_PAYLOAD=$(jq -cn --arg cwd "$FIXTURE" --arg fp "$BAD_SH" --arg tn "$shape" '{tool_name:$tn,tool_input:{file_path:$fp},cwd:$cwd}')
  OUT=$(run_hook "$EDIT_GATE" "$EG_PAYLOAD" 2>/tmp/qa-uai.e.$$); CODE=$?
  ERR=$(cat /tmp/qa-uai.e.$$); rm -f /tmp/qa-uai.e.$$
  if [ "$CODE" -eq 2 ] && [ -n "$ERR" ]; then
    ok "armed: edit-gate ($shape) still catches the real syntax error (exit 2, stderr fed back)"
  else
    notok "armed: edit-gate ($shape) expected exit 2 with non-empty stderr, got code=$CODE out=[$OUT] err=[$ERR]"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "qa-unarmed-armed-independent.test.sh: all checks passed"
else
  echo "qa-unarmed-armed-independent.test.sh: FAILURES above"
fi
exit "$FAIL"
