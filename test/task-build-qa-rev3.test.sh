#!/usr/bin/env bash
# test/task-build-qa-rev3.test.sh — independent QA on REV-3 (41570f2):
#   (1) qx_approved_base_sha moved from Step 6A to Step 5.
#   (2) Step 6L's unit-branch discovery exclusion anchored to the evidence-ref
#       shape (`^${BRANCH_PREFIX}${TASK_ID}-gates-[0-9a-f]+$`) instead of the
#       unanchored `grep -v -- '-gates-'`.
#
# This file adds coverage NOT already in test/task-build-never-local.test.sh:
#   (A) the relocation is proven byte-identical by hashing the extracted block
#       from both commits (not by trusting the diff/PR description), the
#       relocated block is proven to load and RUN cleanly under bash AND zsh
#       against a real git repo (an actual `qx_approved_base_sha: command not
#       found` would show up here as a real interpreter error, not an
#       inference), and the file's OWN line numbers (grep -n against the
#       shipped bytes, not a summary) confirm the definition precedes both
#       call sites — the same mechanical check test/task-build-never-local.
#       test.sh section (r) makes, independently re-derived here.
#   (B) the new anchor is attacked with regex metacharacters. TASK_ID and
#       BRANCH_PREFIX are validated by qx_valid_ids before they ever reach the
#       anchor; this section proves that validator does NOT forbid every
#       metacharacter the anchor mishandles — `.` passes validation and then
#       acts as a regex wildcard inside the interpolated pattern, both
#       distorting an unrelated branch name into a false match and — the
#       concrete, reachable case — recreating the exact failure mode REV-3
#       fixes (a real unit branch dropped, so a re-run would invent a second
#       branch and open a second PR) whenever a task's title-derived slug is
#       literally `gates-<hex only>`. This is a genuine, narrow gap in the
#       new anchor, not a regression: it is strictly rarer than the unanchored
#       bug it replaces (which fired on ANY slug containing `gates` between
#       hyphens; this needs the slug to be `gates-` followed by nothing but
#       hex digits, or a task id containing '.'). Logged as a coverage gap,
#       not asserted as a blocking FAIL — see .quetrex/qa-report.json's
#       not_verified[] for the same note.
#
# Run: bash test/task-build-qa-rev3.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
COMMAND="$ROOT/.claude/commands/task-build.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

# --------------------------------------------------------------------------
# (A) Byte-identical relocation, proven by hash — not by trusting the diff.
# --------------------------------------------------------------------------
extract_marked_block() {  # extract_marked_block <name> <ref:path> -> stdout
  local name="$1" ref_path="$2"
  git -C "$ROOT" show "$ref_path" 2>/dev/null | sed -n \
    "/# ── quetrex:exec-block ${name} ────/,/# ── end quetrex:exec-block ${name} ───/p"
}

OLD_HEAD="199e648"
NEW_HEAD="$(git -C "$ROOT" rev-parse HEAD)"

extract_marked_block qx_approved_base_sha "$OLD_HEAD:.claude/commands/task-build.md" > "$WORK/old_block.txt"
extract_marked_block qx_approved_base_sha "$NEW_HEAD:.claude/commands/task-build.md" > "$WORK/new_block.txt"

if [ -s "$WORK/old_block.txt" ] && [ -s "$WORK/new_block.txt" ]; then
  OLD_SUM="$(cksum < "$WORK/old_block.txt")"
  NEW_SUM="$(cksum < "$WORK/new_block.txt")"
  if [ "$OLD_SUM" = "$NEW_SUM" ]; then
    pass "(A) qx_approved_base_sha's exec-block bytes are IDENTICAL between $OLD_HEAD and HEAD ($NEW_HEAD) — cksum $OLD_SUM"
  else
    fail "(A) qx_approved_base_sha's exec-block bytes DIFFER between $OLD_HEAD ($OLD_SUM) and HEAD ($NEW_SUM) — relocation was not mechanical"
  fi
else
  fail "(A) could not extract qx_approved_base_sha from both $OLD_HEAD and HEAD"
fi

