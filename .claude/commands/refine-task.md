---
description: Refine a Quetrex task into a clear, buildable spec — an interactive dialog grounded in the repo code, then writes the sharpened description back to the kanban. Does not change status or start work. Usage: /refine-task SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Refine Task

Sharpen one kanban task's description into a clear, buildable spec — with explicit
Acceptance Criteria, Scope, Likely-affected files, and Edge cases — through an interactive
dialog grounded in this repo's actual code. This command is **read-only on status**: it
never moves the task between columns and never starts implementation. Any team member with
project access can run it.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`.

---

## 1. Parse the argument

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/refine-task SMA-1`

---

## 2. Source the helper and resolve context

Run a single bash block. The helper owns all auth/access messaging — do not reinvent it.

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1      # prints "Run /quetrex-login" on failure
resolve_project || exit 1      # prints "Run /quetrex-init" on failure
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

If either resolver fails, surface its message verbatim and stop. Do not continue.

---

## 3. Validate project access

```bash
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
```

A non-zero exit means `qapi` already printed the correct message (401 → `Run /quetrex-login`,
403/404 → `No access — contact your administrator`, other → `Quetrex API error (HTTP <code>)`).
Just stop.

---

## 4. Fetch the task by identifier

The argument is a human identifier (e.g. `SMA-1`), so resolve it to the task record:

```bash
qapi GET "/api/tasks?project=$QX_PROJECT_CODE"
```

From the returned list, find the entry whose identifier matches `TASK_ID`. Capture its
internal `id`, plus the current `title`, `description`, `type`, and `status`. For the full
record (so the draft is grounded in everything already known), then fetch:

```bash
qapi GET "/api/tasks/$ID"
```

If no entry matches `TASK_ID`, tell the user the identifier isn't in this project and stop.

---

## 5. Ground the spec in the repo

Before drafting anything, read the relevant **code**. Use Glob / Grep / Read to locate the
files implied by the task title and description — routes, components, models, configs,
tests. Build an accurate map of where the change would actually land. This is what makes
"Likely-affected files" and "Edge cases" real instead of generic.

---

## 6. Interactive refinement dialog

Propose a DRAFT improved spec to the user as markdown with these sections:

- **Summary** — one-paragraph restatement of intent
- **Acceptance Criteria** — explicit, testable bullet list
- **Scope** — what's in, and what's explicitly out
- **Likely-affected files** — concrete repo paths from step 5
- **Edge cases** — failure modes, empty states, auth/permission, concurrency
- *(optional)* **Suggested type** — Project / Feature / Bug, clearly marked as a
  suggestion only. Classification is **not** this command's job — it stays with `/que-task`.

Then ITERATE: ask the user to accept or tweak. Keep revising until they **explicitly
accept**. Do not proceed to write anything back until they do.

---

## 7. On acceptance — persist via the helper

Build every JSON payload with `node` / `JSON.stringify` so multi-line specs and quotes are
escaped correctly. Never hand-build JSON with `echo`. The helper injects the bearer token
safely — never echo or print the token.

```bash
# Update the task description with the accepted spec.
PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({description:process.argv[1]}))' "$SPEC")"
qapi PATCH "/api/tasks/$ID" "$PAYLOAD" >/dev/null || exit 1

# Post an audit-trail comment.
USER_NAME="$(git config user.name 2>/dev/null || echo "$USER")"
DATE="$(date +%Y-%m-%d)"
CPAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({body:process.argv[1]}))' "Spec refined by $USER_NAME on $DATE")"
qapi POST "/api/tasks/$ID/comments" "$CPAYLOAD" >/dev/null || exit 1
```

If the optional **Suggested type** was accepted as a hint, you may include it in the PATCH
payload as a suggestion field — but do not treat that as a classification. Final
classification stays with `/que-task`.

---

## 8. Confirm and stop

Tell the user:
- the task description was updated, and
- the "Spec refined by …" comment was posted.

Then remind them that the task's column/status was **not** changed and that classification
stays with `/que-task`. Do **not** start any implementation work.

---

## Error-handling rules

- Any `qapi` or resolver non-zero exit → the helper already printed the correct user-facing
  message. Just stop; do not add your own auth/access explanation.
- Never print or echo the bearer token. Never run `set -x` around `qapi`.
- This command never changes task status and never begins implementation.
