#!/usr/bin/env bash
# test/plan-stamp.test.sh — behavioural test for bin/quetrex-plan-stamp, the
# tool /quetrex:task-build Step 6A runs to record the APPROVED base sha in the
# plan JSON it publishes to the spec branch (SPEC R1.1, dispatcher half).
#
# Run: bash test/plan-stamp.test.sh
#
# WHY THIS EXISTS. A cloud routine cannot be handed a ref: the platform clones
# "the default branch" and reuses a filesystem SNAPSHOT of the environment, so a
# run can begin behind the base a human approved — non-deterministically. The
# only defence is recording which sha was approved, and the only recording that
# counts is one that actually EXECUTES. So this test runs the real tool against a
# real throwaway git repo rather than asserting that a markdown file contains the
# right sentence.
#
# The fixture deliberately drives `origin/main` and the local `HEAD` APART (one
# pushed commit, one local-only commit). That is what makes assertion (ii)
# meaningful: a stamper that lazily wrote `rev-parse HEAD` would look correct in
# any fixture where the two coincide, and would then stamp a sha the cloud has
# never seen.
#
# Proves:
#   (i)   the stamped plan still parses as JSON
#   (ii)  base_sha == origin/main, and is NOT the local HEAD
#   (iii) every pre-existing plan field survives, unchanged and deep-equal
#   (iv)  a second run is byte-identical (idempotent — safe on a retried dispatch)
#   (v)   REFUSALS write nothing: an unresolvable base branch, a base that exists
#         only as a LOCAL branch (no remote-tracking ref), and an unparseable plan
#         all exit non-zero and leave the file byte-for-byte intact. A half-stamped
#         plan would ship a wrong "approved" sha, which is worse than a loud stop.
#   (vi)  the write is ATOMIC and leaves no residue — see the section header at
#         "(vi)" below for why a same-bytes-different-mechanism regression
#         (`renameSync` → `copyFileSync`) has to be caught here.
#
# Runs entirely offline — `origin` is a bare repo on disk. Same fixture-repo
# pattern as test/merge-gate.test.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$REPO_ROOT/bin/quetrex-plan-stamp"

if [ ! -f "$STAMP" ]; then
  echo "FAIL: bin/quetrex-plan-stamp not found at $STAMP"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — quetrex-plan-stamp rewrites JSON with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-plan-stamp.XXXXXX")"
# `chmod -R` first: section (vi) makes a fixture directory read-only, and a bare
# `rm -rf` cannot empty it if the test aborts before restoring the mode.
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture: a bare `origin` plus a clone whose HEAD is AHEAD of it ---------
ORIGIN="$WORK/origin.git"
CLONE="$WORK/work"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$CLONE"
git -C "$CLONE" config user.email "test@example.com"
git -C "$CLONE" config user.name "Fixture"
git -C "$CLONE" remote add origin "$ORIGIN"

echo "approved" > "$CLONE/README.md"
git -C "$CLONE" add README.md
git -C "$CLONE" commit -q -m "chore: the commit the human approved"
git -C "$CLONE" push -q -u origin main            # origin/main now == this commit

echo "later, unpushed" >> "$CLONE/README.md"
git -C "$CLONE" add README.md
git -C "$CLONE" commit -q -m "chore: a local-only commit after approval"

ORIGIN_SHA="$(git -C "$CLONE" rev-parse refs/remotes/origin/main)"
LOCAL_HEAD="$(git -C "$CLONE" rev-parse HEAD)"

if [ "$ORIGIN_SHA" = "$LOCAL_HEAD" ]; then
  echo "FAIL: fixture is broken — origin/main and HEAD must differ for this test to mean anything"
  exit 1
fi

# --- fixture plan, shaped like the architect's artifact ---------------------
PLAN="$WORK/DEA-9.json"
cat > "$PLAN" <<'JSON'
{
  "task": "DEA-9",
  "title": "keep this field",
  "ownership": { "src/a.ts": "dev-1", "src/b.ts": "dev-2" },
  "security_review_required": false,
  "acceptance": ["a", "b"],
  "nested": { "deep": { "n": 3 } }
}
JSON
cp "$PLAN" "$WORK/plan.original"

