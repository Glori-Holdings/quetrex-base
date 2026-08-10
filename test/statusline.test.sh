#!/usr/bin/env bash
# test/statusline.test.sh — behavioural test for the Quetrex engine version
# segment in .claude/statusline-command.sh, and for the statusLine
# registration in .claude/settings.json.
#
# Run: bash test/statusline.test.sh
#
# WHY THIS FILE EXISTS. Quetrex pins no version anywhere — a pinned
# enabledPlugins entry makes the plugin count as disabled for dependency
# resolution and the whole /quetrex:* command layer stops loading. Because
# config carries no version, the status bar is the ONLY place the running
# engine version is ever surfaced (that is also why doctor.md must never
# quarantine a live statusline-command.sh — see test/doctor-checks.test.sh
# AC-B1). The engine version was nonetheless never shipped in the repo's own
# .claude/statusline-command.sh: the segment existed only in one operator's
# personal ~/.claude copy, so every other machine ran an engine whose version
# it could not name.
#
# DEFECT A (the segment was missing). Line 1's right-aligned group must read
#   Quetrex <x.y.z>  v<claude-code-version>
# with "Quetrex" gold (38;2;212;175;55), its version one shade lighter and
# subordinate (38;2;168;162;158), and Claude Code's own version LAST in the
# existing dim tone (38;2;68;64;60), separated from the Quetrex group by
# exactly two spaces.
#   AC1: engine present -> the right group is exactly "Quetrex 2.4.0  v9.9.9"
#        and it terminates line 1 (order proven by the contiguous match).
#   AC2: each colour lands on the correct token — gold immediately precedes
#        the literal word "Quetrex", the lighter tone immediately precedes the
#        engine version, the dim tone immediately precedes Claude Code's.
#   AC5/AC6: the version always renders with THREE components. A bare "2.4"
#        reads as a truncated version, which is the exact confusion this
#        segment exists to remove: "2.4" -> "2.4.0", "2" -> "2.0.0", and an
#        already-complete "2.4.0" passes through untouched (AC1).
#
# DEFECT B (it must never be able to break the status bar). quetrex-version
# exits non-zero when no engine is installed. A status script must NEVER
# surface an interpreter error, a "command not found", or a half-rendered
# placeholder to the operator — it reads as "the build failed" when nothing
# failed (see the LESSONS section of .claude/CLAUDE.md).
#   AC3: engine ABSENT (quetrex-version not on PATH) -> exit 0, empty stderr,
#        no "Quetrex" anywhere, no error text, and Claude Code's version still
#        rendered on its own.
#   AC7: quetrex-version present but printing GARBAGE -> the segment is
#        omitted entirely rather than rendered as garbage.
#
# DEFECT C (right-alignment must stay ANSI-blind). The gap is computed from
# the PLAIN (uncolored) width of the right group; counting escape sequences
# would silently shove the group left by ~30 columns.
#   AC4: the ANSI-stripped width of line 1 is IDENTICAL with the engine
#        present (4 escape sequences in the right group) and absent (1), and
#        stays flush against the terminal width. If escapes were counted, the
#        two would differ by the escape-length delta.
#
# DEFECT D (line 2 must not regress). Line 1 is the version's only home.
#   AC8: output is exactly two lines; line 2 is still the context bar and
#        never mentions Quetrex.
#
# DEFECT E (the shipped registration pointed at the operator's home). The repo
# registered "bash ~/.claude/statusline-command.sh", so the copy this project
# owns and ships was never the copy that ran — which is precisely how the repo
# copy drifted a whole feature behind one operator's personal file without
# anyone noticing.
#
# The replacement resolves via ${CLAUDE_PROJECT_DIR}, NOT ${CLAUDE_PLUGIN_ROOT}.
# .claude/settings.json is this repo's PROJECT settings; the plugin's own
# registration surface is hooks/hooks.json (which does use ${CLAUDE_PLUGIN_ROOT},
# correctly, and carries no statusLine key at all). CLAUDE_PLUGIN_ROOT is not
# exported into a project-scoped statusLine, so using it here would expand to a
# bare "/.claude/statusline-command.sh" and blank the status bar outright.
# Every hook registration in this same settings.json already uses
# ${CLAUDE_PROJECT_DIR}, so there is direct in-file precedent that it expands.
#   AC9: statusLine.command contains ${CLAUDE_PROJECT_DIR} and does not
#        contain ~/.claude/ — the home path was the real defect.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$TOOLROOT/.claude/statusline-command.sh"
SETTINGS="$TOOLROOT/.claude/settings.json"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: statusline-command.sh not found at $SCRIPT"
  exit 1
