#!/usr/bin/env bash
# stop-bounded-by-construction.test.sh — proves G2 (HOOKFIX,
# .quetrex/plan/HOOKFIX.json): the per-turn Stop/SubagentStop verify chain is
# now BOUNDED BY CONSTRUCTION for ANY repo, including one that never declared
# a verifyQuick, and including one that DECLARES a slow verifyQuick.
#
# EVERY ASSERTION DRIVES THE SHIPPED HOOK end to end via its real stdin JSON
# payload (overridable via QX_VERIFY_GATE_HOOK, matching the existing
# convention in test/quick-chain-on-stop.test.sh and test/verify-gate.test.sh)
# against fixture git repos this file builds itself. Nothing here re-implements
# or greps a sub-expression of the hook — every assertion is on OBSERVABLE
# behavior: marker files written by the fixture's own commands, the ledger
# file, stdout, exit code, wall clock.
#
# HEAVY FIXTURES USE REAL COMMAND SHAPES (operator-directed correction,
# 2026-08-21 — see verify-gate-quick-chain.sh's qx_is_heavy_segment): the
# matcher is now PRECISE structured-token matching (npm/yarn/pnpm/bun run
# <script>, bare "npm test", or a direct test/build binary), not a
# whole-string substring regex — a `# test` comment tag on an arbitrary `sh
# -c` command no longer counts as heavy, and correctly so. Every "heavy"
# fixture below is therefore a REAL npm-shaped invocation, with its actual
# behavior (sleep/fail/mark) supplied by a per-fixture PATH-shimmed `npm` (or
# other binary) — never a real npm install. A "cheap" fixture stays a plain
# `sh -c`/`echo`, exactly as before.
#
# AC1: a heavy command ("npm test", shimmed to sleep 30s) never runs; a cheap
#      one does.
# AC2: the quick-chain wall-clock cap (QUETREX_VERIFY_QUICK_CAP) cuts a run
#      short and ALLOWS — no ledger line for the cut command, no containment
#      side effects (ESCALATION/verify-attempts untouched).
# AC3: a genuinely failing CHEAP command still blocks (red stays red).
# AC4: 12 commands (7 heavy, real npm/playwright/vitest/jest/cypress shapes;
#      5 cheap) — the derived chain runs exactly the 5.
# AC5: an ALL-heavy verify[] runs nothing, allows, and says so once.
# AC6: SubagentStop + a non-subset verifyQuick still runs the real chain and
#      blocks on its genuine failure (subset enforcement is untouched).
# ADDENDUM (coordinator correction, 2026-08-21): the heavy-command filter and
# the quick-chain cap apply to a DECLARED verifyQuick too, not only an
# auto-derived one — a repo that explicitly configures a slow verifyQuick is
# bounded exactly like a repo that configures none.
# PRECISION (coordinator correction, 2026-08-21): the matcher must NOT flag a
# plain `echo` whose text happens to contain "BUILD"/"TEST", and must NOT
# flag a command whose PATH ARGUMENT merely traverses a directory containing
# "test" — pinned directly against the exact two collision shapes the
# coordinator's own review found.
# AC11 (fail-first): every new assertion below is proven to fail against the
# pre-change baseline resolved from origin/main (fallback main).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_VERIFY_GATE_HOOK:-$ROOT/.claude/hooks/verify-gate.sh}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable — verify-gate is jq-mandatory"; echo; echo "stop-bounded-by-construction.test.sh: $PASS passed, $FAIL failed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkrepo() {  # mkrepo <dir> <verify-json>
  mkdir -p "$1/.quetrex"
  git -C "$1" init --quiet -b main 2>/dev/null || git -C "$1" init --quiet 2>/dev/null
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  printf '%s' "$2" > "$1/.quetrex/verify.json"
  git -C "$1" add -A 2>/dev/null
  git -C "$1" commit -qm init 2>/dev/null
}
fire_ev() {  # fire_ev <repo> <event> [extra env assignments...] -> stdout on
  # stdout; the CALLER reads $? immediately after `X="$(fire_ev ...)"`, which
  # correctly reflects this function's own exit status (bash propagates a
  # function's last-command exit status through a command substitution) —
  # deliberately NOT a global variable set inside the function body, which
  # would be set inside the subshell `$(...)` forks and lost the instant it
  # exits (the exact class of bug merge-gate.sh's normalize_segment comment
  # warns about for output, not just for exit status).
  local repo="$1" event="$2"; shift 2
  printf '{"hook_event_name":"%s","cwd":"%s"}' "$event" "$repo" \
    | ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" env "$@" bash "$HOOK" 2>&1 )
}
block_count() { printf '%s' "$1" | grep -c '"decision"[[:space:]]*:[[:space:]]*"block"'; }
ledger_count_for() {  # ledger_count_for <repo> <cmd>
  local repo="$1" cmd="$2"
  [ -f "$repo/.quetrex/verify-ledger.jsonl" ] || { echo 0; return; }
  jq -s --arg c "$cmd" '[.[] | select(.cmd==$c)] | length' "$repo/.quetrex/verify-ledger.jsonl" 2>/dev/null || echo 0
}
ledger_lines_total() {
  [ -f "$1/.quetrex/verify-ledger.jsonl" ] || { echo 0; return; }
  wc -l < "$1/.quetrex/verify-ledger.jsonl" | tr -d ' '
}
# is_bounded_skip_line <repo> <cmd> -- SEC-1/SEC-3 (security review,
# 2026-08-21): the ledger must describe the WHOLE resolved chain, always. A
# command the bounded quick chain excluded (heavy-filtered, or cut by the
# cap) must carry EXACTLY ONE ledger line: skipped:true, exit:null,
# skipReason:"boundedQuick" (never absent, never "requiredEnv").
is_bounded_skip_line() {  # -> "1" if exactly one such line exists, else "0"
  local repo="$1" cmd="$2"
  [ -f "$repo/.quetrex/verify-ledger.jsonl" ] || { echo 0; return; }
  jq -s --arg c "$cmd" \
    '[.[] | select(.cmd==$c and .skipped==true and .skipReason=="boundedQuick" and .exit==null)] | length' \
    "$repo/.quetrex/verify-ledger.jsonl" 2>/dev/null || echo 0
}
# mkshim <dir> <name> <body> — writes an executable fake binary at
# <dir>/<name> whose body is <body> (a real shell script fragment). Used to
# give a REAL npm/playwright/vitest/jest/cypress-shaped command controllable
# behavior (sleep/fail/mark) without a real install.
mkshim() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$body"; } > "$dir/$name"
  chmod +x "$dir/$name"
}

