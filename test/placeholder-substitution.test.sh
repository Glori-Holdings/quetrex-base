#!/usr/bin/env bash
# test/placeholder-substitution.test.sh — SPEC R4.2, the substitution guard.
#
# Run: bash test/placeholder-substitution.test.sh
#
# THE DEFECT THIS CLOSES (RC4). .claude/lib/cloud-build-routine.md is a template:
# .claude/commands/task-build.md Step 6A fills its `{{...}}` placeholders and
# pastes the filled text verbatim as a RemoteTrigger event's `message.content`.
# The substituted set lived in one sentence of task-build.md and the template's
# placeholders lived in another file, with nothing tying the two together — so
# the template grew a placeholder (`{{TASK_ID}}`, in the gates-branch name) that
# task-build.md never substituted. Every cloud run therefore received a LITERAL
# unfilled placeholder, pushed its evidence to a branch of that literal name, and
# /quetrex:merge looked for the real name and found nothing: gate evidence could
# never come home, on every single run, silently.
#
# A missing substitution is invisible in review (both files read correctly on
# their own) and invisible at runtime (the prompt is still valid text). Only a
# set-comparison catches it. So this test makes the two lists a CHECKED CONTRACT:
#
#   1. SUBSET  — every `{{X}}` anywhere in cloud-build-routine.md appears in the
#      substituted list in task-build.md. Fails with the offending placeholder
#      and its line numbers.
#   2. EXACT   — the placeholder TABLE at the top of cloud-build-routine.md names
#      exactly the substituted set, no more and no less, so the operator-facing
#      documentation cannot drift away from the code path that fills it.
#   3. NEGATIVE CONTROL — the detector is run against a MUTATED copy of the real
#      template with novel placeholders injected, and must report every one. This
#      is what makes assertion 1 mean "no unsubstituted placeholder can ship"
#      rather than "no placeholder named {{TASK_ID}} can ship". Without it, a
#      too-narrow pattern (or one that stops matching at all) makes assertion 1
#      pass VACUOUSLY: an empty extracted set is a subset of everything.
#
# Both sides are located by ANCHOR TEXT, never by line number: this file must not
# start lying the moment an unrelated line is inserted above it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_ROOT/.claude/lib/cloud-build-routine.md"
COMMAND="$REPO_ROOT/.claude/commands/task-build.md"

for f in "$TEMPLATE" "$COMMAND"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f"
    exit 1
  fi
done

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-placeholders.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A placeholder is any `{{…}}` run with no brace inside it. Deliberately NOT
# `{{[A-Za-z0-9_]+}}`: the point of this guard is to catch a placeholder NOBODY
# ANTICIPATED, and a pattern that only admits the naming convention already in use
# would wave through `{{TASK-ID}}`, `{{ TASK }}` or `{{task_id}}` — each of which
# would reach the cloud session as literal text exactly like `{{TASK_ID}}` did.
#
# The one thing that must not be treated as a placeholder is the template's own
# PROSE about placeholders ("any OTHER `{{…}}` name reaches the cloud session as a
# literal"). The rule that separates them carries no name list: a placeholder
# contains at least one ASCII alphanumeric; the ellipsis form contains none.
# Assertion 3 pins both halves of that behaviour.
placeholders() {
  grep -o '{{[^{}]\{1,\}}}' | grep '[A-Za-z0-9]' | sort -u
}

# --- 1. what the TEMPLATE needs filled -------------------------------------
placeholders < "$TEMPLATE" > "$WORK/template.txt"

# --- 2. what task-build.md actually SUBSTITUTES ----------------------------
# The authority is the single paragraph beginning "…substitute its …" and ending
# at the following blank line. Reading the whole file instead would silently
# absorb any placeholder mentioned anywhere in prose and make the guard useless.
SUBST_START="$(grep -n 'substitute its' "$COMMAND" | head -n1 | cut -d: -f1)"
if [ -z "$SUBST_START" ]; then
  fail "cannot find the substitution paragraph in $COMMAND (anchor: 'substitute its') — the guard has no authority to check against"
  echo
  echo "placeholder-substitution.test.sh: FAILURES above"
  exit 1
fi
awk -v start="$SUBST_START" 'NR >= start { if (NR > start && $0 ~ /^[[:space:]]*$/) exit; print }' \
  "$COMMAND" > "$WORK/subst-paragraph.txt"