fi
if [ ! -f "$SETTINGS" ]; then
  echo "FAIL: settings.json not found at $SETTINGS"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the status line parses its stdin with a single jq call"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — this file measures ANSI-stripped widths with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-statusline.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ESC="$(printf '\033')"
C_GOLD="${ESC}[38;2;212;175;55m"       # the literal word "Quetrex"
C_LIGHTER="${ESC}[38;2;168;162;158m"   # its version, one shade subordinate
C_DIM="${ESC}[38;2;68;64;60m"          # Claude Code's own version, last

# A deliberately unmistakable fixture version for Claude Code itself, so a
# match can never be confused with the engine version under test.
CC_VERSION="9.9.9"

# Isolated PATH: the stub bin dir under test + the directories holding the
# tools the status line genuinely uses (jq, node, git) + the base system dirs
# — but NEVER a directory carrying this machine's real quetrex-version, so the
# "no engine installed" case is a real absence rather than a live engine.
JQ_DIR="$(dirname "$(command -v jq)")"
NODE_DIR="$(dirname "$(command -v node)")"
GIT_DIR_BIN=""
if command -v git >/dev/null 2>&1; then GIT_DIR_BIN=":$(dirname "$(command -v git)")"; fi
BASE_PATH="${JQ_DIR}:${NODE_DIR}${GIT_DIR_BIN}:/usr/bin:/bin"

TERM_COLS=100

# Strip ANSI SGR sequences and report the remaining length in CODE POINTS
# (bash's ${#var} counts characters too under a UTF-8 locale, so the two
# agree on the 📂/🤖 glyphs the left group carries).
plain_of()     { printf '%s' "$1" | node -e 'process.stdout.write(require("fs").readFileSync(0,"utf8").replace(/\x1B\[[0-9;]*m/g,""))'; }
plain_len_of() { printf '%s' "$1" | node -e 'const s=require("fs").readFileSync(0,"utf8").replace(/\x1B\[[0-9;]*m/g,"");process.stdout.write(String([...s].length))'; }

# make_stub <dir> <body|"">
#   Creates <dir> and, when a body is given, a quetrex-version stub in it.
#   An empty body means "no engine installed at all".
make_stub() {
  local dir="$1" body="${2:-}"
  mkdir -p "$dir"
  if [ -n "$body" ]; then
    printf '#!/bin/bash\n%s\n' "$body" > "$dir/quetrex-version"
    chmod +x "$dir/quetrex-version"
  fi
}

