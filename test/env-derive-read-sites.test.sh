#!/usr/bin/env bash
# test/env-derive-read-sites.test.sh — a requiredEnv READ SITE must be SOURCE,
# never prose; and `propose` must not re-ask about a name already answered.
#
# Run: bash test/env-derive-read-sites.test.sh
#
# THE DEFECT (operator evidence, re-running /quetrex-setup:init on an
# already-linked repo). The requiredEnv step offered 14 candidates and asked
# a pairing question per candidate, including:
#     NODE_ENV      — read at .issue/plan-SMA-197.md:29
#     DATABASE_URL  — read at .claude/agent-memory/reviewer/playbook_client_bundle_db_leak.md:13
# Both "read sites" are MARKDOWN that quotes `process.env.X` — not a read any
# verify command executes. quetrex-env-derive's read-site search grepped
# every tracked file (`git grep ... HEAD -- . :!.quetrex`), so any prose
# that mentions the token counted as evidence, and the operator was asked to
# pair chain commands with locations he could not act on.
#
# THE FIX: the read-site search excludes *.md, *.mdx, *.txt, *.rst and the
# trees .claude/**, .issue/**, .issues/**, docs/**, .github/** — applied
# IDENTICALLY to the committed (git grep) and working-tree (ls-files)
# searches, which the tool's own header says must share one path resolution.
#
# FAIL-FIRST, MECHANICALLY: AC1 runs the SAME fixture against the tool as it
# was at 7333ab07abecf95c3e699c528eb0abae79e078a6 (a fixed sha, never `main`)
# and asserts the OLD tool DOES list the prose-only name — proving this file
# detects the defect and is not vacuous.
#
#   AC1  fixture: committed .env.example declares FOO_A and FOO_B; FOO_A is
#        read fallback-less ONLY in notes/plan.md; FOO_B in src/x.ts.
#        NEW tool: propose/scan list FOO_B only. OLD tool: lists both.
#   AC2  every excluded tree/extension: a name read ONLY under .claude/,
#        .issue/, .issues/, docs/, .github/, or in .mdx/.txt/.rst is NOT a
#        candidate — while the same name read in src/ IS.
#   AC3  parity: the working-tree liveness hint applies the same exclusion
#        (an uncommitted prose-only read produces no hint; an uncommitted
#        source read does).
#   AC4  `propose` emits `.outstanding[]` = candidates minus names already in
#        requiredEnv or requiredEnvDeclined, so init 5c never re-asks; and
#        `.candidates[]` is still the full committed set (declare validates
#        against it).

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$TOOLROOT/plugins/quetrex-setup/bin/quetrex-env-derive"
BASELINE_SHA="7333ab07abecf95c3e699c528eb0abae79e078a6"

if [ ! -f "$TOOL" ]; then echo "FAIL: tool not found at $TOOL"; exit 1; fi
command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed — quetrex-env-derive requires node"; exit 0; }
command -v jq >/dev/null 2>&1   || { echo "SKIP: jq not installed — this suite reads propose JSON with jq"; exit 0; }

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/env-derive-read-sites.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

git_init_repo() {  # git_init_repo <path>
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Fixture"
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "${2:-fixture}"; }

# --- AC1 fixture --------------------------------------------------------------
R1="$TMPROOT/ac1"; git_init_repo "$R1"
mkdir -p "$R1/notes" "$R1/src"
printf 'FOO_A=\nFOO_B=\n' > "$R1/.env.example"
printf '# plan\n\nThe app reads process.env.FOO_A at startup.\n' > "$R1/notes/plan.md"
printf 'export const b = process.env.FOO_B;\n' > "$R1/src/x.ts"
commit_all "$R1"

NEW_NAMES="$("$TOOL" propose "$R1" 2>/dev/null | jq -r '.candidates[].name' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$NEW_NAMES" = "FOO_B" ]; then
  pass "AC1: propose lists FOO_B only — a name read only in notes/plan.md is not a candidate"
