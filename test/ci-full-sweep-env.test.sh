#!/usr/bin/env bash
# test/ci-full-sweep-env.test.sh — the CI-side half of the guarantee stated
# in test/merge-gate-sweep.test.sh's header: "CI always runs the full 819-row
# sweep". That claim was true only as long as nobody touched one YAML line.
#
# THE FINDING (security review, PR #108). test/merge-gate-sweep.test.sh is
# opt-in locally (QX_FULL_SWEEP) and relies on .github/workflows/verify.yml
# setting QX_FULL_SWEEP=1 on the step that runs the .quetrex/verify.json
# chain. That line was UNASSERTED: delete it, or move it to the job's own
# top-level env: (a sibling of `steps:`, NOT inherited by the step's `run:`
# block the way this repo's design requires it to be scoped), and CI goes
# green reporting "43 passed, 1 skipped" while the entire 819-row proof of
# merge-gate.sh silently stops running — nothing goes red anywhere. Same
# class of defect as every other gap this week: a guard that can disappear
# without a sound. This file is the sound.
#
# WHAT IT ASSERTS. Parses the real .github/workflows/verify.yml (no fixture,
# no copy) and requires:
#   1. the step whose `run:` block actually executes the verify chain — the
#      one that reads `.verify[]` out of a `verify.json` file — is found
#      (there must be exactly one; zero or more than one is itself a FAIL,
#      not silently ignored).
#   2. THAT step (not any other step, not the job, not the workflow) has its
#      OWN `env:` mapping setting QX_FULL_SWEEP to exactly the string "1".
# The chain-executing step is found by CONTENT signature (the `.verify[]` /
# verify.json read), not by matching its `name:` or `id:` — a rename of
# either must not blind this check. See check-sweep-env.js's `check()` for
# the exact walk.
#
# THE PARSER IS DELIBERATELY NOT A YAML PARSER. It is an indentation-tracking
# scan that understands exactly the shapes this workflow uses today (one job,
# a `steps:` block-sequence, 2-space nesting, `run: |` block scalars) — no
# anchors, no flow mappings, no multi-document files. This is a feature, not
# a gap to fix later: the moment the file's shape stops matching what the
# scanner expects (no `steps:` key, the chain step vanishes, more than one
# step matches, no step-scoped `env:`), it reports FAIL, never a silent pass.
# An edit that changes the workflow's structure in a way this scanner can't
# follow is exactly the kind of edit that could hide the invariant, so
# "I don't understand this shape" must fail loudly here too.
#
# FAIL-FIRST, MECHANICALLY, AGAINST REAL FILES. Below, the SAME check() used
# on the real file is run against two fixtures DERIVED from the real file
# (never hand-authored/duplicated YAML that could drift): one with the
# QX_FULL_SWEEP line stripped entirely, and one where it is relocated to a
# job-level env: block ahead of `steps:`. Both must FAIL; only the real file
# may PASS. This is not a one-off dev-time proof — it stays in the suite so
# a future change to check-sweep-env.js that quietly stops discriminating
# is itself caught (see the DISCRIMINATION assertions below).
#
# Run: bash test/ci-full-sweep-env.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/verify.yml"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

if [ ! -f "$WORKFLOW" ]; then
  echo "NOT OK - workflow not found at $WORKFLOW"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — this file's YAML scan is node-backed, nothing to test"
  exit 0
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/ci-full-sweep-env.XXXXXX")"
trap 'rm -rf "$T"' EXIT
CHECKER="$T/check-sweep-env.js"

cat > "$CHECKER" <<'NODEJS'
'use strict';
const fs = require('fs');

function indentOf(line) { return line.match(/^ */)[0].length; }
function isBlank(line) { const t = line.trim(); return t === '' || t.startsWith('#'); }

function findStepsIndent(lines) {
  for (let i = 0; i < lines.length; i++) {
    if (isBlank(lines[i])) continue;
    if (lines[i].trim() === 'steps:') return { idx: i, indent: indentOf(lines[i]) };
  }
  return null;
}

function findStepStarts(lines, stepsIdx, markerIndent) {
  const starts = [];
  for (let i = stepsIdx + 1; i < lines.length; i++) {
    const l = lines[i];
    if (isBlank(l)) continue;
    const ind = indentOf(l);
    if (ind < markerIndent) break;
    if (ind === markerIndent && l.trim().startsWith('- ')) starts.push(i);
  }
  return starts;
}

