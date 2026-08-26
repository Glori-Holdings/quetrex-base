#!/usr/bin/env bash
# test/git-workflow-qdm6-fixture.test.sh — the REAL QDM-6 artifacts must reach GREEN
# through git-workflow.md's Gates 1-4 as shipped.
#
# THE MEASURED DEFECT (QDM-6, Glori-Holdings/quetrex-demo, HEAD c26bc7238d5a0a3bd53cdcdd07
# ff7f74a9a2dca5, gates branch claude/QDM-6-gates-c26bc72, artifacts fetched verbatim via
# `gh api repos/Glori-Holdings/quetrex-demo/contents/.quetrex/<f>?ref=claude/QDM-6-gates-
# c26bc72`). A cloud build reached this HEAD with qa-report PASS, review-verdict AUTO_MERGE
# pinned to HEAD, and security-findings PASS — and git-workflow refused anyway. Review of
# the first version of this fix (PR #125) found the fix was NECESSARY but not SUFFICIENT:
#
#   SEC-4: Gate 3 (unchanged by the first fix) ran `jq '[.[] | select(.severity...)]'`
#   directly on security-findings.json. The REAL artifact is the canonical OBJECT shape
#   security-reviewer.md prescribes ({task,base,head_sha,...,findings:[...]}), and `.[]` on
#   an object yields its top-level VALUES (strings, a number, an array) — `.severity` on a
#   bare string errors ("Cannot index string with string \"severity\""), so Gate 3 REFUSED
#   before Gate 4's new route-2 allowance was ever reached.
#
#   Separately (found while assembling THIS fixture, not itself a named review finding but
#   required to make "the real artifacts reach GREEN" literally true): Gate 2's "the last
#   ledger line must be exit==0" check also refuses on the REAL ledger, whose tail is a
#   genuine, sanctioned requiredEnv skip preceded by a boundedQuick placeholder — neither of
#   which is a real exit code. See the Gate 2 fix in git-workflow.md for the detail; this
#   file proves it does not regress a genuine failure (ASSERTION 3).
#
# This file EXECUTES the real, unmodified Gates 1-4 bash (all four fences concatenated,
# never a paraphrase) against the VERBATIM fetched artifacts, and fail-first proves the
# pre-fix contract at commit 1032770 refuses this exact real-world shape.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GWMD="$REPO_ROOT/plugins/quetrex-factory/agents/git-workflow.md"
PREFIX_SHA="1032770"

[ -f "$GWMD" ] || { echo "FAIL: git-workflow.md not found at $GWMD"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed — every gate under test is jq-mandatory"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git is not installed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# --- extraction: the WHOLE ```bash fence containing a given anchor line --------------------
extract_gate() {  # extract_gate <anchor-literal-substring>
  awk -v anchor="$1" '
    /^```bash$/ { buf=""; next }
    /^```$/ {
      if (index(buf, anchor) > 0) { print buf; found=1; exit }
      buf=""; next
    }
    { buf = buf $0 "\n" }
    END { if (!found) exit 1 }
  '
}

build_full_gates() {  # build_full_gates <content> -> concatenated Gate1+2+3+4, or empty on any miss
  local content="$1" g1 g2 g3 g4
  g1="$(printf '%s\n' "$content" | extract_gate 'ESCALATION" ]')" || return 1
  g2="$(printf '%s\n' "$content" | extract_gate 'LEDGER="$ROOT/.quetrex/verify-ledger.jsonl"')" || return 1
  g3="$(printf '%s\n' "$content" | extract_gate 'SEC="$ROOT/.quetrex/security-findings.json"')" || return 1
  g4="$(printf '%s\n' "$content" | extract_gate 'RV="$ROOT/.quetrex/review-verdict.json"')" || return 1
  printf '%s\n%s\n%s\n%s\n' "$g1" "$g2" "$g3" "$g4"
}

NEW_CONTENT="$(cat "$GWMD")"
OLD_CONTENT="$(git -C "$REPO_ROOT" show "${PREFIX_SHA}:plugins/quetrex-factory/agents/git-workflow.md" 2>/dev/null)"