STAMP_OUT="$(bash "$STAMP" "$PLAN" "$CLONE" main 2>&1)"
STAMP_RC=$?
if [ "$STAMP_RC" -eq 0 ]; then
  pass "stamping a plan against a fetched base exits 0"
else
  fail "stamping exited $STAMP_RC (output: $STAMP_OUT)"
fi

# =============================================================================
# (i) the result still parses
# =============================================================================
if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$PLAN" 2>/dev/null; then
  pass "(i) the stamped plan parses as JSON"
else
  fail "(i) the stamped plan does NOT parse as JSON — the cloud session would report transport_failure"
fi

# =============================================================================
# (ii) base_sha is origin/<base>, NOT the local HEAD
# =============================================================================
STAMPED_SHA="$(node -e '
  let o; try { o = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); } catch { process.exit(1); }
  process.stdout.write(String(o && o.base_sha ? o.base_sha : ""));
' "$PLAN" 2>/dev/null)"

if [ -z "$STAMPED_SHA" ]; then
  fail "(ii) no base_sha was written — the routine has nothing to compare its checkout against, which IS root cause RC1"
elif [ "$STAMPED_SHA" = "$ORIGIN_SHA" ]; then
  pass "(ii) base_sha is origin/main ($ORIGIN_SHA)"
elif [ "$STAMPED_SHA" = "$LOCAL_HEAD" ]; then
  fail "(ii) base_sha is the LOCAL HEAD ($LOCAL_HEAD), not origin/main ($ORIGIN_SHA) — the cloud would be told to expect a commit that was never pushed"
else
  fail "(ii) base_sha ($STAMPED_SHA) is neither origin/main ($ORIGIN_SHA) nor HEAD ($LOCAL_HEAD)"
fi

# =============================================================================
# (iii) every pre-existing field survives
# =============================================================================
SURVIVED="$(node -e '
  const fs = require("fs"), assert = require("assert");
  const before = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const after  = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  delete after.base_sha;
  try { assert.deepStrictEqual(after, before); } catch (e) { process.stdout.write("no: " + e.message.split("\n")[0]); process.exit(0); }
  process.stdout.write("yes");
' "$WORK/plan.original" "$PLAN" 2>/dev/null)"
if [ "$SURVIVED" = "yes" ]; then
  pass "(iii) every pre-existing plan field survives the stamp, deep-equal"
else
  fail "(iii) the stamp altered the plan beyond adding base_sha ($SURVIVED)"
fi

# =============================================================================
# (iv) idempotent — a retried dispatch must not churn the payload
# =============================================================================
cp "$PLAN" "$WORK/plan.first-run"
bash "$STAMP" "$PLAN" "$CLONE" main >/dev/null 2>&1
if cmp -s "$WORK/plan.first-run" "$PLAN"; then
  pass "(iv) a second stamp is byte-identical (idempotent)"
else
  fail "(iv) a second stamp changed the file — the stamp is not idempotent, so a retried dispatch rewrites the payload"
fi

# =============================================================================
# (v) refusals, and they write NOTHING
# =============================================================================
cp "$PLAN" "$WORK/plan.before-refusals"

OUT="$(bash "$STAMP" "$PLAN" "$CLONE" no-such-branch 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "(v) an unresolvable base branch exits non-zero ($RC)"
else
  fail "(v) an unresolvable base branch exited 0 — a plan stamped with a guessed base is worse than none"
fi
if printf '%s' "$OUT" | grep -q 'no-such-branch'; then
  pass "(v) the refusal names the unresolvable ref on stderr"
else
  fail "(v) the refusal did not name the unresolvable ref (got: $OUT)"
fi
if cmp -s "$WORK/plan.before-refusals" "$PLAN"; then
  pass "(v) the plan is untouched after that refusal"
