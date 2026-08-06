#!/usr/bin/env bash
# test/architect-plan-schema.test.sh — guards the architect's plan-schema contract
# for the two fields the cloud-build hardening added, plus the rule that stops a
# build that can never go green.
#
# Run: bash test/architect-plan-schema.test.sh
#
# WHY THIS EXISTS. The plan artifact is the only thing downstream stages read —
# a context-blind cloud run cannot ask the architect a follow-up question. Three
# separate defects live in this one file:
#
#   1. `base_sha` (R1.1). The run must sync to the APPROVED base, not to whatever
#      checkout the environment cache handed it. That comparison is only sound if
#      the sha is stamped by something that can actually observe the base. The
#      architect can't: its frontmatter grants no Bash, so any sha it wrote would
#      be invented or copied out of prose — and a fictional recorded sha makes the
#      staleness check WORSE than no check. Hence: the key is always present, the
#      architect always emits null, the dispatcher stamps it. This test asserts
#      the schema still says exactly that, and asserts the frontmatter still has
#      no Bash — because the moment someone grants Bash, the documented rationale
#      is stale and the rule needs rewriting rather than silently rotting.
#   2. `required_env` (R2.1/R2.6). Names are DISCOVERED, never enumerated. A var
#      name hardcoded into agent doctrine is wrong for every other repo and, worse,
#      becomes an alibi that hides the reads actually present. So the field rule
#      must keep saying so in writing.
#   3. Contract Rule for `placeholderable: false` (R2.6). It must route through the
#      EXISTING `needs_clarity` exit, before dispatch. A softened version that just
#      notes the problem in `notes[]` is a stop nothing downstream listens for: the
#      plan reads as normal and the run dispatches anyway, burning a whole
#      unattended run on a chain that could never have gone green.
#
# The JSON checks parse the fenced example with a real JSON parser rather than
# grepping it, so a schema example that has drifted into invalid JSON (a stray
# trailing comma is the classic) goes RED here instead of at 3am in a cloud run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$REPO_ROOT/.claude/agents/architect.md"
DEVPIPE="$REPO_ROOT/.claude/lib/dev-pipeline.md"
TASKBUILD="$REPO_ROOT/.claude/commands/task-build.md"
DERIVE_TOOL="$REPO_ROOT/bin/quetrex-env-derive"
CLOUD_PREP="$REPO_ROOT/bin/quetrex-cloud-prep"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

finish() {
  echo
  if [ "$FAIL" -eq 0 ]; then
    echo "architect-plan-schema.test.sh: all checks passed"
    exit 0
  else
    echo "architect-plan-schema.test.sh: FAILURES above"
    exit 1
  fi
}

if [ ! -f "$ARCH" ]; then
  fail "architect agent not found at $ARCH"
  finish
fi

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — cannot JSON-validate the plan schema example"
  finish
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- (a) the fenced plan-schema example is real, parseable JSON ---------------
# Pick the first ```json fence that contains "workstreams" — that identifies the
# plan schema and not the needs_clarity stub further down the file, without
# hardcoding a line number that every future edit would invalidate.
cat > "$TMPD/extract.js" <<'EOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const re = /```json\n([\s\S]*?)```/g;
let m, chosen = null;
while ((m = re.exec(src)) !== null) {
  if (m[1].includes('"workstreams"')) { chosen = m[1]; break; }
}
if (chosen === null) { process.stderr.write("no plan-schema json fence found\n"); process.exit(2); }
process.stdout.write(chosen);
EOF

cat > "$TMPD/checks.js" <<'EOF'
// Exits non-zero (and prints nothing usable) if the example is not valid JSON —
// that alone is a real failure, which is the point of parsing instead of grepping.
const fs = require("fs");
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const o = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = [];
out.push("required_env_array=" + (has(o, "required_env") && Array.isArray(o.required_env)));
out.push("base_sha_null=" + (has(o, "base_sha") && o.base_sha === null));
const e = Array.isArray(o.required_env) ? o.required_env[0] : null;
out.push("entry_present=" + (e !== null && typeof e === "object" && !Array.isArray(e)));
for (const k of ["name", "read_at", "placeholderable", "why"]) {
  out.push("entry_" + k + "=" + (e !== null && typeof e === "object" && has(e, k)));
}
// The key SET is closed, not merely a superset. Contract A in dev-pipeline.md says
// consumers project `name` and nothing else; an entry that grows a fifth key is a
// contract change that must be made THERE first, in all four files at once.
const keys = (e !== null && typeof e === "object" && !Array.isArray(e)) ? Object.keys(e).sort().join(",") : "";
out.push("entry_keys_exact=" + (keys === "name,placeholderable,read_at,why"));
out.push("entry_keys=" + keys);
process.stdout.write(out.join("\n") + "\n");
EOF

