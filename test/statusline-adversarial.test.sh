#!/usr/bin/env bash
# test/statusline-adversarial.test.sh — QA-authored hostile-input coverage for
# the Quetrex engine version segment in .claude/statusline-command.sh.
#
# WHY THIS FILE EXISTS SEPARATELY FROM test/statusline.test.sh.
# statusline.test.sh proves the FEATURE (the segment renders, in the right
# order, in the right colours, padded to three components). Its two
# failure-path cases (AC3 engine absent, AC7 output is "not-a-version") both
# pass VACUOUSLY against the pre-change script — verified by checking the base
# commit's copy out and running the suite against it: AC3 and AC7 were already
# green before the segment existed, because a script with no segment at all
# trivially never renders a bad one. So neither assertion actually constrains
# the new guard. This file closes that hole: every case below is an input the
# guard must survive, and each one is reachable only through the new code.
#
# THE INVARIANT UNDER TEST. `quetrex-version` is a THIRD-PARTY process from
# this script's point of view — a different release train, possibly not
# installed, possibly a wrapper, possibly broken. Whatever it emits, the status
# bar must:
#   (a) exit 0,
#   (b) write NOTHING to stderr,
#   (c) render exactly two lines,
#   (d) never render a fragment of unrecognised output, and
#   (e) still terminate line 1 with Claude Code's own version.
# A status script that violates any of these reads to the operator as "the
# build failed" when nothing failed — the exact failure mode called out in the
# LESSONS section of .claude/CLAUDE.md. Fail CLOSED (drop the segment), never
# fail loud.
#
# NOTE ON WHAT IS DELIBERATELY *NOT* ASSERTED HERE.
#   - No assertion pins a timeout. There is no timeout guard around
#     `quetrex-version`, so a hung engine blocks the status bar for its full
#     duration (measured: a 3s stub delays the render by 3.2s). That is a
#     reported robustness finding, not encoded here as an expectation.
#   - No assertion pins line 1 to the terminal width. Below ~41 columns the
#     right group no longer fits and line 1 wraps. That is also reported, not
#     encoded. What IS asserted at narrow widths is that the script still
#     exits 0 and still emits exactly two logical lines.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$TOOLROOT/.claude/statusline-command.sh"
SETTINGS="$TOOLROOT/.claude/settings.json"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: statusline-command.sh not found at $SCRIPT"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-sl-adv.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

CC_VERSION="9.9.9"

JQ_DIR="$(dirname "$(command -v jq)")"
NODE_DIR="$(dirname "$(command -v node)")"
GIT_DIR_BIN=""
if command -v git >/dev/null 2>&1; then GIT_DIR_BIN=":$(dirname "$(command -v git)")"; fi
BASE_PATH="${JQ_DIR}:${NODE_DIR}${GIT_DIR_BIN}:/usr/bin:/bin"

plain_of() { printf '%s' "$1" | node -e 'process.stdout.write(require("fs").readFileSync(0,"utf8").replace(/\x1B\[[0-9;]*m/g,""))'; }

# render_with <name> <columns> <stub-body>
#   Runs the REAL committed status line with a synthetic quetrex-version whose
#   body is <stub-body>. An empty body installs no stub at all.
#   Sets R_CODE / R_ERR / R_OUT / R_LINE1 / R_LINE2 / R_NLINES / R_PLAIN1.
render_with() {
  local name="$1" cols="$2" body="$3"
  local bin="$WORK/bin-$name" proj="$WORK/proj-$name"
  mkdir -p "$bin" "$proj" "$WORK/home-$name"
  if [ -n "$body" ]; then
    printf '#!/bin/bash\n%s\n' "$body" > "$bin/quetrex-version"
    chmod +x "$bin/quetrex-version"
  fi
  cat > "$WORK/$name.json" <<JSON
{
  "workspace": { "current_dir": "$proj", "project_dir": "$proj" },
  "model": { "display_name": "Opus 5" },
  "version": "$CC_VERSION",
  "context_window": { "used_percentage": 0 }
}
JSON
  env -i \
    HOME="$WORK/home-$name" \
    PATH="$bin:$BASE_PATH" \
    COLUMNS="$cols" \
    LANG=en_US.UTF-8 \
    TERM=dumb \
    bash "$SCRIPT" < "$WORK/$name.json" > "$WORK/$name.out" 2> "$WORK/$name.err"
  R_CODE=$?
  R_OUT="$(cat "$WORK/$name.out")"
  R_ERR="$(cat "$WORK/$name.err")"
  R_LINE1="$(head -n 1 "$WORK/$name.out")"
  R_LINE2="$(sed -n '2p' "$WORK/$name.out")"
  R_NLINES="$(wc -l < "$WORK/$name.out" | tr -d ' ')"
  R_PLAIN1="$(plain_of "$R_LINE1")"
}