# render <case-name> <stub-dir> [interpreter] [json-version]
#   Runs the REAL committed status line under a scrubbed environment and sets
#   R_OUT / R_ERR / R_CODE / R_LINE1 / R_LINE2 / R_NLINES.
#
#   [interpreter] defaults to bare `bash` (whatever the PATH resolves, which on
#   a developer machine is usually a Homebrew bash 5). AC13 passes /bin/bash
#   explicitly, because the script's own shebang is #!/bin/bash and the stock
#   macOS /bin/bash is 3.2 — a different code path in the timeout gate that
#   bare `bash` never reaches.
#
#   [json-version] is inserted RAW into the JSON, so a caller can supply an
#   escaped value like '2.1\\c226' to prove that .version is never
#   escape-interpreted. It defaults to the plain fixture version.
render() {
  local name="$1" stub="$2" interp="${3:-bash}" jver="${4:-$CC_VERSION}"
  local proj="$WORK/proj-$name" out="$WORK/$name.out" err="$WORK/$name.err" input="$WORK/$name.json"
  mkdir -p "$proj" "$WORK/home-$name"
  cat > "$input" <<JSON
{
  "workspace": { "current_dir": "$proj", "project_dir": "$proj" },
  "model": { "display_name": "Opus 5" },
  "version": "$jver",
  "context_window": { "used_percentage": 0 }
}
JSON
  env -i \
    HOME="$WORK/home-$name" \
    PATH="$stub:$BASE_PATH" \
    COLUMNS="$TERM_COLS" \
    LANG=en_US.UTF-8 \
    TERM=dumb \
    "$interp" "$SCRIPT" < "$input" > "$out" 2> "$err"
  R_CODE=$?
  R_OUT="$(cat "$out")"
  R_ERR="$(cat "$err")"
  R_LINE1="$(head -n 1 "$out")"
  R_LINE2="$(sed -n '2p' "$out")"
  R_NLINES="$(wc -l < "$out" | tr -d ' ')"
}

# -----------------------------------------------------------------------------
# Setup guard: the "absent" PATH must really lack quetrex-version, or AC3/AC7
# would silently test the live engine instead of the fixture.
# -----------------------------------------------------------------------------
EMPTY_STUB="$WORK/bin-none"
make_stub "$EMPTY_STUB" ""
if PATH="$EMPTY_STUB:$BASE_PATH" command -v quetrex-version >/dev/null 2>&1; then
  fail "setup: the isolated PATH still resolves a real quetrex-version — the engine-absent cases would be vacuous"
else
  pass "setup: the isolated PATH resolves no quetrex-version, so the engine-absent cases are a real absence"
fi

# -----------------------------------------------------------------------------
# AC1/AC2/AC4/AC8 — engine present, already a complete x.y.z version.
# -----------------------------------------------------------------------------
FULL_STUB="$WORK/bin-full"
make_stub "$FULL_STUB" 'echo 2.4.0'
render present "$FULL_STUB"
P_CODE=$R_CODE; P_ERR="$R_ERR"; P_LINE1="$R_LINE1"; P_LINE2="$R_LINE2"; P_NLINES="$R_NLINES"
P_PLAIN1="$(plain_of "$P_LINE1")"
P_LEN1="$(plain_len_of "$P_LINE1")"

if [ "$P_CODE" -eq 0 ]; then
  pass "AC1: the status line exits 0 with an engine installed"
else
  fail "AC1: the status line exited $P_CODE with an engine installed (stderr: [$P_ERR])"
fi

case "$P_PLAIN1" in
  *"Quetrex 2.4.0  v${CC_VERSION}")
    pass "AC1: line 1 ends with the right group \"Quetrex 2.4.0  v${CC_VERSION}\" — word, engine version, two spaces, Claude Code version, in that order" ;;
  *)
    fail "AC1: line 1 does not end with \"Quetrex 2.4.0  v${CC_VERSION}\" (plain line 1: [$P_PLAIN1])" ;;
esac

case "$P_LINE1" in
  *"${C_GOLD}Quetrex"*) pass "AC2: the gold 38;2;212;175;55 sequence immediately precedes the literal word \"Quetrex\"" ;;
  *)                    fail "AC2: no gold 38;2;212;175;55 sequence immediately precedes \"Quetrex\" on line 1" ;;
esac
case "$P_LINE1" in
  *"${C_LIGHTER}2.4.0"*) pass "AC2: the lighter 38;2;168;162;158 sequence immediately precedes the engine version" ;;
  *)                     fail "AC2: no lighter 38;2;168;162;158 sequence immediately precedes the engine version on line 1" ;;
esac
case "$P_LINE1" in
  *"${C_DIM}v${CC_VERSION}"*) pass "AC2: the dim 38;2;68;64;60 sequence immediately precedes Claude Code's own version" ;;
  *)                          fail "AC2: no dim 38;2;68;64;60 sequence immediately precedes Claude Code's version on line 1" ;;
