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
#   (B) the anchor is attacked with regex metacharacters. TASK_ID and
#       BRANCH_PREFIX are validated by qx_valid_ids before they ever reach the
#       exclusion; this section proves that validator does NOT forbid every
#       metacharacter a pattern would mishandle — `.` passes validation, and in
#       68ea3ef's interpolated anchor it then acted as a regex wildcard,
#       distorting an unrelated branch name into a false match. It also proves
#       the concrete, reachable case: that anchor recreated the exact failure
#       mode REV-3 fixes (a real unit branch dropped, so a re-run would invent a
#       second branch and open a second PR) whenever a task's title-derived slug
#       was literally `gates-<hex only>`.
#
#       BOTH RESIDUALS ARE NOW CLOSED, and this section asserts that rather than
#       logging it. Each one is still reproduced first against the anchor as
#       68ea3ef shipped it — the pattern is read out of that commit's bytes, not
#       retyped — and then re-decided by EXECUTING the shipped HEAD block under
#       bash and zsh. HEAD builds no pattern from either value: it strips the
#       literal `<prefix><TASK>-gates-` and requires what remains to be a sha7
#       (exactly 7 lowercase hex, the length the publication block emits), so an
#       8-hex slug like `gates-deadbeef` is correctly kept as the unit branch and
#       a `.` in an epic-child id is a literal. The stale note in
#       .quetrex/qa-report.json's not_verified[] is pinned to 68ea3ef and
#       describes the state of the code at that sha.
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