# =============================================================================
# AC1 — a heavy command (a real "npm test" invocation) never runs; a cheap
# one does. Wall clock proves it: the shimmed npm sleeps 30s on "test", so
# >=30s would mean it ran.
# =============================================================================
F1="$TMP/ac1"
MARK1="$TMP/ac1-marks"; : > "$MARK1"
mkrepo "$F1" '{"verify":["sh -c \"echo cheap >> '"$MARK1"'\"","npm test"]}'
mkshim "$F1/fakebin" npm "echo heavy >> '"$MARK1"'; sleep 30"
START1=$(date +%s)
OUT1="$(fire_ev "$F1" Stop PATH="$F1/fakebin:$PATH")"; CODE1=$?
END1=$(date +%s)
ELAPSED1=$((END1-START1))
BLOCKS1=$(block_count "$OUT1")
CHEAP1=$(grep -c '^cheap$' "$MARK1" 2>/dev/null; true); CHEAP1=${CHEAP1:-0}
HEAVY1=$(grep -c '^heavy$' "$MARK1" 2>/dev/null; true); HEAVY1=${HEAVY1:-0}

[ "$CODE1" -eq 0 ] && ok "AC1: hook exit 0" || notok "AC1: expected exit 0, got $CODE1"
[ "$BLOCKS1" -eq 0 ] && ok "AC1: 0 block decisions" || notok "AC1: expected 0 block decisions, got $BLOCKS1 (out: [$OUT1])"
[ "$HEAVY1" -eq 0 ] && ok "AC1: the heavy (\"npm test\", sleeping) command never ran (0 marker lines)" \
  || notok "AC1: the heavy command ran ($HEAVY1 marker lines) — it should have been filtered"
[ "$CHEAP1" -eq 1 ] && ok "AC1: the cheap command ran exactly once" \
  || notok "AC1: expected exactly 1 cheap marker line, got $CHEAP1"
[ "$ELAPSED1" -lt 5 ] && ok "AC1: wall clock ${ELAPSED1}s < 5s (a 30s sleep would have failed this)" \
  || notok "AC1: wall clock ${ELAPSED1}s >= 5s — the heavy command likely ran"

# SEC-1/SEC-3 (security review, 2026-08-21): the filtered-out heavy command
# is NOT simply absent from the ledger -- it carries its own boundedQuick
# skip line, so the ledger still describes the whole resolved chain.
BOUNDED1="$(is_bounded_skip_line "$F1" "npm test")"
[ "$BOUNDED1" = "1" ] && ok "AC1: the filtered-out heavy command has exactly 1 boundedQuick ledger line (the ledger describes the WHOLE resolved chain)" \
  || notok "AC1: expected exactly 1 boundedQuick ledger line for the filtered command, got $BOUNDED1"

# =============================================================================
# AC2 — the quick-chain cap cuts the run and ALLOWS; nothing is recorded for
# the cut command; ESCALATION and verify-attempts are untouched (containment).
# A cheap `sh -c "sleep 20"` deliberately stays UN-heavy here (this AC is
# about the cap, not the matcher — see AC5b for a heavy command hitting the
# cap via the empty-filter fallback).
# =============================================================================
F2="$TMP/ac2"
mkrepo "$F2" '{"verify":["sh -c \"sleep 20\""],"verifyQuick":["sh -c \"sleep 20\""]}'
: > "$F2/.quetrex/ESCALATION"
echo 2 > "$F2/.quetrex/verify-attempts"
START2=$(date +%s)
OUT2="$(fire_ev "$F2" Stop QUETREX_VERIFY_QUICK_CAP=2)"; CODE2=$?
END2=$(date +%s)
ELAPSED2=$((END2-START2))
BLOCKS2=$(block_count "$OUT2")
LEDGER2=$(ledger_count_for "$F2" "sh -c \"sleep 20\"")
BOUNDED2="$(is_bounded_skip_line "$F2" "sh -c \"sleep 20\"")"
LINES2=$(printf '%s\n' "$OUT2" | grep -c .)
CAPMENTION2=$(printf '%s' "$OUT2" | grep -ci 'cap')

