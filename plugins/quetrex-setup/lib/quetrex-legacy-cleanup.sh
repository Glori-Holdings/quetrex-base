#!/usr/bin/env bash
# quetrex-legacy-cleanup.sh — the deterministic ENGINE behind the guarded,
# reversible cleanup of npm-era Quetrex artifacts seeded into ~/.claude.
#
# INVOKED BY NAME as `quetrex-cleanup <subcommand>` (bin/quetrex-cleanup is a
# thin launcher that resolves and execs this file). It is invoked from
# /quetrex-setup:init after two agreeing AI agents (proposer + adversarial auditor)
# and a per-item human KEEP/REMOVE gate. This script is the mechanism, NOT the
# judgment: it enumerates and classifies (read-only), and quarantines only the
# EXACT items it is explicitly told to — it never decides on its own.
#
# HARD SAFETY RULES (enforced structurally here, not just by the caller):
#   * ALLOWLIST-SCOPED. Only the exact basenames/paths the npm installer seeded
#     (captured from install.js's GLOBAL_HOOK_SCRIPTS / PER_PROJECT_HOOK_SCRIPTS
#     / SUPERSEDED_HOOK_SCRIPTS + the shipped .claude/ tree + bookkeeping) are
#     ever candidates. When ~/.claude/.quetrex-manifest.json exists it is the
#     authoritative per-machine record and is unioned in.
#   * PRISTINE-ONLY removal. An item is a safe-remove candidate ONLY when it is
#     byte-identical to the file the CURRENT plugin ships (proving it is a stale
#     duplicate of engine-supplied content the user did not customise). Anything
#     modified, or with no shippable baseline to compare, is classified for the
#     human to decide — never auto-removed.
#   * SURGICAL on shared files. settings.json / the user CLAUDE.md are NEVER
#     whole-file removed; only Quetrex's own entries / the @quetrex-doctrine.md
#     import line are stripped, never user content or #LESSONS.
#   * REVERSIBLE. Nothing is ever hard-deleted. Every removal is a MOVE into a
#     timestamped ~/.claude/.quetrex-backup-<ts>/ quarantine.
#   * secrets.env is NEVER removed — only ever flagged.
#   * ONCE PER MACHINE. A marker under ${CLAUDE_PLUGIN_DATA} (never ~/.claude,
#     never the repo) makes the offer idempotent.
#
# SUBCOMMANDS (all read-only except `quarantine`, `strip-settings`,
# `strip-claudemd`, `mark-done`):
#   scan                      -> TSV of candidates: STATUS<TAB>REL<TAB>REASON
#   already-ran               -> exit 0 if the once-per-machine marker is set
#   mark-done                 -> set the once-per-machine marker
#   quarantine <rel>...       -> move each ~/.claude/<rel> into the backup dir
#   strip-settings            -> surgically drop Quetrex entries from settings.json
#   strip-claudemd            -> surgically drop the @quetrex-doctrine.md import line
#   backup-dir                -> print the backup dir path that would be used
#
# STATUS values emitted by `scan`:
#   PRISTINE   byte-identical to a current-plugin baseline -> safe-remove candidate
#   LEGACY     on the allowlist, npm-era, no baseline to compare -> human decides
#   MODIFIED   on the allowlist, has a baseline, but differs -> KEEP + flag
#   SURGICAL   shared file (settings.json / CLAUDE.md) -> strip-only, never move
#   SECRET     secrets.env -> FLAG ONLY, never removed
#   MISSING    on the allowlist but not on disk -> nothing to do (skipped in output)

set -uo pipefail

HOME_CLAUDE="$HOME/.claude"

