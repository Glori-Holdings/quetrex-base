#!/usr/bin/env bash
# edit-gate.sh — PostToolUse hook (matcher: "Write|Edit").
#
# THE GAP THIS CLOSES. The verify chain runs at Stop, at the END of a turn. A
# syntax or type error introduced by the FIRST edit of a long turn therefore
# stays invisible until the agent tries to finish — at which point it costs a
# full verify chain to discover, and burns one of only three self-heal
# attempts. Three such edits exhaust the budget, write .quetrex/ESCALATION, and
# block the merge on what was a one-character typo. A per-file syntax check
# costs about a second and hands the error back immediately.
#
# CONTRACT. PostToolUse fires AFTER the tool already ran, so this hook can
# never prevent the write — that is by design and is not what it is for. What
# exit 2 does here is feed stderr straight back to the model as context, so the
# agent reads its own error and fixes it on the spot without the user asking.
# Exit 0 = quiet pass. Exit 1 would be silently ignored; never use it.
#
# DELIBERATELY NARROW, for three reasons:
#   - CHECK ONLY, NEVER FIX. A formatter already runs ahead of this hook
#     (auto-format.sh). A gate that rewrites the file the agent just wrote
#     makes the agent's mental model of the file wrong. Any resolved command
#     containing a fix/write flag is REFUSED rather than run.
#   - ONE FILE, the one just edited. This is not a project build.
#   - A HARD 10s CAP. This runs after every single edit; it must never become
#     the reason a turn feels slow, and it must never outlive its own hook
#     timeout.
#
# COMMAND RESOLUTION, in priority order. NOTHING here hardcodes a stack: tiers
# 1-2 read the project's OWN configuration, in exactly verify-gate.sh's
# precedence, and tier 3 is a syntax parse in the file's own language.
#   1. .quetrex/verify.json -> .editCheck[] — an array of {match, command}
#      objects, where `match` is a shell glob against the file's basename and
#      `command` contains the {file} placeholder. First match wins. This is how
#      a project opts into a stricter per-file check than the defaults below.
#   2. The project's VERIFY CHAIN, resolved the way verify-gate.sh resolves it —
#      .quetrex/verify.json (.verifyEdit[] else .verify[]), else the
#      "## Verification" fenced block in .claude/CLAUDE.md, else autodetect —
#      then filtered to the entries that can actually check ONE file (a linter,
#      not `next build`), with the project-wide path target and EVERY fix flag
#      stripped. This is what makes the per-edit check and the finish gate agree
#      about the project's toolchain without either one naming a stack.
#   3. built-in syntax checks by extension (below).
# No rule matches -> exit 0 silently. Many edits check nothing, and that is the
# correct behavior: this gate exists to catch the cheap, unambiguous class of
# error, not to duplicate the verify chain.

set -uo pipefail

# --- qx_repo_armed: the ONE shared arming predicate (ONE-COPY round 2) -----
# See session-state.sh's identical comment for why a path two levels up from
# this file resolves the sibling helper correctly both in the repo checkout
# and in the installed "quetrex" plugin cache.
QX_ARMED_HELPER="$(dirname "${BASH_SOURCE[0]}")/../../plugins/quetrex-factory/scripts/qx-armed.sh"
if ! source "$QX_ARMED_HELPER" 2>/dev/null || ! command -v qx_repo_armed >/dev/null 2>&1; then
  qx_repo_armed() { [ -n "${1:-}" ] && [ -f "$1/.quetrex/project.json" ]; }
fi

CAP="${QUETREX_EDIT_BUDGET:-10}"
case "$CAP" in ''|*[!0-9]*) CAP=10 ;; esac

input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

FILE=""
SESSION_CWD=""
if [ "$HAVE_JQ" -eq 1 ]; then
  FILE=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  SESSION_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
