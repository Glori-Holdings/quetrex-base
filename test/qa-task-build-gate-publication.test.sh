#!/usr/bin/env bash
# test/qa-task-build-gate-publication.test.sh — QA's own independent adversarial
# harness on the qx_valid_ids / qx_publish_gates exec blocks in
# .claude/commands/task-build.md, driven under bash AND zsh with QA-authored
# payloads (distinct from test/task-build-never-local.test.sh's own).
#
# Three checks:
#   (1) injection re-proof — a task id and a branch prefix each carrying a
#       command substitution, a quoted-string break, a backtick, and a
#       newline are all refused before anything runs (no canary file), and a
#       LEGITIMATE id/prefix still publishes correctly against a bare remote
#       this file creates.
#   (2) qx_valid_ids is not vacuous — a real epic-child id (ABC-1.2) and a
#       real prefix (claude/) are still ACCEPTED.
#   (3) the environment hand-off actually delivers the values — the published
#       gates branch name contains the real task id, proving the extracted
#       sentinel block received QX_TASK/QX_BRANCH_PREFIX rather than a
#       template placeholder.
#
# Run: bash test/qa-task-build-gate-publication.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="$REPO_ROOT/.claude/commands/task-build.md"
export PATH="$REPO_ROOT/bin:$PATH"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

