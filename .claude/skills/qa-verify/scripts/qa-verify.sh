#!/usr/bin/env bash
# qa-verify — the mechanical half of the qa-verify skill.
#
# Runs the project's OWN verify chain, proves no test was weakened to make it
# green, scans for leaked secrets without printing any secret, and prints a
# PASS / FAIL / WARN summary. Exits non-zero if any check FAILs.
#
# HARDCODES NO STACK. The chain is resolved through the same strict precedence
# the qa agent uses:
#   1. .quetrex/verify.json      (authoritative, machine-readable)
#   2. .claude/CLAUDE.md "## Verification"
#   3. manifest autodetect (package.json / Makefile / pyproject / go.mod / Cargo)
# There is no assumption of pnpm vs npm, biome vs eslint, jest vs vitest, or
# TypeScript at all. In a Python or Rust repo this runs that repo's commands.
#
# NO ENV-ERROR LAUNDERING: a command that exits non-zero is RED even if its
# output says "command not found" / ENOENT. Missing tooling is a setup failure
# to report, not a reason to call the run green.
#
# Usage:
#   qa-verify.sh [--base <ref>] [--term <TERM>]... [--timeout <secs>]
#                [--skip-chain] [-h|--help]
#
# Exit codes: 0 = every check passed (WARNs may be present) · 1 = a check FAILed
#             2 = could not run (not a git repo, no resolvable verify chain)

set -u

# ---------------------------------------------------------------------------
# 0. Context
# ---------------------------------------------------------------------------

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || true
if [ -z "${ROOT:-}" ]; then
  echo "qa-verify: not inside a git repository — cannot verify anything." >&2
  exit 2
fi
cd "$ROOT" || exit 2

BASE_REF=""
TERMS=()
CMD_TIMEOUT=600
SKIP_CHAIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base)    BASE_REF="${2:-}"; shift 2 ;;
    --term)    TERMS+=("${2:-}"); shift 2 ;;
    --timeout) CMD_TIMEOUT="${2:-600}"; shift 2 ;;
    --skip-chain) SKIP_CHAIN=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "qa-verify: unknown option '$1'" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t qaverify)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAILS=0
WARNS=0
RESULTS="$TMP/results"
: > "$RESULTS"
NOTV="$TMP/notverified"
: > "$NOTV"

record() {  # record <PASS|FAIL|WARN|SKIP> <label> [detail]
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$RESULTS"
  case "$1" in
    FAIL) FAILS=$((FAILS + 1)) ;;
    WARN) WARNS=$((WARNS + 1)) ;;
  esac
  return 0
}

notverified() { printf '%s\n' "$1" >> "$NOTV"; return 0; }

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Resolve the base commit this change is measured against.
if [ -z "$BASE_REF" ]; then
  for c in origin/main main origin/master master; do
    if git rev-parse --verify -q "$c" >/dev/null 2>&1; then BASE_REF="$c"; break; fi
  done
fi
BASE=""
if [ -n "$BASE_REF" ]; then
  BASE="$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
fi
[ -n "$BASE" ] || BASE="$(git rev-parse -q --verify HEAD~1 2>/dev/null || true)"

echo "qa-verify · root=$ROOT"
if [ -n "$BASE" ]; then
  echo "           base=${BASE_REF:-HEAD~1} ($(git rev-parse --short "$BASE"))"
else
  echo "           base=<none> — diff-based checks will be skipped"
  notverified "diff-based checks (anti-weakening, added-line scans): no base commit resolvable"
fi

# ---------------------------------------------------------------------------
# 1. Resolve the verify chain — precedence, never a hardcoded stack
# ---------------------------------------------------------------------------

CHAIN=()
CHAIN_SOURCE=""

read_json_array() {  # read_json_array <file> <key>
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k][]? // empty' "$1" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e '
      const fs=require("fs");
      let o; try { o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch { process.exit(1); }
      const a=o[process.argv[2]]; if(!Array.isArray(a)) process.exit(1);
      for(const c of a) process.stdout.write(String(c)+"\n");
    ' "$1" "$2" 2>/dev/null
  else
    return 1
  fi
}