fi
if [ -z "$FILE" ]; then
  # jq-free fallback, so tiers 2-3 still work on a machine without jq. This hook
  # is advisory, so an unreadable payload exits 0 rather than blocking: the gate
  # that must fail closed is verify-gate.sh, and it does.
  FILE=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
if [ -z "$SESSION_CWD" ]; then
  SESSION_CWD=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
[ -n "$FILE" ] || exit 0
[ -f "$FILE" ] || exit 0    # deleted or never landed -> nothing to check

# --- resolve repo root (worktree-safe; mirrors verify-gate.sh) --------------
ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || ROOT="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
# The edited file's own repo, before the hook's cwd — the hook's cwd can belong
# to a different checkout entirely, which would silently skip every check.
[ -z "$ROOT" ] && ROOT=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null)
[ -z "$ROOT" ] && ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

# ARMED-ONLY: an unarmed repo (no .quetrex/project.json) gets none of the
# pipeline's per-edit checking — "unarmed repo = no gates at all".
# SEC-ONECOPY-1 (round 2): qx_repo_armed also honors project.json tracked at
# HEAD / the default branch tip, not just the working-tree file.
qx_repo_armed "$ROOT" || exit 0

# Only ever check a file inside the project. An edit to a file elsewhere on the
# machine is none of this gate's business, and the pipeline's own control
# artifacts are not source.
case "$FILE" in
  "$ROOT"/*) ;;
  *) exit 0 ;;
esac
case "$FILE" in
  "$ROOT"/.quetrex/*|"$ROOT"/.git/*) exit 0 ;;
esac

BASE=$(basename "$FILE")
EXT="${BASE##*.}"
[ "$EXT" = "$BASE" ] && EXT=""
CMD=""

# --- 1. project-declared per-file check -------------------------------------
VERIFY_JSON="$ROOT/.quetrex/verify.json"
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$VERIFY_JSON" ]; then
  while IFS=$'\t' read -r pat tmpl; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254  # $pat is intentionally a glob
    case "$BASE" in
      $pat) CMD="$tmpl"; break ;;
    esac
  done < <(jq -r '(.editCheck // [])[] | select(.match and .command) | "\(.match)\t\(.command)"' "$VERIFY_JSON" 2>/dev/null)
fi

# --- 2. derive from the project's OWN verify chain ---------------------------
# Same sources, same order, as verify-gate.sh — so the per-edit check and the
# finish gate can never disagree about which toolchain this project uses, and
# nothing about a stack is assumed here.
chain_from_verify_json() {
  [ "$HAVE_JQ" -eq 1 ] || return 1
  [ -f "$VERIFY_JSON" ] || return 1
  local sel
  for sel in .verifyEdit .verify; do
    if jq -e "$sel | type == \"array\" and length > 0" "$VERIFY_JSON" >/dev/null 2>&1; then
      jq -r "$sel[]" "$VERIFY_JSON" 2>/dev/null
      return 0
    fi
  done
  return 1
}

chain_from_claude_md() {
  local f="$ROOT/.claude/CLAUDE.md" out
  [ -f "$f" ] || return 1
  # The fence toggle is evaluated BEFORE the heading rule, and the heading rule
  # only applies OUTSIDE a fence — otherwise a `# comment` inside the block is
  # read as a heading and silently truncates the chain.
  out=$(awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    (!infence && /^#{1,6}[[:space:]]/) { insec = (tolower($0) ~ /verification/) ? 1 : 0; next }
    (insec && infence) {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      sub(/^\$[[:space:]]*/, "", line)
      print line
    }
  ' "$f" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