[ -f "$COMMAND" ] || { echo "NOT OK - task-build.md not found at $COMMAND"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-qa-gatepub.XXXXXX")"
CANDIR="$WORK/canary"; mkdir -p "$CANDIR"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

extract_block() {   # extract_block <name> > file
  awk -v name="$1" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$COMMAND"
}

VALIDS="$WORK/qx_valid_ids.sh";     extract_block qx_valid_ids     > "$VALIDS"
PUB="$WORK/qx_publish_gates.sh";    extract_block qx_publish_gates > "$PUB"
if [ ! -s "$VALIDS" ] || ! grep -q '^qx_valid_task_id()' "$VALIDS"; then
  fail "could not extract qx_valid_ids from $COMMAND — nothing else can run"
  echo; echo "qa-task-build-gate-publication.test.sh: FAILURES above"; exit 1
fi
if [ ! -s "$PUB" ] || ! grep -q '^qx_publish_gates()' "$PUB"; then
  fail "could not extract qx_publish_gates from $COMMAND — nothing else can run"
  echo; echo "qa-task-build-gate-publication.test.sh: FAILURES above"; exit 1
fi

canary_absent() {   # canary_absent <label> <name>
  if [ -e "$CANDIR/$2" ]; then
    fail "$1: the injected payload RAN — $CANDIR/$2 exists"
    rm -f "$CANDIR/$2"
  else
    pass "$1: nothing executed (no $2 canary)"
  fi
}

# fixture <name> <task> — a real repo with a bare remote, seeded exactly like
# a finished dev-pipeline worktree (gate artifacts present).
fixture() {
  local bare="$WORK/$1.git" work="$WORK/$1"
  git init -q --bare "$bare"
  git init -q -b main "$work"
  git -C "$work" config user.email qa@example.com
  git -C "$work" config user.name  QA
  printf '.quetrex/\n' > "$work/.gitignore"
  printf 'console.log(1);\n' > "$work/app.js"
  git -C "$work" add -A && git -C "$work" commit -q -m seed
  git -C "$work" remote add origin "$bare" && git -C "$work" push -q origin main
  git -C "$work" checkout -q -b "qa-fixture-$1"
  mkdir -p "$work/.quetrex/plan"
  printf '{"verdict":"AUTO_MERGE"}\n'    > "$work/.quetrex/review-verdict.json"
  printf '{"cmd":"npm test","exit":0}\n' > "$work/.quetrex/verify-ledger.jsonl"
  printf '{"task":"%s","review_iter":0}\n' "$2" > "$work/.quetrex/state.json"
  printf '{"task":"%s","ownership":{"app.js":"ws1"}}\n' "$2" > "$work/.quetrex/plan/$2.json"
  echo "$work"
}

# QA's own drive helper: the same env-only hand-off the command uses.
drive_publish() {   # drive_publish <shell> <wt> <task> <prefix> [routine]
  PATH="$REPO_ROOT/bin:$PATH" "$1" -c '. "$1"; . "$2"; qx_publish_gates "$3" "$4" "$5" "${6:-}"' \
    _ "$VALIDS" "$PUB" "$2" "$3" "$4" "${5:-}"
}
vid()  { "$1" -c '. "$1"; qx_valid_task_id "$2"'       _ "$VALIDS" "$2"; }
vpfx() { "$1" -c '. "$1"; qx_valid_branch_prefix "$2"' _ "$VALIDS" "$2"; }

SHELLS=""
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 && SHELLS="$SHELLS $sh"
done
[ -n "$SHELLS" ] || { echo "SKIP: neither bash nor zsh found on PATH"; exit 0; }

echo "== check 1: injection re-proof (QA-authored payloads) =="
# QA's own payload set — deliberately different literal text from the
# developer's fixtures, but the same four shapes: quote-break, command
# substitution, backtick, newline.
TASK_PAYLOADS='
QAX-1\x27; touch QACAN/qa-t-quote; echo \x27
$(touch QACAN/qa-t-subshell)
`touch QACAN/qa-t-backtick`
'
for sh in $SHELLS; do
  # 1a. task id payloads
  P1="QAX-1'; touch $CANDIR/qa-t-quote; echo '"
  P2='$(touch '"$CANDIR"'/qa-t-subshell)'
  P3='`touch '"$CANDIR"'/qa-t-backtick`'
  P4="$(printf 'QAX-1\n; touch %s/qa-t-newline' "$CANDIR")"
  for P in "$P1" "$P2" "$P3" "$P4"; do
    OUT="$(vid "$sh" "$P" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'Not a task id'; then
      pass "$sh: qx_valid_task_id refuses QA task-id payload before publish is even reached"
    else
      fail "$sh: qx_valid_task_id did NOT refuse QA task-id payload — rc=$RC out=[$OUT]"
    fi
  done
  # 1b. branch prefix payloads
  Q1="claude/'; touch $CANDIR/qa-p-quote; echo '/"
  Q2='claude/$(touch '"$CANDIR"'/qa-p-subshell)/'
  Q3='claude/`touch '"$CANDIR"'/qa-p-backtick`/'
  Q4="$(printf 'claude/\n; touch %s/qa-p-newline' "$CANDIR")"
  for Q in "$Q1" "$Q2" "$Q3" "$Q4"; do
    OUT="$(vpfx "$sh" "$Q" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'Not a branch prefix'; then
      pass "$sh: qx_valid_branch_prefix refuses QA prefix payload before publish is even reached"
    else
      fail "$sh: qx_valid_branch_prefix did NOT refuse QA prefix payload — rc=$RC out=[$OUT]"
    fi
  done
  # 1c. end-to-end through qx_publish_gates itself (not just the validators
  # in isolation) — hostile task id with a legitimate prefix, and vice versa.
  SAFE="QAOK${$}${sh}-1"
  WT="$(fixture "qa-inj-$sh" "$SAFE")"
  for P in "$P1" "$P2" "$P3" "$P4"; do
    OUT="$(drive_publish "$sh" "$WT" "$P" "claude/" 2>&1)"; RC=$?
    [ "$RC" -ne 0 ] || fail "$sh: qx_publish_gates accepted a hostile task id end-to-end"
  done
  for Q in "$Q1" "$Q2" "$Q3" "$Q4"; do
    OUT="$(drive_publish "$sh" "$WT" "$SAFE" "$Q" 2>&1)"; RC=$?
    [ "$RC" -ne 0 ] || fail "$sh: qx_publish_gates accepted a hostile branch prefix end-to-end"
  done
  NPUSHED="$(git -C "$WORK/qa-inj-$sh.git" for-each-ref --format='%(refname:short)' refs/heads/ | grep -c -- '-gates-' || true)"
  if [ "$NPUSHED" = "0" ]; then
    pass "$sh: none of the 8 hostile end-to-end payloads pushed anything to origin"
  else
    fail "$sh: $NPUSHED gates ref(s) were pushed despite hostile payloads"
  fi

  # 1d. legitimate id/prefix must still publish correctly against a FRESH
  # bare remote QA creates for this purpose.
  LEGIT_TASK="QAOK${$}${sh}-2"
  WTG="$(fixture "qa-good-$sh" "$LEGIT_TASK")"
  HEADG="$(git -C "$WTG" rev-parse HEAD)"
  OUT="$(drive_publish "$sh" "$WTG" "$LEGIT_TASK" "claude/" 2>&1)"; RC=$?
  REF="$(git -C "$WORK/qa-good-$sh.git" for-each-ref --format='%(refname:short)' "refs/heads/claude/$LEGIT_TASK-gates-*" | head -1)"
  if [ "$RC" -eq 0 ] && [ -n "$REF" ]; then
    pass "$sh: a legitimate task id + prefix still publishes cleanly ($REF)"
  else
    fail "$sh: legitimate publish failed — rc=$RC ref='${REF:-none}' out=[$OUT]"
  fi
  GH="$(git -C "$WORK/qa-good-$sh.git" show "$REF:.quetrex/gates-head" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$REF" ] && [ "$GH" = "$HEADG" ]; then
    pass "$sh: published gates-head matches the real unit HEAD"
  else
    fail "$sh: gates-head mismatch: got '${GH:-missing}', want $HEADG"
  fi
