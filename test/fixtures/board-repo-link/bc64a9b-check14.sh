# Captured from commit bc64a9bc9ad97f150c6d38b57cdb9216a654fd65 (bc64a9b)
# Source: plugins/quetrex-setup/commands/doctor.md, "## Check 14" bash fences
# Extracted verbatim by extract_check14() — do not hand-edit; re-extract if the section moves.
# Two inputs to this check are attacker-controllable in a cloned repo.
# (1) `remote.origin.url` can carry an embedded NEWLINE (git config accepts a \n
#     escape) and `grep -Eq` matches per LINE, so an anchored pattern succeeds on
#     ANY one line while the remaining lines flow into what this check prints.
#     Refuse a multi-line origin outright; truncating to line 1 would just hand
#     the attacker the owner/repo halves.
# (2) the project code is read out of ./.quetrex/project.json, which nothing
#     validates, and the mismatch Fix interpolates it into a `quetrex-api PATCH`
#     one-liner the operator is invited to paste. Offer that command ONLY for a
#     code shaped the way the BOARD mints one. `quetrex-api code-ok` is the
#     single definition of that shape and resolve_project already enforces it,
#     so this check asks rather than carrying its own copy of the pattern.
#     Otherwise name the board dialog and offer nothing runnable.
# Every value this check renders is stripped of control characters whatever its
# source — an ESC byte rewrites this report. LC_ALL=C so `tr` deletes bytes
# 0x00-0x1F and 0x7F and leaves UTF-8 intact.
qx_ctl() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]'; }
QX_ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
QX_ORIGIN_MULTILINE=""
if [ "$(printf '%s' "$QX_ORIGIN" | wc -l | tr -d ' ')" != 0 ]; then
  QX_ORIGIN_MULTILINE=1
  QX_ORIGIN=""
fi
QX_SLUG="$(printf '%s' "$QX_ORIGIN" | sed -E 's#^(git@github\.com:|(https?|ssh|git)://(git@)?github\.com/)##; s#/+$##; s#\.git$##; s#/+$##')"
if ! printf '%s' "$QX_SLUG" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "✗ Webhook registered — origin is not a GitHub repo, so no hook can move cards to pr_ready."
  [ -z "$QX_ORIGIN_MULTILINE" ] || echo "    remote.origin.url spans more than one line — refused unread, and nothing from it is shown here."
  echo "    Fix: add a GitHub origin remote, then re-run /quetrex-setup:init"
elif ! command -v gh >/dev/null 2>&1; then
  echo "✗ Webhook registered — gh CLI not installed, so the hook on $QX_SLUG could not be checked."
  echo "    Fix: install gh (brew install gh && gh auth login), then re-run /quetrex-setup:init"
elif ! { [ -f "$BIND" ] && CODE="$(quetrex-api json-get "$BIND" projectCode 2>/dev/null)" && [ -n "$CODE" ]; }; then
  echo "✗ Webhook registered — this repo has no project binding, so there is no vault or project to check."
  echo "    Fix: run /quetrex-setup:init"
elif ! KANBAN="$(quetrex-api kanban-url 2>/dev/null)" || [ -z "$KANBAN" ]; then
  echo "✗ Webhook registered — not logged in, so the board's hook URL is unknown."
  echo "    Fix: run /quetrex-setup:login, then re-run /quetrex-setup:init"
