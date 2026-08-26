#!/usr/bin/env bash
# test/ac18-live-line-sweep.test.sh — AC18 of .quetrex/plan/GLOBAL.json,
# generalized beyond just the three moved command files to every real bash
# surface this product ships (the same three defect classes, wherever
# executable bash actually lives), and made COMMENT-AWARE so a line that
# merely DISCUSSES one of these patterns (every shipped script explains WHY
# it avoids them) is never confused with a line that actually uses one.
#
# THE THREE FORBIDDEN PATTERNS, and why each is a real defect class, not a
# style preference:
#   1. ${CLAUDE_PLUGIN_ROOT} outside a hooks.json file. In plugin
#      slash-command bash (a command's own ```bash fence) this variable is
#      UNSET — Claude Code only exports it to HOOK processes, never to a
#      command's bash block. A command that references it silently resolves
#      to an empty string, producing a bare, broken path. hooks.json files
#      are the ONE place it legitimately appears (that IS how a hook
#      resolves its own plugin root), so they are excluded from this check.
#   2. ~/.claude/lib — a plugin never seeds that path; a shipped script
#      referencing it depends on machinery the per-project gate-copy retired.
#   3. `read -r ... < <(` — `read` returns NON-ZERO when the process
#      substitution's last line has no trailing newline, so any
#      `|| { fatal }` guard right after it fires on SUCCESS. This is the
#      exact defect that made /quetrex-setup:login fail 100% of the time on
#      healthy input (see test/plugin.test.js's header).
#
# SCOPE: every real .sh script under plugins/quetrex-setup/,
# plugins/quetrex-factory/ and .claude/hooks/, plus every ```bash fence
# embedded in every command file under .claude/commands/ and
# plugins/quetrex-setup/commands/ — the full set of places this product's
# own bash actually executes. test/** is deliberately excluded: a test
# fixture legitimately constructs and asserts against these exact strings.
#
# COMMENT-AWARE: within each scanned unit, a line is EXCLUDED from the sweep
# when, after trimming leading whitespace, it starts with `#` — every
# occurrence of these three patterns in the shipped tree today is exactly
# that: a comment explaining why the pattern is avoided, never a live use.
# This is proven below by construction: the same sweep run WITHOUT the
# comment filter finds real hits (the explanatory comments themselves), and
# WITH the filter finds zero — demonstrating the filter is load-bearing, not
# decorative.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# live_lines <file> -> stdout: every line of <file> with comment lines
# (trimmed leading whitespace starts with '#') removed.
live_lines() {
  # `sed 's/^[[:space:]]*//'` trims, then the pattern-space test drops '#'
  # lines; awk is simpler and more portable across the shells this repo
  # already assumes (see test/lib/check-sh.sh's own portability notes).
  awk '{ line=$0; sub(/^[ \t]*/, "", line); if (substr(line,1,1) != "#") print $0 }' "$1"
}

# scan_unit <label> <content-file> — appends any pattern hit for the 3
# forbidden shapes found in the LIVE lines of <content-file>.
SCAN_BAD=0
scan_unit() {
  local label="$1" f="$2" live
  live="$(live_lines "$f")"
  if printf '%s\n' "$live" | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
    case "$label" in
      */hooks.json) : ;;  # the one legitimate use site
      *)
        SCAN_BAD=$((SCAN_BAD + 1))
        notok "AC18: $label has a LIVE (non-comment) \${CLAUDE_PLUGIN_ROOT} reference outside a hooks.json file — UNSET in slash-command bash"
        ;;
    esac
  fi
  if printf '%s\n' "$live" | grep -qF '~/.claude/lib'; then
    SCAN_BAD=$((SCAN_BAD + 1))
    notok "AC18: $label has a LIVE (non-comment) ~/.claude/lib reference — a plugin never seeds that path"
  fi
  if printf '%s\n' "$live" | grep -qE 'read -r .*< <'; then
    SCAN_BAD=$((SCAN_BAD + 1))
    notok "AC18: $label has a LIVE (non-comment) \`read -r ... < <(\` — read exits non-zero without a trailing newline and fires \`|| fatal\` on SUCCESS"
  fi
}

UNITS=0