chain_autodetect() {
  local pkg="$ROOT/package.json" key out=""
  [ "$HAVE_JQ" -eq 1 ] || return 1
  [ -f "$pkg" ] || return 1
  for key in typecheck type-check tsc lint build test; do
    jq -e --arg k "$key" '.scripts[$k] // empty' "$pkg" >/dev/null 2>&1 && out="$out
npm run $key"
  done
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Which tools can meaningfully check exactly ONE file, and for which languages.
# A capability table, not a stack choice: an entry only ever fires when the
# PROJECT already put that tool in its own verify chain.
tool_exts() {
  case "$1" in
    eslint|oxlint)  echo "ts tsx js jsx mjs cjs mts cts vue svelte" ;;
    biome)          echo "ts tsx js jsx mjs cjs mts cts json jsonc css" ;;
    prettier)       echo "ts tsx js jsx mjs cjs json jsonc css scss less html md mdx yaml yml" ;;
    stylelint)      echo "css scss less sass" ;;
    ruff|flake8|pylint|pyflakes|mypy|pyright) echo "py pyi" ;;
    shellcheck)     echo "sh bash" ;;
    rubocop)        echo "rb" ;;
    luacheck)       echo "lua" ;;
    phpcs|phpstan)  echo "php" ;;
    swiftlint)      echo "swift" ;;
    ktlint)         echo "kt kts" ;;
    *)              echo "" ;;
  esac
}

takes_value() {
  case "$1" in
    -c|--config|--config-file|--rcfile|--ext|--parser|--plugin|--rulesdir| \
    --resolve-plugins-relative-to|--max-warnings|--format|-f|--ignore-path| \
    --cache-location|--report|--settings|--output-format|--reporter) return 0 ;;
  esac
  return 1
}

looks_like_target() {
  case "$1" in
    .|./|../*|./*|*/*|*'*'*) return 0 ;;
  esac
  [ -e "$ROOT/$1" ] && return 0
  return 1
}

# Turn one chain entry into a per-file check command (with a {file} slot), or
# print nothing when that entry cannot check a single file of THIS type.
build_from_chain_entry() {
  local tool out a exts
  set -f
  # shellcheck disable=SC2086
  set -- $1
  set +f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      sudo|env|command|time|nice|ionice) shift ;;
      npx|bunx|pnpx) shift ;;
      pnpm|npm|yarn|bun) shift; case "${1:-}" in exec|run|dlx|x) shift ;; esac ;;
      poetry|uv|rye|pipenv|pdm) shift; case "${1:-}" in run) shift ;; esac ;;
      python|python3) shift; case "${1:-}" in -m) shift ;; *) return 0 ;; esac ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  tool="${1##*/}"
  exts=$(tool_exts "$tool")
  [ -n "$exts" ] || return 0
  [ -n "$EXT" ] || return 0
  case " $exts " in *" $EXT "*) ;; *) return 0 ;; esac
  command -v "$tool" >/dev/null 2>&1 || [ -x "$ROOT/node_modules/.bin/$tool" ] || return 0
  out="$1"; shift
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      # NEVER auto-fix — fixing hides the violation.
      --fix|--fix-dry-run|--write|-w|--apply|--apply-unsafe|--unsafe|--fix-suggestions) continue ;;
      --fix-type) [ "$#" -gt 0 ] && shift; continue ;;
      --fix-type=*) continue ;;
      -*)
        out="$out $a"
        if takes_value "$a" && [ "$#" -gt 0 ]; then out="$out $1"; shift; fi
        continue ;;
      *)
        # Drop the project-wide path target of the original invocation
        # (`eslint .`) — this gate checks ONE file.
        looks_like_target "$a" && continue
        out="$out $a"
        continue ;;
    esac
  done
  printf '%s {file}' "$out"
}

