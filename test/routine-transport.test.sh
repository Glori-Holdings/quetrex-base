#!/usr/bin/env bash
# test/routine-transport.test.sh — EXECUTES the gate-evidence publication block
# out of .claude/lib/cloud-build-routine.md against real git repositories.
#
# Run: bash test/routine-transport.test.sh
#
# WHY THIS FILE EXISTS. The cloud routine is the ONLY supported execution route,
# and everything the operator's merge gate knows about a cloud build arrives on
# one branch that this block pushes. Two defects lived in that block for the
# life of the feature, and both were invisible to every existing check because
# the block is prose in a markdown file that nothing ever ran:
#
#   (1) It published five artifacts and NOT `.quetrex/plan/<TASK>.json` /
#       `.quetrex/state.json`. merge-gate.sh resolves the plan from those two
#       paths, so on every cloud build PLAN="" — GATE 5 (file ownership) skipped
#       entirely ("NO PLAN -> SKIP, NOT FAIL") and a plan that set
#       security_review_required:true had literally no effect at the merge
#       boundary. Both of the strongest artifact gates were dead on the only
#       route that exists.
#   (2) It staged the artifacts with `2>/dev/null || true`, so a staging failure
#       published a gates branch that LOOKS complete while the evidence is
#       silently missing — the operator's gate then reads "no evidence" and the
#       failure surfaces as a mystery denial, or worse, as a skipped gate.
#
# So this file does not grep the markdown for reassuring words. It EXTRACTS the
# block between the two sentinel comments, substitutes the routine's
# placeholders exactly as task-build.md does, and RUNS it in a real repo with a
# real bare remote — then asks the REMOTE what actually landed. Three vacuous
# grep-only assertions have already been found in this repo; a grep over prose
# cannot fail when the behaviour is broken.
#
# The last section runs the PRE-FIX block (inlined verbatim) against the same
# fixtures as a permanent fail-first control: it proves each assertion above
# would go red on the old text, so none of them is vacuously green.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTINE="$REPO_ROOT/.claude/lib/cloud-build-routine.md"

if [ ! -f "$ROUTINE" ]; then
  echo "NOT OK - routine-transport: .claude/lib/cloud-build-routine.md not found at $ROUTINE"
  echo "routine-transport.test.sh: FAILURES above"
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — this file publishes to real git repositories"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — the publication block writes its artifacts with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

# A task id unique to this process: the block copies the approved plan from the
# literal path /tmp/plan-<TASK>.json (that is the routine's own contract with
# step 2), so two concurrent runs must not collide. Cleaned up on exit.
TASK="QXT${$}"
PREFIX="claude/"
GATES_BRANCH="${PREFIX}${TASK}-gates"
PLAN_TMP="/tmp/plan-${TASK}.json"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-routine-transport.XXXXXX")"
cleanup() { rm -rf "$WORK"; rm -f "$PLAN_TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Extract the publication block from the markdown
# ---------------------------------------------------------------------------
START_RE='^[[:space:]]*# >>> QUETREX GATE PUBLICATION >>>[[:space:]]*$'
END_RE='^[[:space:]]*# <<< QUETREX GATE PUBLICATION <<<[[:space:]]*$'

n_start=$(grep -c -E "$START_RE" "$ROUTINE")
n_end=$(grep -c -E "$END_RE" "$ROUTINE")
if [ "$n_start" -eq 1 ] && [ "$n_end" -eq 1 ]; then
  pass "the routine carries exactly one publication block, delimited by the sentinels the extractor keys on"
else
  fail "expected exactly 1 start and 1 end sentinel in cloud-build-routine.md, found start=$n_start end=$n_end — the block cannot be extracted, so nothing below can be executed"
  echo "routine-transport.test.sh: FAILURES above"
  exit 1
fi

RAW="$WORK/block.raw.sh"
awk -v s="$START_RE" -v e="$END_RE" '
  $0 ~ s { inb = 1; next }
  $0 ~ e { inb = 0; next }
  inb    { print }
' "$ROUTINE" > "$RAW"

# The block is indented 4 spaces inside the routine prompt; de-indent it.
BLOCK="$WORK/block.sh"
sed 's/^    //' "$RAW" \
  | sed -e "s|{{TASK}}|$TASK|g" -e "s|{{BRANCH_PREFIX}}|$PREFIX|g" > "$BLOCK"

BLOCK_LINES=$(grep -c '' "$BLOCK")
if [ "$BLOCK_LINES" -ge 10 ]; then
  pass "extracted a non-trivial publication block ($BLOCK_LINES lines)"
else
  fail "extracted block is only $BLOCK_LINES lines — the sentinels moved or the block was gutted"
fi

if ! grep -q '{{' "$BLOCK"; then
  pass "every placeholder in the block is substitutable — no {{...}} survives substitution"
else
  fail "unsubstituted placeholder left in the block: $(grep -o '{{[A-Z_]*}}' "$BLOCK" | sort -u | tr '\n' ' ') — the routine would paste literal braces into a shell"
fi

if bash -n "$BLOCK" 2>"$WORK/syntax.err"; then
  pass "the extracted block is syntactically valid shell (bash -n)"
else
  fail "the extracted block does not parse as shell: $(cat "$WORK/syntax.err")"
  echo "routine-transport.test.sh: FAILURES above"
  exit 1
fi

# Secondary to the executed proof below, but cheap and specific: the exact
# swallow that made a failed publication silent must not come back. Comment
# lines are stripped first — the block's own comment NAMES the anti-pattern to
# keep it from being reintroduced, and a check that cannot tell a warning about
# a defect apart from the defect is a check that punishes documenting it.
if ! grep -v '^[[:space:]]*#' "$BLOCK" | grep -q '2>/dev/null || true'; then
  pass "no '2>/dev/null || true' swallow remains in the publication block"
else
  fail "the publication block still swallows staging failures with '2>/dev/null || true'"
fi

# ---------------------------------------------------------------------------
# 2. Fixtures — a real bare remote plus a working clone standing in for the
#    cloud sandbox at the moment step 5b runs.
# ---------------------------------------------------------------------------
PLAN_JSON='{
  "task": "'"$TASK"'",
  "base_sha": "0000000000000000000000000000000000000000",
  "security_review_required": true,
  "ownership": { "src/build.js": "ws1" },
  "workstreams": [ { "id": "ws1", "owns": ["src/build.js", "test/build.test.js"] } ]
}'