[ "$CODE2" -eq 0 ] && ok "AC2: hook exit 0 (cap-allow, not a block)" || notok "AC2: expected exit 0, got $CODE2"
[ "$BLOCKS2" -eq 0 ] && ok "AC2: 0 block decisions" || notok "AC2: expected 0 block decisions, got $BLOCKS2 (out: [$OUT2])"
[ "$ELAPSED2" -lt 10 ] && ok "AC2: wall clock ${ELAPSED2}s < 10s (a 20s sleep would have failed this)" \
  || notok "AC2: wall clock ${ELAPSED2}s >= 10s — the cap did not cut the run"
# SEC-1/SEC-3 (security review, 2026-08-21): the capped command is not simply
# absent from the ledger (absence broke merge-gate's ledger-derived-chain
# fallback in both directions) -- it carries exactly ONE boundedQuick skip
# line: exit:null, skipped:true, skipReason:"boundedQuick" (never
# "requiredEnv", never a genuine exit code).
[ "$LEDGER2" -eq 1 ] && ok "AC2: exactly 1 ledger line for the capped command (never 0 — the ledger describes the whole resolved chain)" \
  || notok "AC2: expected exactly 1 ledger line for the capped command, got $LEDGER2"
[ "$BOUNDED2" = "1" ] && ok "AC2: that line is a genuine boundedQuick skip (exit:null, skipped:true, skipReason:boundedQuick) — never a null/124/137 entry read as a real failure" \
  || notok "AC2: expected exactly 1 boundedQuick-shaped line, got $BOUNDED2"
[ -f "$F2/.quetrex/ESCALATION" ] && ok "AC2: pre-existing ESCALATION still exists (a cap-allow is not a green)" \
  || notok "AC2: ESCALATION was cleared by a cap-allow run"
[ "$(cat "$F2/.quetrex/verify-attempts" 2>/dev/null)" = "2" ] && ok "AC2: verify-attempts still reads '2' (self-heal counter untouched)" \
  || notok "AC2: verify-attempts changed, expected '2', got '$(cat "$F2/.quetrex/verify-attempts" 2>/dev/null)'"
[ "$LINES2" -eq 1 ] && ok "AC2: stdout is exactly 1 line" || notok "AC2: expected exactly 1 stdout line, got $LINES2 (out: [$OUT2])"
[ "$CAPMENTION2" -ge 1 ] && ok "AC2: stdout names the cap" || notok "AC2: stdout does not mention the cap (out: [$OUT2])"

# =============================================================================
# AC3 — a genuinely failing CHEAP command still blocks (red stays red).
# =============================================================================
F3="$TMP/ac3"
mkrepo "$F3" '{"verify":["sh -c \"exit 9\""]}'
HEAD3="$(git -C "$F3" rev-parse HEAD)"
OUT3="$(fire_ev "$F3" Stop)"; CODE3=$?
BLOCKS3=$(block_count "$OUT3")
REASON3="$(printf '%s' "$OUT3" | jq -r '.reason // empty' 2>/dev/null)"
LEDGER3_LINE="$(jq -s -c --arg c "sh -c \"exit 9\"" '[.[] | select(.cmd==$c)]' "$F3/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
LEDGER3_EXIT="$(printf '%s' "$LEDGER3_LINE" | jq -r '.[0].exit // empty' 2>/dev/null)"
LEDGER3_SHA="$(printf '%s' "$LEDGER3_LINE" | jq -r '.[0].sha // empty' 2>/dev/null)"
LEDGER3_N="$(printf '%s' "$LEDGER3_LINE" | jq 'length' 2>/dev/null)"

[ "$CODE3" -eq 0 ] && ok "AC3: hook exit 0" || notok "AC3: expected exit 0, got $CODE3"
[ "$BLOCKS3" -eq 1 ] && ok "AC3: exactly 1 block decision" || notok "AC3: expected 1 block decision, got $BLOCKS3 (out: [$OUT3])"
printf '%s' "$REASON3" | grep -Eq 'exited 9([^0-9]|$)' \
  && ok "AC3: block reason matches 'exited 9([^0-9]|\$)'" \
  || notok "AC3: block reason does not match 'exited 9([^0-9]|\$)' [$REASON3]"
[ "$LEDGER3_N" = "1" ] && ok "AC3: exactly 1 ledger line for the failing command" \
  || notok "AC3: expected exactly 1 ledger line, got $LEDGER3_N"
[ "$LEDGER3_EXIT" = "9" ] && ok "AC3: ledger .exit == 9" || notok "AC3: expected ledger .exit == 9, got [$LEDGER3_EXIT]"
[ "$LEDGER3_SHA" = "$HEAD3" ] && ok "AC3: ledger .sha == the fixture's HEAD sha" \
  || notok "AC3: expected ledger .sha == $HEAD3, got [$LEDGER3_SHA]"