else
  fail "(v) the plan was modified by a refused stamp"
fi

# A base that exists ONLY as a local branch must NOT satisfy the stamp: the sha
# the cloud will clone is the one on origin, and nothing else.
git -C "$CLONE" branch -q local-only
OUT="$(bash "$STAMP" "$PLAN" "$CLONE" local-only 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "(v) a base that exists only as a LOCAL branch is refused ($RC)"
else
  fail "(v) a local-only branch was accepted as the approved base — the stamp is not reading origin"
fi
if cmp -s "$WORK/plan.before-refusals" "$PLAN"; then
  pass "(v) the plan is untouched after the local-only refusal"
else
  fail "(v) the plan was modified by the local-only refusal"
fi

BAD_PLAN="$WORK/broken.json"
printf '{ "task": "DEA-9", oops\n' > "$BAD_PLAN"
cp "$BAD_PLAN" "$WORK/broken.before"
OUT="$(bash "$STAMP" "$BAD_PLAN" "$CLONE" main 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "(v) an unparseable plan exits non-zero ($RC)"
else
  fail "(v) an unparseable plan exited 0"
fi
if cmp -s "$WORK/broken.before" "$BAD_PLAN"; then
  pass "(v) an unparseable plan is left byte-for-byte intact"
else
  fail "(v) an unparseable plan was rewritten — a half-stamped plan is unrecoverable for the routine"
fi
if ls "$WORK"/broken.json.stamp.* >/dev/null 2>&1; then
  fail "(v) a temp .stamp.* file was left behind next to the plan"
else
  pass "(v) no temp .stamp.* leftovers"
fi

# =============================================================================
# (vi) ATOMICITY — the plan is REPLACED by rename(2), never written in place
# =============================================================================
# WHY A WHOLE SECTION FOR ONE SYSCALL. Every assertion above only looks at the
# FINAL BYTES of the plan, and `copyFileSync(tmp, plan)` produces byte-identical
# final bytes — so swapping the atomic rename for a copy passed every check (i)
# through (v) untouched. It is still a defect twice over: the copy truncates and
# rewrites the real plan in place (a crash or a concurrent reader — task-build's
# own `git add` of `.quetrex/plan/<TASK>.json` — can observe an unparseable
# plan, which the routine must treat as `transport_failure`), and it leaves the
# `.stamp.<pid>` temp file next to the plan, inside the directory that gets
# staged onto the spec branch.
#
# A mechanism defect needs a mechanism assertion, so this section observes HOW
# the file was written, not what it ended up containing:
#   - fs-write TRACE: a NODE_OPTIONS `--require` preload wraps the fs write
#     entry points and logs each destination. `renameSync` may target the plan;
#     no write/copy/append/truncate may. (Injected from OUTSIDE — the production
#     script gets no test hook, which is the point: the hook could rot.)
#   - INODE identity: rename swaps a fresh inode into place, a copy writes
#     through the existing one. Verified independently of the trace.
#   - RESIDUE: no `*.stamp.*` survives a success OR a failure.

ATOMIC_DIR="$WORK/atomic"
mkdir -p "$ATOMIC_DIR"
APLAN="$ATOMIC_DIR/DEA-9.json"
cp "$WORK/plan.original" "$APLAN"

TRACER="$ATOMIC_DIR/trace-fs-writes.js"
cat > "$TRACER" <<'JS'
// Records the DESTINATION basename of every fs write the process performs.
// `rawWrite` is captured BEFORE patching: logging through the patched
// writeFileSync would recurse, because appendFileSync is writeFileSync inside.
const fs = require('fs');
const path = require('path');
const rawWrite = fs.writeFileSync;
const log = process.env.QX_FS_TRACE;
const rec = (op, p) => {
  try { rawWrite(log, op + ' ' + path.basename(String(p)) + '\n', { flag: 'a' }); } catch (e) { /* ignore */ }
};
for (const op of ['writeFileSync', 'copyFileSync', 'appendFileSync', 'truncateSync', 'renameSync']) {
  const orig = fs[op];
  if (typeof orig !== 'function') continue;
  fs[op] = function (...args) {
    // rename/copy take (src, dest); the rest take the destination first.
    rec(op, (op === 'copyFileSync' || op === 'renameSync') ? args[1] : args[0]);
    return orig.apply(this, args);
  };
}
JS