if [ -z "$OLD_CONTENT" ]; then
  notok "SETUP: could not read git-workflow.md at $PREFIX_SHA"
  echo; echo "git-workflow-qdm6-fixture.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

NEW_GATES="$(build_full_gates "$NEW_CONTENT")"
if [ -n "$NEW_GATES" ]; then
  ok "SETUP: extracted current Gates 1-4 (all four fences) from git-workflow.md"
else
  notok "SETUP: could not extract all four current gate fences — cannot run this test"
  echo; echo "git-workflow-qdm6-fixture.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

OLD_GATES="$(build_full_gates "$OLD_CONTENT")"
if [ -n "$OLD_GATES" ]; then
  ok "SETUP: extracted pre-fix ($PREFIX_SHA) Gates 1-4 from git-workflow.md"
else
  notok "SETUP: could not extract all four pre-fix gate fences — the fail-first half cannot run"
fi

# --- the real QDM-6 fixture, fetched verbatim from Glori-Holdings/quetrex-demo -------------
#
# Gate 4 pins review-verdict.json's `.sha` to `git -C "$ROOT" rev-parse HEAD` — so the
# fixture's actual git commit must produce SOME concrete sha, and every `.quetrex/*` file
# below must agree with THAT sha, not a hardcoded literal (a fresh local commit can never be
# made to reproduce the real repo's exact 40-hex-char sha without recreating its entire real
# tree, which would require a live network fetch — this suite is hermetic by the same
# convention every other test/*.sh file here follows). So: commit first, read the real local
# HEAD sha, then substitute it for QDM6_HEAD_SHA_PLACEHOLDER in the verbatim-fetched
# artifacts below. Everything else in those artifacts — the verdict, the reason text, the
# findings, the ledger's exact tail shape — is byte-identical to what
# `gh api repos/Glori-Holdings/quetrex-demo/contents/.quetrex/<f>?ref=claude/QDM-6-gates-
# c26bc72` returned.
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/qdm6-fixture.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
git -C "$FIXTURE" init -q -b work
echo "qdm6 fixture placeholder commit" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" -c user.email=test@example.com -c user.name=Fixture commit -q -m "qdm6 fixture"
HEAD_SHA_FIXTURE="$(git -C "$FIXTURE" rev-parse HEAD)"

mkdir -p "$FIXTURE/.quetrex"

cat > "$FIXTURE/.quetrex/verify.json" <<'VERIFY_JSON_EOF'
{
  "verify": [
    "npm run lint",
    "npm run test",
    "npm run build"
  ],
  "requiredEnv": {
    "npm run build": [
      "DEMO_DATABASE_URL"
    ]
  }
}
VERIFY_JSON_EOF