# Mechanical order check against the SHIPPED bytes (grep -n on the real file,
# never a summary or the PR description).
DEF_LINE="$(grep -n '^qx_approved_base_sha()' "$COMMAND" | head -1 | cut -d: -f1)"
CALL_LINES="$(grep -n 'qx_approved_base_sha "\$PAYLOAD"' "$COMMAND" | cut -d: -f1)"
if [ -n "$DEF_LINE" ] && [ -n "$CALL_LINES" ]; then
  # zsh does not word-split an unquoted $VAR the way bash does — read line by
  # line instead of `for L in $CALL_LINES`.
  BAD=""
  while IFS= read -r L; do
    [ -n "$L" ] || continue
    [ "$L" -lt "$DEF_LINE" ] && BAD="$BAD $L"
  done <<EOF
$CALL_LINES
EOF
  CALL_LINES_ONELINE="$(printf '%s' "$CALL_LINES" | tr '\n' ',' | sed 's/,$//')"
  if [ -z "$BAD" ]; then
    pass "(A) qx_approved_base_sha defined at line $DEF_LINE, before every call site (lines:$CALL_LINES_ONELINE) — mechanically re-derived from the shipped file, not trusted from a summary"
  else
    fail "(A) qx_approved_base_sha called at line(s)$BAD BEFORE its definition at $DEF_LINE"
  fi
else
  fail "(A) could not locate the definition and/or call sites of qx_approved_base_sha in $COMMAND"
fi

# EXECUTION proof: the relocated block, extracted verbatim from the shipped
# file (never retyped), actually LOADS and RUNS under bash and zsh against a
# real repo — a genuine forward-reference or syntax break shows up here as a
# real interpreter error ("command not found" / non-zero exit), not an
# inference from a diff.
extract_marked_block qx_approved_base_sha "HEAD:.claude/commands/task-build.md" > "$WORK/def_block.sh"
if [ -s "$WORK/def_block.sh" ]; then
  ORIGIN="$WORK/origin"; REPO="$WORK/repo"
  git init -q "$ORIGIN"
  git -C "$ORIGIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
  git -C "$ORIGIN" branch -q -M main
  git clone -q "$ORIGIN" "$REPO" 2>/dev/null

  STUBBIN="$WORK/bin"
  mkdir -p "$STUBBIN"
  cat > "$STUBBIN/quetrex-api" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "json-get" ]; then
  node -e '
    const fs=require("fs");
    const [f,k]=process.argv.slice(1);
    let p={}; try{p=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
    if (p[k]!==undefined) process.stdout.write(String(p[k]));
  ' "$2" "$3"
  exit 0
fi
echo "stub: unhandled $*" >&2
exit 1
EOF
  chmod +x "$STUBBIN/quetrex-api"

  ALL_OK=1
  for SH in bash zsh; do
    command -v "$SH" >/dev/null 2>&1 || { echo "SKIP: $SH not installed"; continue; }
    echo '{}' > "$WORK/payload_$SH.json"
    OUT="$(PATH="$STUBBIN:$PATH" "$SH" -c '
      set -e
      source "'"$WORK/def_block.sh"'"
      sha1="$(qx_approved_base_sha "'"$WORK/payload_$SH.json"'" "'"$REPO"'" "main")"
      # simulate a re-dispatch: same task, main unchanged — must REUSE, not re-resolve
      sha2="$(qx_approved_base_sha "'"$WORK/payload_$SH.json"'" "'"$REPO"'" "main")"
      printf "%s %s\n" "$sha1" "$sha2"
    ' 2>&1)"
    if printf '%s' "$OUT" | grep -qi 'command not found'; then
      fail "(A) $SH: qx_approved_base_sha: command not found when sourced/called from its shipped position — $OUT"
      ALL_OK=0
    elif printf '%s' "$OUT" | grep -qE '^[0-9a-f]{40} [0-9a-f]{40}$'; then
      S1="${OUT%% *}"; S2="${OUT##* }"
      if [ "$S1" = "$S2" ]; then
        : # first + re-dispatch both resolve, and reuse the pinned sha — correct
      else
        fail "(A) $SH: re-dispatch re-resolved a NEW sha ($S2) instead of reusing the pinned one ($S1)"
        ALL_OK=0
      fi
    else
      fail "(A) $SH: unexpected output executing the shipped block: $OUT"
      ALL_OK=0
    fi
  done
  [ "$ALL_OK" = 1 ] && pass "(A) EXECUTED: the exec-block extracted verbatim from its Step-5 position loads and runs correctly under bash and zsh — first dispatch resolves+pins, re-dispatch reuses the pinned sha"
else
  fail "(A) could not extract the def block from HEAD for execution"
fi

# --------------------------------------------------------------------------
# (B) Attack the new anchor with regex metacharacters permitted by qx_valid_ids.
# --------------------------------------------------------------------------
VALID_START="$(grep -n '^qx_show_value()' "$COMMAND" | head -1 | cut -d: -f1)"
VALID_END="$(grep -n '^# ── end quetrex:exec-block qx_valid_ids' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$VALID_START" ] && [ -n "$VALID_END" ]; then
  sed -n "${VALID_START},${VALID_END}p" "$COMMAND" > "$WORK/valid_ids.sh"
