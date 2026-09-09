# Captured from commit bc64a9bc9ad97f150c6d38b57cdb9216a654fd65 (bc64a9b)
# Source: plugins/quetrex-setup/commands/init.md, exec-block qx_link_project_repo
# Extracted verbatim by extract_exec_block() — do not hand-edit; re-extract if the block moves.
# ── quetrex:exec-block qx_link_project_repo ────────────────────────────────────
# Owner and repo are the two halves of the origin slug. The API validates each
# against ^[A-Za-z0-9._-]+$ — bare halves, never "owner/repo" in one field.
#
# Two inputs here are attacker-controllable in a cloned repo, and both are
# handled before anything is compared, printed or PATCHed:
#   * `remote.origin.url` can carry an embedded NEWLINE (git config accepts a \n
#     escape) and `grep -Eq` matches per LINE, so an anchored pattern succeeds on
#     ANY one line while the remaining lines flow straight into the advice below.
#     Refuse a multi-line origin outright; truncating to line 1 would just hand
#     the attacker the owner/repo halves.
#   * the project code comes from ./.quetrex/project.json, which nothing
#     validates, and it is interpolated into a `quetrex-api PATCH` one-liner the
#     operator is invited to paste. Only a code shaped the way the BOARD mints
#     one gets that treatment. `quetrex-api code-ok` is the single definition of
#     that shape and resolve_project already enforces it, so this block asks
#     rather than re-implementing the pattern next to the line it prints.
# Every value rendered into a printed line also has its control characters
# stripped, whatever its source — an ESC byte rewrites the operator's terminal.
# LC_ALL=C so `tr` deletes bytes 0x00-0x1F and 0x7F and leaves UTF-8 intact.
qx_ctl() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]'; }
QX_ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
if [ "$(printf '%s' "$QX_ORIGIN" | wc -l | tr -d ' ')" != 0 ]; then
  echo "origin remote is not a single-line URL — refusing to read a repo slug from it" >&2
  QX_ORIGIN=""
fi
QX_SLUG="$(printf '%s' "$QX_ORIGIN" | sed -E 's#^(git@github\.com:|(https?|ssh|git)://(git@)?github\.com/)##; s#/+$##; s#\.git$##; s#/+$##')"
QX_CODE_SHOWN="$(qx_ctl "$QX_PROJECT_CODE")"
if printf '%s' "$QX_SLUG" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  QX_OWNER_NAME="${QX_SLUG%%/*}"
  QX_REPO_NAME="${QX_SLUG##*/}"
  # A board OUTAGE must never read as "nothing recorded yet". `jq -r '… // empty'`
  # on empty stdin exits 0 printing nothing, so an unread GET would fall into the
  # PATCH arm below and overwrite a link belonging to a different repo. Take the
  # GET's exit status AND prove the body is a JSON object; anything else says so
  # and touches nothing.
  QX_LINKED_JSON="$(quetrex-api GET "/api/projects/$QX_PROJECT_CODE" 2>/dev/null)"; QX_GET_RC=$?
  if [ "$QX_GET_RC" -ne 0 ] || ! printf '%s' "$QX_LINKED_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "could not read project $QX_CODE_SHOWN from the board — leaving the repo link alone" >&2
  else
    QX_LINKED_OWNER="$(printf '%s' "$QX_LINKED_JSON" | jq -r '.githubOwner // empty' 2>/dev/null)"
    QX_LINKED_REPO="$(printf '%s' "$QX_LINKED_JSON" | jq -r '.githubRepo // empty' 2>/dev/null)"
    # Compare the way the BOARD compares (quetrex-kanban src/lib/branch-ref.ts
    # repoMatchesProject): trim, lowercase, strip a trailing `.git`, then strip
    # trailing slashes. Lowercasing alone was only one of the four — a stored
    # `dealerq.git` against an origin `dealerq` read as a different repo and
    # refused the link forever, the same way `DealerQ` used to. `quetrex-api
    # repo-norm` holds that shape once, and BOTH sides of every comparison go
    # through it, so init and doctor cannot drift from each other or from the
    # board. (It is also why there is no ${v,,}/${v:l} here — neither is
    # portable across bash and zsh, and neither does the other three steps.)
    QX_OWNER_LC="$(quetrex-api repo-norm "$QX_OWNER_NAME")"
    QX_REPO_LC="$(quetrex-api repo-norm "$QX_REPO_NAME")"
    QX_LINKED_OWNER_LC="$(quetrex-api repo-norm "$QX_LINKED_OWNER")"
    QX_LINKED_REPO_LC="$(quetrex-api repo-norm "$QX_LINKED_REPO")"
    if { [ -n "$QX_LINKED_OWNER" ] && [ "$QX_LINKED_OWNER_LC" != "$QX_OWNER_LC" ]; } \
       || { [ -n "$QX_LINKED_REPO" ] && [ "$QX_LINKED_REPO_LC" != "$QX_REPO_LC" ]; }; then
      # Name BOTH halves. A half-set link rendered as "Someone-Else/" reads as a
      # repository nobody owns.
      if [ -n "$QX_LINKED_OWNER" ] && [ -n "$QX_LINKED_REPO" ]; then
        QX_LINKED_SHOWN="$(qx_ctl "$QX_LINKED_OWNER")/$(qx_ctl "$QX_LINKED_REPO")"
      elif [ -n "$QX_LINKED_OWNER" ]; then
        QX_LINKED_SHOWN="owner $(qx_ctl "$QX_LINKED_OWNER"), repo unset"
      else
        QX_LINKED_SHOWN="owner unset, repo $(qx_ctl "$QX_LINKED_REPO")"
      fi
      echo "project $QX_CODE_SHOWN is linked to a different repo ($QX_LINKED_SHOWN), not $QX_SLUG — left alone" >&2
      # The one-liner is offered ONLY for a code the board could have issued.
      if quetrex-api code-ok "$QX_PROJECT_CODE"; then
        echo "  re-running init will not change it. Set the pair on the board's repo-link dialog, or as a project admin: quetrex-api PATCH \"/api/projects/$QX_PROJECT_CODE\" '{\"githubOwner\":\"$QX_OWNER_NAME\",\"githubRepo\":\"$QX_REPO_NAME\"}'" >&2
      else
        echo "  re-running init will not change it. Set the pair on the board's repo-link dialog. (This repo's .quetrex/project.json holds a project code the board could not have issued, so there is no command to offer — fix the binding with /quetrex-setup:init first.)" >&2
      fi
      unset QX_LINKED_SHOWN
    elif [ -z "$QX_LINKED_OWNER" ] || [ -z "$QX_LINKED_REPO" ]; then
      quetrex-api PATCH "/api/projects/$QX_PROJECT_CODE" \
        "$(jq -cn --arg o "$QX_OWNER_NAME" --arg r "$QX_REPO_NAME" '{githubOwner:$o,githubRepo:$r}')" >/dev/null 2>&1 \
        && echo "project $QX_CODE_SHOWN linked to $QX_OWNER_NAME/$QX_REPO_NAME" \
        || echo "could not link project $QX_CODE_SHOWN to $QX_OWNER_NAME/$QX_REPO_NAME — the board shows it unlinked and the webhook will ignore its deliveries" >&2
    fi
    unset QX_LINKED_OWNER QX_LINKED_REPO QX_LINKED_OWNER_LC QX_LINKED_REPO_LC QX_OWNER_LC QX_REPO_LC
  fi
  unset QX_LINKED_JSON QX_GET_RC
fi
unset QX_CODE_SHOWN
unset -f qx_ctl
# ── end quetrex:exec-block qx_link_project_repo ────────────────────────────────