# -----------------------------------------------------------------------------
# ADV-1 — hostile / malformed engine output must ALL fail closed.
#
# Each case: <label>|<stub body>|<a substring that must NEVER reach the screen>
# The guard is a whole-string numeric regex, so every one of these is rejected
# and the segment is dropped. The point of the sentinel column is that dropping
# it is not enough — no FRAGMENT of the rejected text may leak either.
# -----------------------------------------------------------------------------
i=0
while IFS='|' read -r label body sentinel; do
  [ -z "$label" ] && continue
  i=$((i + 1))
  render_with "adv$i" 100 "$body"

  if [ "$R_CODE" -eq 0 ]; then
    pass "ADV-1/$label: exits 0"
  else
    fail "ADV-1/$label: exited $R_CODE (stderr: [$R_ERR])"
  fi

  if [ -z "$R_ERR" ]; then
    pass "ADV-1/$label: stderr stays empty — nothing reads as a failed build"
  else
    fail "ADV-1/$label: wrote to stderr [$R_ERR] — an operator reads that as a failed build"
  fi

  if [ "$R_NLINES" -eq 2 ]; then
    pass "ADV-1/$label: still exactly two lines"
  else
    fail "ADV-1/$label: emitted $R_NLINES line(s), not 2 (out: [$R_OUT])"
  fi

  if [ -n "$sentinel" ]; then
    case "$R_OUT" in
      *"$sentinel"*) fail "ADV-1/$label: unrecognised engine output leaked \"$sentinel\" into the status line (out: [$R_OUT])" ;;
      *)             pass "ADV-1/$label: no fragment of the unrecognised output reaches the screen" ;;
    esac
  fi

  case "$R_PLAIN1" in
    *"v${CC_VERSION}") pass "ADV-1/$label: line 1 still ends with Claude Code's own version" ;;
    *)                 fail "ADV-1/$label: line 1 no longer ends with Claude Code's version (plain: [$R_PLAIN1])" ;;
  esac

  case "$R_OUT" in
    *"not found"*|*"No such file"*|*"unbound variable"*|*"syntax error"*|*"command not found"*)
      fail "ADV-1/$label: interpreter/command error text leaked into the render (out: [$R_OUT])" ;;
    *)
      pass "ADV-1/$label: no interpreter error text in the render" ;;
  esac
done <<'CASES'
trailing-space|printf "2.4.0   \n"|2.4.0
trailing-tab|printf "2.4.0\t\n"|2.4.0
crlf|printf "2.4.0\r\n"|2.4.0
leading-space|printf "  2.4.0\n"|2.4.0
banner-then-version|printf "warning: engine unverified\n2.4.0\n"|warning
four-components|echo 2.4.0.1|2.4.0.1
empty-output|printf ""|
bare-newline|printf "\n"|
whitespace-only|printf "   \n"|
v-prefixed|echo v2.4.0|v2.4.0
prerelease-semver|echo 2.4.0-beta.1|beta
ansi-wrapped|printf "\033[31m2.4.0\033[0m\n"|31m
silent-success|exit 0|
prints-version-but-exits-nonzero|echo 2.4.0; exit 1|Quetrex
CASES