# =============================================================================
# AC4 — 12 commands: 7 REAL heavy shapes (npm test, npm run build, npm run
# e2e, playwright test, vitest, jest, cypress) + 5 cheap. The derived chain
# runs exactly the 5. PATH-shimmed binaries mark if (and only if) they are
# ever actually invoked — the filter must keep every one of them from ever
# running at all.
# =============================================================================
F4="$TMP/ac4"
MARK4="$TMP/ac4-marks"; : > "$MARK4"
mkshim "$F4/fakebin" npm '
case "$1 $2" in
  "test ") echo H_npmtest >> '"$MARK4"' ;;
  *) case "$1" in
       run) case "$2" in
              build) echo H_npmbuild >> '"$MARK4"' ;;
              e2e) echo H_npme2e >> '"$MARK4"' ;;
            esac ;;
     esac ;;
esac
exit 0'
mkshim "$F4/fakebin" playwright 'echo H_playwright >> '"$MARK4"'; exit 0'
mkshim "$F4/fakebin" vitest 'echo H_vitest >> '"$MARK4"'; exit 0'
mkshim "$F4/fakebin" jest 'echo H_jest >> '"$MARK4"'; exit 0'
mkshim "$F4/fakebin" cypress 'echo H_cypress >> '"$MARK4"'; exit 0'
V4='{"verify":["npm test","npm run build","npm run e2e","playwright test","vitest","jest","cypress",'
for i in 1 2 3 4 5; do
  V4="${V4}\"sh -c \\\"echo C_${i} >> ${MARK4}\\\"\""
  [ "$i" -lt 5 ] && V4="${V4},"
done
V4="${V4}]}"
mkrepo "$F4" "$V4"
OUT4="$(fire_ev "$F4" Stop PATH="$F4/fakebin:$PATH")"; CODE4=$?
BLOCKS4=$(block_count "$OUT4")
HEAVY4_TOTAL=0
for kw in npmtest npmbuild npme2e playwright vitest jest cypress; do
  n=$(grep -c "^H_${kw}\$" "$MARK4" 2>/dev/null; true); n=${n:-0}
  HEAVY4_TOTAL=$((HEAVY4_TOTAL+n))
done
CHEAP4_TOTAL=0
for i in 1 2 3 4 5; do
  n=$(grep -c "^C_${i}\$" "$MARK4" 2>/dev/null; true); n=${n:-0}
  CHEAP4_TOTAL=$((CHEAP4_TOTAL+n))
done
LEDGER4_TOTAL="$(ledger_lines_total "$F4")"

[ "$CODE4" -eq 0 ] && ok "AC4: hook exit 0" || notok "AC4: expected exit 0, got $CODE4"
[ "$BLOCKS4" -eq 0 ] && ok "AC4: 0 block decisions" || notok "AC4: expected 0 block decisions, got $BLOCKS4"
[ "$HEAVY4_TOTAL" -eq 0 ] && ok "AC4: 0 total marker lines from the 7 heavy commands (none ever invoked)" \
  || notok "AC4: expected 0 heavy marker lines, got $HEAVY4_TOTAL"
[ "$CHEAP4_TOTAL" -eq 5 ] && ok "AC4: exactly 5 total marker lines from the 5 cheap commands (one each)" \
  || notok "AC4: expected 5 cheap marker lines, got $CHEAP4_TOTAL"
# SEC-1/SEC-3 (security review, 2026-08-21): the ledger must describe the
# WHOLE resolved chain, always — the 7 excluded heavy commands are NOT
# simply absent; each carries its own boundedQuick skip line, alongside the
# 5 genuine (exit:0) lines from the cheap commands that actually ran.
[ "$LEDGER4_TOTAL" = "12" ] && ok "AC4: exactly 12 ledger lines were appended (5 genuine + 7 boundedQuick — the whole resolved chain, not just what ran)" \
  || notok "AC4: expected 12 ledger lines (5 genuine + 7 boundedQuick), got $LEDGER4_TOTAL"
BOUNDED4_TOTAL=0
for hcmd in "npm test" "npm run build" "npm run e2e" "playwright test" "vitest" "jest" "cypress"; do
  n="$(is_bounded_skip_line "$F4" "$hcmd")"
  BOUNDED4_TOTAL=$((BOUNDED4_TOTAL + n))
done
[ "$BOUNDED4_TOTAL" -eq 7 ] && ok "AC4: all 7 heavy commands each have exactly 1 boundedQuick ledger line" \
  || notok "AC4: expected 7 boundedQuick lines (one per heavy command), got $BOUNDED4_TOTAL"

