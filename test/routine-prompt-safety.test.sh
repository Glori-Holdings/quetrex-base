#!/usr/bin/env bash
# routine-prompt-safety.test.sh — the dispatched prompt must not read as evasion coaching.
#
# MEASURED, not hypothesised. A real cloud dispatch of QDM-5.1
# (trigger trig_01LSiG7KAJG3hujgKyWKJ7pD, session cse_01SUbyeQTy7CwEoYL9PskdE6) REFUSED before
# running a single mutating command. No hook fired; nothing was denied. The cloud model read
# the gate-publication comments — which explained, step by step, how to phrase a destructive
# git command so a PreToolUse hook would approve it — and said:
#
#   "a detailed rationale for structuring a command so an automated safety guard doesn't block
#    it ... is a textbook instruction-evasion pattern, and I'm not going to execute a
#    destructive git operation ... using phrasing chosen to slip past a security control,
#    especially unattended with no one watching."
#
# It was right. That text shipped in message.content of EVERY dispatch, so every cloud build
# refused identically. The refusal even reported success (turns=5, is_error=false), so a
# caller checking exit status saw nothing wrong.
#
# The rule this file enforces: a comment may explain WHY an operation is safe, and may state a
# requirement. It may not read as instructions for getting a destructive command past a
# control. The difference is the audience — one informs the reader, the other coaches the
# executor.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# The two files whose text is dispatched to, or read by, an unattended cloud session.
DISPATCHED="$ROOT/.claude/lib/cloud-build-routine.md $ROOT/.claude/commands/task-build.md"

for f in $DISPATCHED; do
  [ -f "$f" ] || { notok "missing $f"; continue; }
  n="$(basename "$f")"

  # --- ASSERTION 1: no phrasing that frames a command as chosen to satisfy a guard ---
  # These are the specific constructions the cloud model called out. Matched
  # case-insensitively against the whole file.
  HITS=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if grep -qiE "$pat" "$f"; then HITS="$HITS
      - $pat"; fi
  done <<'PATTERNS'
so the guard can (see|read)
written where the guard
opaque to that rule
slip past
so .{0,20}deny-guard.{0,30}(approves|permits|allows)
the dispatch dies at the deny
PATTERNS
  if [ -z "$HITS" ]; then
    ok "ASSERTION 1: $n carries no guard-evasion phrasing"
  else
    notok "ASSERTION 1: $n reads as coaching a command past a safety control:$HITS"
  fi

  # --- ASSERTION 2: destructive steps carry a refusal valve ---------------------
  # An executor that judges an operation unsafe must have a sanctioned way to stop
  # that is NOT "rephrase it until it passes". Both files perform a remote ref
  # delete, so both must offer that exit.
  if grep -q 'push .*--delete' "$f"; then
    if grep -qiE 'do (NOT|not) rephrase|report .transport_failure. naming this step' "$f"; then
      ok "ASSERTION 2: $n gives an executor a sanctioned refusal path for its ref delete"
    else
      notok "ASSERTION 2: $n performs a remote ref delete but offers no way to refuse except working around it"
    fi
  fi
done

# --- ASSERTION 3: the disarm check must not wait on a field that never clears ---
# Measured on the live API: a disabled routine still returns a future next_run_at, on this and
# every historical trigger. The old instruction told the dispatcher to repeat the disarm until
# that field cleared — an infinite loop written as a safety check.
TB="$ROOT/.claude/commands/task-build.md"
if grep -qiE 'next_run_at.{0,40}(must come back null|must be null|until it (is )?(null|absent))' "$TB"; then
  notok "ASSERTION 3: task-build.md still requires next_run_at to clear — it never does; a dispatcher following that never reports"
else
  ok "ASSERTION 3: the disarm check does not wait on next_run_at clearing"
fi

if grep -qE '`enabled` is `false`|enabled: false. is the gate' "$TB"; then
  ok "ASSERTION 3: the disarm is confirmed via enabled:false, the field the API actually sets"
else
  notok "ASSERTION 3: no enabled:false confirmation — the disarm has no observable check"
fi

echo
echo "routine-prompt-safety.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