chain_from_verify_json() {
  [ -f "$ROOT/.quetrex/verify.json" ] || return 1
  read_json_array "$ROOT/.quetrex/verify.json" verify
}

# Extract commands from the project CLAUDE.md "## Verification" section.
# The fence toggle is evaluated BEFORE the heading rule, so a `# comment`
# inside a fenced block cannot be mistaken for a heading and truncate the
# chain. Both fenced lines and backticked list items are recognised.
chain_from_claude_md() {
  [ -f "$ROOT/.claude/CLAUDE.md" ] || return 1
  awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    (!infence) && /^#{1,6}[[:space:]]/ {
      insec = (tolower($0) ~ /verification/) ? 1 : 0
      next
    }
    (insec && infence) {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "" || substr(line,1,1) == "#") next
      sub(/^\$[[:space:]]*/, "", line)
      print line
      next
    }
    (insec && !infence) && /^[[:space:]]*([0-9]+[.)]|[-*])[[:space:]]*`/ {
      if (match($0, /`[^`]+`/)) {
        cmd = substr($0, RSTART + 1, RLENGTH - 2)
        if (cmd != "") print cmd
      }
    }
  ' "$ROOT/.claude/CLAUDE.md" 2>/dev/null
}

# Manifest autodetect. The JS package manager is read off the lockfile — never
# assumed. Mirrors verify-gate.sh's order so the skill and the gate agree.
chain_autodetect() {
  if [ -f "$ROOT/package.json" ]; then
    local mgr=npm k
    [ -f "$ROOT/pnpm-lock.yaml" ] && mgr=pnpm
    [ -f "$ROOT/yarn.lock" ]      && mgr=yarn
    [ -f "$ROOT/bun.lockb" ]      && mgr=bun
    [ -f "$ROOT/bun.lock" ]       && mgr=bun
    for k in typecheck type-check tsc lint build test; do
      if command -v jq >/dev/null 2>&1; then
        jq -e --arg k "$k" '.scripts[$k] // empty' "$ROOT/package.json" >/dev/null 2>&1 \
          && printf '%s run %s\n' "$mgr" "$k"
      elif command -v node >/dev/null 2>&1; then
        node -e '
          const fs=require("fs");
          let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(1)}
          process.exit((o.scripts||{})[process.argv[2]]?0:1);
        ' "$ROOT/package.json" "$k" 2>/dev/null && printf '%s run %s\n' "$mgr" "$k"
      fi
    done
    return 0
  fi
  if [ -f "$ROOT/Makefile" ] || [ -f "$ROOT/makefile" ]; then
    local mk="$ROOT/Makefile"; [ -f "$mk" ] || mk="$ROOT/makefile"
    grep -qE '^lint:'  "$mk" 2>/dev/null && echo "make lint"
    grep -qE '^build:' "$mk" 2>/dev/null && echo "make build"
    grep -qE '^test:'  "$mk" 2>/dev/null && echo "make test"
    grep -qE '^check:' "$mk" 2>/dev/null && echo "make check"
    return 0
  fi
  if [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/setup.cfg" ]; then
    echo "python -m pytest -q"; return 0
  fi
  if [ -f "$ROOT/go.mod" ];    then echo "go build ./..."; echo "go test ./..."; return 0; fi
  if [ -f "$ROOT/Cargo.toml" ]; then echo "cargo build";   echo "cargo test";   return 0; fi
  return 1
}