# =============================================================================
# AC5 — CORRECTED (coordinator directive, 2026-08-21): an ALL-heavy verify[]
# does NOT run nothing. The plan's original AC5 text ("nothing is executed,
# the finish is allowed... stdout == exactly 1 line") is EXPLICITLY SUPERSEDED
# — filtering to an EMPTY chain allowed a red finish with ZERO evidence
# written. The corrected rule: if filtering would leave nothing runnable,
# DISCARD the filter and run the ORIGINAL chain instead, still under the
# wall-clock cap. Two real fixtures (a real "npm test" invocation, shimmed)
# prove both directions of that fallback:
#   AC5a — a fast-FAILING all-heavy chain still runs for real and BLOCKS,
#          with a genuine ledger line (the cap never even has to fire).
#   AC5b — a genuinely SLOW all-heavy chain is still bounded by the cap and
#          ALLOWS (identical mechanism to AC2, reached via the fallback path
#          instead of a chain that was never filtered in the first place).
# =============================================================================
F5A="$TMP/ac5a"
mkrepo "$F5A" '{"verify":["npm test"]}'
mkshim "$F5A/fakebin" npm "exit 3"
HEAD5A="$(git -C "$F5A" rev-parse HEAD)"
OUT5A="$(fire_ev "$F5A" Stop PATH="$F5A/fakebin:$PATH")"; CODE5A=$?
BLOCKS5A=$(block_count "$OUT5A")
REASON5A="$(printf '%s' "$OUT5A" | jq -r '.reason // empty' 2>/dev/null)"
LEDGER5A="$(jq -s -c --arg c "npm test" '[.[] | select(.cmd==$c)]' "$F5A/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
LEDGER5A_N="$(printf '%s' "$LEDGER5A" | jq 'length' 2>/dev/null)"
LEDGER5A_EXIT="$(printf '%s' "$LEDGER5A" | jq -r '.[0].exit // empty' 2>/dev/null)"

[ "$CODE5A" -eq 0 ] && ok "AC5a: hook exit 0" || notok "AC5a: expected exit 0, got $CODE5A"
[ "$BLOCKS5A" -eq 1 ] && ok "AC5a: a fast-failing all-heavy chain still BLOCKS (fallback ran the original chain for real)" \
  || notok "AC5a: expected 1 block decision, got $BLOCKS5A (out: [$OUT5A])"
printf '%s' "$REASON5A" | grep -Eq 'exited 3([^0-9]|$)' && ok "AC5a: block reason names the real exit code 3" \
  || notok "AC5a: block reason does not name exit 3 [$REASON5A]"
[ "$LEDGER5A_N" = "1" ] && [ "$LEDGER5A_EXIT" = "3" ] \
  && ok "AC5a: exactly 1 genuine ledger line for the heavy command, exit 3 (real evidence, not silence)" \
  || notok "AC5a: expected 1 ledger line with exit 3, got n=$LEDGER5A_N exit=$LEDGER5A_EXIT"

F5B="$TMP/ac5b"
mkrepo "$F5B" '{"verify":["npm test"]}'
mkshim "$F5B/fakebin" npm "sleep 20"
START5B=$(date +%s)
OUT5B="$(fire_ev "$F5B" Stop QUETREX_VERIFY_QUICK_CAP=2 PATH="$F5B/fakebin:$PATH")"; CODE5B=$?
END5B=$(date +%s)
ELAPSED5B=$((END5B-START5B))
BLOCKS5B=$(block_count "$OUT5B")
LEDGER5B_TOTAL="$(ledger_lines_total "$F5B")"
CAPMENTION5B=$(printf '%s' "$OUT5B" | grep -ci 'cap')

[ "$CODE5B" -eq 0 ] && ok "AC5b: hook exit 0 (cap-allow via the fallback path)" || notok "AC5b: expected exit 0, got $CODE5B"
[ "$BLOCKS5B" -eq 0 ] && ok "AC5b: 0 block decisions" || notok "AC5b: expected 0 block decisions, got $BLOCKS5B"
[ "$ELAPSED5B" -lt 10 ] && ok "AC5b: wall clock ${ELAPSED5B}s < 10s (a 20s sleep would have failed this)" \
  || notok "AC5b: wall clock ${ELAPSED5B}s >= 10s — the cap did not bound the fallback chain"
# SEC-1/SEC-3 (security review, 2026-08-21): the capped command is not
# simply absent from the ledger — it carries exactly 1 boundedQuick skip
# line (exit:null, skipped:true, skipReason:"boundedQuick"), reached here
# via the empty-filter FALLBACK path (this single-command chain, all heavy,
# would filter to empty and fall back to the original chain, which then
# genuinely hits the cap) — proving boundedQuick recording applies on the
# fallback path too, not only the ordinary-filter path AC2/AC4 already cover.
BOUNDED5B="$(is_bounded_skip_line "$F5B" "npm test")"
[ "$LEDGER5B_TOTAL" = "1" ] && ok "AC5b: exactly 1 ledger line appended for the capped command (never 0)" \
  || notok "AC5b: expected exactly 1 ledger line, got $LEDGER5B_TOTAL"
[ "$BOUNDED5B" = "1" ] && ok "AC5b: that line is a genuine boundedQuick skip, reached via the empty-filter fallback path" \
  || notok "AC5b: expected exactly 1 boundedQuick-shaped line, got $BOUNDED5B"
[ "$CAPMENTION5B" -ge 1 ] && ok "AC5b: stdout mentions the cap" || notok "AC5b: stdout does not mention the cap (out: [$OUT5B])"

