#!/usr/bin/env bash
# protected-files-guard.sh — PreToolUse guard over the FIVE safety-floor
# scripts (deny-guard.sh, secret-scan.sh, enforce-branch.sh, merge-gate.sh,
# verify-gate.sh), covering BOTH the Write/Edit vector and Bash-mediated
# writes (cp/mv/sed -i/tee/redirection/install/rsync/dd/ln/truncate).
#
# WHAT THIS IS NOT. It is NOT the fix for the observed reversions (four repos
# on disk still carrying a pre-fix verify-gate.sh, plus session binding to a
# stale plugin cache — see quetrex-bound-version-guard.sh for the latter). A
# permission gate in quetrex-base would have caught NONE of those; it closes a
# DIFFERENT vector — an in-session edit or `cp` overwriting a floor script —
# that has not fired yet but would be the obvious next one.
#
# HOOKFIX CORRECTION 2 (operator-approved, 2026-08-21, verified against
# https://code.claude.com/docs/en/hooks.md): this hook DENIES, it never asks.
# The original design used permissionDecision:"ask", but the docs do not
# define what "ask" does when prompts are disabled (skipDangerousModePermission
# Prompt / a non-prompting default mode) — it may be silently ignored, which is
# precisely the failure this guard exists to prevent: a guard that LOOKS
# installed and gates NOTHING. What IS verified: a "deny" decision is
# absolute and honored in every permission mode, including bypassPermissions.
# So a write to a floor script is DENIED by default. The unlock is the
# environment variable QUETREX_UNLOCK_FLOOR=1 — never a marker file inside
# the repo (a file is something an agent can create for itself, which would
# make the guard trivially self-authorizing). Every unlocked write is
# RECORDED, never silent.
#
# SEC-6 (security review, 2026-08-21): the unlock is NOT self-granting via
# the ONE path this hook actually closes — an agent cannot smuggle
# QUETREX_UNLOCK_FLOOR=1 into the environment of the SAME Bash command that
# performs the edit, since a PreToolUse hook sees that command's own
# env only if the agent explicitly prefixes it there, and no other
# in-session mechanism lets a Bash tool call inject an env var into a
# DIFFERENT, later PreToolUse invocation. What this guard does NOT close:
# `.claude/settings.json`'s top-level `env` block IS passed through to
# every hook subprocess quetrex-base spawns (confirmed empirically), so an
# agent that already has write access to settings.json — the SAME
# permission surface that gates most other repo-wide changes — could add
# QUETREX_UNLOCK_FLOOR=1 there and unlock every future floor-script write
# for the rest of the session, not just one command. That is a real,
# disclosed limitation of THIS mechanism, not a false guarantee: the
# original text here claimed the unlock "cannot be self-granted" without
# qualification, which settings.json's env reaching hook subprocesses
# makes plainly false. Reported to the operator as a design gap in the
# unlock mechanism itself (not a defect in this hook's enforcement of it);
# the mechanism is unchanged pending that decision.
#
# DECISION SCHEMA: PreToolUse denies via
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# on stdout, exit 0 — the same jq-primary / printf-fallback shape
# plugins/quetrex-factory/scripts/deny-guard.sh and merge-gate.sh's own
# deny() already use. When jq is unavailable the fallback is deliberately NOT hand-rolled
# JSON (a control byte in a captured command/reason would malform it, and a
# malformed payload is DROPPED and reads as ALLOW) — it uses the OTHER
# blocking channel the hook contract provides: exit 2 with the reason on
# stderr. A missing jq must never degrade this guard to silence.
#
# PROTECTED SET (CORRECTED, C1 review finding, critical): the six floor
# basenames are SOURCED in exactly one place (plugins/quetrex-factory/
# scripts/, the one-copy rule), but that is NOT the only path shape that
# actually EXECUTES. The prior version of this comment claimed the
# repo-local copy and "the INSTALLED marketplace copy" share one tail,
# quetrex-factory/scripts/<name>.sh — true for a marketplace CLONE
# (.claude/plugins/marketplaces/quetrex/plugins/quetrex-factory/scripts/),
# but FALSE for the copy CLAUDE_PLUGIN_ROOT actually resolves and RUNS at
# runtime: the plugin CACHE, which interposes a VERSION directory —
# .claude/plugins/cache/quetrex/quetrex-factory/<VERSION>/scripts/<name>.sh
# (e.g. .../quetrex-factory/1.7.3/scripts/merge-gate.sh). The narrowed
# regex never matched that tail, so a Write to the copy that governs every
# armed repo on the machine went from DENY (40feac8) to silent ALLOW —
# reproduced and fixed here. PROT_PATH_ERE now matches all three shapes:
#   1. plugins/quetrex-factory/scripts/<name>.sh        (repo-local, or a
#      marketplace clone — no version segment interposed)
#   2. quetrex-factory/<anything>/scripts/<name>.sh      (the installed
#      CACHE layout — the one that actually executes)
#   3. (hooks|scripts)/<name>.sh                         (the PRE-one-copy
#      floor, kept as a FLOOR per "when you replace a detector, keep the
#      old one and prove you lost nothing" — closes SEC-ONECOPY-2 too: a
#      forked/older-layout repo or plugin-cache generation that still ships
#      a floor script under hooks/ or a bare scripts/ stays protected)
# `cd` tracking (mirroring merge-gate.sh's own PENDING_CD) still covers a
# bare <name> written from inside a directory ending .../quetrex-factory/
# scripts (or a versioned .../quetrex-factory/<ver>/scripts). session-
# state.sh, edit-gate.sh, auto-format.sh and quetrex-update-check.sh are
# deliberately NOT protected — they are not the floor, and a set that
# grows past the floor trains the operator to click through the one prompt
# that matters.
#
# ARMED-ONLY EXEMPTION (C3 review finding): the INSTALLED shapes (1 and 2
# above, under .claude/plugins/cache/ or .claude/plugins/marketplaces/) are
# machine-global — outside any repo root, and governing EVERY armed repo on
# the machine, not just the session's own. Gating their protection on the
# SESSION's own arming state left them writable from any scratch/unarmed
# repo. See PROT_INSTALLED_HINT_ERE and the bypass below the ARMED-ONLY
# gate: those two shapes are checked BEFORE that gate, unconditionally.
# Shape 3 (the pre-one-copy floor) and a bare repo-local
# plugins/quetrex-factory/scripts/<name>.sh remain armed-gated as before —
# they describe a REPO's own committed floor, which is only meaningful for
# a repo actually under Quetrex management.
#
# TOKENIZER: split_segments_quote_aware() and normalize_segment(), copied
# VERBATIM (not sourced — merge-gate.sh executes at load, so it cannot be
# sourced without running the merge gate) from
# plugins/quetrex-factory/scripts/merge-gate.sh, between the
# `# >>> QX-CMDSCAN BEGIN/END` sentinels below.
#
# REVIEWER FIX (2026-08-21): this comment used to say "merge-gate.sh itself
# is UNCHANGED" — no longer true. SEC-17 (security review, 2026-08-21)
# found a Critical in this shared tokenizer's `>|` handling that required
# fixing all THREE copies (this file, merge-gate.sh, and verify-gate-
# quick-chain.sh) in the same commit. The copy is pinned MECHANICALLY, not
# just by convention: test/protected-files-guard.test.sh's AC16 extracts BOTH
# tokenizer functions from ALL THREE files (merge-gate.sh, this file, and
# verify-gate-quick-chain.sh) by their function-name boundaries and asserts
# byte-identity PAIRWISE across all three, so a future fix to any one
# copy's parser cannot silently leave the other two on an older, weaker
# one.
#
# Registered: PreToolUse, matcher "Bash|Write|Edit", in this repo's
# hooks/hooks.json, command bash "${CLAUDE_PLUGIN_ROOT}/.claude/hooks/protected-files-guard.sh".
set -uo pipefail