load_chain() {
  local out
  out="$(chain_from_verify_json || true)"
  if [ -n "$out" ]; then CHAIN_SOURCE=".quetrex/verify.json"
  else
    out="$(chain_from_claude_md || true)"
    if [ -n "$out" ]; then CHAIN_SOURCE=".claude/CLAUDE.md ## Verification"
    else
      out="$(chain_autodetect || true)"
      [ -n "$out" ] && CHAIN_SOURCE="autodetected from the manifest (INFERRED — not a declared chain)"
    fi
  fi
  [ -n "$out" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && CHAIN+=("$line")
  done <<EOF
$out
EOF
  [ "${#CHAIN[@]}" -gt 0 ]
}

if [ "$SKIP_CHAIN" -eq 0 ]; then
  if ! load_chain; then
    echo "" >&2
    echo "qa-verify: no verify chain is resolvable — nothing can be proven." >&2
    echo "  Fix by declaring one, in this order of preference:" >&2
    echo "    1. .quetrex/verify.json  ->  {\"verify\":[\"<cmd>\",\"<cmd>\"]}" >&2
    echo "    2. a '## Verification' section in .claude/CLAUDE.md" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# 2. Run the chain — exit codes are the only truth
# ---------------------------------------------------------------------------

TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
[ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"

if [ "$SKIP_CHAIN" -eq 1 ]; then
  section "1. Verify chain — SKIPPED (--skip-chain)"
  notverified "the verify chain (--skip-chain was passed)"
else
  section "1. Verify chain — source: $CHAIN_SOURCE"
  case "$CHAIN_SOURCE" in
    autodetect*) record WARN "verify chain source" "INFERRED from the manifest — declare .quetrex/verify.json" ;;
  esac
  for cmd in "${CHAIN[@]}"; do
    printf '  $ %s\n' "$cmd"
    if [ -n "$TIMEOUT_BIN" ]; then
      out="$( cd "$ROOT" && $TIMEOUT_BIN -k 10 "$CMD_TIMEOUT" bash -c "$cmd" 2>&1 )"; code=$?
    else
      out="$( cd "$ROOT" && bash -c "$cmd" 2>&1 )"; code=$?
    fi
    if [ "$code" -eq 0 ]; then
      record PASS "verify: $cmd" "exit 0"
      printf '    exit 0\n'
    else
      if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
        record FAIL "verify: $cmd" "TIMED OUT after ${CMD_TIMEOUT}s (exit $code)"
      else
        record FAIL "verify: $cmd" "exit $code"
      fi
      printf '    exit %s\n' "$code"
      printf '%s\n' "$out" | tail -20 | sed 's/^/    | /'
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. Anti-weakening — was a test loosened to make the chain green?
#    Green is not proof. A test can be quietly loosened so it passes no matter
#    what. This runs HERE, in the script, so it cannot be skipped.
# ---------------------------------------------------------------------------

TEST_PATH_RE='(^|/)(tests?|specs?|__tests__|testing)/|[._-](test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$|_test\.(go|py|rb|ts|js)$|(^|/)[A-Za-z0-9_]*Test\.(java|kt|cs|scala)$'

HATCH_RE='\.skip\(|\.only\(|\bfdescribe\(|\bfit\(|\bxit\(|\bxdescribe\(|\.todo\(|@ts-ignore|@ts-nocheck|@ts-expect-error|eslint-disable|biome-ignore|type:[[:space:]]*ignore|noqa|passWithNoTests|--no-verify|pytest\.mark\.(skip|xfail)|unittest\.skip|#\[ignore\]|t\.Skip\(|\.Ignore\(|assert[[:space:]]+True[[:space:]]*$|expect\(true\)\.toBe\(true\)'

ANNOT_RE='qa-verify:[[:space:]]*allow'

# `git diff` has no --pathspec-from-file, so read the path list into argv.
git_diff_paths() {  # git_diff_paths <pathspec-file>
  [ -n "$BASE" ] || return 0
  [ -s "$1" ] || return 0
  local paths=() p
  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < "$1"
  [ "${#paths[@]}" -gt 0 ] || return 0
  git diff -U0 --no-color "$BASE"...HEAD -- "${paths[@]}" 2>/dev/null
}

# Emit "file:newline:content" for every ADDED line in the given pathspec.
added_lines() {  # added_lines <pathspec-file>
  git_diff_paths "$1" | awk '
    /^\+\+\+ b\// { file = substr($0, 7); next }
    /^\+\+\+ / { file = ""; next }
    /^@@ / {
      n = $3; sub(/^\+/, "", n); split(n, b, ","); ln = b[1] + 0; next
    }
    /^\+/ { if (file != "") { print file ":" ln ":" substr($0, 2); ln++ } }
  '
}

section "2. Anti-weakening (diff vs base)"

if [ -z "$BASE" ]; then
  record SKIP "anti-weakening" "no base commit"
else
  git diff --name-only "$BASE"...HEAD 2>/dev/null > "$TMP/changed" || : > "$TMP/changed"
  grep -Ei "$TEST_PATH_RE" "$TMP/changed" > "$TMP/testfiles" 2>/dev/null || : > "$TMP/testfiles"

  if [ ! -s "$TMP/changed" ]; then
    record WARN "anti-weakening" "the diff against the base is empty — nothing changed?"
  elif [ ! -s "$TMP/testfiles" ]; then
    record WARN "anti-weakening" "$(wc -l < "$TMP/changed" | tr -d ' ') files changed, NO test file touched — is this change covered?"
    notverified "test coverage of the changed files: no test file was added or modified"
  else
    added_lines "$TMP/testfiles" > "$TMP/added_tests" 2>/dev/null || : > "$TMP/added_tests"
    grep -Ei "$HATCH_RE" "$TMP/added_tests" 2>/dev/null | grep -Ev "$ANNOT_RE" > "$TMP/hatches" || : > "$TMP/hatches"
    if [ -s "$TMP/hatches" ]; then
      record FAIL "anti-weakening: escape hatches added to tests" "$(wc -l < "$TMP/hatches" | tr -d ' ') unannotated"
      sed 's/^/    /' "$TMP/hatches"
      echo "    -> Remove each, or annotate the same line with: qa-verify: allow <reason>"
    else
      record PASS "anti-weakening: no escape hatch added to a test" ""
    fi
  fi

  # Assertions and whole test files removed by this change.
  if [ -s "$TMP/testfiles" ]; then
    DEL_ASSERTS="$(git_diff_paths "$TMP/testfiles" \
      | grep '^-' | grep -v '^---' | grep -cEi 'expect\(|assert|should\(|\.toBe|\.toEqual' || true)"
    DEL_ASSERTS="${DEL_ASSERTS:-0}"
    if [ "$DEL_ASSERTS" -gt 0 ]; then
      record WARN "anti-weakening: $DEL_ASSERTS assertion line(s) deleted from tests" "explain each in the PR body"
    fi
  fi
  git diff --diff-filter=D --name-only "$BASE"...HEAD 2>/dev/null | grep -Ei "$TEST_PATH_RE" > "$TMP/deltests" || : > "$TMP/deltests"
  if [ -s "$TMP/deltests" ]; then
    record WARN "anti-weakening: test file(s) deleted" "$(wc -l < "$TMP/deltests" | tr -d ' ') — explain each in the PR body"
    sed 's/^/    /' "$TMP/deltests"
  fi

  # Did the change edit the thing that DEFINES green?
  GUARD_RE='^\.quetrex/verify\.json$|(^|/)tsconfig[^/]*\.json$|(^|/)\.eslintrc|(^|/)eslint\.config\.|(^|/)biome\.jsonc?$|(^|/)\.claude/CLAUDE\.md$|(^|/)ruff\.toml$|(^|/)mypy\.ini$|(^|/)pytest\.ini$|(^|/)setup\.cfg$|(^|/)\.golangci|(^|/)clippy\.toml$|(^|/)jest\.config\.|(^|/)vitest\.config\.'
  grep -Ei "$GUARD_RE" "$TMP/changed" > "$TMP/guarded" 2>/dev/null || : > "$TMP/guarded"
  if [ -s "$TMP/guarded" ]; then
    record WARN "verification config changed by this diff" "prove it was not loosened"
    sed 's/^/    /' "$TMP/guarded"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Secrets — report position, never content; env files excluded and asserted
# ---------------------------------------------------------------------------

section "3. Secrets"

ENV_PATH_RE='(^|/)\.env($|\.)'
SKIP_PATH_RE='(^|/)(node_modules|dist|build|vendor|target|\.next|coverage)/|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|Cargo\.lock|go\.sum|poetry\.lock|composer\.lock)$|\.(example|sample|template)$|(^|/)(SKILL|README|SECURITY|CHANGELOG)\.md$|(^|/)\.claude/skills/qa-verify/'

{ git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null \
  | sort -u | grep -Ev "$SKIP_PATH_RE" | grep -Ev "$ENV_PATH_RE" > "$TMP/scanlist" || : > "$TMP/scanlist"

# Keyword must sit beside an assignment with a substantial value — so lockfile
# digests and prose stay quiet. False positives erode trust in the check.
SEC_RE='(api[_-]?key|secret|passwd|password|access[_-]?key|private[_-]?key|token|bearer)[a-z0-9_]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_./+-]{16,}'

if [ -s "$TMP/scanlist" ]; then
  tr '\n' '\0' < "$TMP/scanlist" \
    | xargs -0 grep -nIEi -e "$SEC_RE" -- 2>/dev/null \
    | awk -F: '
        {
          file=$1; ln=$2;
          rest="";
          for (i=3; i<=NF; i++) rest = rest (i>3 ? ":" : "") $i;
          low=tolower(rest);
          key="secret";
          if      (match(low, /private[_-]?key/)) key="private_key";
          else if (match(low, /access[_-]?key/))  key="access_key";
          else if (match(low, /api[_-]?key/))     key="api_key";
          else if (match(low, /passwd|password/)) key="password";
          else if (match(low, /bearer/))          key="bearer";
          else if (match(low, /token/))           key="token";
          printf "%s:%s\t%s = ****(masked, %d chars on line)\n", file, ln, key, length(rest);
        }' > "$TMP/secrets" || : > "$TMP/secrets"
else
  : > "$TMP/secrets"
fi

if [ -s "$TMP/secrets" ]; then
  record FAIL "secret-shaped assignment in a non-env file" "$(wc -l < "$TMP/secrets" | tr -d ' ') hit(s)"
  sed 's/^/    /' "$TMP/secrets"
  echo "    -> Values are masked on purpose. Open each file:line yourself."
else
  record PASS "no secret-shaped assignment outside env files" ""
fi

# Env files are NOT scanned (that would dump them into context). They are
# asserted instead: never tracked, always gitignored.
ENV_BAD=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in *.example|*.sample|*.template) continue ;; esac
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    echo "    TRACKED IN GIT: $f"; ENV_BAD=$((ENV_BAD + 1)); continue
  fi
  if ! git check-ignore -q -- "$f" 2>/dev/null; then
    echo "    NOT GITIGNORED: $f"; ENV_BAD=$((ENV_BAD + 1))
  fi
done <<EOF
$(find . -maxdepth 3 -type f \( -name '.env' -o -name '.env.*' \) \
    -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | sed 's|^\./||')
EOF

if [ "$ENV_BAD" -gt 0 ]; then
  record FAIL "env files must be gitignored and untracked" "$ENV_BAD violation(s)"
else
  record PASS "env files untracked and gitignored (contents never read)" ""
fi
notverified "the contents of .env* files — deliberately never read by this script"

# ---------------------------------------------------------------------------
# 5. TypeScript-only checks — skipped entirely when there is no TypeScript
# ---------------------------------------------------------------------------

section "4. Language-specific"

HAS_TS=0
if [ -f "$ROOT/tsconfig.json" ] || git ls-files -- '*.ts' '*.tsx' 2>/dev/null | head -1 | grep -q .; then
  HAS_TS=1
fi

if [ "$HAS_TS" -eq 0 ]; then
  record SKIP "no-any check" "no TypeScript in this repo"
elif [ -z "$BASE" ]; then
  record SKIP "no-any check" "no base commit"
else
  grep -E '\.tsx?$' "$TMP/changed" > "$TMP/tsfiles" 2>/dev/null || : > "$TMP/tsfiles"
  if [ -s "$TMP/tsfiles" ]; then
    added_lines "$TMP/tsfiles" 2>/dev/null \
      | grep -E ':[[:space:]]*any\b|as any\b|<any>|Array<any>' \
      | grep -Ev "$ANNOT_RE" > "$TMP/anys" || : > "$TMP/anys"
    if [ -s "$TMP/anys" ]; then
      record FAIL "\`any\` introduced in TypeScript" "$(wc -l < "$TMP/anys" | tr -d ' ') added line(s)"
      sed 's/^/    /' "$TMP/anys"
      echo "    -> Type it, or annotate the line with: qa-verify: allow <reason>"
    else
      record PASS "no \`any\` added to TypeScript" ""
    fi
  else
    record SKIP "no-any check" "no .ts/.tsx file changed"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Rename / removal proof (--term) — unfiltered, no file-type filters
# ---------------------------------------------------------------------------

if [ "${#TERMS[@]}" -gt 0 ]; then
  section "5. Rename / removal proof"
  { git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u > "$TMP/allfiles"
  for term in "${TERMS[@]}"; do
    [ -n "$term" ] || continue

    if [ -s "$TMP/allfiles" ]; then
      tr '\n' '\0' < "$TMP/allfiles" | xargs -0 grep -nIi -e "$term" -- 2>/dev/null > "$TMP/termhits" || : > "$TMP/termhits"
    else
      : > "$TMP/termhits"
    fi
    if [ -s "$TMP/termhits" ]; then
      record FAIL "term '$term' still present in content" "$(wc -l < "$TMP/termhits" | tr -d ' ') line(s)"
      head -40 "$TMP/termhits" | sed 's/^/    /'
      echo "    -> Every remaining hit must be removed or annotated in the PR body."
    else
      record PASS "term '$term' absent from all tracked+untracked content" ""
    fi

    grep -i -- "$term" "$TMP/allfiles" > "$TMP/termnames" 2>/dev/null || : > "$TMP/termnames"
    if [ -s "$TMP/termnames" ]; then
      record FAIL "term '$term' still present in filenames" "$(wc -l < "$TMP/termnames" | tr -d ' ') path(s)"
      sed 's/^/    /' "$TMP/termnames"
    else
      record PASS "term '$term' absent from all filenames" ""
    fi

    git branch -a --format='%(refname:short)' 2>/dev/null | grep -i -- "$term" > "$TMP/termbranches" || : > "$TMP/termbranches"
    if [ -s "$TMP/termbranches" ]; then
      record WARN "term '$term' still present in branch names" "$(wc -l < "$TMP/termbranches" | tr -d ' ')"
      sed 's/^/    /' "$TMP/termbranches"
    else
      record PASS "term '$term' absent from branch names" ""
    fi
  done
else
  notverified "rename/removal proof — no --term was passed (pass --term TERM when a term was purged)"
fi

# ---------------------------------------------------------------------------
# 7. Branch hygiene
# ---------------------------------------------------------------------------

section "6. Branch"

CUR="$(git branch --show-current 2>/dev/null || true)"
if [ -z "$CUR" ]; then
  record WARN "current branch" "detached HEAD"
elif [ "$CUR" = "main" ] || [ "$CUR" = "master" ]; then
  record FAIL "current branch is '$CUR'" "all work belongs on a branch"
else
  record PASS "on branch '$CUR'" ""
fi

# ---------------------------------------------------------------------------
# 8. Summary — and what was NOT verified
# ---------------------------------------------------------------------------

notverified "acceptance criteria from the plan artifact — this script proves mechanics, not intent"
notverified "runtime / end-to-end behaviour"
notverified "conventional-commit format and the PR body"

printf '\n\033[1m== SUMMARY\033[0m\n'
awk -F'\t' '{ printf "  %-5s %s%s\n", $1, $2, ($3 == "" ? "" : "  — " $3) }' "$RESULTS"

printf '\n\033[1m== NOT VERIFIED (state these explicitly)\033[0m\n'
sed 's/^/  · /' "$NOTV"

PASSES="$(grep -c '^PASS' "$RESULTS" 2>/dev/null || echo 0)"
printf '\n%s passed · %s failed · %s warned\n' "$PASSES" "$FAILS" "$WARNS"

if [ "$FAILS" -gt 0 ]; then
  printf '\n\033[1mRESULT: FAIL\033[0m — %s check(s) failed. The task is NOT done.\n' "$FAILS"
  exit 1
fi
printf '\nRESULT: PASS — mechanical checks clean. Report the WARN and NOT VERIFIED lines anyway.\n'
exit 0