# =============================================================================
# AC6 — SubagentStop + non-subset verifyQuick: subset enforcement is
# UNCHANGED — the real verify[] chain runs and blocks on its genuine failure.
# =============================================================================
F6="$TMP/ac6"
REALCMD6="sh -c 'exit 9'"
mkrepo "$F6" "$(jq -cn --arg real "$REALCMD6" '{verify: [$real], verifyQuick: ["true"]}')"
OUT6="$(fire_ev "$F6" SubagentStop)"; CODE6=$?
BLOCKS6=$(block_count "$OUT6")
REASON6="$(printf '%s' "$OUT6" | jq -r '.reason // empty' 2>/dev/null)"
LEDGER6_REAL="$(ledger_count_for "$F6" "$REALCMD6")"
LEDGER6_TRUE="$(ledger_count_for "$F6" "true")"

[ "$CODE6" -eq 0 ] && ok "AC6: hook exit 0" || notok "AC6: expected exit 0, got $CODE6"
[ "$BLOCKS6" -eq 1 ] && ok "AC6: exactly 1 block decision" || notok "AC6: expected 1 block decision, got $BLOCKS6 (out: [$OUT6])"
printf '%s' "$REASON6" | grep -Eq 'exited 9([^0-9]|$)' && ok "AC6: reason matches 'exited 9([^0-9]|\$)'" \
  || notok "AC6: reason does not match 'exited 9([^0-9]|\$)' [$REASON6]"
printf '%s' "$REASON6" | grep -qi 'not a subset' && ok "AC6: reason case-insensitively contains 'not a subset'" \
  || notok "AC6: reason does not mention 'not a subset' [$REASON6]"
[ "$LEDGER6_REAL" = "1" ] && ok "AC6: exactly 1 ledger line for the real command" \
  || notok "AC6: expected 1 ledger line for the real command, got $LEDGER6_REAL"
[ "$LEDGER6_TRUE" = "0" ] && ok "AC6: 0 ledger lines for the rejected verifyQuick's \`true\`" \
  || notok "AC6: expected 0 ledger lines for \`true\`, got $LEDGER6_TRUE"

# =============================================================================
# ADDENDUM — a DECLARED verifyQuick is not exempt from the heavy filter or the
# cap. A repo that declares verifyQuick:["npm run lint","npm test"] must run
# lint and must NOT run test — nothing is special about a declared chain.
# =============================================================================
F7="$TMP/addendum"
MARK7="$TMP/addendum-marks"; : > "$MARK7"
mkshim "$F7/fakebin" npm '
if [ "$1" = "run" ] && [ "$2" = "lint" ]; then echo LINT >> '"$MARK7"'; exit 0; fi
if [ "$1" = "test" ]; then echo TESTED >> '"$MARK7"'; exit 0; fi
exit 0'
mkrepo "$F7" '{"verify":["npm run lint","npm test"],"verifyQuick":["npm run lint","npm test"]}'
OUT7="$(fire_ev "$F7" Stop PATH="$F7/fakebin:$PATH")"; CODE7=$?
BLOCKS7=$(block_count "$OUT7")
LINT7=$(grep -c '^LINT$' "$MARK7" 2>/dev/null; true); LINT7=${LINT7:-0}
TESTED7=$(grep -c '^TESTED$' "$MARK7" 2>/dev/null; true); TESTED7=${TESTED7:-0}

[ "$CODE7" -eq 0 ] && ok "ADDENDUM: hook exit 0" || notok "ADDENDUM: expected exit 0, got $CODE7"
[ "$BLOCKS7" -eq 0 ] && ok "ADDENDUM: 0 block decisions" || notok "ADDENDUM: expected 0 block decisions, got $BLOCKS7"
[ "$LINT7" -eq 1 ] && ok "ADDENDUM: the declared verifyQuick's cheap command still ran" \
  || notok "ADDENDUM: expected the cheap declared-quick command to run once, got $LINT7"
[ "$TESTED7" -eq 0 ] && ok "ADDENDUM: the declared verifyQuick's heavy command was filtered out (a declared chain is not exempt)" \
  || notok "ADDENDUM: the heavy command in a DECLARED verifyQuick ran anyway ($TESTED7) — declared chains must not be exempt from the heavy filter"
# SEC-1/SEC-3 (security review, 2026-08-21): the filtered-out heavy command
# still carries its own boundedQuick ledger line, even in a DECLARED
# verifyQuick — the ledger-completeness fix applies uniformly.
BOUNDED7="$(is_bounded_skip_line "$F7" "npm test")"
[ "$BOUNDED7" = "1" ] && ok "ADDENDUM: the filtered-out heavy command in a declared verifyQuick has exactly 1 boundedQuick ledger line" \
  || notok "ADDENDUM: expected exactly 1 boundedQuick ledger line for the filtered declared command, got $BOUNDED7"