cat > "$FIXTURE/.quetrex/review-verdict.json" <<'REVIEW_VERDICT_EOF'
{
  "verdict": "AUTO_MERGE",
  "task": "QDM-6",
  "sha": "QDM6_HEAD_SHA_PLACEHOLDER",
  "base": "main",
  "ts": "2026-08-26T08:58:43Z",
  "reason": "No defect found in an independent hostile pass at this commit. I re-proved the verify chain myself (lint 0, test 0 with DEMO_DATABASE_URL unset and 17 checks, build 0 with the placeholder env sourced) and re-ran the untouched QDM-4 provenance suite (11/11, 0 bytes changed). All 10 acceptance criteria are met and ownership is exact (src/build.js + test/manifest.test.js, both mapped to workstream core). My own credential probe with a runtime-generated userinfo-bearing DEMO_DATABASE_URL found 0 occurrences of the user token, password token, database name, host, scheme, sslmode or '@' in dist/manifest.json, and I proved the new artifact is byte-identical to the pre-existing dist/build-manifest.json minus its dbHost key, so it discloses a strict subset and cannot widen the credential boundary. 6 of 7 of my own mutants on the changed lines were killed (cwd-relative sourceDir, dbHost leaked into the new artifact, lost indent, lost trailing newline, swapped key order, omitted write); the 7th only reverts to base behavior and violates no acceptance criterion. On SEC-1 I reached my own conclusion rather than deferring: I reproduced the ERR_INVALID_URL credential echo and the stack frame is src/build.js:10, an untouched line, which runs unconditionally first on the same never-reassigned const, so the changed line 29 is unreachable as a throw site; call sites for new URL(connectionString) are 2 in base and 2 at HEAD, so the diff neither introduces nor widens it. It is low/PLAUSIBLE, not an open CONFIRMED Critical, and it is pre-existing rather than caused by this diff, so it does not block. Independence is satisfied via merge-gate GATE 2b route 2: .quetrex/security-findings.json parses, pins head_sha to this exact commit, and has 0 open Critical findings. The native SlashCommand tool is structurally absent from this agent's tool set, so nativeSecurityReview is recorded honestly as errored rather than laundered to clean.",
  "reviewedFiles": 2,
  "inputs": {
    "verifyGreen": true,
    "openCritical": false,
    "reviewIter": 0,
    "nonTrivial": true,
    "nativeReview": "errored",
    "nativeSecurityReview": "errored",
    "qaReportPinned": true,
    "qaGapOnSecuritySurface": false
  },
  "confirmed": [],
  "plausible": [],
  "notes": [
    "Out of scope (pre-existing, not caused by this diff): src/build.js writes cwd-relative dist/ paths, so fs.writeFileSync follows a pre-planted symlink at the destination. I re-examined this independently and confirmed the new dist/manifest.json write is a third instance of the identical pre-existing pattern already used for dist/output.txt and dist/build-manifest.json, and that its content is a strict subset of build-manifest.json, so it adds no exploitable capability. Non-blocking, reported once and not blocked on."
  ]
}
REVIEW_VERDICT_EOF

cat > "$FIXTURE/.quetrex/security-findings.json" <<'SEC_FINDINGS_EOF'
{
  "task": "QDM-6",
  "base": "main",
  "head_sha": "QDM6_HEAD_SHA_PLACEHOLDER",
  "reviewed_files": 2,
  "verdict": "PASS",
  "findings": [
    {
      "id": "SEC-1",
      "severity": "low",
      "confidence": "PLAUSIBLE",
      "category": "error-handling",
      "cwe": "CWE-209",
      "owasp": "API8:2023",
      "file": "src/build.js",
      "line": 29,
      "summary": "Modified line re-parses connectionString with an unguarded new URL(); an ERR_INVALID_URL crash echoes the raw connection string via the error's input property. Pre-existing behavior carried onto a touched line - NOT introduced, NOT widened by this change.",
      "exploit": "If DEMO_DATABASE_URL is set to a credential-bearing but unparseable value, node exits with an uncaught TypeError whose printed own-properties include input: '<raw connection string>', landing the credential in CI build logs. Verified empirically on node v22.22.2. Reachability via THIS line is nil: the identical unguarded parse already exists at the untouched src/build.js:10, which runs first on the same value and fails fast, so line 29 is unreachable for any input that would make it throw. Call-site count for new URL(connectionString) is 2 before and 2 after the change; the diff adds no new parse and no new sink.",
      "remediation": "Out of scope for QDM-6. If hardened later, wrap the parse once in try/catch at src/build.js:10 and rethrow a generic 'DEMO_DATABASE_URL is not a parseable URL' error that does not carry the input value, then reuse the parsed host for both artifacts.",
      "status": "open"
    }
  ]
}
SEC_FINDINGS_EOF