else
  HOOK_URL="${KANBAN%/}/api/webhooks/github"
  CODE_SHOWN="$(qx_ctl "$CODE")"   # never render the raw binding value
  WH_MISSING=""    # every unmet condition, each named on its own
  WH_MOVE=""       # something here stops cards auto-moving to pr_ready
  WH_DISPLAY=""    # something here only changes what the board DISPLAYS
  WH_INIT=""       # something here is a thing init will actually write
  WH_MISMATCH=""   # a stored half DIFFERS — init leaves those alone by design
  WH_UNREAD=""     # the board did not answer; the link state is UNKNOWN
  # (b) a hook on the repo whose config.url is the board's endpoint
  HOOK_ID="$(gh api "repos/$QX_SLUG/hooks" --jq '.[] | select(.config.url=="'"$HOOK_URL"'") | .id' 2>/dev/null | head -1)"
  if [ -z "$HOOK_ID" ]; then
    WH_MISSING="$WH_MISSING GitHub hook on $QX_SLUG -> $HOOK_URL;"; WH_MOVE=1; WH_INIT=1
  fi
  # (c) the vault lists the NAME — masked collection GET, never a value
  if ! quetrex-api GET "/api/projects/$CODE/secrets" 2>/dev/null | node -e '
    let d=""; process.stdin.on("data",c=>{d+=c;}).on("end",()=>{
      let a; try { a=JSON.parse(d); } catch { process.exit(1); }
      const list = Array.isArray(a) ? a : (Array.isArray(a.secrets) ? a.secrets : Object.keys(a).map(k=>({name:k})));
      process.exit(list.some(x=>(typeof x==="string"?x:(x&&(x.name||x.key||x.id)))==="GITHUB_WEBHOOK_SECRET") ? 0 : 1);
    });' 2>/dev/null; then
    WH_MISSING="$WH_MISSING GITHUB_WEBHOOK_SECRET in project $CODE_SHOWN's vault;"; WH_MOVE=1; WH_INIT=1
  fi
  # (d) the project records BOTH halves of the origin slug. They do DIFFERENT
  # jobs: the webhook matches a delivery on githubRepo alone, so only that half
  # gates card movement; githubOwner is what makes the board render the pair as
  # linked. Report each with its own consequence, never one blanket claim.
  # A board OUTAGE is not an unset field — take the GET's exit status and prove
  # the body is a JSON object, or say the link could not be read and assert
  # nothing about it.
  LINKED_JSON="$(quetrex-api GET "/api/projects/$CODE" 2>/dev/null)"; LINKED_RC=$?
  linked_field() { printf '%s' "$LINKED_JSON" | node -e '
    let d=""; process.stdin.on("data",c=>{d+=c;}).on("end",()=>{
      let p; try { p=JSON.parse(d); } catch { process.exit(0); }
      process.stdout.write(String((p && p[process.argv[1]]) || ""));
    });' "$1" 2>/dev/null; }
  # Compare the way the BOARD compares (branch-ref.ts repoMatchesProject): trim,
  # lowercase, strip a trailing `.git`, then strip trailing slashes. Lowercasing
  # alone was only one of the four, so a stored `dealerq.git` against origin
  # `dealerq` drew a cross here and a fix line that resolved nothing — the board
  # had considered them the same repo all along. `quetrex-api repo-norm` holds
  # that shape once and init uses the identical call, so the two cannot drift.
  qx_norm() { quetrex-api repo-norm "$1"; }
  SLUG_OWNER="${QX_SLUG%%/*}"; SLUG_REPO="${QX_SLUG##*/}"
  LINKED_OWNER=""; LINKED_REPO=""
  if [ "$LINKED_RC" -ne 0 ] || ! printf '%s' "$LINKED_JSON" | node -e '
    let d=""; process.stdin.on("data",c=>{d+=c;}).on("end",()=>{
      let p; try { p=JSON.parse(d); } catch { process.exit(1); }
      process.exit(p && typeof p === "object" && !Array.isArray(p) ? 0 : 1);
    });' 2>/dev/null; then
    WH_MISSING="$WH_MISSING project $CODE_SHOWN's repo link (could not read project $CODE_SHOWN from the board — unverified);"
    WH_UNREAD=1
  else
    LINKED_OWNER="$(linked_field githubOwner)"; LINKED_REPO="$(linked_field githubRepo)"
    if [ -z "$LINKED_OWNER" ]; then
      WH_MISSING="$WH_MISSING project $CODE_SHOWN githubOwner (unset; origin is $SLUG_OWNER);"; WH_DISPLAY=1; WH_INIT=1
    elif [ "$(qx_norm "$LINKED_OWNER")" != "$(qx_norm "$SLUG_OWNER")" ]; then
      WH_MISSING="$WH_MISSING project $CODE_SHOWN githubOwner (is $(qx_ctl "$LINKED_OWNER"), origin is $SLUG_OWNER);"; WH_DISPLAY=1; WH_MISMATCH=1
    fi
    if [ -z "$LINKED_REPO" ]; then
      WH_MISSING="$WH_MISSING project $CODE_SHOWN githubRepo (unset; origin is $SLUG_REPO);"; WH_MOVE=1; WH_DISPLAY=1; WH_INIT=1
    elif [ "$(qx_norm "$LINKED_REPO")" != "$(qx_norm "$SLUG_REPO")" ]; then
      WH_MISSING="$WH_MISSING project $CODE_SHOWN githubRepo (is $(qx_ctl "$LINKED_REPO"), origin is $SLUG_REPO);"; WH_MOVE=1; WH_DISPLAY=1; WH_MISMATCH=1
    fi
  fi
  if [ -z "$WH_MISSING" ]; then
    echo "✓ Webhook registered — $QX_SLUG hook $HOOK_ID -> $HOOK_URL, GITHUB_WEBHOOK_SECRET in project $CODE_SHOWN's vault, project linked to $(qx_ctl "$LINKED_OWNER")/$(qx_ctl "$LINKED_REPO") — board shows the repository as linked."
  else
    echo "✗ Webhook registered — missing:$WH_MISSING"
    [ -z "$WH_MOVE" ]    || echo "    Cards will not auto-move to pr_ready."
    [ -z "$WH_DISPLAY" ] || echo "    The board will show the repository as not linked."
    if [ -n "$WH_UNREAD" ]; then
      echo "    Fix: the board did not answer for project $CODE_SHOWN — check it is reachable and the login is current (/quetrex-setup:login), then re-run /quetrex-setup:doctor."
    fi
    if [ -n "$WH_MISMATCH" ]; then
      echo "    Fix: init never overwrites a differing repo link, so re-running it changes nothing here. Set the pair on the board's repo-link dialog, or as a project admin run:"
      if quetrex-api code-ok "$CODE"; then
        echo "         quetrex-api PATCH \"/api/projects/$CODE\" '{\"githubOwner\":\"$SLUG_OWNER\",\"githubRepo\":\"$SLUG_REPO\"}'"
        echo "         (admin-gated: a plain member gets \"No access — contact your administrator\" and must ask an admin to change it.)"
      else
        echo "         (no command is offered: this repo's .quetrex/project.json holds a project code the board could not have issued. Fix the binding with /quetrex-setup:init, then use the dialog.)"
      fi
    fi
    if [ -n "$WH_INIT" ]; then
      echo "    Fix: re-run /quetrex-setup:init"
    fi
  fi
fi