# =============================================================================
# PRECISION — the two exact collision shapes the coordinator's review found:
# a plain `echo` containing "BUILD"/"TEST" must NOT be flagged heavy, and a
# command whose PATH ARGUMENT merely traverses a directory named with "test"
# in it must NOT be flagged heavy either. Both must actually RUN.
# =============================================================================
F8="$TMP/precision-test-dir"   # deliberately a tmpdir-style name containing "test"
MARK8="$TMP/precision-marks"; : > "$MARK8"
mkrepo "$F8" '{"verify":["echo BUILD_MARKER >> '"$MARK8"'","echo TEST_MARKER >> '"$MARK8"'","cat '"$F8"'/.quetrex/verify.json >> /dev/null"]}'
OUT8="$(fire_ev "$F8" Stop)"; CODE8=$?
BLOCKS8=$(block_count "$OUT8")
BUILDMARK8=$(grep -c '^BUILD_MARKER$' "$MARK8" 2>/dev/null; true); BUILDMARK8=${BUILDMARK8:-0}
TESTMARK8=$(grep -c '^TEST_MARKER$' "$MARK8" 2>/dev/null; true); TESTMARK8=${TESTMARK8:-0}
LEDGER8_TOTAL="$(ledger_lines_total "$F8")"

[ "$CODE8" -eq 0 ] && ok "PRECISION: hook exit 0" || notok "PRECISION: expected exit 0, got $CODE8"
[ "$BLOCKS8" -eq 0 ] && ok "PRECISION: 0 block decisions" || notok "PRECISION: expected 0 block decisions, got $BLOCKS8 (out: [$OUT8])"
[ "$BUILDMARK8" -eq 1 ] && ok "PRECISION: \`echo BUILD_MARKER\` ran — an echo whose TEXT contains \"BUILD\" is not heavy" \
  || notok "PRECISION: \`echo BUILD_MARKER\` did not run ($BUILDMARK8) — a plain echo was wrongly flagged heavy"
[ "$TESTMARK8" -eq 1 ] && ok "PRECISION: \`echo TEST_MARKER\` ran — an echo whose TEXT contains \"TEST\" is not heavy" \
  || notok "PRECISION: \`echo TEST_MARKER\` did not run ($TESTMARK8) — a plain echo was wrongly flagged heavy"
[ "$LEDGER8_TOTAL" = "3" ] && ok "PRECISION: all 3 commands ran (this fixture's OWN tmpdir path contains \"-test\", proving a path fragment is not enough to match)" \
  || notok "PRECISION: expected 3 ledger lines (all cheap, this fixture's tmpdir path itself contains \"test\"), got $LEDGER8_TOTAL"

# =============================================================================
# REQUIREDENV-HEAVY (QA-added, GREEN-PROOF review of HOOKFIX): a command that
# is BOTH heavy AND requiredEnv-skip-eligible must still be RECORDED as a
# declarative skip, never silently dropped by the heavy filter, under the
# REAL QUICK=1 (Stop) code path — not just under QUETREX_VERIFY_FULL=1, which
# is the only way test/verify-gate-env-derive-integration.test.sh drives this
# contract (see that file's own header note). qx_filter_heavy_chain's
# `should_skip_for_env "$_c" || ! qx_is_heavy_command "$_c"` ordering is the
# code under test here: dropping the `should_skip_for_env` half would make a
# heavy, missing-env command vanish with ZERO ledger evidence, which is
# exactly the merge-deadlock class HOOKFIX's notes[17]/security_surface
# exist to prevent (see verify-gate.sh's ledger-append comment at the
# requiredEnv skip site).
# =============================================================================
F9="$TMP/reqenv-heavy"
mkdir -p "$F9/.quetrex"
git -C "$F9" init --quiet -b main
git -C "$F9" config user.email t@t; git -C "$F9" config user.name t
printf '%s' '{"verify":["sh -c \"echo cheap\"","npm run build"],"requiredEnv":{"npm run build":["QX_REQENV_HEAVY_VAR"]}}' > "$F9/.quetrex/verify.json"
printf 'QX_REQENV_HEAVY_VAR=\n' > "$F9/.env.example"
git -C "$F9" add -A
git -C "$F9" commit -qm init
OUT9="$(printf '{"hook_event_name":"Stop","cwd":"%s"}' "$F9" \
  | ( cd "$F9" && CLAUDE_PROJECT_DIR="$F9" env -u QX_REQENV_HEAVY_VAR bash "$HOOK" 2>&1 ) )"; CODE9=$?
BLOCKS9=$(block_count "$OUT9")
SKIPLINE9=$(printf '%s\n' "$OUT9" | grep -c '^VERIFY SKIPPED')
LEDGER9="$(jq -s -c --arg c "npm run build" '[.[] | select(.cmd==$c)]' "$F9/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
LEDGER9_N="$(printf '%s' "$LEDGER9" | jq 'length' 2>/dev/null)"
LEDGER9_SKIPPED="$(printf '%s' "$LEDGER9" | jq -r '.[0].skipped // empty' 2>/dev/null)"
LEDGER9_REASON="$(printf '%s' "$LEDGER9" | jq -r '.[0].skipReason // empty' 2>/dev/null)"
LEDGER9_EXIT="$(printf '%s' "$LEDGER9" | jq -r '.[0].exit' 2>/dev/null)"