done
for c in qa-t-quote qa-t-subshell qa-t-backtick qa-t-newline \
         qa-p-quote qa-p-subshell qa-p-backtick qa-p-newline; do
  canary_absent "check 1 canary" "$c"
done

echo "== check 2: qx_valid_ids is not vacuous =="
for sh in $SHELLS; do
  if vid "$sh" "ABC-1.2" >/dev/null 2>&1; then
    pass "$sh: qx_valid_task_id ACCEPTS a real epic-child id (ABC-1.2)"
  else
    fail "$sh: qx_valid_task_id REJECTED the legitimate epic-child id ABC-1.2 — validator is over-tight/vacuous"
  fi
  if vpfx "$sh" "claude/" >/dev/null 2>&1; then
    pass "$sh: qx_valid_branch_prefix ACCEPTS the real prefix claude/"
  else
    fail "$sh: qx_valid_branch_prefix REJECTED the legitimate prefix claude/ — validator is over-tight/vacuous"
  fi
done

echo "== check 3: environment hand-off actually delivers the values =="
for sh in $SHELLS; do
  T="QAHAND${$}${sh}-3"
  WT="$(fixture "qa-hand-$sh" "$T")"
  OUT="$(drive_publish "$sh" "$WT" "$T" "claude/" 2>&1)"; RC=$?
  REF="$(git -C "$WORK/qa-hand-$sh.git" for-each-ref --format='%(refname:short)' refs/heads/ | grep -- '-gates-' | head -1)"
  if [ "$RC" -eq 0 ] && [ -n "$REF" ]; then
    case "$REF" in
      *"$T"*)
        pass "$sh: published gates branch '$REF' contains the real task id — QX_TASK reached the extracted block" ;;
      *"{{TASK}}"*)
        fail "$sh: published gates branch '$REF' still carries the unrendered {{TASK}} placeholder — the env hand-off did not deliver" ;;
      *)
        fail "$sh: published gates branch '$REF' does not contain the task id '$T' at all" ;;
    esac
  else
    fail "$sh: publish failed for the hand-off check — rc=$RC out=[$OUT]"
  fi
  # And the prefix half of the hand-off: the branch must start with claude/.
  case "$REF" in
    claude/*) pass "$sh: published gates branch starts with the real branch prefix (claude/) — QX_BRANCH_PREFIX reached the block" ;;
    *)        fail "$sh: published gates branch '$REF' does not start with claude/ — QX_BRANCH_PREFIX was not delivered" ;;
  esac
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "qa-task-build-gate-publication.test.sh: all checks passed"
else
  echo "qa-task-build-gate-publication.test.sh: FAILURES above"
fi
exit "$FAIL"