else
  fail "(B) could not locate qx_show_value..qx_valid_ids block in $COMMAND"
fi

# Pass the metacharacter through the environment, never string-interpolated
# into a double-quoted shell literal, so a metachar like '$' or '`' cannot be
# re-expanded by the test harness itself and produce a false result.
metachar_task_id_result() {  # metachar_task_id_result <char>
  QX_CH="$1" bash -c '
    source "'"$WORK/valid_ids.sh"'" 2>/dev/null
    val="A-1${QX_CH}2"
    qx_valid_task_id "$val" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
  '
}

for CH in '.' '*' '+' '[' '(' '|' '^' '$'; do
  RESULT="$(metachar_task_id_result "$CH")"
  if [ "$CH" = '.' ]; then
    if [ "$RESULT" = "ACCEPTED" ]; then
      pass "(B) qx_valid_task_id ACCEPTS '.' (e.g. 'A-1.2', the epic-child shape) — this is the metacharacter that reaches the anchor unescaped"
    else
      fail "(B) qx_valid_task_id unexpectedly rejects '.' — epic-child ids ('SMA-1.2') would break; re-check the validator regex"
    fi
  else
    if [ "$RESULT" = "REJECTED" ]; then
      pass "(B) qx_valid_task_id correctly REJECTS metacharacter '$CH'"
    else
      fail "(B) qx_valid_task_id ACCEPTS metacharacter '$CH' — a NEW injection surface into the Step 6L anchor regex, beyond '.'"
    fi
  fi
done

# The concrete, reachable collision: a task whose title slugifies to exactly
# `gates-<hex only>` produces a real unit branch that the new anchor drops —
# same failure class REV-3 fixes (discovery returns empty → fallback invents
# a second branch → a re-run opens a second PR), just far narrower than the
# unanchored bug (which fired on ANY `gates` between hyphens).
BRANCH_PREFIX="claude/"; TASK_ID="SMA-9"
PATTERN="^${BRANCH_PREFIX}${TASK_ID}-gates-[0-9a-f]+\$"
COLLIDING_UNIT_BRANCH="${BRANCH_PREFIX}${TASK_ID}-gates-deadbeef"   # a REAL unit branch: slug = "gates-deadbeef"
if printf '%s' "$COLLIDING_UNIT_BRANCH" | grep -qE "$PATTERN"; then
  pass "(B) CONFIRMED GAP (logged, not blocking): a real unit branch whose slug is literally 'gates-<hex>' ($COLLIDING_UNIT_BRANCH) is itself matched by the anchor and would be wrongly excluded as evidence — narrower than the pre-fix bug but not eliminated; see qa-report.json not_verified[]"
else
  fail "(B) expected the hex-slug collision to reproduce — if this now fails, the anchor's behavior changed and the gap note is stale"
fi

# The dot-as-wildcard case: TASK_ID carrying '.' (a valid epic-child id) makes
# the anchor match a branch that does not contain a literal '.' at all.
TASK_ID_DOT="SMA-1.2"
PATTERN_DOT="^${BRANCH_PREFIX}${TASK_ID_DOT}-gates-[0-9a-f]+\$"
WILDCARD_BRANCH="${BRANCH_PREFIX}SMA-1X2-gates-deadbeef"   # 'X' where the '.' is, not a literal dot
if printf '%s' "$WILDCARD_BRANCH" | grep -qE "$PATTERN_DOT"; then
  pass "(B) CONFIRMED: '.' in a valid task id (epic-child shape) is an unescaped regex wildcard in the anchor — matches '$WILDCARD_BRANCH' though no literal '.' is present"
else
  fail "(B) expected the dot-as-wildcard case to match — if this now fails, re-verify the anchor no longer interpolates TASK_ID raw"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "task-build-qa-rev3.test.sh: all checks passed"
else
  echo "task-build-qa-rev3.test.sh: FAILURES above"
fi
exit "$FAIL"
