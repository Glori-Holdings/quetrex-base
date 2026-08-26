---
description: Mark a deployed Quetrex task Complete (deployed → complete). Usage: /quetrex:task-complete SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Task Complete

Advance one task from **deployed → complete** on the Quetrex kanban. This is the final
manual gate after a deployed change has been human-verified. It touches the kanban only —
no git, no PRs.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`.

---

## 1. Parse the argument

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/quetrex:task-complete SMA-1`

---

## 2. Resolve context via the `quetrex-api` tool

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)"     || exit 1   # prints "Run /quetrex-setup:login" on failure
QX_PROJECT_CODE="$(quetrex-api project-code)" || exit 1   # prints "Run /quetrex-setup:init" on failure
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

---

## 3. Validate project access

```bash
quetrex-api GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
```

A non-zero exit means `quetrex-api` already printed the correct message. Just stop.

---

## 4. Guard the transition, then complete

The complete endpoint only accepts a task currently in `deployed`; out of that state it
returns **409 invalid_transition**, which `quetrex-api` would surface as the generic
`Quetrex API error (HTTP 409)`. To give the user a clear message, read the task's status
first and check it before the POST.

```bash
TASK="$(quetrex-api GET "/api/tasks/$TASK_ID")" || exit 1
STATUS="$(node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write(String(o.status||o.state||""))}catch{}' "$TASK")"

if [ "$STATUS" != "deployed" ]; then
  echo "Cannot complete $TASK_ID — it is in '${STATUS:-unknown}', not 'deployed'. Only deployed tasks can be completed." >&2
  exit 1
fi

quetrex-api POST "/api/tasks/$TASK_ID/complete" >/dev/null || {
  echo "Could not complete $TASK_ID — it was not in 'deployed' at write time. Re-check its status and retry." >&2
  exit 1
}
echo "$TASK_ID marked Complete."
```

The pre-check turns the common 409 into a clear, human message before the POST. If a race
still yields a non-2xx on the POST, the helper's `Quetrex API error (HTTP <code>)` is the
fallback and the hint above explains the likely cause.

---

## 5. Confirm and stop

Confirm in one line that `$TASK_ID` is now **Complete**. Do not touch git, branches, or PRs.

---

## Error-handling rules

- Empty argument → print usage and stop.
- Unknown identifier → `GET /api/tasks/$TASK_ID` returns 404 → helper prints
  `No access — contact your administrator`; just stop.
- Not in `deployed` → clear pre-check message (above); stop.
- Any `quetrex-api` or resolver non-zero exit → the helper already printed the correct message.
- Never print or echo the bearer token. Never run `set -x` around `quetrex-api`.
