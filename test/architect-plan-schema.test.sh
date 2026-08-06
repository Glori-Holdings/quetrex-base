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

finish