new_fixture() {                       # new_fixture <name> -> echoes the work path
  local name="$1"
  local bare="$WORK/$name.git" work="$WORK/$name"
  git init -q --bare "$bare"
  git init -q -b main "$work"
  git -C "$work" config user.email t@example.com
  git -C "$work" config user.name  Tester
  printf '.quetrex/\n' > "$work/.gitignore"
  mkdir -p "$work/src"
  printf 'console.log(1);\n' > "$work/src/build.js"
  git -C "$work" add -A
  git -C "$work" commit -q -m "seed"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q origin main

  # The gate artifacts as the stages leave them in the sandbox. .quetrex/ is
  # git-ignored above on purpose: without `git add -f` NONE of this can land,
  # which is precisely the transport the block exists to perform.
  mkdir -p "$work/.quetrex"
  printf '{"verdict":"AUTO_MERGE"}\n'          > "$work/.quetrex/review-verdict.json"
  printf '{"cmd":"npm test","exit":0}\n'       > "$work/.quetrex/verify-ledger.jsonl"
  printf '{"green":true}\n'                    > "$work/.quetrex/qa-report.json"
  printf '{"findings":[]}\n'                   > "$work/.quetrex/security-findings.json"
  echo "$work"
}

# The approved plan, as step 2 of the routine left it on disk.
printf '%s\n' "$PLAN_JSON" > "$PLAN_TMP"

run_block() {                         # run_block <script> <workdir> -> rc, sets OUT
  local script="$1" work="$2" rc
  OUT="$( cd "$work" && bash "$script" 2>&1 )"
  rc=$?
  return $rc
}