if node "$TMPD/extract.js" "$ARCH" > "$TMPD/schema.json" 2>"$TMPD/extract.err"; then
  pass "the plan-schema example is extractable as a fenced json block"
  if RESULTS="$(node "$TMPD/checks.js" "$TMPD/schema.json" 2>"$TMPD/checks.err")"; then
    pass "the plan-schema example parses as valid JSON"

    want() { # want <token> <description>
      case "$RESULTS" in
        *"$1=true"*) pass "$2" ;;
        *) fail "$2" ;;
      esac
    }
    want "required_env_array" 'schema example has own property required_env, an array'
    want "base_sha_null"      'schema example has own property base_sha, present and null'
    want "entry_present"      'schema example carries a required_env[0] example entry'
    # (b) the example entry shows every field a consumer is entitled to expect.
    want "entry_name"            'required_env[0] carries `name`'
    want "entry_read_at"         'required_env[0] carries `read_at`'
    want "entry_placeholderable" 'required_env[0] carries `placeholderable`'
    want "entry_why"             'required_env[0] carries `why`'
    case "$RESULTS" in
      *entry_keys_exact=true*) pass 'required_env[0] carries EXACTLY the four Contract A keys' ;;
      *) fail "required_env[0] must carry EXACTLY name,placeholderable,read_at,why — got '$(printf '%s\n' "$RESULTS" | sed -n 's/^entry_keys=//p')'. The shape is fixed by Contract A in .claude/lib/dev-pipeline.md and is read by three files that cannot see this one; a unilateral change to it fails GREEN (the consumers project nothing, hydrate nothing, and exit 0)." ;;
    esac
  else
    fail "the plan-schema example parses as valid JSON ($(tr '\n' ' ' < "$TMPD/checks.err"))"
    fail 'schema example has own property required_env, an array (unparseable)'
    fail 'schema example has own property base_sha, present and null (unparseable)'
    fail 'required_env[0] field checks (unparseable)'
  fi
else
  fail "the plan-schema example is extractable as a fenced json block ($(tr '\n' ' ' < "$TMPD/extract.err"))"
  fail 'schema example JSON checks (no block to parse)'
fi

# --- (c) the Field rules section documents both new fields --------------------
# Extract one field-rule bullet: from its `- **<name>**` line up to the next
# top-level bullet. Scoping matters — `needs_clarity`, `dispatcher` and Bash all
# appear elsewhere in the file, so an unscoped grep would pass on a gutted rule.
# Every extracted block is whitespace-normalized to ONE line before phrase greps,
# because these rules are hard-wrapped at ~95 cols and a required phrase routinely
# straddles a newline — an unnormalized grep would fail on correct prose.
field_rule() {
  awk -v pat="$1" '
    $0 ~ pat { f = 1; print; next }
    f && /^- \*\*/ { exit }
    f { print }
  ' "$ARCH" | tr '\n' ' ' | tr -s ' '
}

BASE_RULE="$(field_rule '^- [*][*]`base_sha`[*][*]')"
ENV_RULE="$(field_rule '^- [*][*]`required_env[[][]]`[*][*]')"

if [ -n "$BASE_RULE" ]; then
  pass 'Field rules document `base_sha`'
  # The writer must be named: a rule that says "someone stamps it" is unenforceable.
  case "$BASE_RULE" in
    *DISPATCHER-STAMPED*|*dispatcher*) pass 'the `base_sha` rule names the dispatcher as the writer' ;;
    *) fail 'the `base_sha` rule names the dispatcher as the writer' ;;
  esac
  # And it must cite WHY the architect can't: no Bash, so no `git rev-parse`.
  if printf '%s' "$BASE_RULE" | grep -q 'no Bash' && printf '%s' "$BASE_RULE" | grep -q 'git rev-parse'; then
    pass 'the `base_sha` rule cites the missing-Bash reason (no `git rev-parse`)'
  else
    fail 'the `base_sha` rule cites the missing-Bash reason (no `git rev-parse`)'
  fi
  # The stamping site, so the sha is taken where origin/<base> was just fetched.
  case "$BASE_RULE" in
    *task-build*) pass 'the `base_sha` rule points at the task-build stamping site' ;;
    *) fail 'the `base_sha` rule points at the task-build stamping site' ;;
  esac
  # And it forbids inventing/copying one.
  if printf '%s' "$BASE_RULE" | grep -qi 'never guess'; then
    pass 'the `base_sha` rule forbids guessing or copying a sha'
  else
    fail 'the `base_sha` rule forbids guessing or copying a sha'
  fi