esac

if [ "$P_NLINES" -eq 2 ]; then
  pass "AC8: the status line still renders exactly two lines"
else
  fail "AC8: expected exactly 2 lines, got $P_NLINES (out: [$R_OUT])"
fi
case "$P_LINE2" in
  *Quetrex*) fail "AC8: line 2 (the context bar) also mentions Quetrex — line 1 is its only home (line 2: [$P_LINE2])" ;;
  *)         pass "AC8: line 2 never mentions Quetrex — line 1 is its only home" ;;
esac
case "$(plain_of "$P_LINE2")" in
  *"0%"*) pass "AC8: line 2 is still the context bar (percentage label intact)" ;;
  *)      fail "AC8: line 2 no longer looks like the context bar (line 2: [$P_LINE2])" ;;
esac

# -----------------------------------------------------------------------------
# AC3 — engine ABSENT: clean render, no error text, no partial segment.
# -----------------------------------------------------------------------------
render absent "$EMPTY_STUB"
A_CODE=$R_CODE; A_ERR="$R_ERR"; A_LINE1="$R_LINE1"; A_OUT="$R_OUT"
A_PLAIN1="$(plain_of "$A_LINE1")"
A_LEN1="$(plain_len_of "$A_LINE1")"

if [ "$A_CODE" -eq 0 ]; then
  pass "AC3: the status line exits 0 when no engine is installed"
else
  fail "AC3: the status line exited $A_CODE with no engine installed (stderr: [$A_ERR])"
fi
if [ -z "$A_ERR" ]; then
  pass "AC3: nothing is written to stderr when no engine is installed"
else
  fail "AC3: stderr is not empty when no engine is installed — an operator reads that as a failed build (stderr: [$A_ERR])"
fi
case "$A_OUT" in
  *Quetrex*) fail "AC3: the Quetrex segment is still rendered with no engine installed (out: [$A_OUT])" ;;
  *)         pass "AC3: the Quetrex half is omitted entirely when no engine is installed" ;;
esac
case "$A_OUT" in
  *"not found"*|*"No such file"*|*"unbound variable"*|*"syntax error"*|*"Traceback"*)
    fail "AC3: error text leaked into the rendered status line (out: [$A_OUT])" ;;
  *)
    pass "AC3: no interpreter/command error text leaks into the rendered status line" ;;
esac
case "$A_PLAIN1" in
  *"v${CC_VERSION}")
    pass "AC3: Claude Code's own version still terminates line 1 on its own" ;;
  *)
    fail "AC3: Claude Code's version no longer terminates line 1 with no engine installed (plain line 1: [$A_PLAIN1])" ;;
esac

# -----------------------------------------------------------------------------
# AC4 — right-alignment is computed from PLAIN width, never from the escapes.
# The present render carries 4 SGR sequences in the right group, the absent
# render 1; if escapes were counted in the gap the two stripped widths would
# differ by roughly 45 columns.
# -----------------------------------------------------------------------------
if [ "$P_LEN1" = "$A_LEN1" ]; then
  pass "AC4: the ANSI-stripped width of line 1 is identical with the engine present and absent ($P_LEN1) — escapes are not counted in the gap"
else
  fail "AC4: the ANSI-stripped width of line 1 differs (present $P_LEN1, absent $A_LEN1) — the right-alignment gap is counting ANSI escapes"
fi
if [ "$P_LEN1" -le "$TERM_COLS" ] && [ "$P_LEN1" -ge $((TERM_COLS - 4)) ]; then
  pass "AC4: line 1 stays flush against the ${TERM_COLS}-column terminal width (stripped width $P_LEN1)"
else
  fail "AC4: line 1's stripped width is $P_LEN1, not flush against the ${TERM_COLS}-column terminal width"
fi