# --- qx_repo_armed: the ONE shared arming predicate (ONE-COPY round 2) -----
# See session-state.sh's identical comment for why a path two levels up from
# this file resolves the sibling helper correctly both in the repo checkout
# and in the installed "quetrex" plugin cache.
QX_ARMED_HELPER="$(dirname "${BASH_SOURCE[0]}")/../../plugins/quetrex-factory/scripts/qx-armed.sh"
if ! source "$QX_ARMED_HELPER" 2>/dev/null || ! command -v qx_repo_armed >/dev/null 2>&1; then
  qx_repo_armed() { [ -n "${1:-}" ] && [ -f "$1/.quetrex/project.json" ]; }
fi

# --- read hook input (absence is fine) -------------------------------------
input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

JQ_OK=0
command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq . >/dev/null 2>&1 && JQ_OK=1

if [ "$JQ_OK" -eq 1 ]; then
  TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  FILE_PATH=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  COMMAND=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  SESSION_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
else
  # jq-free fallback (same shape as secret-scan.sh:72-77 / merge-gate.sh:107-111).
  # A missing jq must never degrade to silence: best-effort extraction, then
  # evaluate whatever was found.
  TOOL_NAME=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  FILE_PATH=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  COMMAND=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
  SESSION_CWD=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

[ -n "$TOOL_NAME" ] || exit 0
case "$TOOL_NAME" in Bash|Write|Edit) : ;; *) exit 0 ;; esac

# --- worktree-safe ROOT ------------------------------------------------
resolve_root() {
  local r=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR:-}" ]; then
    r=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || r="$CLAUDE_PROJECT_DIR"
  fi
  if [ -z "$r" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
    r=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
  fi
  [ -z "$r" ] && r=$(git rev-parse --show-toplevel 2>/dev/null)
  printf '%s' "$r"
}