# --- real shipped scripts ----------------------------------------------
for f in plugins/quetrex-setup/scripts/*.sh plugins/quetrex-setup/bin/* plugins/quetrex-setup/lib/*.sh \
         plugins/quetrex-setup/*.sh plugins/quetrex-factory/scripts/*.sh .claude/hooks/*.sh; do
  [ -f "$f" ] || continue
  UNITS=$((UNITS + 1))
  scan_unit "$f" "$f"
done

# --- every ```bash fence embedded in every command file -----------------
TMPDIR_AC18="$(mktemp -d "${TMPDIR:-/tmp}/qx-ac18.XXXXXX")"
trap 'rm -rf "$TMPDIR_AC18"' EXIT
BLOCKS=0
for dir in .claude/commands plugins/quetrex-setup/commands; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8");
      const out = process.argv[2];
      let i = 0;
      for (const m of src.matchAll(/```bash\n([\s\S]*?)```/g)) {
        i++;
        fs.writeFileSync(out + "." + i, m[1]);
      }
      process.stdout.write(String(i));
    ' "$f" "$TMPDIR_AC18/$(basename "$f")" > "$TMPDIR_AC18/count"
    n="$(cat "$TMPDIR_AC18/count")"
    for ((i = 1; i <= n; i++)); do
      block="$TMPDIR_AC18/$(basename "$f").$i"
      [ -f "$block" ] || continue
      BLOCKS=$((BLOCKS + 1))
      UNITS=$((UNITS + 1))
      scan_unit "$dir/$(basename "$f") block#$i" "$block"
      if ! bash -n "$block" 2>/tmp/ac18-bashn.$$; then
        SCAN_BAD=$((SCAN_BAD + 1))
        notok "AC18: $dir/$(basename "$f") block#$i fails bash -n: $(cat /tmp/ac18-bashn.$$)"
      fi
      rm -f /tmp/ac18-bashn.$$
    done
  done
done

if [ "$BLOCKS" -gt 0 ]; then
  ok "AC18: extracted $BLOCKS bash fence(s) from the command files (block count > 0)"
else
  notok "AC18: extracted 0 bash fences from the command files — the extractor is broken or the tree is empty"
fi

if [ "$UNITS" -eq 0 ]; then
  notok "AC18: 0 units scanned — the file globs matched nothing"
else
  ok "AC18: scanned $UNITS unit(s) (shipped scripts + command bash fences)"
fi

if [ "$SCAN_BAD" -eq 0 ]; then
  ok "AC18: 0 live (non-comment) occurrences of any of the 3 forbidden patterns across $UNITS unit(s)"
fi

# =============================================================================
# FAIL-FIRST (mechanical): the comment filter is load-bearing, not
# decorative. Every current occurrence of these patterns in the shipped tree
# is a comment; prove that the SAME sweep, run WITHOUT the comment filter,
# actually finds them — so a passing scan above is not merely "the grep
# pattern never matches anything, commented or not".
# =============================================================================
RAW_HIT_COUNT=0
for f in plugins/quetrex-setup/scripts/*.sh plugins/quetrex-setup/bin/* plugins/quetrex-setup/lib/*.sh \
         plugins/quetrex-setup/*.sh plugins/quetrex-factory/scripts/*.sh .claude/hooks/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in
    */hooks.json) continue ;;
  esac
  n="$(grep -cF '${CLAUDE_PLUGIN_ROOT}' "$f" 2>/dev/null || true)"
  RAW_HIT_COUNT=$((RAW_HIT_COUNT + ${n:-0}))
done
if [ "$RAW_HIT_COUNT" -gt 0 ]; then
  ok "FAIL-FIRST: the same \${CLAUDE_PLUGIN_ROOT} sweep WITHOUT the comment filter finds $RAW_HIT_COUNT raw occurrence(s) (all of them comments explaining the rule) — the comment filter above is genuinely doing work, not passing vacuously"
else
  notok "FAIL-FIRST: the raw (unfiltered) sweep found 0 occurrences of \${CLAUDE_PLUGIN_ROOT} anywhere — the comment-filtered pass above proves nothing, since there was nothing to filter"
fi

echo
echo "ac18-live-line-sweep.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