# Plugin root, for baseline_for()'s PRISTINE-vs-MODIFIED comparison below.
# This file lives at <plugin-root>/lib/ (quetrex-setup's own flat layout), so
# its OWN plugin root is one dir up — but the actual current-shipped .claude/
# baseline tree that HOOK_BASENAMES compares against (session-state.sh and
# friends) lives in a SIBLING plugin, `quetrex`, not in quetrex-setup itself
# (quetrex-setup ships no .claude/ tree of its own). ${CLAUDE_PLUGIN_ROOT} is
# preferred when the caller (a hook) exported it — untrue in practice for this
# launcher (it runs from /quetrex-setup:init's slash-command bash, where that
# variable is UNSET, exactly like every other bin/ tool in this plugin) — so
# the fallback resolves the DEV-CHECKOUT root three dirs up
# (lib -> quetrex-setup -> plugins -> repo root), which is where `quetrex`'s
# .claude/ tree actually lives when this script runs from inside this
# repository. NOTE (pre-existing, not introduced by the setup-plugin split):
# in a real installed-plugin scenario (a target repo's own plugin cache),
# neither resolution reaches a sibling `quetrex` checkout at all — a
# git-subdir install pulls in only plugins/quetrex-setup/ — so most
# HOOK_BASENAMES already have no baseline to compare against and fall through
# to LEGACY (human decides), never a wrong PRISTINE. That gap predates this
# move and is unrelated to it.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SELF_DIR/../../.." && pwd)}"

# Plugin-local state ONLY for the once-per-machine marker (never ~/.claude,
# never the repo).
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.local/state}/quetrex}"
MARKER="$STATE_DIR/legacy-cleanup.done"

# One backup dir per invocation, timestamped, under ~/.claude.
_BACKUP_DIR=""
backup_dir() {
  if [ -z "$_BACKUP_DIR" ]; then
    _BACKUP_DIR="$HOME_CLAUDE/.quetrex-backup-$(date +%Y%m%d-%H%M%S)"
  fi
  printf '%s\n' "$_BACKUP_DIR"
}

# --- the allowlist -----------------------------------------------------------
# Basenames the installer seeded into ~/.claude/hooks/ (GLOBAL + PER_PROJECT +
# SUPERSEDED, captured from install.js before it was retired).
HOOK_BASENAMES=(
  deny-guard.sh secret-scan.sh enforce-branch.sh workflow-reminder.sh
  auto-format.sh edit-gate.sh session-state.sh
  verify-gate.sh merge-gate.sh
  security-check.sh enforce-merge-approval.sh check-quetrex-update.sh
)
# npm-era command files (old quetrex-*.md names), from the manifest.
COMMAND_BASENAMES=(
  quetrex-deploy.md quetrex-init.md quetrex-login.md quetrex-task-build.md
  quetrex-task-complete.md quetrex-task-new.md quetrex-task-refine.md
  quetrex-task-rework.md
)
AGENT_BASENAMES=(
  architect.md database-architect.md developer.md git-workflow.md qa.md
  reviewer.md security-reviewer.md
)
LIB_BASENAMES=( dev-pipeline.md quetrex-api.sh quetrex-install-project-gates.sh )
# Top-level seeded files (relative to ~/.claude).
TOPLEVEL_RELS=(
  statusline-command.sh team-protocol.md quetrex-doctrine.md
  templates/verify.json templates/global-CLAUDE.md settings.local.json
)
# Skills seeded as whole directories (dir name under ~/.claude/skills/).
SKILL_DIRS=( qa-verify tab-control worktree-workflow )

# Build the full candidate REL list (paths relative to ~/.claude).
candidate_rels() {
  local b
  for b in "${HOOK_BASENAMES[@]}";    do echo "hooks/$b"; done
  for b in "${COMMAND_BASENAMES[@]}"; do echo "commands/$b"; done
  for b in "${AGENT_BASENAMES[@]}";   do echo "agents/$b"; done
  for b in "${LIB_BASENAMES[@]}";     do echo "lib/$b"; done
  for b in "${TOPLEVEL_RELS[@]}";     do echo "$b"; done
  for b in "${SKILL_DIRS[@]}";        do echo "skills/$b"; done
  # Union in whatever the authoritative on-disk manifest recorded.
  if [ -f "$HOME_CLAUDE/.quetrex-manifest.json" ]; then
    node -e '
      const fs=require("fs");
      let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(0)}
      for (const f of (o.files||[])) if (typeof f==="string") console.log(f);
    ' "$HOME_CLAUDE/.quetrex-manifest.json" 2>/dev/null
  fi
}

# The current-plugin baseline for a given ~/.claude-relative path, when one
# exists in this plugin's committed tree. Prints the absolute baseline path or
# nothing. The plugin ships the same layout under its own .claude/, so a
# hooks/agents/lib/skills path maps 1:1.
baseline_for() {  # <rel>
  local rel="$1" cand="$PLUGIN_ROOT/.claude/$1"
  [ -f "$cand" ] && { printf '%s\n' "$cand"; return; }
  return 1
}