SUBST_END=$(( SUBST_START + $(wc -l < "$WORK/subst-paragraph.txt") - 1 ))
placeholders < "$WORK/subst-paragraph.txt" > "$WORK/substituted.txt"

# The comparison itself, as a function, so assertion 3 can re-run the EXACT code
# path of assertion 1 against a template that is known to be broken.
unsubstituted_in() {
  placeholders < "$1" > "$WORK/candidate.txt"
  comm -23 "$WORK/candidate.txt" "$WORK/substituted.txt"
}

if [ ! -s "$WORK/substituted.txt" ]; then
  fail "the substitution paragraph at $COMMAND:$SUBST_START-$SUBST_END names no placeholders at all"
fi

# --- 3. the operator-facing TABLE in the template ---------------------------
# Anchored on the "**Placeholders**" lead-in; the table is the run of `|` rows
# that follows it. Only the first cell is read, because the "Filled with" column
# legitimately mentions other placeholders in prose.
TABLE_START="$(grep -n '^\*\*Placeholders\*\*' "$TEMPLATE" | head -n1 | cut -d: -f1)"
if [ -z "$TABLE_START" ]; then
  fail "cannot find the placeholder table lead-in ('**Placeholders**') in $TEMPLATE"
  : > "$WORK/table.txt"
else
  awk -v start="$TABLE_START" '
    NR < start { next }
    /^\|/ { rows = rows $0 "\n"; seen = 1; next }
    seen  { exit }
    { next }
    END { printf "%s", rows }
  ' "$TEMPLATE" > "$WORK/table-rows.txt"
  awk -F'|' '{ print $2 }' "$WORK/table-rows.txt" | placeholders > "$WORK/table.txt"
fi

# =============================================================================
# ASSERTION 0 — the extractor actually extracted something
# =============================================================================
# Vacuity guard. `comm -23` over an empty left side is empty, so a broken
# extractor turns assertion 1 into an unconditional pass — the precise failure
# shape this whole file exists to prevent.
if [ -s "$WORK/template.txt" ]; then
  pass "the extractor found $(wc -l < "$WORK/template.txt" | tr -d ' ') placeholder(s) in cloud-build-routine.md"
else
  fail "extracted ZERO placeholders from $TEMPLATE — the detector is broken (or the template stopped being a template), and assertion 1 below would pass vacuously"
fi

# =============================================================================
# ASSERTION 1 — template placeholders ⊆ substituted set
# =============================================================================
MISSING="$(unsubstituted_in "$TEMPLATE")"
if [ -z "$MISSING" ]; then
  pass "every placeholder in cloud-build-routine.md is substituted by task-build.md:$SUBST_START-$SUBST_END ($(wc -l < "$WORK/template.txt" | tr -d ' ') placeholders)"
else
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    LINES="$(grep -n -- "$p" "$TEMPLATE" | cut -d: -f1 | paste -sd, - | tr -d ' ')"
    fail "UNSUBSTITUTED placeholder $p — present in .claude/lib/cloud-build-routine.md at line(s) $LINES but NOT in the substituted list at .claude/commands/task-build.md:$SUBST_START-$SUBST_END. The cloud session would receive the literal text $p."
  done <<EOF
$MISSING
EOF
fi

# =============================================================================
# ASSERTION 2 — the documented table equals the substituted set exactly
# =============================================================================
if [ -s "$WORK/table.txt" ]; then
  UNDOCUMENTED="$(comm -13 "$WORK/table.txt" "$WORK/substituted.txt")"
  PHANTOM="$(comm -23 "$WORK/table.txt" "$WORK/substituted.txt")"
  if [ -z "$UNDOCUMENTED" ] && [ -z "$PHANTOM" ]; then
    pass "the placeholder table in cloud-build-routine.md names exactly the substituted set ($(wc -l < "$WORK/table.txt" | tr -d ' ') rows)"
  else
    [ -z "$UNDOCUMENTED" ] || fail "substituted but MISSING a row in the cloud-build-routine.md placeholder table: $(printf '%s' "$UNDOCUMENTED" | paste -sd' ' -)"
    [ -z "$PHANTOM" ] || fail "documented in the cloud-build-routine.md placeholder table but NOT substituted by task-build.md: $(printf '%s' "$PHANTOM" | paste -sd' ' -)"
  fi
