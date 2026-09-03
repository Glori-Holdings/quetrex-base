#!/usr/bin/env bash
# test/status-command.test.sh — behavioural test for .claude/commands/status.md
# (/quetrex:status [--all]).
#
# Run: bash test/status-command.test.sh
#
# The command is ONE bash fence: resolve auth + project through quetrex-api,
# fetch GET /api/tasks?project=<CODE> once, render in node. This file does not
# read status.md for reassurance — it EXTRACTS that fence and EXECUTES it under
# bash AND zsh (the operator's shell) against a stub `quetrex-api` on PATH that
# serves a fixed 5-task fixture, then asserts on the rendered output:
#
#   AC1  frontmatter Usage is /quetrex:status [--all]; the file never asks
#        (no AskUserQuestion token) and never writes (no POST/PUT/PATCH/DELETE).
#   AC2  default view: exactly 4 data rows (the complete task hidden);
#        --all: exactly 5.
#   AC3  rows are in board order (queued < in_progress < pr_ready <
#        needs_clarity < complete), NOT the order the API returned them.
#   AC4  a `|` in a title is escaped as `\|`; a >60-char title is truncated
#        at 59 chars + `…`; a null assignee renders as `—`; status shows the
#        board label (`In Progress`, `PR Ready`, `Needs Clarity`).
#   AC5  the counts line is right (non-zero statuses, board order, and the
#        hidden-complete note only when hidden).
#   AC6  the LAST line is `Board: <kanban-url>/board`.
#   AC7  zero tasks -> "No tasks in <CODE>" + the board link, nothing else.
#   AC8  auth failure -> ONLY quetrex-api's own line ("Run /quetrex-setup:login"),
#        no table, non-zero exit; same for an unlinked repo ("Run /quetrex-setup:init").
#   AC9  the fetch is made exactly once and only via GET.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_MD="$ROOT/.claude/commands/status.md"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
[ -f "$STATUS_MD" ] || { echo "NOT OK - status.md not found at $STATUS_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-status-cmd.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- AC1: shape --------------------------------------------------------------
if head -5 "$STATUS_MD" | grep -q 'Usage: /quetrex:status \[--all\]'; then
  ok "AC1: frontmatter Usage is /quetrex:status [--all]"
else
  notok "AC1: frontmatter Usage is not /quetrex:status [--all]"
fi
if ! grep -q 'AskUserQuestion' "$STATUS_MD"; then
  ok "AC1: status.md contains no AskUserQuestion token — it never asks"
else
  notok "AC1: status.md mentions AskUserQuestion"
fi
if ! grep -vE '^[[:space:]]*(#|-)' "$STATUS_MD" | grep -qE 'quetrex-api (POST|PUT|PATCH|DELETE|task-status|task-ainote|task-comment|task-type|create-child|add-dep)'; then
  ok "AC1: status.md issues no write call"
else
  notok "AC1: status.md contains a write call"
fi

# The command's bash fences, concatenated (there is one; concatenating keeps
# this robust if a setup fence is ever split out).
awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "$STATUS_MD" > "$WORK/block.sh"
if [ -s "$WORK/block.sh" ] && bash -n "$WORK/block.sh" 2>/dev/null; then
  ok "AC1: the bash fence extracts and parses"
else
  notok "AC1: could not extract a parseable bash fence from status.md"
  printf '\n%s\n' "status-command.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

# --- harness -----------------------------------------------------------------
# Fixture: 5 tasks, deliberately NOT in board order, with one complete, one
# title containing `|`, one title > 60 chars, one null assignee.
LONG_TITLE="This title is deliberately longer than sixty characters so it gets truncated"
cat > "$WORK/tasks.json" <<JSON
[
  {"id":"u3","identifier":"DEA-3","number":3,"projectCode":"DEA","title":"Fix pipe | in title","status":"pr_ready","priority":"high","type":"bug","assignee":{"id":"a1","name":"Glen Barnhardt","image":null},"updatedAt":"2026-09-01T00:00:00.000Z"},
  {"id":"u5","identifier":"DEA-5","number":5,"projectCode":"DEA","title":"Shipped already","status":"complete","priority":"none","type":"feature","assignee":{"id":"a1","name":"Glen Barnhardt","image":null},"updatedAt":"2026-08-01T00:00:00.000Z"},
  {"id":"u1","identifier":"DEA-1","number":1,"projectCode":"DEA","title":"$LONG_TITLE","status":"in_progress","priority":"urgent","type":"feature","assignee":null,"updatedAt":"2026-09-02T00:00:00.000Z"},
  {"id":"u4","identifier":"DEA-4","number":4,"projectCode":"DEA","title":"Waiting on answer","status":"needs_clarity","priority":"medium","type":"bug","assignee":{"id":"a2","name":"Steve","image":null},"updatedAt":"2026-09-02T00:00:00.000Z"},
  {"id":"u2","identifier":"DEA-2","number":2,"projectCode":"DEA","title":"Queued work","status":"queued","priority":"low","type":null,"assignee":{"id":"a2","name":"Steve","image":null},"updatedAt":"2026-09-02T00:00:00.000Z"}
]
JSON
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$WORK/tasks.json" || { echo "NOT OK - fixture is not valid JSON"; exit 1; }

# Stub quetrex-api. Mode is chosen by QX_STUB_MODE: ok | empty | nologin | noinit.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/quetrex-api" <<'STUB'
#!/usr/bin/env bash
MODE="${QX_STUB_MODE:-ok}"
LOG="${QX_STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$LOG"
case "$1" in
  kanban-url)
    if [ "$MODE" = "nologin" ]; then echo "Run /quetrex-setup:login" >&2; exit 1; fi
    echo "https://kanban.example.test/"; exit 0 ;;
  project-code)
    if [ "$MODE" = "noinit" ]; then echo "Run /quetrex-setup:init" >&2; exit 1; fi
    echo "DEA"; exit 0 ;;
  GET)
    case "$2" in
      /api/projects/DEA) echo '{"id":"p1","code":"DEA","name":"DealerQ"}'; exit 0 ;;
      "/api/tasks?project=DEA")
        if [ "$MODE" = "empty" ]; then echo '[]'; else cat "$QX_STUB_FIXTURE"; fi; exit 0 ;;
      *) echo "Quetrex API error (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  *) echo "quetrex-api: unexpected call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/quetrex-api"