on_branch() {                         # on_branch <name> <path> -> 0 if present on remote
  git -C "$WORK/$1.git" show "$GATES_BRANCH:$2" >/dev/null 2>&1
}
show_on_branch() {                    # show_on_branch <name> <path>
  git -C "$WORK/$1.git" show "$GATES_BRANCH:$2" 2>/dev/null
}
branch_exists() {                     # branch_exists <name>
  git -C "$WORK/$1.git" rev-parse --verify --quiet "refs/heads/$GATES_BRANCH" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 3. HAPPY PATH — everything present. The two new files must land.
# ---------------------------------------------------------------------------
W1="$(new_fixture happy)"
HEAD1="$(git -C "$W1" rev-parse HEAD)"
if run_block "$BLOCK" "$W1"; then
  pass "publication block exits 0 with every artifact present"
else
  fail "publication block failed on the happy path: $OUT"
fi

if on_branch happy ".quetrex/plan/$TASK.json"; then
  pass "GAP 7 (a): .quetrex/plan/$TASK.json is published on $GATES_BRANCH — merge-gate can resolve the plan for a cloud build"
else
  fail "GAP 7 (a): .quetrex/plan/$TASK.json is NOT on $GATES_BRANCH — GATE 5 and the plan's security_review_required stay dead"
fi

if on_branch happy ".quetrex/state.json"; then
  pass "GAP 7 (b): .quetrex/state.json is published on $GATES_BRANCH — merge-gate can tell WHICH plan governs the merge"
else
  fail "GAP 7 (b): .quetrex/state.json is NOT on $GATES_BRANCH"
fi

PUBLISHED_PLAN="$(show_on_branch happy ".quetrex/plan/$TASK.json")"
if [ "$PUBLISHED_PLAN" = "$(cat "$PLAN_TMP")" ]; then
  pass "the published plan is byte-identical to the approved plan (not summarised or re-written)"
else
  fail "the published plan differs from the approved plan the operator signed off"
fi

# Prove the published plan is actually USABLE by the gate: the two fields
# merge-gate.sh reads out of it survive the trip.
PLAN_SEC="$(printf '%s' "$PUBLISHED_PLAN" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).security_review_required))}catch(e){process.stdout.write("PARSE_ERROR")}})')"
PLAN_OWN="$(printf '%s' "$PUBLISHED_PLAN" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(((JSON.parse(s).workstreams||[])[0]||{}).owns.join(","))}catch(e){process.stdout.write("PARSE_ERROR")}})')"
if [ "$PLAN_SEC" = "true" ] && [ "$PLAN_OWN" = "src/build.js,test/build.test.js" ]; then
  pass "the published plan parses and still carries security_review_required=true and the ownership map merge-gate reads"
else
  fail "the published plan does not carry the fields the gate needs (security_review_required='$PLAN_SEC', owns='$PLAN_OWN')"
fi

PUBLISHED_TASK="$(show_on_branch happy ".quetrex/state.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).task))}catch(e){process.stdout.write("PARSE_ERROR")}})')"
if [ "$PUBLISHED_TASK" = "$TASK" ]; then
  pass "the published state.json names the task ($TASK), which is how GATE 5 picks the right plan"
else
  fail "the published state.json does not name the task: got '$PUBLISHED_TASK'"
fi

MISSING_OLD=""
for f in verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json gates-head; do
  on_branch happy ".quetrex/$f" || MISSING_OLD="$MISSING_OLD $f"
done
if [ -z "$MISSING_OLD" ]; then
  pass "the five artifacts /quetrex:merge already fetches still land — the new files were added, not swapped in"
else
  fail "artifacts missing from $GATES_BRANCH:$MISSING_OLD"
fi

if [ "$(show_on_branch happy .quetrex/gates-head | tr -d '[:space:]')" = "$HEAD1" ]; then
  pass "gates-head pins the exact commit the PR merges"
else
  fail "gates-head does not match HEAD ($HEAD1)"
fi

# ---------------------------------------------------------------------------
# 4. state.json the pipeline already seeded must survive untouched
# ---------------------------------------------------------------------------
W2="$(new_fixture seeded)"
printf '{"task":"%s","base_branch":"main","branch":"claude/%s","review_iter":2}\n' "$TASK" "$TASK" \
  > "$W2/.quetrex/state.json"
if run_block "$BLOCK" "$W2"; then
  pass "publication block exits 0 when the pipeline already seeded state.json"
else
  fail "publication block failed with a pre-seeded state.json: $OUT"
fi
SEEDED_ITER="$(show_on_branch seeded .quetrex/state.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(`${j.task}/${j.review_iter}/${j.branch}`)}catch(e){process.stdout.write("PARSE_ERROR")}})')"
if [ "$SEEDED_ITER" = "$TASK/2/claude/$TASK" ]; then
  pass "a pre-seeded state.json is published as the stages wrote it (review_iter and branch preserved)"
else
  fail "the block rewrote a state.json the pipeline owned: got '$SEEDED_ITER'"
fi

# ---------------------------------------------------------------------------
# 5. An OPTIONAL artifact may legitimately be absent
# ---------------------------------------------------------------------------
W3="$(new_fixture optional)"
rm -f "$W3/.quetrex/security-findings.json" "$W3/.quetrex/qa-report.json"
if run_block "$BLOCK" "$W3"; then
  pass "a neutral diff with no security-findings.json / qa-report.json still publishes"
else
  fail "the block wrongly refused a legitimate run with no optional artifacts: $OUT"
fi
if ! on_branch optional .quetrex/security-findings.json && on_branch optional ".quetrex/plan/$TASK.json"; then
  pass "the absent optional artifact is simply not published, while the required ones are"
else
  fail "optional-artifact handling is wrong on $GATES_BRANCH"