# -----------------------------------------------------------------------------
# AC5/AC6 — always three components. A bare "2.4" reads as truncated.
# -----------------------------------------------------------------------------
TWO_STUB="$WORK/bin-two"
make_stub "$TWO_STUB" 'echo 2.4'
render twocomp "$TWO_STUB"
T_PLAIN1="$(plain_of "$R_LINE1")"
case "$T_PLAIN1" in
  *"Quetrex 2.4.0  v${CC_VERSION}")
    pass "AC5: a two-component \"2.4\" from quetrex-version renders as \"2.4.0\"" ;;
  *)
    fail "AC5: a two-component \"2.4\" did not render as \"2.4.0\" (plain line 1: [$T_PLAIN1])" ;;
esac

ONE_STUB="$WORK/bin-one"
make_stub "$ONE_STUB" 'echo 2'
render onecomp "$ONE_STUB"
O_PLAIN1="$(plain_of "$R_LINE1")"
case "$O_PLAIN1" in
  *"Quetrex 2.0.0  v${CC_VERSION}")
    pass "AC6: a single-component \"2\" from quetrex-version renders as \"2.0.0\"" ;;
  *)
    fail "AC6: a single-component \"2\" did not render as \"2.0.0\" (plain line 1: [$O_PLAIN1])" ;;
esac

# -----------------------------------------------------------------------------
# AC7 — quetrex-version exits 0 but prints something that is not a version.
# The segment must be omitted, never rendered as garbage.
# -----------------------------------------------------------------------------
JUNK_STUB="$WORK/bin-junk"
make_stub "$JUNK_STUB" 'echo "not-a-version"'
render junk "$JUNK_STUB"
J_PLAIN1="$(plain_of "$R_LINE1")"
if [ "$R_CODE" -eq 0 ] && [ -z "$R_ERR" ]; then
  pass "AC7: garbage from quetrex-version still exits 0 with empty stderr"
else
  fail "AC7: garbage from quetrex-version produced exit $R_CODE / stderr [$R_ERR]"
fi
case "$R_OUT" in
  *not-a-version*) fail "AC7: garbage from quetrex-version was rendered verbatim into the status line (out: [$R_OUT])" ;;
  *)               pass "AC7: garbage from quetrex-version is never rendered into the status line" ;;
esac
case "$J_PLAIN1" in
  *"v${CC_VERSION}") pass "AC7: with garbage suppressed, Claude Code's version still terminates line 1" ;;
  *)                 fail "AC7: line 1 no longer ends with Claude Code's version when the engine output is garbage (plain line 1: [$J_PLAIN1])" ;;
esac

# -----------------------------------------------------------------------------
# AC9 — the shipped statusLine registration resolves inside the plugin.
# -----------------------------------------------------------------------------
SL_CMD="$(node -e '
  const fs = require("fs");
  let o; try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
  process.stdout.write(String((o.statusLine && o.statusLine.command) || ""));
' "$SETTINGS" 2>/dev/null)"

if [ -n "$SL_CMD" ]; then
  pass "AC9: .claude/settings.json declares a statusLine.command"
else
  fail "AC9: .claude/settings.json has no statusLine.command at all"
fi
case "$SL_CMD" in
  *CLAUDE_PROJECT_DIR*)
    pass "AC9: statusLine.command resolves via CLAUDE_PROJECT_DIR, the same variable every hook registration in this file already uses" ;;
  *)
    fail "AC9: statusLine.command does not reference CLAUDE_PROJECT_DIR (command: [$SL_CMD]) — this is a project-scoped setting, so \${CLAUDE_PLUGIN_ROOT} is unset here and would expand to a bare /.claude/... path" ;;
esac
case "$SL_CMD" in
  *'~/.claude/'*)
    fail "AC9: statusLine.command still points at ~/.claude/ (command: [$SL_CMD]) — the personal home copy is exactly what let the shipped copy drift" ;;
  *)
    pass "AC9: statusLine.command no longer points at ~/.claude/" ;;
esac
case "$SL_CMD" in
  *'statusline-command.sh'*)
    pass "AC9: statusLine.command still targets statusline-command.sh" ;;
  *)
    fail "AC9: statusLine.command no longer targets statusline-command.sh (command: [$SL_CMD])" ;;