else
  fail "extracted no placeholder rows from the table in $TEMPLATE — the documentation contract cannot be checked"
fi

# =============================================================================
# ASSERTION 3 — negative control: the detector detects
# =============================================================================
# `{{TASK_ID}}` shipped once; the next one will have a different name, and quite
# possibly a different shape. So: take the REAL template, inject placeholders that
# nobody substitutes — including shapes the old `{{[A-Za-z0-9_]+}}` pattern could
# not see — and require assertion 1's own code path to report every one of them.
# A weakened or over-narrow detector fails HERE instead of going quietly green.
MUTANT="$WORK/mutant-template.md"
cp "$TEMPLATE" "$MUTANT"
{
  echo
  echo "Injected by test/placeholder-substitution.test.sh (negative control):"
  echo "    UNIT_BRANCH=\"{{NEVER_SUBSTITUTED}}\""      # the conventional shape
  echo "    echo {{lower_case_name}}"                    # lowercase
  echo "    echo {{HYPHEN-NAME}}"                        # a character the old pattern excluded
  echo "    echo {{ PADDED_NAME }}"                      # surrounding whitespace
} >> "$MUTANT"

MUTANT_MISSING="$(unsubstituted_in "$MUTANT")"
UNDETECTED=""
for inj in '{{NEVER_SUBSTITUTED}}' '{{lower_case_name}}' '{{HYPHEN-NAME}}' '{{ PADDED_NAME }}'; do
  printf '%s\n' "$MUTANT_MISSING" | grep -qxF -- "$inj" || UNDETECTED="$UNDETECTED $inj"
done
if [ -z "$UNDETECTED" ]; then
  pass "negative control: all 4 injected placeholder shapes are reported as unsubstituted"
else
  fail "negative control: the guard did NOT report these injected, unsubstituted placeholders:$UNDETECTED — it can only catch the placeholder shapes already in use, so the NEXT unsubstituted placeholder ships silently"
fi

# The other half of the rule: the template's prose about placeholders in general
# must not be mistaken for one, or the guard cries wolf on every run and gets
# deleted by the next person who touches it.
if printf '%s\n' "$MUTANT_MISSING" | grep -q '{{[^A-Za-z0-9{}]*}}'; then
  fail "negative control: the guard reported a NON-placeholder (the template's own \`{{…}}\` prose form) — false positives are how a guard gets switched off: $(printf '%s\n' "$MUTANT_MISSING" | grep '{{[^A-Za-z0-9{}]*}}' | paste -sd' ' -)"
else
  pass "negative control: the template's \`{{…}}\` prose form is not mistaken for a placeholder"
fi

# =============================================================================
# ASSERTION 4 — {{TITLE}} is under the contract, by name
# =============================================================================
# Assertions 1-2 are set comparisons: they guarantee that WHATEVER the template
# needs is documented and substituted. They are silent, though, about a
# placeholder being deleted from all three places at once — which is exactly how
# {{TITLE}} could regress. {{TITLE}} carries the transport/session name the
# operator reads on his phone (cloud-build-routine.md's prompt now leads with
# `{{TASK}} — {{TITLE}}`; before that, every concurrent cloud build showed the
# identical boilerplate first line and was unidentifiable). Pin it by name so
# removing it fails HERE, loudly, instead of quietly restoring the defect while
# the set comparison stays green on a smaller set.
TITLE_MISSING=""
grep -qF '{{TITLE}}' "$WORK/template.txt"    || TITLE_MISSING="$TITLE_MISSING template-body"
grep -qF '{{TITLE}}' "$WORK/table.txt"       || TITLE_MISSING="$TITLE_MISSING placeholder-table"
grep -qF '{{TITLE}}' "$WORK/substituted.txt" || TITLE_MISSING="$TITLE_MISSING task-build-substitution-list"
if [ -z "$TITLE_MISSING" ]; then
  pass "{{TITLE}} is present in all three places the contract covers: the template body, the placeholder table, and task-build.md's substitution list"
else
  fail "{{TITLE}} is absent from:$TITLE_MISSING — it is the task's short title in the cloud session's first prompt line, i.e. the ONLY thing that distinguishes one running build from another on the operator's phone"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "placeholder-substitution.test.sh: all checks passed"
  exit 0
else
  echo "placeholder-substitution.test.sh: FAILURES above"
  exit 1
fi