files_identical() {  # <a> <b>
  [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"
}

# --- scan --------------------------------------------------------------------
do_scan() {
  local seen="" rel abs base status reason
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case ",$seen," in *",$rel,"*) continue ;; esac  # de-dupe
    seen="$seen,$rel"
    abs="$HOME_CLAUDE/$rel"

    # secrets.env: FLAG ONLY, whether or not it is on the manifest.
    if [ "$rel" = "secrets.env" ]; then
      [ -e "$abs" ] && printf 'SECRET\t%s\tnever removed — flagged so you know it is here\n' "$rel"
      continue
    fi
    # Shared files: surgical strip only, never a move.
    if [ "$rel" = "settings.json" ] || [ "$rel" = "CLAUDE.md" ]; then
      [ -e "$abs" ] && printf 'SURGICAL\t%s\tstrip only Quetrex entries — never the whole file\n' "$rel"
      continue
    fi

    # Directory (skill) or file must exist to be a candidate.
    if [ ! -e "$abs" ]; then
      continue   # MISSING — nothing to do; omit from output
    fi

    if [ -d "$abs" ]; then
      # A seeded skill dir: pristine only if EVERY file matches the plugin's copy.
      local allmatch=1 f frel
      while IFS= read -r f; do
        frel="${f#$HOME_CLAUDE/}"
        if bmatch="$(baseline_for "$frel" 2>/dev/null)"; then
          files_identical "$f" "$bmatch" || allmatch=0
        else
          allmatch=0
        fi
      done < <(find "$abs" -type f 2>/dev/null)
      if [ "$allmatch" -eq 1 ]; then
        printf 'PRISTINE\t%s\tskill dir byte-identical to the plugin copy — safe stale duplicate\n' "$rel"
      else
        printf 'MODIFIED\t%s\tskill dir differs from the plugin copy — kept, review by hand\n' "$rel"
      fi
      continue
    fi

    # A regular file.
    if base="$(baseline_for "$rel" 2>/dev/null)"; then
      if files_identical "$abs" "$base"; then
        printf 'PRISTINE\t%s\tbyte-identical to the plugin copy — safe stale duplicate\n' "$rel"
      else
        printf 'MODIFIED\t%s\tdiffers from the plugin copy — kept, review by hand\n' "$rel"
      fi
    else
      printf 'LEGACY\t%s\tnpm-era artifact with no current baseline — you decide\n' "$rel"
    fi
  done < <(candidate_rels)
}