esac

# -----------------------------------------------------------------------------
# AC10 — the registered string must survive CLAUDE_PROJECT_DIR being UNSET.
#
# A bare "${CLAUDE_PROJECT_DIR}/..." expands to "/.claude/statusline-command.sh"
# when the variable is absent and exits 127 with an error on stderr — an
# erroring status line, which is the exact thing the LESSONS section of
# .claude/CLAUDE.md forbids, because the operator reads it as a failed build.
# All 10 hook commands in this same settings.json already use the guarded
# "${CLAUDE_PROJECT_DIR:-.}" form for precisely this reason. Pattern-matching
# the string cannot tell the two apart, so this executes it.
# -----------------------------------------------------------------------------
if [ -n "$SL_CMD" ]; then
  UNSET_BIN="$WORK/bin-unset"
  make_stub "$UNSET_BIN" 'echo 2.4.0'
  mkdir -p "$WORK/home-unset"
  cat > "$WORK/unset.json" <<JSON
{
  "workspace": { "current_dir": "$TOOLROOT", "project_dir": "$TOOLROOT" },
  "model": { "display_name": "Opus 5" },
  "version": "$CC_VERSION",
  "context_window": { "used_percentage": 0 }
}
JSON
  # cwd is the repo root, which is what "." resolves to for a project-scoped
  # command, and CLAUDE_PROJECT_DIR is deliberately absent from the environment.
  (
    cd "$TOOLROOT" || exit 1
    env -i \
      HOME="$WORK/home-unset" \
      PATH="$UNSET_BIN:$BASE_PATH" \
      COLUMNS=100 \
      LANG=en_US.UTF-8 \
      TERM=dumb \
      bash -c "$SL_CMD" < "$WORK/unset.json" > "$WORK/unset.out" 2> "$WORK/unset.err"
  )
  U_CODE=$?
  U_ERR="$(cat "$WORK/unset.err")"
  U_PLAIN1="$(plain_of "$(head -n 1 "$WORK/unset.out")")"

  if [ "$U_CODE" -eq 0 ]; then
    # Deliberately narrow wording: this proves the guarded form survives an
    # unset variable WHEN cwd is the project root, which is the case Claude
    # Code actually invokes (it spawns the status line with cwd at the project
    # root). It does NOT prove the registration is robust to an unset variable
    # from an arbitrary cwd — `.` cannot be, by construction.
    pass "AC10: the registered statusLine.command exits 0 with CLAUDE_PROJECT_DIR unset and cwd at the project root"
  else
    fail "AC10: the registered statusLine.command exited $U_CODE with CLAUDE_PROJECT_DIR unset (stderr: [$U_ERR]) — the unguarded \${CLAUDE_PROJECT_DIR} form expands to a bare /.claude/... path and exits 127"
  fi
  if [ -z "$U_ERR" ]; then
    pass "AC10: nothing is written to stderr with CLAUDE_PROJECT_DIR unset"
  else
    fail "AC10: the registered command wrote to stderr with CLAUDE_PROJECT_DIR unset [$U_ERR] — an operator reads that as a failed build"
  fi
  case "$U_PLAIN1" in
    *"Quetrex 2.4.0  v${CC_VERSION}")
      pass "AC10: with CLAUDE_PROJECT_DIR unset the guarded form still renders the full right group" ;;
    *)
      fail "AC10: with CLAUDE_PROJECT_DIR unset the right group did not render (plain line 1: [$U_PLAIN1])" ;;
  esac
fi

# -----------------------------------------------------------------------------
# AC11 — a wedged engine must not freeze the status bar.
#
# quetrex-version is a third-party process from this script's point of view. It
# can hang on a stale lock or a dead mount, and unbounded that hang IS the
# status bar's render time (measured: a 3s stub produced a 3.2s render against
# this file's own <50ms target). The bound is built from `read -t`, because
# timeout/gtimeout are coreutils and absent from a stock macOS. A timeout must
# take the SAME path as a missing engine: drop the segment, exit 0, say nothing.
# -----------------------------------------------------------------------------
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