# -----------------------------------------------------------------------------
# ADV-2 — the "first line only" guard is real, in the direction that PROVES it.
#
# statusline.test.sh AC7 only feeds output that is junk on EVERY line, which a
# script with no segment at all would also pass. The discriminating case is a
# VALID version followed by trailing noise: the segment must still render, and
# the noise must still be dropped. That can only pass if the first-line trim
# actually executes.
# -----------------------------------------------------------------------------
render_with version_then_banner 100 'printf "2.4.0\nnote: update available\n"'
case "$R_PLAIN1" in
  *"Quetrex 2.4.0  v${CC_VERSION}")
    pass "ADV-2: a valid version followed by a trailing banner line still renders \"Quetrex 2.4.0\"" ;;
  *)
    fail "ADV-2: a valid version followed by a trailing banner did not render (plain: [$R_PLAIN1])" ;;
esac
case "$R_OUT" in
  *"update available"*) fail "ADV-2: the trailing banner line leaked into the status line (out: [$R_OUT])" ;;
  *)                    pass "ADV-2: the trailing banner line is discarded — only line 1 of the engine output is read" ;;
esac
if [ "$R_NLINES" -eq 2 ]; then
  pass "ADV-2: multi-line engine output cannot add lines to the status bar"
else
  fail "ADV-2: multi-line engine output produced $R_NLINES status lines, not 2 (out: [$R_OUT])"
fi

# -----------------------------------------------------------------------------
# ADV-3 — engine chatter on ITS stderr must not become the status bar's stderr,
# and must not suppress a perfectly good version.
# -----------------------------------------------------------------------------
render_with stderr_noise 100 'echo "deprecation notice" >&2; echo 2.4.0'
if [ -z "$R_ERR" ]; then
  pass "ADV-3: the engine's own stderr is swallowed, not re-emitted by the status bar"
else
  fail "ADV-3: the engine's stderr leaked out of the status bar [$R_ERR]"
fi
case "$R_PLAIN1" in
  *"Quetrex 2.4.0  v${CC_VERSION}")
    pass "ADV-3: engine stderr chatter does not suppress an otherwise valid version" ;;
  *)
    fail "ADV-3: engine stderr chatter suppressed a valid version (plain: [$R_PLAIN1])" ;;
esac

# -----------------------------------------------------------------------------
# ADV-4 — the engine's stdout is DATA, never code. It is interpolated into a
# printf %b and into arithmetic; a payload that reaches a shell would be a
# remote-ish code execution path through whatever is first on PATH.
# -----------------------------------------------------------------------------
CANARY="$WORK/canary-executed"
render_with injection 100 "echo '2.4.0; touch $CANARY'"
if [ -e "$CANARY" ]; then
  fail "ADV-4: engine output was EXECUTED — a \`;\` payload in quetrex-version's stdout ran (canary $CANARY exists)"
else
  pass "ADV-4: a \`;\`-separated payload in the engine's stdout is never executed"
fi
CANARY2="$WORK/canary-subshell"
render_with injection_subshell 100 "printf '2.4.0\$(touch $CANARY2)\n'"
if [ -e "$CANARY2" ]; then
  fail "ADV-4: a command-substitution payload in the engine's stdout was EXECUTED (canary $CANARY2 exists)"
else
  pass "ADV-4: a command-substitution payload in the engine's stdout is never executed"
fi
case "$R_OUT" in
  *touch*) fail "ADV-4: the injection payload text was rendered into the status line (out: [$R_OUT])" ;;
  *)       pass "ADV-4: the injection payload text is not rendered either" ;;
esac