TRACE="$ATOMIC_DIR/fs-writes.log"
: > "$TRACE"
ino() { node -e 'process.stdout.write(String(require("fs").statSync(process.argv[1]).ino))' "$1" 2>/dev/null; }
INO_BEFORE="$(ino "$APLAN")"
QX_FS_TRACE="$TRACE" NODE_OPTIONS="--require \"$TRACER\"" \
  bash "$STAMP" "$APLAN" "$CLONE" main >/dev/null 2>&1
RC=$?
INO_AFTER="$(ino "$APLAN")"

if [ "$RC" -eq 0 ]; then
  pass "(vi) the traced stamp run exits 0"
else
  fail "(vi) the traced stamp run exited $RC — the rest of section (vi) cannot mean anything"
fi

# Guard the guard: if the preload never loaded, the trace is empty and every
# "no forbidden write" assertion below would pass vacuously.
if [ -s "$TRACE" ] && grep -q '^writeFileSync DEA-9\.json\.stamp\.' "$TRACE"; then
  pass "(vi) the fs-write tracer observed the stamp run (temp file written)"
else
  fail "(vi) the fs-write tracer recorded no write to a DEA-9.json.stamp.* temp file — either NODE_OPTIONS --require was ignored (this guard is blind, do not trust it) or the stamper stopped writing through a temp file at all. Trace: $(tr '\n' ';' < "$TRACE")"
fi

if grep -q '^renameSync DEA-9\.json$' "$TRACE"; then
  pass "(vi) the plan is put into place with rename(2)"
else
  fail "(vi) NOTHING renamed onto DEA-9.json — the write is not atomic. A reader (or task-build's own git add) can observe a truncated, unparseable plan. Trace: $(tr '\n' ';' < "$TRACE")"
fi

FORBIDDEN="$(grep -E '^(writeFileSync|copyFileSync|appendFileSync|truncateSync) DEA-9\.json$' "$TRACE" || true)"
if [ -z "$FORBIDDEN" ]; then
  pass "(vi) nothing writes into the plan path in place — only rename touches it"
else
  fail "(vi) the plan is written IN PLACE by: $(printf '%s' "$FORBIDDEN" | paste -sd' ' -) — atomicity is gone (this is exactly the renameSync→copyFileSync regression). Use a temp file + fs.renameSync."
fi

if [ -n "$INO_BEFORE" ] && [ -n "$INO_AFTER" ] && [ "$INO_BEFORE" != "$INO_AFTER" ]; then
  pass "(vi) the stamp swapped a fresh inode into place ($INO_BEFORE → $INO_AFTER)"
else
  fail "(vi) the plan's inode did not change ($INO_BEFORE → $INO_AFTER) — the existing file was rewritten through, not atomically replaced"
fi