HANG_STUB="$WORK/bin-hang"
make_stub "$HANG_STUB" 'sleep 3; echo 2.4.0'
T_START="$(now_ms)"
render hang "$HANG_STUB"
T_END="$(now_ms)"
ELAPSED=$(( T_END - T_START ))

if [ "$ELAPSED" -lt 2500 ]; then
  pass "AC11: a 3s-wedged engine is bounded — the status line rendered in ${ELAPSED}ms instead of blocking for the full 3s"
else
  fail "AC11: a 3s-wedged engine blocked the status line for ${ELAPSED}ms — the call to quetrex-version is unbounded"
fi
if [ "$R_CODE" -eq 0 ] && [ -z "$R_ERR" ]; then
  pass "AC11: a wedged engine still exits 0 with empty stderr"
else
  fail "AC11: a wedged engine produced exit $R_CODE / stderr [$R_ERR]"
fi
case "$R_OUT" in
  *Quetrex*) fail "AC11: a wedged engine still rendered a Quetrex segment (out: [$R_OUT])" ;;
  *)         pass "AC11: a wedged engine takes the same fail-closed path as a missing one — the segment is dropped silently" ;;
esac
case "$(plain_of "$R_LINE1")" in
  *"v${CC_VERSION}") pass "AC11: Claude Code's own version still terminates line 1 when the engine is wedged" ;;
  *)                 fail "AC11: line 1 no longer ends with Claude Code's version when the engine is wedged" ;;
esac

# -----------------------------------------------------------------------------
# AC12 — .version is DATA from stdin and must never be escape-interpreted.
#
# Claude Code supplies .version, so a semver is what arrives in practice and
# this is not an exploit. It is still the one field that must stay literal:
# printf's %b interprets backslash escapes, and a `\c` in a %b argument
# TERMINATES printf's output entirely — swallowing line 1's newline and welding
# the context bar onto line 1, which silently breaks the two-line invariant that
# AC8 and the whole adversarial suite depend on. Keeping .version on its own %s
# argument is what makes that unreachable, so it needs an assertion that would
# notice if it were ever folded back into a %b.
# -----------------------------------------------------------------------------
BS_STUB="$WORK/bin-backslash"
make_stub "$BS_STUB" 'echo 2.4.0'

# JSON "2.1\\c226" decodes to the 9 characters  2.1\c226
render vbackslash "$BS_STUB" bash '2.1\\c226'
if [ "$R_NLINES" -eq 2 ]; then
  pass "AC12: a \\c in .version does not collapse the status bar — still exactly two lines"
else
  fail "AC12: a \\c in .version collapsed the status bar to $R_NLINES line(s) — .version is being interpreted by printf %b, which terminates output at \\c"
fi
case "$(plain_of "$R_LINE1")" in
  *'v2.1\c226') pass "AC12: a backslash in .version is rendered literally" ;;
  *)            fail "AC12: a backslash in .version was not rendered literally (plain line 1: [$(plain_of "$R_LINE1")])" ;;
esac
case "$R_LINE2" in
  *"▰"*|*"▱"*) pass "AC12: line 2 is still its own line — the context bar was not welded onto line 1" ;;
  *)           fail "AC12: line 2 is no longer the context bar (line 2: [$R_LINE2])" ;;
esac

# JSON "2.1\\033[31mX" decodes to  2.1\033[31mX  — four literal characters
# \033, not an escape. If %b interpreted it, a live red SGR would be injected
# into the render straight from stdin data.
render vansi "$BS_STUB" bash '2.1\\033[31mX'
case "$R_LINE1" in
  *"${ESC}[31m"*) fail "AC12: a \\033 sequence in .version was interpreted and injected a live ANSI colour into the render" ;;
  *)              pass "AC12: a \\033 sequence in .version is not interpreted — no ANSI is injected from stdin data" ;;