cat > "$FIXTURE/.quetrex/verify-ledger.jsonl" <<'LEDGER_EOF'
{"ts":"2026-08-26T08:27:13Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"bf76f3f326dbb950df4747f2ed4f1734c2322239","exit":null,"skipped":true,"skipReason":"boundedQuick","tail":"SKIPPED: excluded by the bounded quick chain (heavy filter or wall-clock cap) — never proven, never a pass"}
{"ts":"2026-08-26T08:27:14Z","cmd":"npm run lint","cwd":"/home/user/quetrex-demo","sha":"bf76f3f326dbb950df4747f2ed4f1734c2322239","exit":0,"tail":"lint ok"}
{"ts":"2026-08-26T08:27:14Z","cmd":"npm run build","cwd":"/home/user/quetrex-demo","sha":"bf76f3f326dbb950df4747f2ed4f1734c2322239","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"DEMO_DATABASE_URL","tail":"SKIPPED: required env var DEMO_DATABASE_URL is unavailable in this checkout"}
{"ts":"2026-08-26T08:38:14Z","cmd":"npm run lint","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"lint ok"}
{"ts":"2026-08-26T08:38:14Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"manifest.test.js: 17 checks passed"}
{"ts":"2026-08-26T08:38:20Z","cmd":"npm run build","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"build ok"}
{"ts":"2026-08-26T08:39:33Z","cmd":"npm run lint","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"lint ok"}
{"ts":"2026-08-26T08:39:33Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"manifest.test.js: 17 checks passed"}
{"ts":"2026-08-26T08:39:33Z","cmd":"npm run build","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"build ok"}
{"ts":"2026-08-26T09:00:00Z","cmd":"npm run lint","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"lint ok"}
{"ts":"2026-08-26T09:00:00Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"manifest.test.js: 17 checks passed"}
{"ts":"2026-08-26T09:00:01Z","cmd":"npm run build","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"build ok"}
{"ts":"2026-08-26T09:00:28Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":null,"skipped":true,"skipReason":"boundedQuick","tail":"SKIPPED: excluded by the bounded quick chain (heavy filter or wall-clock cap) — never proven, never a pass"}
{"ts":"2026-08-26T09:00:29Z","cmd":"npm run lint","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":0,"tail":"lint ok"}
{"ts":"2026-08-26T09:00:29Z","cmd":"npm run build","cwd":"/home/user/quetrex-demo","sha":"QDM6_HEAD_SHA_PLACEHOLDER","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"DEMO_DATABASE_URL","tail":"SKIPPED: required env var DEMO_DATABASE_URL is unavailable in this checkout"}
LEDGER_EOF
# ^ Trimmed of duplicate mid-run rows (the real ledger has 60 lines from repeated Stop
# firings) but every row that survives is byte-identical to what was fetched from the real
# gates branch, and the TAIL — the exact shape that broke Gate 2 (a real green run, then a
# boundedQuick placeholder for `npm run test`, then a sanctioned requiredEnv skip for
# `npm run build`) — is reproduced verbatim and unabridged.

# Substitute the fixture's real local HEAD sha for the placeholder now that all three files
# are written. These are plain working-tree files under a git-ignored .quetrex/ — Gates 1-4
# read them straight off disk (never `git show`), so editing them post-commit is exactly
# what a real cloud sandbox's .quetrex/* looks like: untracked, current, unpinned by git.
for f in review-verdict.json security-findings.json verify-ledger.jsonl; do
  sed -i.bak "s/QDM6_HEAD_SHA_PLACEHOLDER/$HEAD_SHA_FIXTURE/g" "$FIXTURE/.quetrex/$f"
  rm -f "$FIXTURE/.quetrex/$f.bak"
done
if grep -rl QDM6_HEAD_SHA_PLACEHOLDER "$FIXTURE/.quetrex/" >/dev/null 2>&1; then
  notok "SETUP: QDM6_HEAD_SHA_PLACEHOLDER survived substitution — the fixture does not actually pin to this repo's real HEAD, every GREEN assertion below would be meaningless"
else
  ok "SETUP: fixture artifacts pinned to the fixture's real local HEAD ($HEAD_SHA_FIXTURE), matching Gate 4's rev-parse"
fi

run_gates() {  # run_gates <gates-script>
  env ROOT="$FIXTURE" bash -c "$1" 2>&1
}

# =============================================================================
# ASSERTION 1 (the acceptance bar): the REAL QDM-6 artifacts reach GREEN under the
# CURRENT (fixed) Gates 1-4.
# =============================================================================
OUT="$(run_gates "$NEW_GATES")"
if printf '%s' "$OUT" | grep -q 'REFUSED'; then
  notok "ASSERTION 1: the real QDM-6 fixture is still REFUSED by the current Gates 1-4. Output: $OUT"
else
  ok "ASSERTION 1: the real QDM-6 fixture (fixture HEAD $HEAD_SHA_FIXTURE, real defect measured at c26bc7238d5a0a3bd53cdcdd07ff7f74a9a2dca5) reaches GREEN through the current Gates 1-4 — no REFUSED anywhere"
fi

# =============================================================================
# ASSERTION 2 (fail-first): the SAME real fixture REFUSES under the pre-fix (1032770)
# contract — confirms SEC-4 (and the Gate 2 requiredEnv/boundedQuick handling) were both
# real, measurable defects before this rework, not paraphrased ones.
# =============================================================================
if [ -n "$OLD_GATES" ]; then
  OUT="$(run_gates "$OLD_GATES")"
  if printf '%s' "$OUT" | grep -q 'REFUSED\|error\|Error\|cannot'; then
    ok "ASSERTION 2 (FAIL-FIRST): the pre-fix ($PREFIX_SHA) Gates 1-4 do NOT reach GREEN on the same real fixture — confirms the defect predates this rework. Signal: $(printf '%s' "$OUT" | grep -m1 'REFUSED\|error\|Error\|cannot')"
  else
    notok "ASSERTION 2 (FAIL-FIRST): the pre-fix ($PREFIX_SHA) contract reached GREEN on the real fixture too — the fail-first baseline proves nothing. Output: $OUT"
  fi
fi

# =============================================================================
# ASSERTION 3 (regression guard): a GENUINELY red command must still refuse under the
# current (fixed) Gate 2 — the boundedQuick-skip tolerance must never launder a real
# failure, even one that happened at the exact same commit as a later placeholder skip.
# =============================================================================
cp "$FIXTURE/.quetrex/verify-ledger.jsonl" "$FIXTURE/.quetrex/verify-ledger.jsonl.bak"
printf '{"ts":"2026-08-26T09:05:00Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"%s","exit":1,"tail":"1 check FAILED"}\n' "$HEAD_SHA_FIXTURE" >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
printf '{"ts":"2026-08-26T09:05:01Z","cmd":"npm run test","cwd":"/home/user/quetrex-demo","sha":"%s","exit":null,"skipped":true,"skipReason":"boundedQuick","tail":"SKIPPED"}\n' "$HEAD_SHA_FIXTURE" >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
OUT="$(run_gates "$NEW_GATES")"
if printf '%s' "$OUT" | grep -q 'REFUSED'; then
  ok "ASSERTION 3: a genuinely failing command (exit 1) followed by a boundedQuick placeholder is STILL refused — the skip tolerance does not launder a real failure"
else
  notok "ASSERTION 3: a measurably FAILING command was allowed through because a boundedQuick placeholder ran after it — Gate 2 was widened too far. Output: $OUT"
fi
cp "$FIXTURE/.quetrex/verify-ledger.jsonl.bak" "$FIXTURE/.quetrex/verify-ledger.jsonl"

# =============================================================================
# ASSERTION 4 (regression guard): a genuinely open Critical finding must still refuse
# under the current (fixed) Gate 3 normalization — proves the SEC-4 fix does not widen
# GATE 3 into a no-op.
# =============================================================================
cp "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/security-findings.json.bak"
jq '.findings += [{"id":"SEC-9","severity":"critical","status":"open"}]' \
  "$FIXTURE/.quetrex/security-findings.json.bak" > "$FIXTURE/.quetrex/security-findings.json"
OUT="$(run_gates "$NEW_GATES")"
if printf '%s' "$OUT" | grep -q 'REFUSED.*[Cc]ritical'; then
  ok "ASSERTION 4: an open Critical finding on the (still-object-shaped) artifact is still refused after the Gate 3 normalization fix"
else
  notok "ASSERTION 4: an open Critical finding was NOT caught after the Gate 3 fix — normalization widened the gate into a no-op. Output: $OUT"
fi
cp "$FIXTURE/.quetrex/security-findings.json.bak" "$FIXTURE/.quetrex/security-findings.json"

# =============================================================================
# ASSERTIONS 5-7 (O7, review finding): Gate 2 must never be LOOSER than
# merge-gate.sh's own GATE 3 arbitration on the identical ledger. Three cases the
# reviewer measured Gate 2 disagreeing with merge-gate.sh on (Gate 2 GREEN, hook
# DENY) before this fix — all three must now REFUSE, matching the hook.
# =============================================================================
OLD_SHA_O7="0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0"

# 5 — a genuine failure followed by a requiredEnv skip at the SAME (HEAD) sha: the
#     skip must never rescue a real failure recorded at its own commit.
printf '{"ts":"2026-08-26T09:10:00Z","cmd":"npm run test","cwd":"/x","sha":"%s","exit":1,"tail":"FAILED"}\n' "$HEAD_SHA_FIXTURE" > "$FIXTURE/.quetrex/verify-ledger.jsonl"
printf '{"ts":"2026-08-26T09:10:01Z","cmd":"npm run test","cwd":"/x","sha":"%s","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"X"}\n' "$HEAD_SHA_FIXTURE" >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
OUT="$(run_gates "$NEW_GATES")"
if printf '%s' "$OUT" | grep -q 'REFUSED'; then
  ok "ASSERTION 5 (O7 case 1): a genuine failure followed by a requiredEnv skip at the SAME sha still REFUSES — the skip does not rescue a same-commit failure, matching merge-gate.sh's dominance rule"
else
  notok "ASSERTION 5 (O7 case 1): a requiredEnv skip at the same sha as a genuine failure was allowed through — Gate 2 is looser than merge-gate.sh. Output: $OUT"
fi

# 6 — a genuine PASS recorded only at an OLD sha, with NOTHING at all recorded at
#     HEAD: unproven AT HEAD is not green, regardless of history.
printf '{"ts":"2026-08-26T09:10:00Z","cmd":"npm run test","cwd":"/x","sha":"%s","exit":0,"tail":"ok"}\n' "$OLD_SHA_O7" > "$FIXTURE/.quetrex/verify-ledger.jsonl"
OUT="$(run_gates "$NEW_GATES")"
if printf '%s' "$OUT" | grep -q 'REFUSED'; then
  ok "ASSERTION 6 (O7 case 2): a genuine pass recorded ONLY at an old sha, nothing at HEAD, REFUSES — unproven at HEAD is not green"
else
  notok "ASSERTION 6 (O7 case 2): a pass recorded only at an old, non-HEAD sha was accepted as green — Gate 2 does not require proof at HEAD. Output: $OUT"
fi

# 7 — a genuine failure at an OLD sha plus an UNRELATED requiredEnv skip at HEAD:
#     the skip does not clear a real failure recorded elsewhere in this command's
#     history.
printf '{"ts":"2026-08-26T09:10:00Z","cmd":"npm run test","cwd":"/x","sha":"%s","exit":1,"tail":"FAILED"}\n' "$OLD_SHA_O7" > "$FIXTURE/.quetrex/verify-ledger.jsonl"
printf '{"ts":"2026-08-26T09:10:01Z","cmd":"npm run test","cwd":"/x","sha":"%s","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"X"}\n' "$HEAD_SHA_FIXTURE" >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
OUT="$(run_gates "$NEW_GATES")"
if printf '%s' "$OUT" | grep -q 'REFUSED'; then
  ok "ASSERTION 7 (O7 case 3): a genuine failure at an OLD sha plus an unrelated requiredEnv skip at HEAD still REFUSES — the skip does not launder a real failure recorded elsewhere in this command's history"
else
  notok "ASSERTION 7 (O7 case 3): an old failure plus a HEAD skip was accepted as green — Gate 2 is looser than merge-gate.sh. Output: $OUT"
fi

cp "$FIXTURE/.quetrex/verify-ledger.jsonl.bak" "$FIXTURE/.quetrex/verify-ledger.jsonl"

echo
echo "git-workflow-qdm6-fixture.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