else
  fail "AC1: propose candidates = '$NEW_NAMES' (expected exactly 'FOO_B')"
fi
SCAN_NAMES="$("$TOOL" scan "$R1" 2>/dev/null | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$SCAN_NAMES" = "FOO_B" ]; then
  pass "AC1: scan agrees (FOO_B only, read_at src/x.ts)"
else
  fail "AC1: scan names = '$SCAN_NAMES' (expected exactly 'FOO_B')"
fi

# FAIL-FIRST: the pre-change tool, at a FIXED sha, lists the prose-only name.
BASELINE="$TMPROOT/baseline-env-derive"
if ! git -C "$TOOLROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
  git -C "$TOOLROOT" fetch --quiet --depth=1 origin "$BASELINE_SHA" 2>/dev/null || true
fi
if git -C "$TOOLROOT" show "${BASELINE_SHA}:plugins/quetrex-setup/bin/quetrex-env-derive" > "$BASELINE" 2>/dev/null && [ -s "$BASELINE" ]; then
  chmod +x "$BASELINE"
  OLD_NAMES="$(bash "$BASELINE" propose "$R1" 2>/dev/null | jq -r '.candidates[].name' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$OLD_NAMES" = "FOO_A FOO_B" ]; then
    pass "AC1 FAIL-FIRST: the pre-change tool ($BASELINE_SHA) lists FOO_A from notes/plan.md — this test fails against it, so it measures the fix"
  else
    fail "AC1 FAIL-FIRST: expected the pre-change tool to list 'FOO_A FOO_B' (it demonstrably did when this test was authored); got '$OLD_NAMES' — the fail-first proof is broken, not the fix"
  fi
else
  fail "AC1 FAIL-FIRST: baseline $BASELINE_SHA:plugins/quetrex-setup/bin/quetrex-env-derive is not reachable even after a depth-1 fetch — refusing to report a pass having compared against nothing"
fi

# --- AC2: every excluded location, one name each; a src/ read still counts ---
R2="$TMPROOT/ac2"; git_init_repo "$R2"
mkdir -p "$R2/.claude/agent-memory" "$R2/.issue" "$R2/.issues" "$R2/docs" "$R2/.github/workflows" "$R2/src" "$R2/guide"
{
  printf 'IN_CLAUDE=\nIN_ISSUE=\nIN_ISSUES=\nIN_DOCS=\nIN_GITHUB=\nIN_MDX=\nIN_TXT=\nIN_RST=\nIN_SRC=\n'
} > "$R2/.env.example"
printf 'const a = process.env.IN_CLAUDE;\n'      > "$R2/.claude/agent-memory/note.js"
printf 'const a = process.env.IN_ISSUE;\n'       > "$R2/.issue/plan.js"
printf 'const a = process.env.IN_ISSUES;\n'      > "$R2/.issues/plan.js"
printf 'const a = process.env.IN_DOCS;\n'        > "$R2/docs/setup.js"
printf 'run: echo process.env.IN_GITHUB\n'       > "$R2/.github/workflows/x.yml"
printf 'reads process.env.IN_MDX\n'              > "$R2/guide/page.mdx"
printf 'reads process.env.IN_TXT\n'              > "$R2/guide/notes.txt"
printf 'reads process.env.IN_RST\n'              > "$R2/guide/index.rst"
printf 'export const s = process.env.IN_SRC;\n'  > "$R2/src/app.ts"
commit_all "$R2"
AC2_NAMES="$("$TOOL" propose "$R2" 2>/dev/null | jq -r '.candidates[].name' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$AC2_NAMES" = "IN_SRC" ]; then
  pass "AC2: .claude/**, .issue/**, .issues/**, docs/**, .github/**, *.mdx, *.txt, *.rst are all excluded as read sites; src/app.ts still counts"