# --- quarantine (reversible move) --------------------------------------------
do_quarantine() {
  local dir; dir="$(backup_dir)"
  local rel abs dest
  local moved=0
  for rel in "$@"; do
    [ -n "$rel" ] || continue
    # Refuse anything not resolving strictly under ~/.claude (defends against a
    # tampered arg with ../).
    abs="$HOME_CLAUDE/$rel"
    case "$rel" in
      /*|*..*) echo "refused (unsafe path): $rel" >&2; continue ;;
    esac
    # Never move the flag/strip-only classes, even if asked.
    case "$rel" in
      secrets.env|settings.json|CLAUDE.md)
        echo "refused (never removed / strip-only): $rel" >&2; continue ;;
    esac
    [ -e "$abs" ] || { echo "skip (absent): $rel" >&2; continue; }
    dest="$dir/$rel"
    mkdir -p "$(dirname "$dest")" || { echo "backup mkdir failed: $rel" >&2; continue; }
    if mv "$abs" "$dest"; then
      echo "quarantined: $rel -> ${dir/#$HOME/~}/$rel"
      moved=$((moved+1))
    else
      echo "move failed (kept in place): $rel" >&2
    fi
  done
  [ "$moved" -gt 0 ] && echo "Reversible: restore any item from ${dir/#$HOME/~}/"
}

# --- surgical strip of settings.json -----------------------------------------
# Removes ONLY Quetrex-owned hook registrations (commands referencing a known
# Quetrex hook basename) and the statusLine reference to ~/.claude, backing up
# the original first. Never touches permissions, env, or any non-Quetrex hook.
do_strip_settings() {
  local f="$HOME_CLAUDE/settings.json"
  [ -f "$f" ] || { echo "no ~/.claude/settings.json"; return 0; }
  local dir; dir="$(backup_dir)"; mkdir -p "$dir"
  cp "$f" "$dir/settings.json"   # reversible: original preserved
  node -e '
    const fs=require("fs");
    const [file] = process.argv.slice(1);
    const QX = new Set(["deny-guard.sh","secret-scan.sh","enforce-branch.sh",
      "workflow-reminder.sh","auto-format.sh","edit-gate.sh","session-state.sh",
      "verify-gate.sh","merge-gate.sh","security-check.sh",
      "enforce-merge-approval.sh","check-quetrex-update.sh"]);
    let o; try{o=JSON.parse(fs.readFileSync(file,"utf8"))}catch{console.log("STRIP_SKIP_UNPARSEABLE");process.exit(0)}
    let removed=0;
    const isQx = c => typeof c==="string" && [...QX].some(b => c.includes(b));
    if (o.hooks && typeof o.hooks==="object") {
      for (const ev of Object.keys(o.hooks)) {
        const groups = Array.isArray(o.hooks[ev]) ? o.hooks[ev] : [];
        for (const g of groups) {
          if (g && Array.isArray(g.hooks)) {
            const before = g.hooks.length;
            g.hooks = g.hooks.filter(h => !(h && isQx(h.command)));
            removed += before - g.hooks.length;
          }
        }
        // drop now-empty groups, then drop the event if it went empty
        o.hooks[ev] = groups.filter(g => g && Array.isArray(g.hooks) && g.hooks.length);
        if (!o.hooks[ev].length) delete o.hooks[ev];
      }
      if (Object.keys(o.hooks).length===0) delete o.hooks;
    }
    // statusLine pointing at ~/.claude/statusline-command.sh is npm-era; drop it.
    if (o.statusLine && JSON.stringify(o.statusLine).includes(".claude/statusline-command.sh")) {
      delete o.statusLine; removed++;
    }
    if (!removed) { console.log("STRIP_NONE"); process.exit(0); }
    fs.writeFileSync(file, JSON.stringify(o,null,2)+"\n");
    console.log("STRIP_OK "+removed);
  ' "$f"
}

# --- surgical strip of the @quetrex-doctrine.md import from the user CLAUDE.md -
do_strip_claudemd() {
  local f="$HOME_CLAUDE/CLAUDE.md"
  [ -f "$f" ] || { echo "no ~/.claude/CLAUDE.md"; return 0; }
  local dir; dir="$(backup_dir)"; mkdir -p "$dir"
  cp "$f" "$dir/CLAUDE.md"   # reversible
  node -e '
    const fs=require("fs");
    const file=process.argv[1];
    const src=fs.readFileSync(file,"utf8");
    const lines=src.split("\n");
    // Remove ONLY lines that are the doctrine import (e.g. "@quetrex-doctrine.md"
    // possibly with a leading @path). Never touch #LESSONS or any other content.
    const kept=lines.filter(l => !/@[^\s]*quetrex-doctrine\.md/.test(l));
    if (kept.length===lines.length) { console.log("STRIP_NONE"); process.exit(0); }
    fs.writeFileSync(file, kept.join("\n"));
    console.log("STRIP_OK "+(lines.length-kept.length));
  ' "$f"
}

# --- once-per-machine marker -------------------------------------------------
do_already_ran() { [ -f "$MARKER" ]; }
do_mark_done()   { mkdir -p "$STATE_DIR" && : > "$MARKER" && echo "marked: ${MARKER}"; }

# --- dispatch ----------------------------------------------------------------
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  scan)            do_scan ;;
  quarantine)      do_quarantine "$@" ;;
  strip-settings)  do_strip_settings ;;
  strip-claudemd)  do_strip_claudemd ;;
  already-ran)     do_already_ran ;;
  mark-done)       do_mark_done ;;
  backup-dir)      backup_dir ;;
  ""|-h|--help|help)
    echo "usage: quetrex-cleanup {scan|quarantine <rel>...|strip-settings|strip-claudemd|already-ran|mark-done|backup-dir}" >&2
    exit 2 ;;
  *) echo "quetrex-cleanup: unknown command '$cmd'" >&2; exit 2 ;;
esac