fi

# ---------------------------------------------------------------------------
# 6. FAIL LOUDLY — a missing REQUIRED artifact must stop and push NOTHING
# ---------------------------------------------------------------------------
loud_case() {                         # loud_case <name> <setup-cmd...>
  local name="$1"; shift
  local w
  w="$(new_fixture "$name")"
  "$@" "$w"
  if run_block "$BLOCK" "$w"; then
    fail "missing required artifact ($name): the block exited 0 — a silent publication is exactly the defect"
  else
    if printf '%s' "$OUT" | grep -q 'transport_failure'; then
      pass "missing required artifact ($name): the block exits non-zero and reports transport_failure"
    else
      fail "missing required artifact ($name): non-zero but no transport_failure message — the operator gets no reason. Output: $OUT"
    fi
  fi
  if branch_exists "$name"; then
    fail "missing required artifact ($name): $GATES_BRANCH was pushed anyway — a gates branch that looks complete but is not"
  else
    pass "missing required artifact ($name): nothing was pushed to the remote"
  fi
}

rm_verdict() { rm -f "$1/.quetrex/review-verdict.json"; }
rm_ledger()  { rm -f "$1/.quetrex/verify-ledger.jsonl"; }
rm_plan()    { rm -f "$PLAN_TMP"; }

loud_case noverdict rm_verdict
loud_case noledger  rm_ledger
loud_case noplan    rm_plan
printf '%s\n' "$PLAN_JSON" > "$PLAN_TMP"   # restore for the control section

# ---------------------------------------------------------------------------
# 7. FAIL-FIRST CONTROL — the pre-fix block, run verbatim against the same
#    fixtures. Every assertion above must go RED on this text, or it proves
#    nothing about the fix.
# ---------------------------------------------------------------------------
LEGACY="$WORK/legacy.sh"
cat > "$LEGACY" <<LEGACY_EOF
HEAD_SHA="\$(git rev-parse HEAD)"
GATES_BRANCH="${PREFIX}${TASK}-gates"
node -e 'const fs=require("fs");fs.writeFileSync(".quetrex/gates-head",process.argv[1]+"\n")' "\$HEAD_SHA"
git checkout -q -b "\$GATES_BRANCH"
git add -f .quetrex/verify-ledger.jsonl .quetrex/review-verdict.json \\
           .quetrex/qa-report.json .quetrex/security-findings.json \\
           .quetrex/gates-head 2>/dev/null || true
git -c user.name='quetrex-bot' -c user.email='quetrex-bot@users.noreply.github.com' \\
  commit -q -m "chore(gates): ${TASK} gate artifacts for \$HEAD_SHA"
git push -f origin "\$GATES_BRANCH"
LEGACY_EOF

L1="$(new_fixture legacy-happy)"
run_block "$LEGACY" "$L1" || true
if ! on_branch legacy-happy ".quetrex/plan/$TASK.json" && ! on_branch legacy-happy .quetrex/state.json; then
  pass "CONTROL: the pre-fix block published NEITHER the plan NOR state.json — the two happy-path assertions above were genuinely red before this change"
else
  fail "CONTROL is broken: the pre-fix block appears to publish the plan/state, so the happy-path assertions prove nothing"
fi
if on_branch legacy-happy .quetrex/review-verdict.json; then
  pass "CONTROL: the pre-fix block did publish the original five, so the control differs from the fix in exactly the intended way"
else
  fail "CONTROL is broken: the pre-fix block did not publish review-verdict.json either — the fixture, not the change, is being measured"
fi

L2="$(new_fixture legacy-noverdict)"
rm -f "$L2/.quetrex/review-verdict.json"
if run_block "$LEGACY" "$L2"; then
  LEGACY_RC=0
else
  LEGACY_RC=$?
fi
if [ "$LEGACY_RC" -eq 0 ] && branch_exists legacy-noverdict; then
  pass "CONTROL: with a required artifact missing the pre-fix block exited 0 AND pushed the branch — the silent publication the loud assertions now catch"
else
  fail "CONTROL is broken: the pre-fix block already failed loudly here (rc=$LEGACY_RC), so section 6 proves nothing"
fi
if ! on_branch legacy-noverdict .quetrex/review-verdict.json; then
  pass "CONTROL: that silently-pushed legacy branch carries no review-verdict.json — evidence that never arrives, with no error anywhere"
else
  fail "CONTROL is broken: review-verdict.json is on the legacy branch despite being deleted"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "routine-transport.test.sh: all checks passed"
  exit 0
else
  echo "routine-transport.test.sh: FAILURES above"
  exit 1
fi