else
  fail 'Field rules document `base_sha`'
  fail 'the `base_sha` rule content checks (rule missing)'
fi

if [ -n "$ENV_RULE" ]; then
  pass 'Field rules document `required_env[]`'
  # The anti-hardcode sentence is the whole defence against doctrine drifting into
  # data. Assert it verbatim, not paraphrased.
  NEEDLE='No environment variable name may be written into this file as a literal.'
  if printf '%s' "$ENV_RULE" | grep -qF "$NEEDLE"; then
    pass 'the `required_env[]` rule states no env var name may be hardcoded here'
  else
    fail 'the `required_env[]` rule states no env var name may be hardcoded here'
  fi
  # Undeterminable satisfiability goes to notes[], never a guessed boolean.
  if printf '%s' "$ENV_RULE" | grep -qF 'notes[]'; then
    pass 'the `required_env[]` rule routes statically-undeterminable names to notes[]'
  else
    fail 'the `required_env[]` rule routes statically-undeterminable names to notes[]'
  fi
  # THE SHAPE, stated in words and not only shown in the example. The example is
  # what an agent copies; the rule is what an agent reasons from, and the measured
  # defect was a consumer that reasoned "these are strings" and `.join()`ed them
  # into the literal "[object Object]" — hydrating nothing, exiting 0.
  if printf '%s' "$ENV_RULE" | grep -qF 'An array of OBJECTS, never of bare strings'; then
    pass 'the `required_env[]` rule states the shape in words: an array of OBJECTS, never bare strings'
  else
    fail 'the `required_env[]` rule must say IN WORDS that required_env is an array of OBJECTS, never of bare strings — a shape shown only in the example is a shape a consumer guesses at, and the wrong guess fails GREEN'
  fi
  MISSING_KEYS=""
  for k in name read_at placeholderable why; do
    printf '%s' "$ENV_RULE" | grep -qF "\`$k\`" || MISSING_KEYS="$MISSING_KEYS $k"
  done
  if [ -z "$MISSING_KEYS" ]; then
    pass 'the `required_env[]` rule names all four entry keys'
  else
    fail "the \`required_env[]\` rule does not name these entry keys:$MISSING_KEYS — a consumer cannot project a key the producer never documents"
  fi
  # And it must point at the ONE place the shape is owned, so a future change is
  # made in the source of truth first rather than in one of four blind files.
  if printf '%s' "$ENV_RULE" | grep -qF 'Contract A' \
     && printf '%s' "$ENV_RULE" | grep -qF 'dev-pipeline.md'; then
    pass 'the `required_env[]` rule cites Contract A in dev-pipeline.md as the single source of truth'
  else
    fail 'the `required_env[]` rule must cite Contract A in `.claude/lib/dev-pipeline.md` as the single source of truth for the shape — four files that cannot see each other at runtime need one written authority, or they drift silently and greenly'
  fi
  # `name` must be declared the only key consumers read: that is what makes the
  # canonical projection legitimate and everything else informational.
  if printf '%s' "$ENV_RULE" | grep -qiE 'only key any consumer reads|only key a consumer reads'; then
    pass 'the `required_env[]` rule declares `name` the only key a consumer reads'
  else
    fail 'the `required_env[]` rule must declare `name` the only key any consumer reads — otherwise a consumer is free to depend on read_at/why and the entry shape can never be extended'
  fi
else
  fail 'Field rules document `required_env[]`'
  fail 'the `required_env[]` rule content checks (rule missing)'
fi

# --- (d) a numbered Contract Rule ties placeholderable:false to needs_clarity --
CONTRACT_SECTION="$TMPD/contract.md"
awk '/^## Contract Rules/ { f = 1; next } f && /^## / { exit } f { print }' "$ARCH" > "$CONTRACT_SECTION"

# Isolate the single numbered rule that mentions placeholderable, so a softened
# rule cannot borrow the word `needs_clarity` from a neighbouring rule and pass.
# Normalized to one line for the same hard-wrap reason as the field rules above.
PH_RULE="$(awk '
  /^[0-9]+\. / {
    if (buf != "" && buf ~ /placeholderable/) { printf "%s", buf; exit }
    buf = $0 "\n"; next
  }
  { if (buf != "") buf = buf $0 "\n" }
  END { if (buf ~ /placeholderable/) printf "%s", buf }