if ls "$ATOMIC_DIR"/*.stamp.* >/dev/null 2>&1; then
  fail "(vi) a temp file survived a SUCCESSFUL stamp: $(ls "$ATOMIC_DIR"/*.stamp.* | paste -sd' ' -) — it would be committed to the spec branch alongside the plan"
else
  pass "(vi) a successful stamp leaves no .stamp.* residue"
fi

STAMPED_SHA_A="$(node -e '
  let o; try { o = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); } catch { process.exit(1); }
  process.stdout.write(String(o && o.base_sha ? o.base_sha : ""));
' "$APLAN" 2>/dev/null)"
if [ "$STAMPED_SHA_A" = "$ORIGIN_SHA" ]; then
  pass "(vi) the traced run really did stamp the approved base sha"
else
  fail "(vi) the traced run left base_sha='$STAMPED_SHA_A', expected $ORIGIN_SHA"
fi

# --- the cleanup path, reached by making rename(2) itself fail ----------------
# The temp file lives in the plan's own directory, so an unwritable directory
# fails the temp WRITE and never reaches the rename. Injecting the failure is the
# only way to execute the branch that has to delete the temp file.
FAULT="$ATOMIC_DIR/fail-rename.js"
cat > "$FAULT" <<'JS'
const fs = require('fs');
fs.renameSync = function () { const e = new Error('EIO: injected rename failure'); e.code = 'EIO'; throw e; };
JS
cp "$WORK/plan.original" "$APLAN"
cp "$APLAN" "$ATOMIC_DIR/before-fault"
OUT="$(NODE_OPTIONS="--require \"$FAULT\"" bash "$STAMP" "$APLAN" "$CLONE" main 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "(vi) a failed rename exits non-zero ($RC)"
else
  fail "(vi) a failed rename exited 0 — the dispatcher would publish an UNSTAMPED plan believing it was stamped (output: $OUT)"
fi
if cmp -s "$ATOMIC_DIR/before-fault" "$APLAN"; then
  pass "(vi) a failed rename leaves the plan byte-for-byte intact"
else
  fail "(vi) a failed rename corrupted the plan"
fi
if ls "$ATOMIC_DIR"/*.stamp.* >/dev/null 2>&1; then
  fail "(vi) a temp file survived a FAILED stamp: $(ls "$ATOMIC_DIR"/*.stamp.* | paste -sd' ' -) — the cleanup path does not run"
else
  pass "(vi) a failed stamp leaves no .stamp.* residue either"
fi

# --- an unwritable plan directory: refuse, intact, no residue ----------------
if [ "$(id -u)" != "0" ]; then
  RO_DIR="$ATOMIC_DIR/readonly"
  mkdir -p "$RO_DIR"
  cp "$WORK/plan.original" "$RO_DIR/DEA-9.json"
  cp "$RO_DIR/DEA-9.json" "$ATOMIC_DIR/ro.before"
  chmod 500 "$RO_DIR"
  OUT="$(bash "$STAMP" "$RO_DIR/DEA-9.json" "$CLONE" main 2>&1)"; RC=$?
  RESIDUE="$(ls "$RO_DIR"/*.stamp.* 2>/dev/null | paste -sd' ' -)"
  chmod 700 "$RO_DIR"
  if [ "$RC" -ne 0 ]; then
    pass "(vi) an unwritable plan directory is refused ($RC)"
  else
    fail "(vi) an unwritable plan directory exited 0 (output: $OUT)"
  fi
  if cmp -s "$ATOMIC_DIR/ro.before" "$RO_DIR/DEA-9.json"; then
    pass "(vi) the plan in an unwritable directory is untouched"
  else
    fail "(vi) the plan in an unwritable directory was modified"
  fi
  if [ -z "$RESIDUE" ]; then
    pass "(vi) no residue after an unwritable-directory refusal"
  else
    fail "(vi) residue after an unwritable-directory refusal: $RESIDUE"
  fi
else
  echo "skip - (vi) unwritable-directory case (running as root ignores file modes)"
fi

# --- source guard, naming the exact regression -------------------------------
# Cheap and unambiguous: this tool has no legitimate use for copyFileSync in its
# CODE. Comment lines (shell `#` and JS `//`) are stripped first — the script's
# header explains at length why copy is wrong, and that prose must not trip the
# guard that enforces it.
if grep -vE '^[[:space:]]*(#|//)' "$STAMP" | grep -q 'copyFileSync'; then
  fail "(vi) bin/quetrex-plan-stamp mentions copyFileSync — the plan must be replaced by fs.renameSync (temp file + atomic rename), never copied over"
else
  pass "(vi) the stamper does not use copyFileSync anywhere"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "plan-stamp.test.sh: all checks passed"
  exit 0
else
  echo "plan-stamp.test.sh: FAILURES above"
  exit 1
fi