else
  fail "AC2: propose candidates = '$AC2_NAMES' (expected exactly 'IN_SRC')"
fi

# --- AC3: the working-tree liveness hint shares the exclusion ----------------
R3="$TMPROOT/ac3"; git_init_repo "$R3"
mkdir -p "$R3/src" "$R3/notes"
printf 'BASE=\n' > "$R3/.env.example"
printf 'const b = process.env.BASE;\n' > "$R3/src/base.js"
commit_all "$R3"
# Uncommitted: two new declared names, one read only in prose, one in source.
printf 'BASE=\nPROSE_ONLY=\nSRC_NEW=\n' > "$R3/.env.example"
printf 'mentions process.env.PROSE_ONLY\n' > "$R3/notes/draft.md"
printf 'const n = process.env.SRC_NEW;\n'  > "$R3/src/new.js"
HINTS="$("$TOOL" propose "$R3" 2>&1 >/dev/null)"
if printf '%s\n' "$HINTS" | grep -q '^SRC_NEW looks like a candidate' && ! printf '%s\n' "$HINTS" | grep -q 'PROSE_ONLY'; then
  pass "AC3: the working-tree hint names the uncommitted source read (SRC_NEW) and NOT the prose-only one (PROSE_ONLY) — same exclusion, both searches"
else
  fail "AC3: working-tree hints were: $(printf '%s' "$HINTS" | tr '\n' '|')"
fi

# --- AC4: propose.outstanding excludes declared AND declined names -----------
R4="$TMPROOT/ac4"; git_init_repo "$R4"
mkdir -p "$R4/src" "$R4/.quetrex"
printf 'PAIRED=\nDECLINED=\nOPEN=\n' > "$R4/.env.example"
printf 'const p = process.env.PAIRED; const d = process.env.DECLINED; const o = process.env.OPEN;\n' > "$R4/src/a.js"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({verify:["true"],requiredEnv:{"true":["PAIRED"]},requiredEnvDeclined:["DECLINED"]},null,2)+"\n")' "$R4/.quetrex/verify.json"
commit_all "$R4"
P4="$("$TOOL" propose "$R4" 2>/dev/null)"
C4="$(printf '%s' "$P4" | jq -r '.candidates[].name' | sort | tr '\n' ' ' | sed 's/ $//')"
O4="$(printf '%s' "$P4" | jq -r '.outstanding[].name' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$C4" = "DECLINED OPEN PAIRED" ] && [ "$O4" = "OPEN" ]; then
  pass "AC4: .candidates is the full committed set (DECLINED OPEN PAIRED) while .outstanding is OPEN only — a paired or declined name is never re-asked"
else
  fail "AC4: candidates='$C4' outstanding='$O4' (expected 'DECLINED OPEN PAIRED' / 'OPEN')"
fi
# Answer the last one too: outstanding must go empty (the re-run asks nothing).
"$TOOL" declare "$R4" --decline OPEN >/dev/null 2>&1
commit_all "$R4" "decline OPEN"
O4B="$("$TOOL" propose "$R4" 2>/dev/null | jq -r '.outstanding | length')"
if [ "$O4B" = "0" ]; then
  pass "AC4: once every candidate is paired or declined, .outstanding is empty — init 5c has nothing to ask"
else
  fail "AC4: expected 0 outstanding after declining OPEN, got $O4B"
fi
INIT_MD="$TOOLROOT/plugins/quetrex-setup/commands/init.md"
if grep -q 'zero `.outstanding`' "$INIT_MD" && grep -q '`.outstanding\[\].name`' "$INIT_MD"; then
  pass "AC4: init.md step 5c asks about .outstanding[] and skips on zero outstanding"
else
  fail "AC4: init.md step 5c does not key its question on .outstanding[]"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "env-derive-read-sites.test.sh: all checks passed"
else
  echo "env-derive-read-sites.test.sh: FAILURES above"
fi
exit "$FAIL"
