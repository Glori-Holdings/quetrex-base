#!/usr/bin/env bash
# no-false-agency.test.sh — never ask to do something you cannot do.
#
# THE FIELD INCIDENT. /quetrex-setup:init asked "The Claude GitHub App is NOT installed. Run
# /install-github-app?" and offered "Yes — run /install-github-app". The operator answered yes.
# Nothing happened, and nothing could: that is a native interactive command driving a GitHub
# OAuth flow in the operator's own browser. The model cannot run or complete it.
#
# The operator's words: "My partners would have thought it was taken care of and issues would
# have happened."
#
# Same class as every other defect this repo has shipped — something reports success while
# nothing happened — but the victim is a human's belief rather than a gate's state, so no
# artifact records it and no later check catches it.
#
# The remedy went further than rewording: the GitHub App step was REMOVED. Its install flow
# then asks whether to set up GitHub Actions workflows, and "yes" there creates a third
# execution location (a runner with no Claude login, demanding its own API key) — the exact
# thing this project already deleted once. A prompt whose wrong answer breaks the architecture
# should not be asked.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMDS="$ROOT/.claude/commands"
SETUP_CMDS="$ROOT/plugins/quetrex-setup/commands"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# Commands only the operator can complete — they need a browser session or credentials the
# model must never hold. Add to this list; never remove from it.
OPERATOR_ONLY='install-github-app
login'

# --- ASSERTION 1: never phrased as an action a command performs on approval ----
# Mentioning /login is fine and necessary ("run /quetrex-setup:login"). What is forbidden is
# presenting it as something THIS command will do once you say yes.
for f in "$CMDS"/*.md "$SETUP_CMDS"/*.md; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    # "Run /x?" as a question, "do not run /x without a yes", or an option labelled "Yes — run /x"
    # Generalised deliberately. A reviewer defeated the previous three fixed sentence
    # shapes by re-adding the same incident as "Install it now?" / "Yes — install the
    # Claude GitHub App", and again as a fenced block running `claude /install-github-app`.
    # Match the SHAPE — an offer to perform, or a claim of having performed — not a phrasing.
    SUBJ="$cmd"
    [ "$cmd" = "install-github-app" ] && SUBJ="($cmd|GitHub App)"
    if grep -qiE "(do not run|don'?t run) \`?/?$cmd" "$f" \
    || grep -qiE "(run|install|set ?up) \`?/?$SUBJ\`?[^\n]{0,20}\?" "$f" \
    || grep -qiE "yes[^\n]{0,6}(—|-|:)[^\n]{0,10}(run|install) [^\n]{0,40}$SUBJ" "$f" \
    || grep -qiE "offered and (accepted|declined)" "$f" \
    || grep -qiE "^[^#]*\bclaude +/$cmd" "$f"; then
      notok "ASSERTION 1: $n presents /$cmd as an action it runs on approval — it cannot, so a yes produces nothing while reading as done"
    fi
  done <<< "$OPERATOR_ONLY"
done
[ "$FAIL" -eq 0 ] && ok "ASSERTION 1: no shipped command offers to run an operator-only command"

# --- ASSERTION 2: the GitHub App is gone, not merely reworded -----------------
INIT="$SETUP_CMDS/init.md"
if [ -f "$INIT" ]; then
  # The only permitted mention is the rationale inside the removed-section notice, which exists
  # to stop someone helpfully adding it back.
  BODY="$(grep -vE '^\s*-? ?\*\*The model cannot run' "$INIT")"
  if printf '%s' "$BODY" | grep -qiE 'run \`?/install-github-app|offer /install-github-app|Claude GitHub App state'; then
    notok "ASSERTION 2: init.md still offers or checks the Claude GitHub App — it must not ask at all"
  else
    ok "ASSERTION 2: init.md no longer offers or checks the Claude GitHub App"
  fi

  if grep -qE '^## 4g\. \(removed\)' "$INIT"; then
    ok "ASSERTION 2: the removal is recorded with its reasoning, so it is not re-added as a convenience"
  else
    notok "ASSERTION 2: no removal notice — the next person adds the check back"
  fi

  if grep -qiE 'third execution location' "$INIT"; then
    ok "ASSERTION 2: the notice names the real hazard (a runner needing its own API key)"
  else
    notok "ASSERTION 2: the removal notice does not explain why the install flow is harmful"
  fi
fi

# --- ASSERTION 3: doctor must not report it as outstanding --------------------
DOC="$SETUP_CMDS/doctor.md"   # doctor ships in quetrex-setup (user scope)
if [ -f "$DOC" ]; then
  if grep -qiE 'github app' "$DOC"; then
    notok "ASSERTION 3: doctor.md still checks the Claude GitHub App — it would nag forever for something Quetrex does not use"
  else
    ok "ASSERTION 3: doctor.md does not check the Claude GitHub App"
  fi
fi

# --- ASSERTION 4: assertion-count floor ---------------------------------------
# An assertion that silently stops matching disappears instead of failing. That has happened
# here before, so pin the number. Set to the ACTUAL count: pinned one low, an assertion could
# vanish and the floor would still report ok — which is the failure it exists to catch.
EXPECTED=6
TOTAL=$((PASS + FAIL + 1))
if [ "$TOTAL" -ge "$EXPECTED" ]; then
  ok "ASSERTION 4: $TOTAL assertions ran, floor is $EXPECTED"
else
  notok "ASSERTION 4: only $TOTAL assertions ran, floor is $EXPECTED — one stopped matching and vanished rather than failing"
fi

echo
echo "no-false-agency.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