[ "$CODE9" -eq 0 ] && ok "REQUIREDENV-HEAVY: hook exit 0" || notok "REQUIREDENV-HEAVY: expected exit 0, got $CODE9"
[ "$BLOCKS9" -eq 0 ] && ok "REQUIREDENV-HEAVY: 0 block decisions" || notok "REQUIREDENV-HEAVY: expected 0 block decisions, got $BLOCKS9 (out: [$OUT9])"
[ "$SKIPLINE9" -eq 1 ] && ok "REQUIREDENV-HEAVY: exactly 1 VERIFY SKIPPED line for the heavy, env-missing command" \
  || notok "REQUIREDENV-HEAVY: expected exactly 1 VERIFY SKIPPED line, got $SKIPLINE9 (out: [$OUT9])"
[ "$LEDGER9_N" = "1" ] && ok "REQUIREDENV-HEAVY: exactly 1 ledger line for \`npm run build\` — the heavy filter did NOT silently drop it" \
  || notok "REQUIREDENV-HEAVY: expected exactly 1 ledger line for the heavy+skip-eligible command, got $LEDGER9_N — a 0-line result here would be an unprovable, undetected drop (the exact merge-deadlock class HOOKFIX exists to prevent)"
[ "$LEDGER9_SKIPPED" = "true" ] && [ "$LEDGER9_REASON" = "requiredEnv" ] && [ "$LEDGER9_EXIT" = "null" ] \
  && ok "REQUIREDENV-HEAVY: ledger line is skipped:true/skipReason:requiredEnv/exit:null — recorded as a skip, never as a pass" \
  || notok "REQUIREDENV-HEAVY: expected skipped:true/skipReason:requiredEnv/exit:null, got skipped=$LEDGER9_SKIPPED reason=$LEDGER9_REASON exit=$LEDGER9_EXIT"

# =============================================================================
# AC11 — FAIL-FIRST: each key fixture above genuinely fails against the
# pre-change baseline resolved from origin/main (fallback main).
# =============================================================================
BASELINE=""
if git -C "$ROOT" show origin/main:.claude/hooks/verify-gate.sh > "$TMP/baseline.sh" 2>/dev/null; then
  BASELINE="$TMP/baseline.sh"
elif git -C "$ROOT" show main:.claude/hooks/verify-gate.sh > "$TMP/baseline.sh" 2>/dev/null; then
  BASELINE="$TMP/baseline.sh"
fi

if [ -z "$BASELINE" ]; then
  echo "SKIP: no origin/main or main baseline resolvable for .claude/hooks/verify-gate.sh — fail-first proof could not run"
else
  # --- baseline AC1: the heavy (sleeping) command DID run under the old code.
  FB1="$TMP/base-ac1"
  MARKB1="$TMP/base-ac1-marks"; : > "$MARKB1"
  mkrepo "$FB1" '{"verify":["sh -c \"echo cheap >> '"$MARKB1"'\"","npm test"]}'
  mkshim "$FB1/fakebin" npm "echo heavy >> '"$MARKB1"'"
  printf '{"hook_event_name":"Stop","cwd":"%s"}' "$FB1" \
    | ( cd "$FB1" && CLAUDE_PROJECT_DIR="$FB1" PATH="$FB1/fakebin:$PATH" bash "$BASELINE" >/dev/null 2>&1 )
  HEAVYB1=$(grep -c '^heavy$' "$MARKB1" 2>/dev/null; true); HEAVYB1=${HEAVYB1:-0}
  [ "$HEAVYB1" -ge 1 ] \
    && ok "AC11 FAIL-FIRST (AC1): the pre-change baseline DID run the heavy command ($HEAVYB1 marker line(s)) — proving AC1's heavy-filter assertion is a genuine behavior change" \
    || notok "AC11 FAIL-FIRST (AC1): the baseline did not run the heavy command either — this assertion would not have caught the pre-change behavior"

  # --- baseline AC2-equivalent: the OLD hook's only wall-clock knob
  # (QUETREX_VERIFY_BUDGET) is FAIL-CLOSED (BLOCKS) on exhaustion — the NEW
  # hook's quick-chain cap is deliberately the opposite (ALLOWS). Same
  # general scenario (a command overrunning a time budget), proving the
  # invert from fail-closed to fail-open on the QUICK path is a genuine,
  # deliberate change and not an accident of a differently-named variable.
  FB2="$TMP/base-ac2"
  mkrepo "$FB2" '{"verify":["sh -c \"sleep 20\""]}'
  OUTB2="$(printf '{"hook_event_name":"Stop","cwd":"%s"}' "$FB2" \
    | ( cd "$FB2" && CLAUDE_PROJECT_DIR="$FB2" QUETREX_VERIFY_BUDGET=2 bash "$BASELINE" 2>&1 ) )"
  BLOCKSB2=$(block_count "$OUTB2")
  [ "$BLOCKSB2" -eq 1 ] \
    && ok "AC11 FAIL-FIRST (AC2): the pre-change baseline BLOCKS on time-budget exhaustion (fail-closed) — proving AC2's cap-ALLOWS behavior is a genuine, deliberate invert" \
    || notok "AC11 FAIL-FIRST (AC2): the baseline did not block on budget exhaustion either (blocks=$BLOCKSB2) — cannot demonstrate the invert (out: [$OUTB2])"
fi

echo
echo "stop-bounded-by-construction.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