# -----------------------------------------------------------------------------
# ADV-5 — line 2 (the context bar) must be exactly the terminal width whether
# or not the engine is present. Line 1's right group is not allowed to have any
# effect on line 2's geometry.
# -----------------------------------------------------------------------------
line2_width_for() {  # line2_width_for <name> <cols> <body>
  render_with "$1" "$2" "$3"
  printf '%s' "$R_LINE2" | node -e 'const s=require("fs").readFileSync(0,"utf8").replace(/\x1B\[[0-9;]*m/g,"");process.stdout.write(String([...s].length))'
}
W_PRESENT="$(line2_width_for l2present 100 'echo 2.4.0')"
W_ABSENT="$(line2_width_for l2absent 100 '')"
if [ "$W_PRESENT" = "100" ] && [ "$W_ABSENT" = "100" ]; then
  pass "ADV-5: line 2 is exactly the 100-column terminal width with the engine present AND absent ($W_PRESENT/$W_ABSENT)"
else
  fail "ADV-5: line 2 width regressed — present $W_PRESENT, absent $W_ABSENT, expected 100 for both"
fi

# -----------------------------------------------------------------------------
# ADV-6 — narrow terminals must not CRASH or corrupt the two-line structure.
# This deliberately does not assert that line 1 fits: below ~41 columns it does
# not, and that is reported as a finding rather than silently blessed here.
# -----------------------------------------------------------------------------
for cols in 20 40 60; do
  render_with "narrow$cols" "$cols" 'echo 2.4.0'
  if [ "$R_CODE" -eq 0 ] && [ "$R_NLINES" -eq 2 ] && [ -z "$R_ERR" ]; then
    pass "ADV-6/${cols}col: still exits 0 with exactly two lines and empty stderr"
  else
    fail "ADV-6/${cols}col: exit $R_CODE, $R_NLINES line(s), stderr [$R_ERR]"
  fi
  case "$R_PLAIN1" in
    *"Quetrex 2.4.0  v${CC_VERSION}")
      pass "ADV-6/${cols}col: the right group is still intact and correctly ordered (not truncated mid-token)" ;;
    *)
      fail "ADV-6/${cols}col: the right group is corrupted at ${cols} columns (plain: [$R_PLAIN1])" ;;
  esac
done

# -----------------------------------------------------------------------------
# ADV-7 — the REGISTERED COMMAND STRING must actually run.
#
# statusline.test.sh AC9 only pattern-matches the string in settings.json. That
# proves the text changed; it does not prove the text RESOLVES. Claude Code
# spawns the statusLine command through the same runner it uses for hooks, with
# CLAUDE_PROJECT_DIR injected into the child's ENVIRONMENT (shell form is not
# string-substituted — the shell itself expands it). So the faithful check is:
# export CLAUDE_PROJECT_DIR, execute the registered string verbatim through a
# shell, and require a real two-line render.
#
# This is what catches a registration that points at a path which does not
# exist in the shipped tree — the class of defect that let the repo copy and
# the operator's personal ~/.claude copy drift a whole feature apart.
# -----------------------------------------------------------------------------
SL_CMD="$(node -e '
  const fs = require("fs");
  let o; try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
  process.stdout.write(String((o.statusLine && o.statusLine.command) || ""));
' "$SETTINGS" 2>/dev/null)"

if [ -z "$SL_CMD" ]; then
  fail "ADV-7: settings.json declares no statusLine.command to execute"