' "$CONTRACT_SECTION" | tr '\n' ' ' | tr -s ' ')"

if [ -n "$PH_RULE" ]; then
  RULE_NUM="$(printf '%s\n' "$PH_RULE" | sed 's/^\([0-9]\{1,\}\)\..*/\1/')"
  pass "a numbered Contract Rule (#$RULE_NUM) covers placeholderable"

  if printf '%s' "$PH_RULE" | grep -q 'placeholderable`*: *false'; then
    pass 'the rule is keyed on `placeholderable: false`'
  else
    fail 'the rule is keyed on `placeholderable: false`'
  fi

  # The sanctioned exit — not a new terminus, not a note in notes[].
  if printf '%s' "$PH_RULE" | grep -q 'needs_clarity'; then
    pass 'the rule routes through the existing `needs_clarity` exit'
  else
    fail 'the rule routes through the existing `needs_clarity` exit'
  fi

  # Timing is load-bearing: after dispatch, the run is already burnt.
  if printf '%s' "$PH_RULE" | grep -qi 'before dispatch'; then
    pass 'the rule blocks BEFORE dispatch'
  else
    fail 'the rule blocks BEFORE dispatch'
  fi

  # One question per unsatisfiable name, so the human knows which var to supply.
  if printf '%s' "$PH_RULE" | grep -qi 'one question per'; then
    pass 'the rule demands one question per unsatisfiable name'
  else
    fail 'the rule demands one question per unsatisfiable name'
  fi

  # Keep the field rule's cross-reference honest: `required_env[]` cites this
  # rule by number, and a renumbering that silently breaks the pointer is a
  # doctrine defect of exactly the kind this file exists to prevent.
  if [ -n "$RULE_NUM" ] && grep -qF "Contract Rule $RULE_NUM" "$ARCH"; then
    pass "the field rules cross-reference this rule by its real number ($RULE_NUM)"
  else
    fail "the field rules cross-reference this rule by its real number (found #$RULE_NUM)"
  fi
else
  fail "a numbered Contract Rule covers placeholderable"
  fail 'the placeholderable Contract Rule content checks (rule missing)'
fi

# --- (e) the tools frontmatter is unchanged — still no Bash ------------------
# This is not style policing. The `base_sha` rule's entire justification is "the
# architect has no Bash, so it cannot run git rev-parse". Grant Bash and that
# prose becomes a lie while still reading as authoritative. Then this check goes
# RED and forces the rationale to be rewritten deliberately.
TOOLS_LINE="$(grep -m1 '^tools:' "$ARCH" || true)"
if [ "$TOOLS_LINE" = "tools: Read, Grep, Glob, Write" ]; then
  pass "frontmatter tools line is unchanged: $TOOLS_LINE"
else
  fail "frontmatter tools line changed (got: '${TOOLS_LINE}') — the base_sha no-Bash rationale is now stale"
fi
if printf '%s' "$TOOLS_LINE" | grep -qw 'Bash'; then
  fail "frontmatter grants Bash — the base_sha rule's 'no Bash' reason no longer holds"
else
  pass "frontmatter grants no Bash (the base_sha rationale still holds)"
fi