// The core invariant check: exactly one step reads `.verify[]` out of a
// verify.json file (that IS "the chain-executing step", found by content,
// not by name/id), and THAT step's own env: mapping sets QX_FULL_SWEEP to
// exactly "1".
function check(filePath) {
  let text;
  try { text = fs.readFileSync(filePath, 'utf8'); }
  catch (e) { return { ok: false, reason: `cannot read ${filePath}: ${e.message}` }; }
  const lines = text.split(/\r?\n/);

  const steps = findStepsIndent(lines);
  if (!steps) return { ok: false, reason: "no top-level 'steps:' key found" };
  const markerIndent = steps.indent + 2;
  const keyIndent = markerIndent + 2;

  const starts = findStepStarts(lines, steps.idx, markerIndent);
  if (starts.length === 0) return { ok: false, reason: "'steps:' has no list items at the expected indentation" };
  starts.push(lines.length);

  const SIG_ARR = /\.verify\[\]/;
  const SIG_FILE = /verify\.json/;
  let chainStep = -1, matches = 0;
  for (let s = 0; s < starts.length - 1; s++) {
    const block = lines.slice(starts[s], starts[s + 1]).join('\n');
    if (SIG_ARR.test(block) && SIG_FILE.test(block)) { matches++; chainStep = s; }
  }
  if (matches === 0) return { ok: false, reason: "no step's run: block reads '.verify[]' from a verify.json file -- cannot locate the chain-executing step" };
  if (matches > 1) return { ok: false, reason: `${matches} steps match the chain-execution signature -- expected exactly 1` };

  const block = lines.slice(starts[chainStep], starts[chainStep + 1]);
  let envIdx = -1;
  for (let i = 0; i < block.length; i++) {
    const l = block[i];
    if (isBlank(l)) continue;
    const ind = indentOf(l);
    if (ind === keyIndent && l.trim() === 'env:') { envIdx = i; break; }
  }
  if (envIdx === -1) return { ok: false, reason: "the chain-executing step has no step-scoped 'env:' mapping" };

  const childIndent = keyIndent + 2;
  let value = null;
  for (let i = envIdx + 1; i < block.length; i++) {
    const l = block[i];
    if (isBlank(l)) continue;
    const ind = indentOf(l);
    if (ind <= keyIndent) break;
    if (ind !== childIndent) continue;
    const m = l.trim().match(/^QX_FULL_SWEEP\s*:\s*(.+)$/);
    if (m) { value = m[1].trim(); break; }
  }
  if (value === null) return { ok: false, reason: "QX_FULL_SWEEP is not set inside the chain-executing step's own env:" };
  const unquoted = value.replace(/^['"]|['"]$/g, '');
  if (unquoted !== '1') return { ok: false, reason: `QX_FULL_SWEEP is set to ${JSON.stringify(value)}, not exactly 1` };

  return { ok: true, reason: "QX_FULL_SWEEP=1 is set inside the chain-executing step's own env:" };
}

// Fixture generators, DERIVED from the real file's own content (never a
// hand-duplicated copy that could drift out of sync with it).
function stripSweepEnv(lines) {
  let qIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*QX_FULL_SWEEP\s*:/.test(lines[i])) { qIdx = i; break; }
  }
  if (qIdx === -1) return null;
  const qIndent = indentOf(lines[qIdx]);
  const qLineTrimmed = lines[qIdx].trim();
  let envIdx = -1;
  for (let i = qIdx - 1; i >= 0; i--) {
    if (isBlank(lines[i])) continue;
    const ind = indentOf(lines[i]);
    if (ind === qIndent - 2 && lines[i].trim() === 'env:') { envIdx = i; break; }
    if (ind < qIndent - 2) break;
  }
  if (envIdx === -1) return null;
  const envIndent = indentOf(lines[envIdx]);
  let end = envIdx + 1;
  while (end < lines.length) {
    const l = lines[end];
    if (l.trim() === '') { end++; continue; }
    if (indentOf(l) > envIndent) { end++; continue; }
    break;
  }
  return { lines: lines.slice(0, envIdx).concat(lines.slice(end)), qxLine: qLineTrimmed };
}

function insertJobLevelEnv(lines, qxLineTrimmed) {
  const steps = findStepsIndent(lines);
  if (!steps) throw new Error("no 'steps:' key found to anchor job-level env insertion");
  const indentStr = ' '.repeat(steps.indent);
  const childIndentStr = ' '.repeat(steps.indent + 2);
  const insert = [`${indentStr}env:`, `${childIndentStr}${qxLineTrimmed}`];
  return lines.slice(0, steps.idx).concat(insert, lines.slice(steps.idx));
}