if [ -z "$CMD" ]; then
  CHAIN=$(chain_from_verify_json || chain_from_claude_md || chain_autodetect || true)
  if [ -n "$CHAIN" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      CMD=$(build_from_chain_entry "$entry")
      [ -n "$CMD" ] && break
    done <<< "$CHAIN"
  fi
fi

# --- 3. built-in syntax checks ----------------------------------------------
# Syntax/parse only — cheap, unambiguous, and free of project configuration.
# A type check is deliberately NOT here: per-file `tsc` ignores the project's
# tsconfig and reports errors that are not real. Projects wanting one declare
# it through .editCheck[] where they can pass their own flags.
if [ -z "$CMD" ]; then
  case "$FILE" in
    *.sh|*.bash)          command -v bash    >/dev/null 2>&1 && CMD='bash -n {file}' ;;
    *.js|*.cjs|*.mjs)     command -v node    >/dev/null 2>&1 && CMD='node --check {file}' ;;
    *.json)               [ "$HAVE_JQ" -eq 1 ] && CMD='jq empty {file}' ;;
    *.py)                 command -v python3 >/dev/null 2>&1 && CMD='python3 -m py_compile {file}' ;;
    *.rb)                 command -v ruby    >/dev/null 2>&1 && CMD='ruby -c {file}' ;;
    *.go)                 command -v gofmt   >/dev/null 2>&1 && CMD='gofmt -e {file}' ;;
    *) ;;
  esac
fi

[ -n "$CMD" ] || exit 0

# --- refuse anything that would REWRITE the file ----------------------------
# A check that mutates the file the agent just wrote desynchronizes the agent
# from its own work. Refusing loudly beats silently rewriting.
case "$CMD" in
  *--fix*|*--write*|*-w\ *|*--in-place*|*-i\ *)
    printf 'edit-gate: refusing to run a rewriting command as a check: %s\n' "$CMD" >&2
    printf 'Declare a CHECK-ONLY command in .quetrex/verify.json .editCheck[] — formatting is auto-format.sh, not this gate.\n' >&2
    exit 2
    ;;
esac

# Substitute the file path. Quoted at the call site so spaces are safe.
RUN=${CMD//\{file\}/\"$FILE\"}

# --- run under a hard cap (10s default; QUETREX_EDIT_BUDGET overrides) ------
if command -v timeout >/dev/null 2>&1; then
  OUT=$( (cd "$ROOT" && timeout -k 2 "${CAP}s" bash -c "$RUN") 2>&1 ); CODE=$?
elif command -v gtimeout >/dev/null 2>&1; then
  OUT=$( (cd "$ROOT" && gtimeout -k 2 "${CAP}s" bash -c "$RUN") 2>&1 ); CODE=$?
else
  OUT=$( (cd "$ROOT" && bash -c "$RUN") 2>&1 ); CODE=$?
fi

[ "$CODE" -eq 0 ] && exit 0

# A timeout is NOT a code failure. Saying "your edit is broken" when the check
# merely ran long would send the agent chasing a bug that does not exist.
if [ "$CODE" -eq 124 ] || [ "$CODE" -eq 137 ]; then
  printf 'edit-gate: the per-file check for %s exceeded its %ss cap and was killed. This is a CHECK-SPEED problem, not a defect in your edit — do not "fix" the file in response. Simplify the .editCheck[] command.\n' "${FILE#"$ROOT"/}" "$CAP" >&2
  exit 2
fi

# 127 = the resolved tool is not installed here. That is a SETUP failure, not a
# defect in the edit, and verify-gate.sh already reports a missing toolchain as
# RED at the finish boundary with a far better message. Note it on stderr and
# exit 0 rather than burn the agent's attention on it after every edit.
if [ "$CODE" -eq 127 ]; then
  printf 'edit-gate: `%s` is not installed here, so the per-file check was skipped. The Stop gate still runs the full chain.\n' "$CMD" >&2
  exit 0
fi

REL=${FILE#"$ROOT"/}
{
  printf 'edit-gate: `%s` failed on %s (exit %d) immediately after your edit.\n' "$CMD" "$REL" "$CODE"
  printf 'Fix it now, in this file. Catching it here costs one second; the same error found by the Stop-time verify chain costs the full chain and one of only three self-heal attempts.\n\n'
  printf '%s\n' "$OUT" | tail -n 20
} >&2
exit 2
