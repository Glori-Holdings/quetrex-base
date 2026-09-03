#!/usr/bin/env bash
# test/status-command-adversarial.test.sh — QA-authored adversarial coverage for
# .claude/commands/status.md (/quetrex:status), independent of the developer's
# own test/status-command.test.sh. Focus: inputs the developer fixture never
# exercised.
#
# Run: bash test/status-command-adversarial.test.sh
#
#   QA1  a task title containing an embedded newline, backticks, and a raw
#        `</script>` tag renders as exactly ONE table row (the newline is
#        collapsed to a space so it cannot start a bogus new "row" or break
#        the pipe-table grid), with no extra `| DEA-` row injected and the
#        literal `</script>`/backtick bytes passed through inertly as table
#        text (this is a markdown table rendered in a terminal, not HTML/JS,
#        so no HTML-escaping is required — but it must never desync the grid
#        or throw).
#   QA2  a non-JSON /api/tasks response produces exactly ONE clean line plus
#        the board link and a non-zero exit — never a raw node/V8 stack trace
#        (CLAUDE.md: a hook/command must never surface an interpreter trace
#        to the operator).
#   QA3  the malicious-title row (QA1) renders BYTE-IDENTICAL under bash and
#        zsh — the shells must not diverge on how they hand the fence's
#        stdin/argv to node.
#   QA4  a title carrying ESC `[2K` (erase line), an OSC sequence ending in
#        BEL (`ESC ] 0 ; hijacked BEL` — retitles the terminal), and a DEL
#        renders with NONE of those bytes in the output (`cat -v` shows no
#        `^[`, `^G`, `^?`) — the renderer must strip terminal control bytes,
#        not just collapse whitespace. Under bash and zsh.
#   QA5  a task whose status is `constructor` (a prototype property name)
#        renders the literal word `constructor` in the Status cell, never
#        a `function ...` body from Object.prototype.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_MD="$ROOT/.claude/commands/status.md"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
[ -f "$STATUS_MD" ] || { echo "NOT OK - status.md not found at $STATUS_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-status-adv.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "$STATUS_MD" > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ] || ! bash -n "$WORK/block.sh" 2>/dev/null; then
  echo "NOT OK - could not extract a parseable bash fence from status.md"
  exit 1
fi

# --- QA1 fixture: newline + backticks + </script> in a title -----------------
# Build via node so the embedded raw newline lands correctly inside JSON (a
# JSON string escape \n, not a literal control byte breaking the file).
node -e '
  const fs = require("fs");
  const title = "line one\nline two `backtick` </script> end";
  const tasks = [
    {id:"m1", identifier:"DEA-9", number:9, projectCode:"DEA",
     title, status:"queued", priority:"high", type:"bug",
     assignee:{id:"a1",name:"Glen Barnhardt",image:null},
     updatedAt:"2026-09-02T00:00:00.000Z"}
  ];
  fs.writeFileSync(process.argv[1], JSON.stringify(tasks));
' "$WORK/tasks-malicious.json"

# --- badjson fixture (QA2): API returns non-JSON garbage ---------------------
printf 'not json at all <<<garbage>>>' > "$WORK/tasks-badjson.txt"

# --- QA4/QA5 fixture: terminal control bytes in a title + prototype-name
# status. ESC [2K erases the line, ESC ]0;hijacked BEL retitles the terminal,
# DEL is 0x7F; "constructor" is inherited from Object.prototype by any
# plain-object lookup table.
node -e '
  const fs = require("fs");
  const title = "pwn\x1b[2K\x1b[1;31mSAFE\x1b]0;hijacked\x07\x7fend";
  const tasks = [
    {id:"c1", identifier:"DEA-10", number:10, projectCode:"DEA",
     title, status:"queued", priority:"high", type:"bug",
     assignee:{id:"a1",name:"Glen\x1b[2K Barnhardt",image:null},
     updatedAt:"2026-09-02T00:00:00.000Z"},
    {id:"c2", identifier:"DEA-11", number:11, projectCode:"DEA",
     title:"proto status", status:"constructor", priority:"low", type:"chore",
     assignee:null, updatedAt:"2026-09-02T00:00:00.000Z"}
  ];
  fs.writeFileSync(process.argv[1], JSON.stringify(tasks));
' "$WORK/tasks-ctrl.json"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/quetrex-api" <<'STUB'
#!/usr/bin/env bash
MODE="${QX_STUB_MODE:-ok}"
LOG="${QX_STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$LOG"
case "$1" in
  kanban-url)
    echo "https://kanban.example.test/"; exit 0 ;;
  project-code)
    echo "DEA"; exit 0 ;;
  GET)
    case "$2" in
      /api/projects/DEA) echo '{"id":"p1","code":"DEA","name":"DealerQ"}'; exit 0 ;;
      "/api/tasks?project=DEA")
        if [ "$MODE" = "badjson" ]; then cat "$QX_STUB_FIXTURE_TXT"; exit 0; fi
        if [ "$MODE" = "ctrl" ]; then cat "$QX_STUB_FIXTURE_CTRL"; exit 0; fi
        cat "$QX_STUB_FIXTURE"; exit 0 ;;
      *) echo "Quetrex API error (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  *) echo "quetrex-api: unexpected call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/quetrex-api"