const mode = process.argv[2];
if (mode === 'check') {
  const result = check(process.argv[3]);
  if (result.ok) { console.log(`PASS: ${result.reason}`); process.exit(0); }
  console.log(`FAIL: ${result.reason}`);
  process.exit(1);
} else if (mode === 'strip-env') {
  const stripped = stripSweepEnv(fs.readFileSync(process.argv[3], 'utf8').split(/\r?\n/));
  if (!stripped) { console.log('FAIL: could not find a QX_FULL_SWEEP line to strip'); process.exit(2); }
  fs.writeFileSync(process.argv[4], stripped.lines.join('\n'));
  console.log('OK');
} else if (mode === 'move-to-job') {
  const stripped = stripSweepEnv(fs.readFileSync(process.argv[3], 'utf8').split(/\r?\n/));
  if (!stripped) { console.log('FAIL: could not find a QX_FULL_SWEEP line to strip'); process.exit(2); }
  fs.writeFileSync(process.argv[4], insertJobLevelEnv(stripped.lines, stripped.qxLine).join('\n'));
  console.log('OK');
} else {
  console.log(`FAIL: unknown mode ${mode}`);
  process.exit(2);
}
NODEJS

# --- AC1: the real, committed workflow must PASS -------------------------
REAL_OUT="$(node "$CHECKER" check "$WORKFLOW" 2>&1)"; REAL_CODE=$?
if [ "$REAL_CODE" -eq 0 ] && printf '%s' "$REAL_OUT" | grep -q '^PASS:'; then
  ok "AC1: .github/workflows/verify.yml scopes QX_FULL_SWEEP=1 to the chain-executing step ($REAL_OUT)"
else
  notok "AC1: the real workflow no longer guarantees CI runs the full sweep -- $REAL_OUT (exit $REAL_CODE)"
fi

# --- AC2: deleting the env line must FAIL (fixture derived from the real file) ---
DELETED="$T/deleted.yml"
if ! node "$CHECKER" strip-env "$WORKFLOW" "$DELETED" >/dev/null 2>&1; then
  notok "AC2: fixture setup failed -- could not derive a deleted-env copy of the real workflow"
else
  DEL_OUT="$(node "$CHECKER" check "$DELETED" 2>&1)"; DEL_CODE=$?
  if [ "$DEL_CODE" -ne 0 ] && printf '%s' "$DEL_OUT" | grep -q '^FAIL:'; then
    ok "AC2: a copy with QX_FULL_SWEEP deleted from the chain step correctly FAILS ($DEL_OUT)"
  else
    notok "AC2: deleting QX_FULL_SWEEP from the chain step did NOT fail -- the check does not actually guard the env line ($DEL_OUT, exit $DEL_CODE)"
  fi
fi

# --- AC3: moving it to job-level env: (a sibling of steps:) must FAIL ----
MOVED="$T/moved.yml"
if ! node "$CHECKER" move-to-job "$WORKFLOW" "$MOVED" >/dev/null 2>&1; then
  notok "AC3: fixture setup failed -- could not derive a job-level-env copy of the real workflow"
else
  MOV_OUT="$(node "$CHECKER" check "$MOVED" 2>&1)"; MOV_CODE=$?
  if [ "$MOV_CODE" -ne 0 ] && printf '%s' "$MOV_OUT" | grep -q '^FAIL:'; then
    ok "AC3: a copy with QX_FULL_SWEEP moved to the job's own env: (not the step's) correctly FAILS ($MOV_OUT)"
  else
    notok "AC3: moving QX_FULL_SWEEP to job-level env: did NOT fail -- the check is not actually scoped to the executing step ($MOV_OUT, exit $MOV_CODE)"
  fi
fi

# --- DISCRIMINATION: the deleted/moved fixtures must genuinely differ from
# the real file (never trivially identical, or AC2/AC3 would pass vacuously
# by testing the same content as AC1). ------------------------------------
if [ -f "$DELETED" ] && ! diff -q "$WORKFLOW" "$DELETED" >/dev/null 2>&1; then
  ok "AC4: the deleted-env fixture genuinely differs from the real workflow (AC2 is a real check, not vacuous)"
else
  notok "AC4: the deleted-env fixture is identical to the real workflow -- AC2 proves nothing"
fi
if [ -f "$MOVED" ] && ! diff -q "$WORKFLOW" "$MOVED" >/dev/null 2>&1; then
  ok "AC5: the job-level-env fixture genuinely differs from the real workflow (AC3 is a real check, not vacuous)"
else
  notok "AC5: the job-level-env fixture is identical to the real workflow -- AC3 proves nothing"
fi

echo
echo "ci-full-sweep-env.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