# --- (f) Contract A actually exists — AC19. architect.md and
# bin/quetrex-cloud-prep both cite "Contract A ... in .claude/lib/dev-pipeline.md
# ('The two env shape contracts')" as the single source of truth for the
# required_env entry shape. A grep of dev-pipeline.md found 0 occurrences of
# 'Contract A' — the cited authority did not exist. This asserts it now does,
# and that it actually states the shape rather than merely naming it.
if [ -f "$DEVPIPE" ]; then
  DP_CONTRACT_A="$(grep -c 'Contract A' "$DEVPIPE")"
  if [ "$DP_CONTRACT_A" -ge 1 ]; then
    pass "dev-pipeline.md names Contract A at least once"
  else
    fail "dev-pipeline.md never mentions Contract A — the authority architect.md and bin/quetrex-cloud-prep both cite does not exist"
  fi

  MISSING_DP_KEYS=""
  for k in name read_at placeholderable why; do
    n="$(grep -c "\`$k\`" "$DEVPIPE")"
    [ "$n" -ge 1 ] || MISSING_DP_KEYS="$MISSING_DP_KEYS $k"
  done
  if [ -z "$MISSING_DP_KEYS" ]; then
    pass "dev-pipeline.md's Contract A section names all four entry keys"
  else
    fail "dev-pipeline.md is missing these Contract A keys:$MISSING_DP_KEYS"
  fi

  DP_MISSING_FIELDS=""
  for field in required_env env_placeholdered; do
    n="$(grep -c "$field" "$DEVPIPE")"
    [ "$n" -ge 1 ] || DP_MISSING_FIELDS="$DP_MISSING_FIELDS $field"
  done
  if [ -z "$DP_MISSING_FIELDS" ]; then
    pass "dev-pipeline.md names both contract field names: required_env and env_placeholdered"
  else
    fail "dev-pipeline.md never names these contract fields:$DP_MISSING_FIELDS"
  fi

  DP_TOOL_MENTIONS="$(grep -c 'quetrex-env-derive' "$DEVPIPE")"
  if [ "$DP_TOOL_MENTIONS" -ge 1 ]; then
    pass "dev-pipeline.md names the shared derivation tool quetrex-env-derive"
  else
    fail "dev-pipeline.md never names bin/quetrex-env-derive as the shared implementation both /quetrex:init and the dispatcher call"
  fi
else
  fail "dev-pipeline.md not found at $DEVPIPE"
  fail "dev-pipeline.md Contract A key checks (file missing)"
  fail "dev-pipeline.md contract field name checks (file missing)"
  fail "dev-pipeline.md derivation tool name check (file missing)"
fi

# The architect rule must additionally read the committed derivation output
# instead of inventing a second one: it needs to say 'requiredEnv' (the
# verify.json key), '.quetrex/verify.json' (where it's committed) and
# 'dispatcher' (who repairs a miss) — 3 of 3 greps, per AC19.
ARCH_MISSING_TOKENS=""
for token in 'requiredEnv' '\.quetrex/verify\.json' 'dispatcher'; do
  n="$(grep -c "$token" "$ARCH")"
  [ "$n" -ge 1 ] || ARCH_MISSING_TOKENS="$ARCH_MISSING_TOKENS $token"
done
if [ -z "$ARCH_MISSING_TOKENS" ]; then
  pass "architect.md contains requiredEnv, .quetrex/verify.json and dispatcher (reads the committed derivation instead of inventing a second one)"
else
  fail "architect.md is missing these tokens:$ARCH_MISSING_TOKENS — it must read the committed .quetrex/verify.json requiredEnv map (the derivation's own reviewed output) instead of re-deriving it"
fi

# --- (g) the dispatcher stamps required_env one line after quetrex-plan-stamp
# — AC18. task-build.md:393 already invokes quetrex-plan-stamp with
# `|| exit 1` immediately before the spec worktree is committed and pushed;
# required_env must be stamped by the same deterministic executable path.
ac18_checks() {  # ac18_checks <file> -> prints exactly 3 lines, PASS or FAIL:<reason>
  local f="$1" derive_count derive_line derive_text stamp_line_num derive_line_num add_line_num
  derive_count="$(grep -c 'quetrex-env-derive plan' "$f")"
  if [ "$derive_count" -ge 1 ]; then echo "PASS"; else echo "FAIL:count"; fi

  derive_line="$(grep -n 'quetrex-env-derive plan' "$f" | head -1)"
  derive_text="${derive_line#*:}"
  case "$derive_text" in
    *'|| exit 1') echo "PASS" ;;
    *) echo "FAIL:suffix" ;;
  esac

  stamp_line_num="$(grep -n 'quetrex-plan-stamp ' "$f" | head -1 | cut -d: -f1)"
  derive_line_num="${derive_line%%:*}"
  add_line_num="$(grep -n 'git -C "\$TMP_WT" add -f' "$f" | head -1 | cut -d: -f1)"
  if [ -n "$stamp_line_num" ] && [ -n "$derive_line_num" ] && [ -n "$add_line_num" ] \
     && [ "$derive_line_num" -gt "$stamp_line_num" ] && [ "$derive_line_num" -lt "$add_line_num" ]; then
    echo "PASS"
  else
    echo "FAIL:order"
  fi
}

if [ -f "$TASKBUILD" ]; then
  RESULTS18="$(ac18_checks "$TASKBUILD")"
  R18_1="$(printf '%s\n' "$RESULTS18" | sed -n '1p')"
  R18_2="$(printf '%s\n' "$RESULTS18" | sed -n '2p')"
  R18_3="$(printf '%s\n' "$RESULTS18" | sed -n '3p')"

  if [ "$R18_1" = "PASS" ]; then
    pass "task-build.md calls quetrex-env-derive plan at least once"
  else
    fail "task-build.md never calls quetrex-env-derive plan — required_env is never stamped into the dispatched plan"
  fi
  if [ "$R18_2" = "PASS" ]; then
    pass "the quetrex-env-derive plan call ends with the literal '|| exit 1'"
  else
    fail "the quetrex-env-derive plan call must end with '|| exit 1'"
  fi
  if [ "$R18_3" = "PASS" ]; then
    pass "the quetrex-env-derive plan call lands after quetrex-plan-stamp and before the git add -f staging line"
  else
    fail "the quetrex-env-derive plan call must land strictly between the quetrex-plan-stamp invocation and the git add -f line that stages the plan for commit"
  fi

  STAMP_COUNT="$(grep -c 'quetrex-plan-stamp ' "$TASKBUILD")"
  if [ "$STAMP_COUNT" = "1" ]; then
    pass "the surrounding fenced block still contains exactly 1 quetrex-plan-stamp invocation (unmodified)"
  else
    fail "expected exactly 1 quetrex-plan-stamp invocation, got $STAMP_COUNT — quetrex-plan-stamp itself must not be modified"
  fi

  # NEGATIVE CONTROL — deleting only the quetrex-env-derive plan call line
  # must turn exactly 3 assertions red (the 3 above), leaving every
  # pre-existing assertion in this file green.
  MUT_TB="$TMPD/task-build.no-derive-stamp.md"
  grep -v 'quetrex-env-derive plan' "$TASKBUILD" > "$MUT_TB"
  RESULTS18_NEG="$(ac18_checks "$MUT_TB")"
  REDS18_NEG="$(printf '%s\n' "$RESULTS18_NEG" | grep -c '^FAIL')"
  if [ "$REDS18_NEG" = "3" ]; then
    pass "NEGATIVE CONTROL: deleting only the quetrex-env-derive plan call line turns exactly 3 assertions red"
  else
    fail "NEGATIVE CONTROL: expected exactly 3 reds when the call line is deleted, got $REDS18_NEG"
  fi
else
  fail "task-build.md not found at $TASKBUILD"
  fail "task-build.md dispatcher-stamp checks (file missing)"
fi

# --- (h) end to end — AC17. The dispatcher stamp closes the QDM-1 defect
# unattended: the plan carries Contract A required_env[], and
# quetrex-cloud-prep hydrate — which reads only `.name` — exports exactly the
# derived name with a credential-less placeholder, with no human hand-
# patching the spec branch.
if [ ! -f "$DERIVE_TOOL" ]; then
  fail "AC17: bin/quetrex-env-derive not found at $DERIVE_TOOL"
elif [ ! -f "$CLOUD_PREP" ]; then
  fail "AC17: bin/quetrex-cloud-prep not found at $CLOUD_PREP"
elif ! command -v jq >/dev/null 2>&1; then
  echo "SKIP AC17: jq is not installed — this section is jq-assisted, nothing to test"
else
  mk_ac17_fixture() {  # mk_ac17_fixture <dir>
    local d="$1"
    mkdir -p "$d/src"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Fixture"
    printf 'A_URL=\n' > "$d/.env.example"
    cat > "$d/src/db.js" <<'EOF'
// db client module
// A_URL has no fallback -- line 3 is the read the tool must find
const url = process.env.A_URL;
EOF
    cat > "$d/package.json" <<'EOF'
{
  "scripts": {
    "build": "./build.sh"
  }
}
EOF
    cat > "$d/build.sh" <<'EOF'
#!/usr/bin/env bash
if [ -z "${A_URL:-}" ]; then exit 1; else exit 0; fi
EOF
    chmod +x "$d/build.sh"
    git -C "$d" add -A
    git -C "$d" commit -q -m "chore: AC17 fixture"
    mkdir -p "$d/.quetrex/plan"
  }

  F17="$TMPD/ac17"
  mk_ac17_fixture "$F17"
  PLAN17="$F17/.quetrex/plan/T-1.json"
  jq -n '{
    task: "T-1", route: "STANDARD", base_sha: "deadbeef", summary: "AC17 fixture plan",
    workstreams: [], ownership: {}, acceptance: [], security_surface: [],
    verify: ["npm run build"],
    security_review_required: false, db_migration: false, impact: {}, notes: []
  }' > "$PLAN17"
  PRE17_CANON="$(jq -S . "$PLAN17")"

  "$DERIVE_TOOL" plan "$PLAN17" "$F17" >/dev/null; CODE17=$?
  if [ "$CODE17" -eq 0 ]; then
    pass "AC17: quetrex-env-derive plan exits 0"
  else
    fail "AC17: expected exit 0, got $CODE17"
  fi

  REQ_LEN17="$(jq '.required_env | length' "$PLAN17")"
  if [ "$REQ_LEN17" = "1" ]; then
    pass "AC17: required_env has length 1 after the stamp"
  else
    fail "AC17: expected required_env length 1, got '$REQ_LEN17'"
  fi

  REQ_KEYS17="$(jq -r '.required_env[0] | keys | sort | join(",")' "$PLAN17")"
  if [ "$REQ_KEYS17" = "name,placeholderable,read_at,why" ]; then
    pass "AC17: required_env[0] carries exactly name,placeholderable,read_at,why"
  else
    fail "AC17: expected exact key set, got '$REQ_KEYS17'"
  fi

  REQ_NAME17="$(jq -r '.required_env[0].name' "$PLAN17")"
  if [ "$REQ_NAME17" = "A_URL" ]; then
    pass "AC17: required_env[0].name == A_URL"
  else
    fail "AC17: expected name A_URL, got '$REQ_NAME17'"
  fi

  REQ_READAT17="$(jq -r '.required_env[0].read_at' "$PLAN17")"
  if [ "$REQ_READAT17" = "src/db.js:3" ]; then
    pass "AC17: required_env[0].read_at == src/db.js:3"
  else
    fail "AC17: expected read_at src/db.js:3, got '$REQ_READAT17'"
  fi

  POST17_DEL_CANON="$(jq -S 'del(.required_env)' "$PLAN17")"
  if [ "$POST17_DEL_CANON" = "$PRE17_CANON" ]; then
    pass "AC17: stripping required_env from the stamped plan reproduces the pre-stamp plan byte-for-byte (jq -S) -- base_sha and every architect field survive"
  else
    fail "AC17: stamping the plan altered a field other than required_env"
  fi

  cp "$PLAN17" "$TMPD/ac17-after-run1.json"
  "$DERIVE_TOOL" plan "$PLAN17" "$F17" >/dev/null
  if cmp -s "$TMPD/ac17-after-run1.json" "$PLAN17"; then
    pass "AC17: a second stamp produces a byte-identical file (idempotent)"
  else
    fail "AC17: a second stamp changed the file — the stamp must be idempotent"
  fi

  STAMP_ARTIFACTS17="$(find "$F17/.quetrex/plan" \( -name '.stamp.*' -o -name '.qxcp.*' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$STAMP_ARTIFACTS17" = "0" ]; then
    pass "AC17: 0 stray .stamp.*/.qxcp.* files remain in the plan directory"
  else
    fail "AC17: expected 0 stray temp files, found $STAMP_ARTIFACTS17"
  fi

  # UNION — a plan whose architect already emitted an entry for a name the
  # scan would not find keeps that entry, unchanged, and gains the derived one.
  F17u="$TMPD/ac17-union"
  mk_ac17_fixture "$F17u"
  PLAN17u="$F17u/.quetrex/plan/T-2.json"
  jq -n '{
    task: "T-2", route: "STANDARD", base_sha: "deadbeef", summary: "union fixture",
    workstreams: [], ownership: {}, acceptance: [], security_surface: [],
    verify: ["npm run build"],
    required_env: [{name:"ARCHITECT_ONLY",read_at:"src/other.js:9",placeholderable:true,why:"architect found it by hand"}],
    security_review_required: false, db_migration: false, impact: {}, notes: []
  }' > "$PLAN17u"
  "$DERIVE_TOOL" plan "$PLAN17u" "$F17u" >/dev/null
  UNION_LEN17="$(jq '.required_env | length' "$PLAN17u")"
  if [ "$UNION_LEN17" = "2" ]; then
    pass "AC17: UNION — re-running against a plan with an architect-authored entry yields length 2"
  else
    fail "AC17: expected union length 2, got '$UNION_LEN17'"
  fi
  ARCH_ENTRY_UNCHANGED17="$(jq -S -c '.required_env[] | select(.name=="ARCHITECT_ONLY")' "$PLAN17u")"
  if [ "$ARCH_ENTRY_UNCHANGED17" = '{"name":"ARCHITECT_ONLY","placeholderable":true,"read_at":"src/other.js:9","why":"architect found it by hand"}' ]; then
    pass "AC17: UNION — the architect's own entry is unchanged"
  else
    fail "AC17: expected the architect's entry unchanged, got '$ARCH_ENTRY_UNCHANGED17'"
  fi

  # END TO END — hydrate the stamped plan with A_URL unset.
  ENV_FILE17="$TMPD/ac17-env.sh"
  HYDRATE_OUT17="$(env -u A_URL "$CLOUD_PREP" hydrate "$PLAN17" --env-file "$ENV_FILE17" --repo "$F17" 2>/dev/null)"
  PLACEHOLDERED17="$(printf '%s\n' "$HYDRATE_OUT17" | grep "^QX_ENV_PLACEHOLDERED=" | sed "s/^QX_ENV_PLACEHOLDERED='//; s/'\$//")"
  if [ "$PLACEHOLDERED17" = "A_URL" ]; then
    pass "AC17: END TO END — hydrate prints QX_ENV_PLACEHOLDERED='A_URL' (exactly 1 name)"
  else
    fail "AC17: expected QX_ENV_PLACEHOLDERED='A_URL', got '$PLACEHOLDERED17'"
  fi

  EXPORT_LINES17="$(grep -c '^export ' "$ENV_FILE17" 2>/dev/null || true)"
  [ -n "$EXPORT_LINES17" ] || EXPORT_LINES17=0
  if [ "$EXPORT_LINES17" = "1" ]; then
    pass "AC17: END TO END — the env file has exactly 1 export line"
  else
    fail "AC17: expected exactly 1 export line, got $EXPORT_LINES17"
  fi
  if grep -q '^export A_URL=' "$ENV_FILE17" 2>/dev/null; then
    pass "AC17: END TO END — the exported name is A_URL"
  else
    fail "AC17: expected an export line for A_URL"
  fi
  CRED_SEGMENTS17="$(grep -c '@' "$ENV_FILE17" 2>/dev/null || true)"
  [ -n "$CRED_SEGMENTS17" ] || CRED_SEGMENTS17=0
  if [ "$CRED_SEGMENTS17" = "0" ]; then
    pass "AC17: END TO END — the exported value has 0 '@' credential segments"
  else
    fail "AC17: expected 0 '@' segments, got $CRED_SEGMENTS17"
  fi

  # NEGATIVE CONTROL — reverting only the stamp (skipping the `plan`
  # subcommand entirely) makes QX_ENV_PLACEHOLDERED empty and the env file
  # carry 0 export lines.
  F17n="$TMPD/ac17-neg"
  mk_ac17_fixture "$F17n"
  PLAN17n="$F17n/.quetrex/plan/T-3.json"
  jq -n '{
    task: "T-3", route: "STANDARD", base_sha: "deadbeef", summary: "neg",
    workstreams: [], ownership: {}, acceptance: [], security_surface: [],
    verify: ["npm run build"],
    security_review_required: false, db_migration: false, impact: {}, notes: []
  }' > "$PLAN17n"
  # deliberately do NOT run "$DERIVE_TOOL" plan here -- this is the negative control
  ENV_FILE17n="$TMPD/ac17-neg-env.sh"
  HYDRATE_NEG17="$(env -u A_URL "$CLOUD_PREP" hydrate "$PLAN17n" --env-file "$ENV_FILE17n" --repo "$F17n" 2>/dev/null)"
  PLACEHOLDERED17n="$(printf '%s\n' "$HYDRATE_NEG17" | grep "^QX_ENV_PLACEHOLDERED=" | sed "s/^QX_ENV_PLACEHOLDERED='//; s/'\$//")"
  if [ -z "$PLACEHOLDERED17n" ]; then
    pass "AC17: NEGATIVE CONTROL — skipping the stamp makes QX_ENV_PLACEHOLDERED empty"
  else
    fail "AC17: NEGATIVE CONTROL — expected QX_ENV_PLACEHOLDERED empty when the stamp is skipped, got '$PLACEHOLDERED17n'"
  fi
  EXPORT_LINES17n="$(grep -c '^export ' "$ENV_FILE17n" 2>/dev/null || true)"
  [ -n "$EXPORT_LINES17n" ] || EXPORT_LINES17n=0
  if [ "$EXPORT_LINES17n" = "0" ]; then
    pass "AC17: NEGATIVE CONTROL — skipping the stamp leaves 0 export lines"
  else
    fail "AC17: NEGATIVE CONTROL — expected 0 export lines, got $EXPORT_LINES17n"
  fi
fi

finish