run_block() {  # run_block <shell> <mode> <arguments-string>
  local sh="$1" mode="$2" args="$3"
  : > "$WORK/calls.log"
  { printf 'ARGUMENTS=%q\n' "$args"; cat "$WORK/block.sh"; } > "$WORK/run.sh"
  PATH="$WORK/bin:$PATH" QX_STUB_MODE="$mode" QX_STUB_FIXTURE="$WORK/tasks.json" QX_STUB_LOG="$WORK/calls.log" \
    "$sh" "$WORK/run.sh" 2>&1
}
data_rows() { printf '%s\n' "$1" | grep -E '^\| DEA-[0-9]+ \|'; }
row_ids()   { data_rows "$1" | awk -F'|' '{gsub(/ /,"",$2); print $2}' | tr '\n' ' ' | sed 's/ $//'; }

for SH in $SHELLS; do
  # --- AC2/AC3/AC4/AC5/AC6: default view --------------------------------------
  OUT="$(run_block "$SH" ok "")"; RC=$?
  N="$(data_rows "$OUT" | wc -l | tr -d ' ')"
  if [ "$RC" -eq 0 ] && [ "$N" -eq 4 ]; then
    ok "AC2/$SH: default view renders exactly 4 data rows (complete hidden), exit 0"
  else
    notok "AC2/$SH: default view: rc=$RC rows=$N: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  IDS="$(row_ids "$OUT")"
  if [ "$IDS" = "DEA-2 DEA-1 DEA-3 DEA-4" ]; then
    ok "AC3/$SH: rows are in board order (queued, in_progress, pr_ready, needs_clarity) not API order"
  else
    notok "AC3/$SH: row order is '$IDS', expected 'DEA-2 DEA-1 DEA-3 DEA-4'"
  fi
  if printf '%s\n' "$OUT" | grep -qF '| DEA-3 | Fix pipe \| in title | PR Ready | high | bug | Glen Barnhardt |'; then
    ok "AC4/$SH: the pipe in the title is escaped and the status shows its board label"
  else
    notok "AC4/$SH: pipe-escape/label row wrong: $(printf '%s\n' "$OUT" | grep 'DEA-3')"
  fi
  EXPECT_CLIP="$(node -e 'process.stdout.write(Array.from(process.argv[1]).slice(0,59).join("")+"…")' "$LONG_TITLE")"
  if printf '%s\n' "$OUT" | grep -qF "| DEA-1 | $EXPECT_CLIP | In Progress | urgent | feature | — |" \
     && ! printf '%s\n' "$OUT" | grep -qF "$LONG_TITLE"; then
    ok "AC4/$SH: the >60-char title is truncated at 59 + … and the null assignee renders as —"
  else
    notok "AC4/$SH: truncation/null-assignee row wrong: $(printf '%s\n' "$OUT" | grep 'DEA-1')"
  fi
  if printf '%s\n' "$OUT" | grep -qF '| DEA-4 | Waiting on answer | Needs Clarity | medium | bug | Steve |' \
     && printf '%s\n' "$OUT" | grep -qF '| DEA-2 | Queued work | Queued | low | — | Steve |'; then
    ok "AC4/$SH: Needs Clarity label and a null type render correctly"
  else
    notok "AC4/$SH: needs_clarity/null-type rows wrong"
  fi
  if printf '%s\n' "$OUT" | grep -qxF '1 queued · 1 in progress · 1 pr ready · 1 needs clarity · 1 complete (hidden — use --all)'; then
    ok "AC5/$SH: the counts line is right, in board order, with the hidden-complete note"
  else
    notok "AC5/$SH: counts line wrong: $(printf '%s\n' "$OUT" | grep -E '^[0-9]+ ')"
  fi
  LAST="$(printf '%s\n' "$OUT" | grep -v '^$' | tail -n 1)"
  if [ "$LAST" = "Board: https://kanban.example.test/board" ]; then
    ok "AC6/$SH: the last line is the board URL (trailing slash normalised)"
  else
    notok "AC6/$SH: last line is '$LAST'"
  fi
  if [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "$LAST" ]; then
    ok "AC6/$SH: nothing is printed after the board link"
  else
    notok "AC6/$SH: output continues after the board link"
  fi
  NFETCH="$(grep -c '^GET /api/tasks?project=DEA$' "$WORK/calls.log")"
  NWRITE="$(grep -cE '^(POST|PUT|PATCH|DELETE|task-) ' "$WORK/calls.log")"
  if [ "$NFETCH" -eq 1 ] && [ "$NWRITE" -eq 0 ]; then
    ok "AC9/$SH: the task list is fetched exactly once, and nothing is written"
  else
    notok "AC9/$SH: fetches=$NFETCH writes=$NWRITE: $(tr '\n' '|' < "$WORK/calls.log")"
  fi

  # --- AC2/AC3/AC5 with --all ------------------------------------------------
  OUT="$(run_block "$SH" ok "--all")"; RC=$?
  N="$(data_rows "$OUT" | wc -l | tr -d ' ')"
  IDS="$(row_ids "$OUT")"
  if [ "$RC" -eq 0 ] && [ "$N" -eq 5 ] && [ "$IDS" = "DEA-2 DEA-1 DEA-3 DEA-4 DEA-5" ]; then
    ok "AC2/AC3/$SH: --all renders all 5 rows with complete last"
  else
    notok "AC2/AC3/$SH: --all: rc=$RC rows=$N order='$IDS'"
  fi
  if printf '%s\n' "$OUT" | grep -qxF '1 queued · 1 in progress · 1 pr ready · 1 needs clarity · 1 complete' \
     && ! printf '%s\n' "$OUT" | grep -q 'hidden'; then
    ok "AC5/$SH: --all counts complete plainly and drops the hidden note"
  else
    notok "AC5/$SH: --all counts line wrong: $(printf '%s\n' "$OUT" | grep -E '^[0-9]+ ')"
  fi

  # --- AC7: zero tasks --------------------------------------------------------
  OUT="$(run_block "$SH" empty "")"; RC=$?
  if [ "$RC" -eq 0 ] \
     && [ "$(printf '%s\n' "$OUT" | grep -v '^$' | head -n 1)" = "No tasks in DEA" ] \
     && [ "$(printf '%s\n' "$OUT" | grep -v '^$' | tail -n 1)" = "Board: https://kanban.example.test/board" ] \
     && [ "$(printf '%s\n' "$OUT" | grep -vc '^$')" -eq 2 ]; then
    ok "AC7/$SH: zero tasks -> 'No tasks in DEA' + the board link, nothing else"
  else
    notok "AC7/$SH: empty case wrong: rc=$RC: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC8: setup failures surface only quetrex-api's own line ----------------
  OUT="$(run_block "$SH" nologin "")"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(printf '%s\n' "$OUT" | grep -vc '^$')" -eq 1 ] \
     && printf '%s\n' "$OUT" | grep -qx 'Run /quetrex-setup:login'; then
    ok "AC8/$SH: not logged in -> only 'Run /quetrex-setup:login', non-zero exit, no table"
  else
    notok "AC8/$SH: login failure output wrong: rc=$RC: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_block "$SH" noinit "")"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(printf '%s\n' "$OUT" | grep -vc '^$')" -eq 1 ] \
     && printf '%s\n' "$OUT" | grep -qx 'Run /quetrex-setup:init'; then
    ok "AC8/$SH: unlinked repo -> only 'Run /quetrex-setup:init', non-zero exit, no table"
  else
    notok "AC8/$SH: init failure output wrong: rc=$RC: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if ! grep -q '^GET /api/tasks' "$WORK/calls.log"; then
    ok "AC8/$SH: an unlinked repo never reaches the task fetch"
  else
    notok "AC8/$SH: the task fetch ran despite the unlinked repo"
  fi
done

printf '\n%s\n' "status-command.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