# --- the protected set (moved above the ARMED-ONLY gate: C3 needs PROT_ALT
# to build the installed-plugin hint BEFORE that gate can run) -------------
# The six floor basenames, including verify-gate-quick-chain.sh (added
# 2026-08-21): verify-gate.sh now SOURCES it, so editing it changes the gate's
# behavior exactly as effectively as editing verify-gate.sh itself would,
# without ever touching the "protected" file by name.
PROT_ALT='deny-guard|secret-scan|enforce-branch|merge-gate|verify-gate|verify-gate-quick-chain'
# Path-tail shape, matched anywhere in the text (a file_path value or a Bash
# command/segment string) — see the PROTECTED SET comment above the vector
# sections below for the three alternatives and why each exists.
PROT_PATH_ERE="(^|[^A-Za-z0-9_.-])(quetrex-factory/(scripts|[^/]+/scripts)/(${PROT_ALT})\\.sh|(hooks|scripts)/(${PROT_ALT})\\.sh)([^A-Za-z0-9_.-]|\$)"
# Bare basename only (no leading path segment) — used together with `cd`
# tracking below for the fourth shape the plan names.
PROT_BARE_ERE="(^|[^A-Za-z0-9_.-])(${PROT_ALT})\\.sh([^A-Za-z0-9_.-]|\$)"
# C3: the shapes that are machine-global (outside ANY repo root, governing
# every armed repo on the machine) — the installed marketplace clone and,
# critically, the installed CACHE copy with its interposed version segment.
# A raw substring hint, not the full protected-path grammar: used ONLY to
# decide whether to bypass the ARMED-ONLY exit below, never to make the
# actual deny/allow decision (that is still names_protected_path_or_symlink
# against the real target token, later, via the existing SEC-7-fixed
# write-target extraction). A false-positive hint here just means an
# unarmed repo does a little more work before correctly allowing something
# that was never actually a protected write target.
# SEC-ONECOPY-5 (Medium, round 2): requiring `.*quetrex-factory` in this hint
# meant only the STANDALONE quetrex-factory plugin's cached/marketplace copy
# was recognized as "installed, machine-global" — the five floor-script
# copies cached under the "quetrex" plugin's OWN versions (e.g.
# ~/.claude/plugins/cache/quetrex/quetrex/2.5.3/.claude/hooks/merge-gate.sh,
# and every OTHER installed version on the machine: 2.4.0, 2.5.0, 2.5.1,
# 2.5.2, ...) stayed writable from an UNARMED session, since they no longer
# hit this hint and fell straight through to the ARMED-ONLY exit below on
# the session's own (unarmed) repo. `.claude/plugins/(cache|marketplaces)/`
# is already the whole "this is a machine-global installed-plugin path, not
# something inside the session's own repo" signal — PROT_PATH_ERE (matched
# afterward, on the real candidate token) is what actually decides whether
# the path names a protected floor script, so broadening this HINT only
# means an unarmed repo does a little more work before correctly allowing
# something that was never a protected target. Covers both plugins'
# cache/marketplace layouts, any plugin name, any version segment.
PROT_INSTALLED_HINT_ERE='(^|[^A-Za-z0-9_.-])\.claude/plugins/(cache|marketplaces)/'

# ARMED-ONLY, WITH THE C3 EXEMPTION: "unarmed repo = no gates at all" for
# everything EXCEPT the machine-global installed-plugin shapes above, which
# are not a property of the session's own repo and must stay protected no
# matter what that repo's arming state is. Resolve ROOT once, up front,
# before any pattern-matching or decision emission, and reuse it below
# (allow_unlocked no longer needs its own resolve_root call).
ROOT=$(resolve_root)
INSTALLED_TARGET_HINT=0
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  printf '%s' "$FILE_PATH" | grep -Eq "$PROT_INSTALLED_HINT_ERE" && INSTALLED_TARGET_HINT=1
else
  printf '%s' "$COMMAND" | grep -Eq "$PROT_INSTALLED_HINT_ERE" && INSTALLED_TARGET_HINT=1
fi
# SEC-ONECOPY-1 (round 2): qx_repo_armed also honors project.json tracked at
# HEAD / the default branch tip, not just the working-tree file.
if [ "$INSTALLED_TARGET_HINT" -eq 0 ] && { [ -z "$ROOT" ] || ! qx_repo_armed "$ROOT"; }; then
  exit 0
fi