# --------------------------------------------------------------------------
# (B) The two residuals QA recorded against the 68ea3ef anchor, now CLOSED.
#
# Both are still proven to reproduce — but against the anchor as 68ea3ef
# actually shipped it, read out of that commit's bytes rather than retyped
# here, so the fail-first cannot drift away from the code it indicts. Each is
# then re-asserted against the SHIPPED HEAD, which decides the same question
# with a literal prefix strip and a sha7 shape check instead of a pattern.
# --------------------------------------------------------------------------
ANCHOR_SHA="68ea3ef"
ANCHOR_PATTERN=""
if git -C "$ROOT" cat-file -e "$ANCHOR_SHA^{commit}" 2>/dev/null; then
  # The anchor's own text, lifted from the shipped line: grep -v -E "<pattern>"
  ANCHOR_PATTERN="$(git -C "$ROOT" show "$ANCHOR_SHA:.claude/commands/task-build.md" \
    | sed -n 's/.*grep -v -E "\([^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$ANCHOR_PATTERN" ]; then
  pass "(B) read the anchor pattern out of $ANCHOR_SHA's shipped bytes: $ANCHOR_PATTERN"
else
  fail "(B) could not read the anchor pattern from $ANCHOR_SHA — the fail-first below would prove nothing"
fi

# Residual 1 — the concrete, reachable collision: a task whose title slugifies
# to exactly `gates-<hex only>` produces a REAL unit branch that the anchor
# drops. Same failure class REV-3 fixes (discovery returns empty → fallback
# invents a second branch → a re-run opens a second PR), just narrower than the
# unanchored bug (which fired on ANY `gates` between hyphens).
BRANCH_PREFIX="claude/"; TASK_ID="SMA-9"
PATTERN="$(printf '%s' "$ANCHOR_PATTERN" | sed -e "s#\${BRANCH_PREFIX}#$BRANCH_PREFIX#" -e "s#\${TASK_ID}#$TASK_ID#")"
COLLIDING_UNIT_BRANCH="${BRANCH_PREFIX}${TASK_ID}-gates-deadbeef"   # a REAL unit branch: slug = "gates-deadbeef"
if [ -n "$PATTERN" ] && printf '%s' "$COLLIDING_UNIT_BRANCH" | grep -qE "$PATTERN"; then
  pass "(B) FAIL-FIRST reproduces: $ANCHOR_SHA's anchor matched the real unit branch $COLLIDING_UNIT_BRANCH (slug 'gates-deadbeef') and would have excluded it as evidence"
else
  fail "(B) expected the hex-slug collision to reproduce against $ANCHOR_SHA — the baseline is wrong, so the HEAD assertion below proves nothing"
fi

# Residual 2 — the dot-as-wildcard case: TASK_ID carrying '.' (a valid
# epic-child id) makes the anchor match a branch with no literal '.' in it.
TASK_ID_DOT="SMA-1.2"
PATTERN_DOT="$(printf '%s' "$ANCHOR_PATTERN" | sed -e "s#\${BRANCH_PREFIX}#$BRANCH_PREFIX#" -e "s#\${TASK_ID}#$TASK_ID_DOT#")"
WILDCARD_BRANCH="${BRANCH_PREFIX}SMA-1X2-gates-deadbeef"   # 'X' where the '.' is, not a literal dot
if [ -n "$PATTERN_DOT" ] && printf '%s' "$WILDCARD_BRANCH" | grep -qE "$PATTERN_DOT"; then
  pass "(B) FAIL-FIRST reproduces: '.' in a valid task id was an unescaped regex wildcard in $ANCHOR_SHA's anchor — it matched '$WILDCARD_BRANCH' though no literal '.' is present"
else
  fail "(B) expected the dot-as-wildcard case to reproduce against $ANCHOR_SHA — the baseline is wrong, so the HEAD assertion below proves nothing"
fi

# --------------------------------------------------------------------------
# (B) CLOSED at HEAD — the shipped discovery block, EXECUTED under bash and zsh.
# Independent of test/task-build-never-local.test.sh section (q): the block is
# re-extracted here by its own markers and driven through a stubbed ref listing,
# so both residuals are decided by running the shipped bytes, not by reading them.
# --------------------------------------------------------------------------
awk '
  /UNIT_BRANCH=/ && /ls-remote/ { inb = 1 }
  inb { print }
  inb && /head -1/ { exit }
' "$COMMAND" > "$WORK/disc_head.sh"

if grep -q 'ls-remote' "$WORK/disc_head.sh"; then
  if grep -qE 'grep -v -?E' "$WORK/disc_head.sh"; then
    fail "(B) HEAD's discovery block still interpolates BRANCH_PREFIX/TASK_ID into a grep -E pattern"
  else
    pass "(B) HEAD's discovery block builds no regex out of BRANCH_PREFIX or TASK_ID"
  fi

  # <shell> <outdir> <prefix> <task> <ref>... -> the branch discovery selects
  head_disc() {
    local sh="$1" out="$2" pfx="$3" tsk="$4"; shift 4
    local b
    rm -rf "$out"; mkdir -p "$out/bin"
    : > "$out/refs.txt"
    for b in "$@"; do printf '%s\trefs/heads/%s\n' "0000000000000000000000000000000000000000" "$b" >> "$out/refs.txt"; done
    printf '#!/bin/sh\ncat "%s"\n' "$out/refs.txt" > "$out/bin/git"
    chmod +x "$out/bin/git"
    {
      printf '%s\n' 'REPO_ROOT="$1"; BRANCH_PREFIX="$2"; TASK_ID="$3"'
      cat "$WORK/disc_head.sh"
      printf '%s\n' 'printf "%s\n" "$UNIT_BRANCH"'
    } > "$out/drive.sh"
    PATH="$out/bin:$PATH" "$sh" "$out/drive.sh" "$out" "$pfx" "$tsk" 2>/dev/null
  }

  for SH in bash zsh; do
    command -v "$SH" >/dev/null 2>&1 || { echo "SKIP: $SH not installed — (B) HEAD cases"; continue; }

    GOT="$(head_disc "$SH" "$WORK/b1-$SH" "claude/" "SMA-9" \
        "claude/SMA-9-gates-a1b2c3d" "$COLLIDING_UNIT_BRANCH")"
    if [ "$GOT" = "$COLLIDING_UNIT_BRANCH" ]; then
      pass "$SH: (B) CLOSED: HEAD keeps the real unit branch $COLLIDING_UNIT_BRANCH and excludes the sha7 evidence ref beside it"
    else
      fail "$SH: (B) HEAD still mishandles the 'gates-<hex>' slug: got '${GOT:-<empty>}', want $COLLIDING_UNIT_BRANCH"
    fi

    # The '.' is STILL a literal, and the EXPECTATION INVERTED when discovery
    # gained its literal-prefix guard (the ls-remote pattern is a TAIL match, so
    # refs in foreign namespaces reached this filter). claude/SMA-1X2-gates-deadbee
    # is not a branch for task SMA-1.2 at all, so it is now correctly DROPPED —
    # and only a LITERAL dot can drop it. A regex-era '.' wildcard MATCHES the 'X'
    # and keeps the ref, which is precisely the 68ea3ef fail-first reproduced
    # above. Both directions are asserted: this reject, and the literal-dot ACCEPT
    # immediately below, so the pair still discriminates.
    GOT="$(head_disc "$SH" "$WORK/b2-$SH" "claude/" "$TASK_ID_DOT" \
        "claude/SMA-1X2-gates-deadbee")"
    if [ -z "$GOT" ]; then
      pass "$SH: (B) CLOSED: with task id $TASK_ID_DOT the '.' is a literal, so claude/SMA-1X2-gates-deadbee fails the literal-prefix guard and is dropped"
    else
      fail "$SH: (B) HEAD still treats '.' as a wildcard: got '$GOT' — the '.' matched an 'X' and a foreign task's ref was adopted"
    fi

    # ACCEPT side of that pair: a candidate carrying the real dot IS selected, so
    # the reject above cannot be passing because SMA-1.2 discovers nothing at all.
    GOT="$(head_disc "$SH" "$WORK/b2b-$SH" "claude/" "$TASK_ID_DOT" \
        "claude/SMA-1.2-real-work")"
    if [ "$GOT" = "claude/SMA-1.2-real-work" ]; then
      pass "$SH: (B) the literal-dot unit branch claude/SMA-1.2-real-work IS selected for $TASK_ID_DOT"
    else
      fail "$SH: (B) literal-dot accept: got '${GOT:-<empty>}', want claude/SMA-1.2-real-work"
    fi

    # And a foreign-namespace ref that the TAIL-matching ls-remote glob really does
    # return is never selected over the legitimate unit branch.
    GOT="$(head_disc "$SH" "$WORK/b2c-$SH" "claude/" "SMA-9" \
        "backup/claude/SMA-9-old" "claude/SMA-9-real-unit")"
    if [ "$GOT" = "claude/SMA-9-real-unit" ]; then
      pass "$SH: (B) a foreign-namespace ref (backup/claude/SMA-9-old) never wins over the real unit branch"
    else
      fail "$SH: (B) foreign-namespace ref selected: got '${GOT:-<empty>}', want claude/SMA-9-real-unit"
    fi

    GOT="$(head_disc "$SH" "$WORK/b3-$SH" "claude/" "$TASK_ID_DOT" \
        "claude/SMA-1.2-gates-deadbee")"
    if [ -z "$GOT" ]; then
      pass "$SH: (B) HEAD still excludes a genuine sha7 evidence ref for an epic-child id (claude/SMA-1.2-gates-deadbee)"
    else
      fail "$SH: (B) HEAD selected an evidence ref as the unit branch: '$GOT'"
    fi
  done
else
  fail "(B) could not extract HEAD's discovery block from $COMMAND"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "task-build-qa-rev3.test.sh: all checks passed"
else
  echo "task-build-qa-rev3.test.sh: FAILURES above"
fi
exit "$FAIL"