run_block() {  # run_block <shell> <mode> <arguments-string>
  local sh="$1" mode="$2" args="$3"
  { printf 'ARGUMENTS=%q\n' "$args"; cat "$WORK/block.sh"; } > "$WORK/run.sh"
  PATH="$WORK/bin:$PATH" QX_STUB_MODE="$mode" \
    QX_STUB_FIXTURE="$WORK/tasks-malicious.json" QX_STUB_FIXTURE_TXT="$WORK/tasks-badjson.txt" \
    QX_STUB_FIXTURE_CTRL="$WORK/tasks-ctrl.json" \
    "$sh" "$WORK/run.sh" 2>&1
}

BASH_MALICIOUS_OUT=""
for SH in $SHELLS; do
  # --- QA1: malicious title stays one row, grid intact, no crash -----------
  OUT="$(run_block "$SH" ok "")"; RC=$?
  ROWCOUNT="$(printf '%s\n' "$OUT" | grep -cE '^\| DEA-')"
  if [ "$RC" -eq 0 ] && [ "$ROWCOUNT" -eq 1 ]; then
    ok "QA1/$SH: exit 0 and exactly one data row for the malicious title"
  else
    notok "QA1/$SH: rc=$RC data-rows=$ROWCOUNT: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  ROW="$(printf '%s\n' "$OUT" | grep -E '^\| DEA-9 ' || true)"
  # The embedded newline must be collapsed to a space (norm()), so the row
  # keeps both halves of the title on one physical line and the grid is not
  # desynced by a stray bare `|`-count mismatch.
  if printf '%s\n' "$ROW" | grep -qF 'line one line two `backtick` </script> end' \
     && [ "$(printf '%s' "$ROW" | awk -F'|' '{print NF}')" = "8" ]; then
    ok "QA1/$SH: newline collapsed to a space, backticks/</script> pass through inertly, 6-column grid intact"
  else
    notok "QA1/$SH: malicious row malformed: '$ROW'"
  fi
  if [ "$SH" = "bash" ]; then BASH_MALICIOUS_OUT="$OUT"; fi

  # --- QA2: non-JSON API response -> one clean line, never a stack trace ---
  OUT="$(run_block "$SH" badjson "")"; RC=$?
  if printf '%s\n' "$OUT" | grep -qiE 'at Object\.|at Module\.|\.js:[0-9]+:[0-9]+|SyntaxError|TypeError|ReferenceError|node:internal'; then
    notok "QA2/$SH: raw interpreter stack trace leaked to output: $(printf '%s' "$OUT" | tr '\n' '|')"
  else
    ok "QA2/$SH: no raw interpreter stack trace on a non-JSON API response"
  fi
  NONBLANK="$(printf '%s\n' "$OUT" | grep -vc '^$')"
  if [ "$RC" -ne 0 ] && [ "$NONBLANK" -le 2 ] \
     && printf '%s\n' "$OUT" | grep -qF 'unreadable task list for DEA'; then
    ok "QA2/$SH: exactly a clean unreadable-list line (+ board link), non-zero exit"
  else
    notok "QA2/$SH: badjson handling wrong: rc=$RC lines=$NONBLANK: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- QA4: ESC/OSC-BEL/DEL in a title never reach the terminal ------------
  OUT="$(run_block "$SH" ctrl "")"; RC=$?
  VIS="$(printf '%s\n' "$OUT" | cat -v)"
  if [ "$RC" -eq 0 ] && ! printf '%s\n' "$VIS" | grep -qE '\^\[|\^G|\^\?' \
     && printf '%s\n' "$VIS" | grep -qE '^\| DEA-10 \| pwn .*SAFE .*end \| Queued \|.*\| Glen .*Barnhardt \|$'; then
    ok "QA4/$SH: ESC [2K, OSC..BEL and DEL stripped from title and assignee (cat -v shows no ^[, ^G, ^?)"
  else
    notok "QA4/$SH: control bytes leaked or row malformed: rc=$RC: $(printf '%s' "$VIS" | tr '\n' '|')"
  fi

  # --- QA5: a prototype-name status renders as its raw string ---------------
  if printf '%s\n' "$OUT" | grep -qE '^\| DEA-11 \| proto status \| constructor \| low \|' \
     && ! printf '%s\n' "$OUT" | grep -qi 'function'; then
    ok "QA5/$SH: status \"constructor\" renders the literal word, not Object.prototype.constructor"
  else
    notok "QA5/$SH: prototype-name status mishandled: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
done

# --- QA3: bash vs zsh render the malicious title byte-identically -----------
if [ "$SHELLS" = "bash zsh" ]; then
  ZSH_MALICIOUS_OUT="$(run_block zsh ok "")"
  if [ "$BASH_MALICIOUS_OUT" = "$ZSH_MALICIOUS_OUT" ]; then
    ok "QA3: malicious-title output is byte-identical under bash and zsh"
  else
    notok "QA3: bash/zsh output diverged on the malicious title"
  fi
else
  echo "SKIP: QA3 needs zsh, only bash available"
fi

printf '\n%s\n' "status-command-adversarial.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
