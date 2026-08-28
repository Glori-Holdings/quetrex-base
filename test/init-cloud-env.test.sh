#!/usr/bin/env bash
# test/init-cloud-env.test.sh — /quetrex-setup:init DERIVES cloudEnvironmentId
# instead of asking the operator to paste one.
#
# Run: bash test/init-cloud-env.test.sh
#
# WHY. A cloud routine needs an environment_id. Nothing set it, so the FIRST
# /quetrex:task-build on a freshly-bound repo stopped and printed a `node -e`
# one-liner asking the human to open claude.ai, find an env_… id in a URL, and
# paste it back. Every new partner stalled there. Arming a feature belongs in
# init, never in a failure message from the command that needed it.
#
# THIS FILE DRIVES THE SHIPPED BLOCK. It extracts the `qx_env_candidates`
# exec-block from plugins/quetrex-setup/commands/init.md — the same bytes the
# model is told to run — and executes it. No restatement of the logic.
#
# THE FIXTURE IS REAL. test/fixtures/remote-triggers.json was captured from an
# actual `RemoteTrigger action:"list"` response (GET /v1/code/triggers, 20
# routines, 2026-08-28), with only the multi-KB prompt bodies removed. AC1 is a
# SHAPE ASSERTION against it: a hand-written fixture proves the fixture, not the
# code, so if the API ever moves environment_id or the repo sources, AC1 fails
# loudly rather than the derivation silently returning nothing.
#
# FAIL-FIRST (baseline pinned to a FIXED SHA, never `main`): against 1d5c364,
# init.md has no qx_env_candidates block at all —
#   git show 1d5c364:plugins/quetrex-setup/commands/init.md > /tmp/old-init.md
#   QX_INIT_COMMAND=/tmp/old-init.md bash test/init-cloud-env.test.sh
# prints NOT OK on extraction and exits 1.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="${QX_INIT_COMMAND:-$ROOT/plugins/quetrex-setup/commands/init.md}"
FIXTURE="$ROOT/test/fixtures/remote-triggers.json"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$COMMAND" ]  || { echo "NOT OK - init.md not found at $COMMAND"; exit 1; }
[ -f "$FIXTURE" ]  || { echo "NOT OK - fixture not found at $FIXTURE"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/init-cloud-env.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- extract the shipped exec-block ------------------------------------------
awk -v name="qx_env_candidates" '
  $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
' "$COMMAND" > "$WORK/block.sh"

if [ ! -s "$WORK/block.sh" ] || ! grep -q '^[[:space:]]*qx_env_candidates()' "$WORK/block.sh"; then
  notok "init.md has no executable block 'qx_env_candidates' — the derivation is prose again, and this file can only check prose"
  printf '\n%s\n' "init-cloud-env.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi
if ERR="$(bash -n "$WORK/block.sh" 2>&1)"; then
  ok "extracted the shipped qx_env_candidates block from init.md and it parses"
else
  notok "the qx_env_candidates block is not valid shell: $ERR"
  printf '\n%s\n' "init-cloud-env.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi
# shellcheck source=/dev/null
. "$WORK/block.sh"

cand() { qx_env_candidates "$1" < "${2:-$FIXTURE}"; }

# --- AC1: SHAPE ASSERTION on the captured payload ----------------------------
# The two field paths the derivation depends on must still exist in a real
# response. If Anthropic moves either, this fails instead of the derivation
# quietly returning nothing and init falling back to "paste an id".
SHAPE=$(python3 - "$FIXTURE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("data") or []
envs = sum(1 for t in rows if ((t.get("job_config") or {}).get("ccr") or {}).get("environment_id"))
urls = sum(1 for t in rows
           if [s for s in ((((t.get("job_config") or {}).get("ccr") or {}).get("session_context") or {}).get("sources") or [])
               if ((s or {}).get("git_repository") or {}).get("url")])
print("%d %d %d" % (len(rows), envs, urls))
PY
)
read -r N_ROWS N_ENV N_URL <<< "$SHAPE"
if [ "${N_ROWS:-0}" -ge 20 ] && [ "${N_ENV:-0}" -ge 10 ] && [ "${N_URL:-0}" -ge 10 ]; then
  ok "AC1 shape: the captured payload still carries job_config.ccr.environment_id ($N_ENV/$N_ROWS) and session_context.sources[].git_repository.url ($N_URL/$N_ROWS)"
else
  notok "AC1 shape: the real-response field paths moved (rows=$N_ROWS env=$N_ENV url=$N_URL) — the derivation would silently find nothing"
fi

# --- AC2: this repo's environments are found, and marked `repo` --------------
OUT=$(cand "https://github.com/Glori-Holdings/quetrex-base")
N=$(printf '%s\n' "$OUT" | grep -c . || true)
REPO_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="repo"' | grep -c . || true)
if [ "$N" -eq 2 ] && [ "$REPO_N" -eq 2 ]; then
  ok "AC2: both environments that have run against quetrex-base are returned and marked 'repo'"
else
  notok "AC2: expected 2 candidates both marked repo, got $N candidates / $REPO_N repo: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# --- AC3: distinct environments only, never one row per routine --------------
# 20 routines share 2 environments. A per-routine list would present the same
# environment ten times in an AskUserQuestion panel.
DUPES=$(printf '%s\n' "$OUT" | awk -F'\t' 'NF{print $1}' | sort | uniq -d | grep -c . || true)
if [ "$DUPES" -eq 0 ]; then
  ok "AC3: environments are de-duplicated — 20 routines collapse to distinct ids"
else
  notok "AC3: $DUPES environment id(s) repeated — the caller would ask about the same environment twice"
fi

# --- AC4: a repo used by exactly one environment resolves UNAMBIGUOUSLY ------
# quetrex-plugins ran under one environment only: init must write it silently,
# with no question. This is the case that removes the partner stall.
OUT3=$(cand "https://github.com/Glori-Holdings/quetrex-plugins")
ONLY=$(printf '%s\n' "$OUT3" | awk -F'\t' '$2=="repo"{print $1}')
if [ "$(printf '%s\n' "$ONLY" | grep -c .)" -eq 1 ] && [ "$ONLY" = "env_011CUpkAEM4fzsAD6dx1zW3r" ]; then
  ok "AC4: a repo with exactly one environment resolves to it unambiguously (no question asked)"
else
  notok "AC4: expected exactly one 'repo' environment for quetrex-plugins, got: $(printf '%s' "$ONLY" | tr '\n' ' ')"
fi

# --- AC5: repo-first ordering ------------------------------------------------
# An unknown repo still gets the account's environments offered, all 'other'.
# For a known repo the 'repo' ones must sort ahead of the rest.
OUT4=$(cand "https://github.com/Someone-Else/never-seen")
OTHER_N=$(printf '%s\n' "$OUT4" | awk -F'\t' '$2=="other"' | grep -c . || true)
FIRST=$(printf '%s\n' "$OUT3" | head -1 | cut -f2)
if [ "$OTHER_N" -eq 2 ] && [ "$FIRST" = "repo" ]; then
  ok "AC5: an unknown repo still offers the account's 2 environments (as 'other'), and 'repo' sorts first when there is one"
else
  notok "AC5: ordering/fallback wrong — unknown-repo others=$OTHER_N, first row for a known repo='$FIRST'"
fi

# --- AC6: URL normalisation — SSH, .git, and trailing slash all match --------
# The binding is derived from `git remote get-url origin`, which is commonly an
# SSH URL, while the API records the https form. Matching them literally would
# mark every environment 'other' and turn a silent derivation into a question.
NORM_OK=1
for U in \
  "git@github.com:Glori-Holdings/quetrex-plugins.git" \
  "https://github.com/Glori-Holdings/quetrex-plugins.git" \
  "https://github.com/Glori-Holdings/quetrex-plugins/" \
  "ssh://git@github.com/Glori-Holdings/quetrex-plugins" \
  "HTTPS://GitHub.com/Glori-Holdings/quetrex-plugins"; do
  G=$(cand "$U" | awk -F'\t' '$2=="repo"{print $1}')
  [ "$G" = "env_011CUpkAEM4fzsAD6dx1zW3r" ] || { NORM_OK=0; notok "AC6: '$U' did not match the https form (got '${G:-none}')"; }
done
[ "$NORM_OK" -eq 1 ] && ok "AC6: SSH, .git, trailing-slash, scheme and case variants of the origin URL all match the recorded https URL"

# --- AC7: the genuinely-new user — empty in, empty out, no crash -------------
NEW_OK=1
for BAD in '{"data":[]}' '{}' 'not json at all' ''; do
  printf '%s' "$BAD" > "$WORK/bad.json"
  R=$(cand "https://github.com/x/y" "$WORK/bad.json" 2>&1); RC=$?
  if [ "$RC" -ne 0 ] || [ -n "$R" ]; then
    NEW_OK=0; notok "AC7: input '${BAD:0:20}' gave rc=$RC out='$R' — expected clean empty output so init can fall back"
  fi
done
[ "$NEW_OK" -eq 1 ] && ok "AC7: no routines, malformed JSON, and empty input all yield clean empty output (init falls back, never crashes)"

# --- AC8: a routine with no environment_id is skipped, not emitted as blank --
python3 - "$FIXTURE" "$WORK/partial.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["data"]:
    t.setdefault("job_config", {}).setdefault("ccr", {})["environment_id"] = None
json.dump(d, open(sys.argv[2], "w"))
PY
R=$(cand "https://github.com/Glori-Holdings/quetrex-base" "$WORK/partial.json")
if [ -z "$R" ]; then
  ok "AC8: routines carrying no environment_id are skipped entirely — never emitted as an empty candidate"
else
  notok "AC8: a null environment_id produced a candidate row: $(printf '%s' "$R" | tr '\n' ' ')"
fi

# --- AC9: task-build no longer tells the operator to hand-edit the binding ---
# Scoped to the qx_cloud_env_id block itself, not the whole file: init is named
# in a dozen unrelated places, so a file-wide grep would pass on a coincidence
# and assert nothing. Extract the shipped block and read ITS message.
TB="${QX_TASK_BUILD_COMMAND:-$ROOT/.claude/commands/task-build.md}"
awk -v name="qx_cloud_env_id" '
  $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
' "$TB" > "$WORK/envblock.sh" 2>/dev/null
if [ ! -s "$WORK/envblock.sh" ]; then
  notok "AC9: could not extract qx_cloud_env_id from task-build.md"
elif grep -q 'node -e' "$WORK/envblock.sh"; then
  notok "AC9: the missing-environment message STILL prints a node -e one-liner for the operator to run by hand"
elif grep -q 'quetrex-setup:init' "$WORK/envblock.sh"; then
  ok "AC9: the missing-environment message sends the operator to /quetrex-setup:init and no longer prints a hand-run node -e"
else
  notok "AC9: the missing-environment message does not name /quetrex-setup:init"
fi

printf '\n%s\n' "init-cloud-env.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