else
  REG_BIN="$WORK/bin-reg"; REG_PROJ="$WORK/proj-reg"
  mkdir -p "$REG_BIN" "$REG_PROJ" "$WORK/home-reg"
  printf '#!/bin/bash\necho 2.4.0\n' > "$REG_BIN/quetrex-version"
  chmod +x "$REG_BIN/quetrex-version"
  cat > "$WORK/reg.json" <<JSON
{
  "workspace": { "current_dir": "$REG_PROJ", "project_dir": "$REG_PROJ" },
  "model": { "display_name": "Opus 5" },
  "version": "$CC_VERSION",
  "context_window": { "used_percentage": 0 }
}
JSON
  env -i \
    HOME="$WORK/home-reg" \
    PATH="$REG_BIN:$BASE_PATH" \
    COLUMNS=100 \
    LANG=en_US.UTF-8 \
    TERM=dumb \
    CLAUDE_PROJECT_DIR="$TOOLROOT" \
    bash -c "$SL_CMD" < "$WORK/reg.json" > "$WORK/reg.out" 2> "$WORK/reg.err"
  REG_CODE=$?
  REG_ERR="$(cat "$WORK/reg.err")"
  REG_LINES="$(wc -l < "$WORK/reg.out" | tr -d ' ')"
  REG_PLAIN1="$(plain_of "$(head -n 1 "$WORK/reg.out")")"

  if [ "$REG_CODE" -eq 0 ] && [ -z "$REG_ERR" ]; then
    pass "ADV-7: the registered statusLine.command executes cleanly with CLAUDE_PROJECT_DIR exported (exit 0, empty stderr)"
  else
    fail "ADV-7: the registered statusLine.command failed with CLAUDE_PROJECT_DIR exported — exit $REG_CODE, stderr [$REG_ERR]. The registration does not resolve to a runnable script in this tree."
  fi
  if [ "$REG_LINES" -eq 2 ]; then
    pass "ADV-7: the registered command renders exactly two lines"
  else
    fail "ADV-7: the registered command rendered $REG_LINES line(s), not 2"
  fi
  case "$REG_PLAIN1" in
    *"Quetrex 2.4.0  v${CC_VERSION}")
      pass "ADV-7: the registered command renders the full right group end to end — registration and script agree" ;;
    *)
      fail "ADV-7: the registered command did not render the expected right group (plain: [$REG_PLAIN1])" ;;
  esac

  # The path the registration resolves to must be the file this repo SHIPS.
  RESOLVED="$(CLAUDE_PROJECT_DIR="$TOOLROOT" bash -c 'printf "%s" "${CLAUDE_PROJECT_DIR}/.claude/statusline-command.sh"')"
  if [ -f "$RESOLVED" ]; then
    pass "ADV-7: the registration resolves to a file that exists in the shipped tree ($RESOLVED)"
  else
    fail "ADV-7: the registration resolves to $RESOLVED, which does not exist in the shipped tree"
  fi
fi

# -----------------------------------------------------------------------------
# ADV-8 — NO VERSION PIN. The engine version must be read at runtime and never
# baked into the script. A literal x.y.z in this file would be exactly the
# hardcoded pin the repo's LOCKED rule forbids, and would keep displaying a
# stale number after an engine upgrade.
# -----------------------------------------------------------------------------
if grep -qE '(^|[^0-9])[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)' "$SCRIPT"; then
  fail "ADV-8: statusline-command.sh contains a literal x.y.z version — the engine version must be read at runtime, never pinned ($(grep -nE '(^|[^0-9])[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)' "$SCRIPT" | head -3))"
else
  pass "ADV-8: statusline-command.sh contains no literal x.y.z version — nothing is pinned"
fi
if grep -qE 'quetrex-version[[:space:]]+--plain' "$SCRIPT"; then
  pass "ADV-8: the version is obtained at runtime from \`quetrex-version --plain\`"
else
  fail "ADV-8: statusline-command.sh no longer reads the version from \`quetrex-version --plain\`"
fi
# STRIP COMMENTS FIRST, then search — never `grep -q ... | grep`. `grep -q` is
# quiet by definition: it writes zero bytes, so a downstream grep reads an empty
# stream, matches nothing and always exits 1, making the whole `if` unfailable.
# That is not theoretical: a real `_pinned_v=$(cat .../.claude-plugin/plugin.json)`
# injected into the script — precisely the hardcoded pin this assertion exists to
# catch, against a LOCKED repo rule — was reported `ok` with the suite exiting 0.
# The filter has to come first and carry the data, with only the LAST grep quiet.
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE '(plugin|package)\.json'; then
  fail "ADV-8: statusline-command.sh reads a version out of plugin.json/package.json instead of the running engine ($(grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -nE '(plugin|package)\.json' | head -3))"
else
  pass "ADV-8: statusline-command.sh does not read a version out of plugin.json/package.json (comment lines excluded before searching)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "statusline-adversarial.test.sh: all checks passed"
  exit 0
else
  echo "statusline-adversarial.test.sh: FAILURES above"
  exit 1
fi