esac
if [ "$R_NLINES" -eq 2 ]; then
  pass "AC12: an ANSI-looking .version still renders exactly two lines"
else
  fail "AC12: an ANSI-looking .version produced $R_NLINES line(s)"
fi

# -----------------------------------------------------------------------------
# AC13 — the script must be clean under /bin/bash SPECIFICALLY.
#
# The timeout gate branches on ${BASH_VERSINFO[0]}: bash 3.2 rejects a
# fractional `read -t` ("invalid timeout specification" on STDERR — the exact
# operator-facing interpreter error this repo's LESSONS rule forbids), so 3.2
# gets a whole-second bound and bash 4+ a fractional one. Every other case in
# this file runs bare `bash`, which on a developer machine resolves to a
# Homebrew bash 5 — so without this block the 3.2 branch is executed by NO
# test, and a one-character regression to the gate would survive the entire
# suite. The script's own shebang is #!/bin/bash, so /bin/bash is the
# interpreter that actually ships.
# -----------------------------------------------------------------------------
if [ -x /bin/bash ]; then
  SYS_BASH_V="$(/bin/bash -c 'printf "%s" "${BASH_VERSINFO[0]}"')"
  if [ "$SYS_BASH_V" -lt 4 ]; then
    echo "note: /bin/bash is major version $SYS_BASH_V — AC13 exercises the integer-timeout branch"
  else
    echo "note: /bin/bash is major version $SYS_BASH_V — AC13 exercises the fractional-timeout branch"
  fi

  render sysbash_clean "$BS_STUB" /bin/bash
  if [ "$R_CODE" -eq 0 ] && [ -z "$R_ERR" ]; then
    pass "AC13: under /bin/bash (v$SYS_BASH_V) a clean render exits 0 with EMPTY stderr — the timeout value is one this interpreter accepts"
  else
    fail "AC13: under /bin/bash (v$SYS_BASH_V) the render exited $R_CODE with stderr [$R_ERR] — the timeout gate handed this interpreter a value it rejects"
  fi
  case "$(plain_of "$R_LINE1")" in
    *"Quetrex 2.4.0  v${CC_VERSION}")
      pass "AC13: under /bin/bash the full right group still renders correctly" ;;
    *)
      fail "AC13: under /bin/bash the right group did not render (plain line 1: [$(plain_of "$R_LINE1")])" ;;
  esac
  if [ "$R_NLINES" -eq 2 ]; then
    pass "AC13: under /bin/bash the status bar is still exactly two lines"
  else
    fail "AC13: under /bin/bash the status bar rendered $R_NLINES line(s), not 2"
  fi

  # The bound itself must hold under this interpreter too, not just under the
  # one the rest of the file happens to use.
  SB_HANG="$WORK/bin-sysbash-hang"
  make_stub "$SB_HANG" 'sleep 3; echo 2.4.0'
  SB_START="$(now_ms)"
  render sysbash_hang "$SB_HANG" /bin/bash
  SB_END="$(now_ms)"
  SB_ELAPSED=$(( SB_END - SB_START ))
  if [ "$SB_ELAPSED" -lt 2500 ] && [ "$R_CODE" -eq 0 ] && [ -z "$R_ERR" ]; then
    pass "AC13: under /bin/bash a 3s-wedged engine is still bounded (${SB_ELAPSED}ms), exits 0, and says nothing on stderr"
  else
    fail "AC13: under /bin/bash a wedged engine took ${SB_ELAPSED}ms, exit $R_CODE, stderr [$R_ERR]"
  fi
  case "$R_OUT" in
    *Quetrex*) fail "AC13: under /bin/bash a wedged engine still rendered a Quetrex segment" ;;
    *)         pass "AC13: under /bin/bash a wedged engine fails closed like a missing one" ;;
  esac
else
  echo "note: /bin/bash is not present — AC13's interpreter-specific coverage did not run here"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "statusline.test.sh: all checks passed"
  exit 0
else
  echo "statusline.test.sh: FAILURES above"
  exit 1
fi