# qx_normalize_path <path> -- collapses "./" and "a/../b" SYNTACTICALLY (no
# filesystem access, no realpath dependency -- the target frequently does not
# exist yet). SEC-4 FIX (2026-08-21, security review): ".claude/hooks/./
# verify-gate.sh" and ".claude/hooks/sub/../verify-gate.sh" do not literally
# contain the substring "hooks/verify-gate.sh" and previously slipped past
# the regex untouched. bash 3.2-safe (no negative array indices — this repo
# ships on macOS's stock /usr/bin/bash; see merge-gate.sh's own note on the
# same constraint).
qx_normalize_path() {
  local p="$1" part leading_slash="" last_idx joined
  local -a parts=() out=()
  case "$p" in /*) leading_slash="/" ;; esac
  IFS='/' read -ra parts <<< "$p"
  for part in "${parts[@]}"; do
    case "$part" in
      .|'') continue ;;
      ..)
        last_idx=$((${#out[@]} - 1))
        if [ "$last_idx" -ge 0 ] && [ "${out[$last_idx]}" != ".." ]; then
          unset "out[$last_idx]"
          out=(${out[@]+"${out[@]}"})
        else
          out+=("..")
        fi
        ;;
      *) out+=("$part") ;;
    esac
  done
  ( IFS='/'; joined="${out[*]:-}"; printf '%s%s' "$leading_slash" "$joined" )
}

names_protected_path() {  # <text> -> 0 if it names a protected hooks/scripts path
  local norm
  norm=$(qx_normalize_path "$1")
  printf '%s' "$norm" | grep -Eq "$PROT_PATH_ERE" && return 0
  printf '%s' "$1" | grep -Eq "$PROT_PATH_ERE"
}
names_bare_protected() {  # <text> -> 0 if it names a bare protected basename
  printf '%s' "$1" | grep -Eq "$PROT_BARE_ERE"
}
# names_protected_path_or_symlink <candidate-target-token> -- SEC-4 FIX,
# closes the two-step symlink indirection (`ln -s <protected> /tmp/x` in one
# Bash call, `cp evil /tmp/x` in a LATER one): this hook has no memory across
# separate tool calls (same documented boundary as merge-gate.sh's own
# command-string parser), but by the time the SECOND call is evaluated, the
# symlink from the FIRST call already exists on disk. One hop of
# `readlink` — never followed recursively, never executed — catches exactly
# that shape without turning this into a general filesystem-resolution
# engine.
names_protected_path_or_symlink() {
  local t="$1"
  names_protected_path "$t" && return 0
  if [ -L "$t" ] 2>/dev/null; then
    local link_target
    link_target=$(readlink "$t" 2>/dev/null)
    [ -n "$link_target" ] && names_protected_path "$link_target" && return 0
  fi
  return 1
}

# --- deny / allow (correct PreToolUse schema; exit 0) -----------------------
deny() {
  local reason="$1"
  reason="$reason To make this change anyway, the operator (not the agent) must set QUETREX_UNLOCK_FLOOR=1 in the environment of the command that performs the edit — never a marker file in the repo, which an agent could create for itself."
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
  printf '%s\n' "$reason" >&2
  exit 2
}

# UNLOCKED: an explicit, operator-set env var authorizes this one write. Never
# silent — record it, then allow via an explicit decision (never bare
# silence) so the unlock is auditable in the same place a normal deny would
# have appeared.
allow_unlocked() {  # allow_unlocked <what>
  local what="$1" root logf ts
  root="$ROOT"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -n "$root" ] && [ -d "$root" ]; then
    mkdir -p "$root/.quetrex" 2>/dev/null
    logf="$root/.quetrex/protected-files-unlock.log"
    if [ -e "$logf" ] || [ -L "$logf" ]; then rm -f "$logf" 2>/dev/null; fi
    ( umask 077; printf '%s | QUETREX_UNLOCK_FLOOR=1 | tool: %s | %s\n' "$ts" "$TOOL_NAME" "$what" >> "$logf" )
    chmod 600 "$logf" 2>/dev/null
  fi
  local reason="UNLOCKED (QUETREX_UNLOCK_FLOOR=1): a safety-floor script edit was explicitly authorized by the operator and recorded ($what)."
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}'
  fi
  exit 0
}

is_unlocked() { [ "${QUETREX_UNLOCK_FLOOR:-}" = "1" ]; }

# =============================================================================
# >>> QX-CMDSCAN BEGIN — copied verbatim from plugins/quetrex-factory/scripts/merge-gate.sh
# (split_segments_quote_aware, normalize_segment). Do NOT hand-edit this
# region independently of merge-gate.sh OR verify-gate-quick-chain.sh (the
# THIRD copy); test/protected-files-guard.test.sh's AC16 asserts byte-
# identity across all three copies pairwise, extracted by function-name
# boundary.
# =============================================================================
split_segments_quote_aware() {
  # Two `local` statements, same reason as tokenize_argv below: word
  # expansion for the WHOLE `local` command happens before the builtin
  # runs, against the enclosing scope's state -- `n=${#s}` on the same
  # line as `s="$1"` would see `s` as unset under `set -u`.
  local s="$1"
  local i=0 n=${#s} c two nc out='' in_sq=0 in_dq=0 in_cm=0 have=0 gt=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    if [ "$in_cm" -eq 1 ]; then
      out+="$c"; gt=0
      if [ "$c" = $'\n' ]; then in_cm=0; have=0; fi
    elif [ "$in_sq" -eq 1 ]; then
      out+="$c"; have=1; gt=0
      [ "$c" = "'" ] && in_sq=0
    elif [ "$in_dq" -eq 1 ]; then
      out+="$c"; have=1; gt=0
      if [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then
        i=$((i + 1)); out+="${s:$i:1}"; gt=0
      elif [ "$c" = '"' ]; then
        in_dq=0
      fi
    else
      case "$c" in
        ' ' | $'\t')
          out+="$c"; have=0; gt=0
          ;;
        $'\n')
          out+="$c"; have=0; gt=0
          ;;
        "'") in_sq=1; out+="$c"; have=1; gt=0 ;;
        '"') in_dq=1; out+="$c"; have=1; gt=0 ;;
        '#')
          # A `#` starts a shell comment only at the START of a word --
          # tracked with the SAME `have` flag tokenize_argv uses (whether
          # we're currently mid-token), not by inspecting the last emitted
          # character. Those disagree: `a\ #x` (an ESCAPED space before
          # `#`) leaves the literal character before `#` a space either
          # way, but the escape means we're still INSIDE the word "a x" —
          # `have` correctly stays 1 through an escaped separator (see the
          # `\` case below), while inspecting `${out: -1}` could not tell
          # an escaped separator from a real one and wrongly started a
          # "comment" mid-word. A differential test (DEFECT K) feeds both
          # functions the same corpus and fails on any disagreement.
          if [ "$have" -eq 0 ]; then
            in_cm=1
          fi
          out+="$c"; have=1; gt=0
          ;;
        '\')
          # SEC-17 (security review, 2026-08-21): an escaped character is
          # emitted VERBATIM here, so `a\>` leaves a literal '>' as the
          # LAST EMITTED character -- indistinguishable, by inspecting
          # `out` alone, from a real unescaped redirect operator. This is
          # exactly the trap the '#' branch's own comment above already
          # warns about ("could not tell an escaped separator from a real
          # one"). `gt` is explicitly cleared on every path through this
          # branch (never inferred from the emitted bytes), so the
          # '&'|'|' branch below never mistakes an escaped '>' for a real
          # one and never wrongly glues away a REAL following pipe.
          if [ $((i + 1)) -lt "$n" ]; then
            nc="${s:$((i + 1)):1}"
            if [ "$nc" = $'\n' ]; then
              # Genuine continuation: an unescaped backslash immediately
              # followed by a newline. Drop BOTH characters -- a real shell
              # removes them entirely, joining the two physical lines with
              # nothing inserted between them.
              i=$((i + 1))
            else
              out+="$c"; i=$((i + 1)); out+="$nc"; have=1
            fi
          else
            out+="$c"; have=1
          fi
          gt=0
          ;;
        '&' | '|')
          # SEC-13/SEC-17 (security review, 2026-08-21): '>|' is bash own
          # noclobber-override redirect operator, not a pipe -- without
          # this a bare unquoted '|' immediately after a genuine '>' was
          # always read as a pipe/segment separator, splitting
          # "cat x >| protected-path" into two unrelated segments and
          # losing the redirect target entirely. Glue it onto the
          # preceding '>' instead, exactly like '>>' already reaches
          # normalize_segment as one token -- gated on the `gt` flag (set
          # ONLY in the default `*)` branch below when a raw, unescaped,
          # unquoted '>' is emitted; cleared on every other path,
          # including the escape branch above), NEVER by inspecting the
          # last emitted character. SEC-17: `${out: -1}` cannot
          # distinguish `a\>|cmd` (an ESCAPED '>' followed by a REAL pipe)
          # from a genuine `>|` operator, and wrongly glued the real pipe
          # away -- hiding an entire second command from every downstream
          # segment-based scanner (merge-gate GATE 1-4, the floor-script
          # guard) at both DENY sites.
          if [ "$c" = '|' ] && [ "$gt" -eq 1 ]; then
            out+="$c"; have=1; gt=0
          else
            two="${s:$i:2}"
            if [ "$two" = "&&" ] || [ "$two" = "||" ]; then
              out+=$'\n'
              i=$((i + 1))
            else
              out+=$'\n'
            fi
            have=0; gt=0
          fi
          ;;
        ';')
          out+=$'\n'
          have=0; gt=0
          ;;
        *)
          out+="$c"; have=1
          if [ "$c" = '>' ]; then gt=1; else gt=0; fi
          ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

normalize_segment() {
  local s="$1" first
  # A leading `GH_REPO=value` (or `env GH_REPO=value`) is stripped below like
  # any other wrapper/assignment prefix — but gh itself reads GH_REPO from
  # the environment when no --repo/-R flag is present, so silently discarding
  # it here would mean `GH_REPO=other-org/other-repo gh pr merge 7` and
  # `env GH_REPO=other-org/other-repo gh pr merge 7` carry a real repo
  # selector that this hook then never sees. Capture it (last one wins, same
  # as gh's own last-assignment-wins semantics) into NORM_GH_REPO_PREFIX so
  # the caller can fold it into the cross-repo signal set. Reset per call —
  # only the assignments IN THIS SEGMENT are in scope; see the boundary note
  # above `normalize_segment`'s call site for what is deliberately NOT (an
  # `export GH_REPO=x;` on an EARLIER, separate segment of the same line).
  NORM_GH_REPO_PREFIX=""
  s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  while [ -n "$s" ]; do
    first="${s%%[[:space:]]*}"
    case "$first" in
      sudo|env|eval|command|nohup|time)
        s="${s#"$first"}" ;;
      bash|sh|zsh)
        # bash -c '<payload>' — unwrap the payload, then keep normalizing it.
        if [[ "$s" =~ ^(bash|sh|zsh)[[:space:]]+-c[[:space:]]+(.*)$ ]]; then
          s="${BASH_REMATCH[2]}"
          s="${s#[\"\']}"; s="${s%[\"\']}"
        else
          break
        fi ;;
      *)
        # A leading VAR=value assignment only — matched with a regex, not a
        # case glob: `git commit -m "a=b"` also contains `=`, and stripping to
        # the first space there would drop the `git` and silently un-detect a
        # real vector.
        if [[ "$first" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          case "$first" in
            GH_REPO=*) NORM_GH_REPO_PREFIX="${first#GH_REPO=}" ;;
          esac
          s="${s#"$first"}"
        else
          break
        fi ;;
    esac
    s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//')
  done
  NORM_RESULT="$s"
}
# =============================================================================
# <<< QX-CMDSCAN END
# =============================================================================

# --- protected_write_targets: SEC-7 FIX (2026-08-21, security review) ------
# THE DEFECT THIS REPLACES. segment_is_write_shaped's old rule -- "a
# recognized write verb, OR the segment contains a bare '>' anywhere" --
# combined with a "does the WHOLE segment mention a protected basename
# anywhere" targeting check, denied `grep -n QUICK plugins/quetrex-factory/
# scripts/verify-gate.sh > /tmp/out.txt` (redirects to /tmp/out.txt; the
# protected path is only a READ argument to grep) and any legitimate
# hash/backup procedure of the same shape (`shasum -a 256 deny-guard.sh ...
# verify-gate.sh > checksums.txt` -- every floor basename is a READ argument
# being hashed; the write target is checksums.txt). A PreToolUse deny beats
# bypassPermissions, so a wrongful deny here has NO recourse.
#
# THE FIX. Only the REDIRECTION TARGET, or a recognized write-verb's OWN
# destination argument, is ever checked against the protected set -- never a
# protected path merely appearing as a READ argument elsewhere in the same
# command. Sets PWT_TARGETS to the list of candidate write-destination
# tokens for the segment; the caller checks EACH one with
# names_protected_path_or_symlink, never the segment as a whole.
#
# SEC-4 (best-effort write-vector coverage, 2026-08-21): also extracts
# destinations for `git checkout`/`git restore` (a path after a literal `--`,
# else the last positional arg) and `curl -o`/`--output`. Interpreter-
# mediated writes (python/node/perl/ruby inline `-c`/`-e` code) cannot be
# structurally parsed here -- see qx_is_interpreter_inline_write below for
# the deliberately narrower, best-effort heuristic used for that ONE class,
# and the developer's report for what remains genuinely open (inferred
# `patch` targets with no explicit path argument; a `<` stdin-redirect
# source token being misread as a positional argument by callers that do not
# also special-case it).
protected_write_targets() {
  local seg="$1" first
  local -a w=()
  read -ra w <<< "$seg"
  PWT_TARGETS=()
  [ "${#w[@]}" -ge 1 ] || return 0
  first="${w[0]}"

  # last_nonflag_arg <start-index> -- the last token from w[start..] that is
  # neither a flag (leading '-'), a redirection token, nor the token
  # immediately following a '<' (a stdin-redirect SOURCE, never a write
  # destination for the command itself). first_pos is the FIRST such token --
  # for cp/mv/install/rsync's common single-source shape this is the source,
  # used below (SEC-13) to resolve a directory destination.
  local last="" first_pos="" tok skip_next=0 i
  for ((i = 1; i < ${#w[@]}; i++)); do
    tok="${w[$i]}"
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$tok" in
      '<') skip_next=1; continue ;;
      '<'*) continue ;;
      -*)
        # SEC-13: `install -m 0755 src dest` -- install's -m/-o/-g/-t are
        # value-taking flags; without this, the MODE/OWNER/GROUP/TARGET
        # value that follows is wrongly picked up as first_pos (the
        # presumed source) below. Deliberately narrow -- other verbs' own
        # value-taking short flags (rsync's large flag surface especially)
        # are NOT enumerated here; a disclosed best-effort limitation, same
        # class as the interpreter inline-write heuristic above.
        case "$first:$tok" in
          install:-m|install:-o|install:-g|install:-t) skip_next=1 ;;
        esac
        continue
        ;;
      '>'*|'>>'*) continue ;;
    esac
    [ -z "$first_pos" ] && first_pos="$tok"
    last="$tok"
  done

  case "$first" in
    cp|mv|install|rsync|truncate|patch)
      [ -n "$last" ] && PWT_TARGETS+=("$last")
      # SEC-13 (security review, 2026-08-21): a DIRECTORY destination puts
      # the protected basename ONLY in the source token, which the
      # destination-only check above deliberately ignores --
      # `cp /tmp/hooks/verify-gate.sh .claude/hooks/` (or `.claude/hooks`,
      # an existing directory) lands the write at .claude/hooks/verify-
      # gate.sh but `last` alone is just a directory path that names
      # nothing protected. Resolve directory + basename(source) too,
      # for BOTH the explicit trailing-slash form (no filesystem access
      # needed) and an existing real directory on disk (this hook already
      # makes one real filesystem check elsewhere -- the one-hop symlink
      # read in names_protected_path_or_symlink -- so a directory stat
      # here is the same established, disclosed exception, never a
      # general resolution engine).
      if [ "$first" != "patch" ] && [ -n "$last" ] && [ -n "$first_pos" ] && [ "$first_pos" != "$last" ]; then
        local destdir="$last" destcheck srcbase="${first_pos##*/}"
        case "$destdir" in
          */) : ;;
          *)
            destcheck="$destdir"
            case "$destcheck" in
              /*) : ;;
              *) [ -n "$PENDING_CD" ] && destcheck="${PENDING_CD%/}/$destcheck" ;;
            esac
            if [ -d "$destcheck" ]; then destdir="${destdir}/"; else destdir=""; fi
            ;;
        esac
        [ -n "$destdir" ] && [ -n "$srcbase" ] && PWT_TARGETS+=("${destdir%/}/${srcbase}")
      fi
      ;;
    sed)
      if printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])(-[A-Za-z]*i[A-Za-z]*([[:space:]]|=|$)|--in-place([=[:space:]]|$))'; then
        [ -n "$last" ] && PWT_TARGETS+=("$last")
      fi
      ;;
    ln)
      if printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-[A-Za-z]*s[A-Za-z]*f[A-Za-z]*([[:space:]]|$)' \
        || printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-[A-Za-z]*f[A-Za-z]*s[A-Za-z]*([[:space:]]|$)' \
        || { printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-s([[:space:]]|$)' \
             && printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-f([[:space:]]|$)'; }; then
        [ -n "$last" ] && PWT_TARGETS+=("$last")
      fi
      ;;
    tee)
      for tok in "${w[@]:1}"; do
        case "$tok" in -*|'>'*|'>>'*) continue ;; esac
        PWT_TARGETS+=("$tok")
      done
      ;;
    dd)
      for tok in "${w[@]:1}"; do
        case "$tok" in of=*) PWT_TARGETS+=("${tok#of=}") ;; esac
      done
      ;;
    git)
      case "${w[1]:-}" in
        checkout|restore)
          local after_dd=0
          for tok in "${w[@]:2}"; do
            if [ "$after_dd" -eq 1 ]; then PWT_TARGETS+=("$tok"); continue; fi
            case "$tok" in --) after_dd=1 ;; esac
          done
          [ "$after_dd" -eq 0 ] && [ -n "$last" ] && PWT_TARGETS+=("$last")
          ;;
      esac
      ;;
    curl)
      local next_is_out=0
      for tok in "${w[@]:1}"; do
        if [ "$next_is_out" -eq 1 ]; then PWT_TARGETS+=("$tok"); next_is_out=0; continue; fi
        case "$tok" in
          -o|--output) next_is_out=1 ;;
          -o?*) PWT_TARGETS+=("${tok#-o}") ;;
          --output=*) PWT_TARGETS+=("${tok#--output=}") ;;
        esac
      done
      ;;
    exec)
      # SEC-13 (security review, 2026-08-21): `exec N> path` binds fd N to
      # path for the REST OF THE SCRIPT (every later segment, not just this
      # one) -- a later `echo x >&N` in ANY subsequent segment of the SAME
      # command then writes to that same path with no path token of its own
      # for the redirection loop below to see. Record the binding into the
      # QX_FD_* globals (reset once per hook invocation, below the SEGMENTS
      # loop's declaration) so a later segment's `>&N` can resolve it. The
      # target of the `exec N> path` itself is caught directly by the
      # generic redirection loop below (it matches the same numbered-op
      # pattern) -- this case only needs to remember the binding.
      for ((i = 1; i < ${#w[@]}; i++)); do
        tok="${w[$i]}"
        if [[ "$tok" =~ ^([0-9]+)(\>\>|\>)(.*)$ ]]; then
          local fdn="${BASH_REMATCH[1]}" fdtarget="${BASH_REMATCH[3]}"
          if [ -z "$fdtarget" ] && [ $((i + 1)) -lt "${#w[@]}" ]; then
            case "${w[$((i + 1))]}" in -*) : ;; *) fdtarget="${w[$((i + 1))]}" ;; esac
          fi
          if [ -n "$fdtarget" ]; then
            QX_FD_NUMS+=("$fdn")
            QX_FD_PATHS+=("$fdtarget")
          fi
        fi
      done
      ;;
  esac

  # Redirection targets -- ANY command can redirect its OWN output,
  # regardless of verb (`cat x > path`, `echo y >> path`, …).
  #
  # SEC-13 (security review, 2026-08-21): the previous version matched ONLY
  # bare `>`/`>>`, so `cat /tmp/evil 1> plugins/quetrex-factory/scripts/verify-gate.sh`
  # (stdout/stderr-numbered), `... &> path` / `... &>> path` (both streams),
  # and `... >| path` (noclobber-override) all evaded the scanner entirely.
  # One coherent parser now closes all of them plus the `exec N> path` /
  # `... >&N` pair recorded above, rather than special-casing tokens one at
  # a time: an optional leading fd number OR a literal `&`, then `>`, `>>`,
  # or `>|`, then either an attached target (`2>/tmp/x`), a separate next
  # token (`2> /tmp/x`), or an `&N` fd-duplication suffix (`>&3`) resolved
  # against the exec bindings above.
  for ((i = 0; i < ${#w[@]}; i++)); do
    tok="${w[$i]}"
    if [[ "$tok" =~ ^([0-9]+|\&)?(\>\>|\>\||\>)(.*)$ ]]; then
      local rest="${BASH_REMATCH[3]}"
      case "$rest" in
        '&'[0-9]*)
          local dupfd="${rest#&}" j
          for ((j = 0; j < ${#QX_FD_NUMS[@]}; j++)); do
            [ "${QX_FD_NUMS[$j]}" = "$dupfd" ] && PWT_TARGETS+=("${QX_FD_PATHS[$j]}")
          done
          ;;
        '')
          [ $((i + 1)) -lt "${#w[@]}" ] && PWT_TARGETS+=("${w[$((i + 1))]}")
          ;;
        *)
          PWT_TARGETS+=("$rest")
          ;;
      esac
    fi
  done
}

# qx_is_interpreter_inline_write <normalized-segment> -- best-effort ONLY.
# python3/node/perl/ruby's inline `-c`/`-e` argument is arbitrary source
# code this hook cannot structurally parse (no interpreter grammar here), so
# — unlike every other case above, which checks a real destination token —
# this ONE class falls back to scanning the WHOLE segment text for a
# protected basename. Deliberately narrow (gated on the interpreter name AND
# an inline-code flag) so it does not regress SEC-7's fix for every other
# command; still imprecise BY NATURE (a comment or string literal mentioning
# a floor script's name in inline code would also match) — a disclosed,
# accepted limitation, not a silent gap. See the developer's report.
qx_is_interpreter_inline_write() {
  local seg="$1" first
  first="${seg%%[[:space:]]*}"
  case "$first" in
    python|python3|node|nodejs|ruby|perl) : ;;
    *) return 1 ;;
  esac
  case "$seg" in
    *' -c '*|*' -e '*|*' -pi '*|*' -pi'*) : ;;
    *) return 1 ;;
  esac
  names_protected_path "$seg"
}

# =============================================================================
# WRITE / EDIT VECTOR
# =============================================================================
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  [ -n "$FILE_PATH" ] || exit 0

  # SEC-ONECOPY-1: .quetrex/project.json is what makes ROOT "armed" (see the
  # ARMED-ONLY block above) -- by construction we only reach this line when
  # the file ALREADY EXISTS at ROOT (an unarmed repo has no project.json and
  # exits at the ARMED-ONLY gate before this point), so protecting it here
  # can never block /quetrex:init's first-time creation of the file. A
  # Write/Edit whose target normalizes to exactly that path is denied unless
  # QUETREX_UNLOCK_FLOOR=1 -- the same unlock contract (is_unlocked /
  # allow_unlocked / deny) the floor scripts below use.
  #
  # Matched by SUFFIX, never an exact "$ROOT"-prefixed string: FILE_PATH is
  # the raw text the tool call carries, while ROOT came back through `git
  # rev-parse --show-toplevel`, which canonicalizes symlinks (macOS's
  # /tmp -> /private/tmp being the everyday case) -- an absolute FILE_PATH
  # under the UN-resolved form then never byte-matches ROOT. A path-tail
  # match is the same shape PROT_PATH_ERE below already uses for the floor
  # scripts, and sidesteps the mismatch entirely.
  # OBS-9 (round 2, closing the C6 fix's other half): deny-guard._kg_check_path
  # already protects .quetrex/verify.json against the Bash vector (rm/mv/
  # redirect/git rm/git checkout --), but this Write/Edit vector previously
  # covered ONLY project.json. verify-gate.sh accepts a hand-written
  # verify.json ({"verify":["true"]}) as the gate's own definition of green,
  # so a single Write/Edit here replaces the real chain with a no-op and lets
  # every future Stop pass on a red tree -- the same class of hole
  # project.json's own protection closes for arming itself.
  _pj_norm=$(qx_normalize_path "$FILE_PATH")
  case "$_pj_norm" in
    */.quetrex/project.json|.quetrex/project.json)
      is_unlocked && allow_unlocked "$TOOL_NAME $FILE_PATH"
      deny "PROTECTED ARMING FILE: this $TOOL_NAME targets \`$FILE_PATH\` (.quetrex/project.json) -- the file that arms deny-guard, secret-scan, enforce-branch, merge-gate, verify-gate, edit-gate and this guard for the whole repo. Overwriting it in an armed repo would silently disable the entire safety floor for the rest of the session."
      exit 0
      ;;
    */.quetrex/verify.json|.quetrex/verify.json)
      is_unlocked && allow_unlocked "$TOOL_NAME $FILE_PATH"
      deny "PROTECTED VERIFY CHAIN: this $TOOL_NAME targets \`$FILE_PATH\` (.quetrex/verify.json) -- the file that defines the verify chain verify-gate.sh actually gates the tree on. Overwriting it in an armed repo could silently replace the real chain with a no-op (e.g. {\"verify\":[\"true\"]}) and let every future Stop pass on a red tree."
      exit 0
      ;;
  esac

  names_protected_path_or_symlink "$FILE_PATH" || exit 0
  is_unlocked && allow_unlocked "$TOOL_NAME $FILE_PATH"
  deny "PROTECTED FLOOR SCRIPT: this $TOOL_NAME targets \`$FILE_PATH\`, one of the safety-floor scripts (deny-guard.sh, secret-scan.sh, enforce-branch.sh, merge-gate.sh, verify-gate.sh) or its quick-chain helper. Denied by default — see .claude/CLAUDE.md."
  exit 0
fi

# =============================================================================
# BASH VECTOR
# =============================================================================
[ -n "$COMMAND" ] || exit 0

SEGMENTS=$(split_segments_quote_aware "$COMMAND")
PENDING_CD=""
HIT_SEG=""
# SEC-13: fd bindings from `exec N> path`, persisted across every segment of
# THIS one command string (never across separate tool calls -- same
# documented per-call boundary as PENDING_CD and the rest of this hook).
QX_FD_NUMS=()
QX_FD_PATHS=()

while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  normalize_segment "$seg"
  norm="$NORM_RESULT"
  [ -z "$norm" ] && continue

  if [[ "$norm" =~ ^cd[[:space:]]+([^[:space:]]+) ]]; then
    PENDING_CD=$(printf '%s' "${BASH_REMATCH[1]}" | sed "s/^[\"']*//; s/[\"']*\$//")
    continue
  fi

  protected_write_targets "$norm"
  for t in ${PWT_TARGETS[@]+"${PWT_TARGETS[@]}"}; do
    [ -n "$t" ] || continue
    if names_protected_path_or_symlink "$t"; then
      HIT_SEG="$norm"
      break
    fi
    if names_bare_protected "$t" && [ -n "$PENDING_CD" ]; then
      case "$PENDING_CD" in
        */quetrex-factory/scripts) HIT_SEG="$norm" ;;
      esac
      [ -n "$HIT_SEG" ] && break
    fi
  done
  [ -n "$HIT_SEG" ] && break

  if qx_is_interpreter_inline_write "$norm"; then
    HIT_SEG="$norm"
    break
  fi
done <<< "$SEGMENTS"

[ -n "$HIT_SEG" ] || exit 0

is_unlocked && allow_unlocked "Bash: $HIT_SEG"
deny "PROTECTED FLOOR SCRIPT: this Bash command writes to one of the safety-floor scripts (deny-guard.sh, secret-scan.sh, enforce-branch.sh, merge-gate.sh, verify-gate.sh) or its quick-chain helper — offending segment: \`$HIT_SEG\`. Denied by default — see .claude/CLAUDE.md."
