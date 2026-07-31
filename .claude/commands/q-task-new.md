---
description: Create a new Backlog task on the Quetrex kanban — interactively gather title, description, assignee, and priority, then create it. Does not start work. Usage: /q-task-new
---

# New Task

Create one **Backlog** task on the Quetrex kanban through a short interactive dialog.
This command only ADDs a task in its default (Backlog) column — it does **not** start
implementation and does **not** change anyone else's status. Any team member with project
access can run it.

---

## 1. Source the helper and resolve context

Run a single bash block. The helper owns all auth/access messaging — do not reinvent it.

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1      # prints "Run /q-login" on failure
resolve_project || exit 1      # prints "Run /q-init" on failure
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

If either resolver fails, surface its message verbatim and stop.

---

## 2. Validate project access

```bash
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
```

A non-zero exit means `qapi` already printed the correct message (401 → `Run /q-login`,
403/404 → `No access — contact your administrator`, other → `Quetrex API error (HTTP <code>)`).
Just stop.

---

## 3. Gather the task fields interactively

Ask the user **one question at a time**. Do not assume answers.

**a. Title (required).** Ask for a short title. If the user gives an empty title, re-prompt —
do not create a task without a title. Capture into `TITLE`.

**b. Description (optional, multi-line allowed).** Ask for a fuller description. Empty is
allowed. Capture into `DESC`.

**c. Assignee (optional).** Fetch the project-scoped user list and present a numbered
pick-list:

```bash
USERS="$(qapi GET "/api/users")" || exit 1
node -e '
  let a; try{a=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const list=Array.isArray(a)?a:(a.users||[]);
  if(!list.length){process.exit(2)}
  list.forEach((u,i)=>{
    const name=u.name||u.fullName||u.email||"(unknown)";
    const email=u.email?` <${u.email}>`:"";
    console.log(`${i+1}) ${name}${email}`);
  });
' "$USERS"
```

Print the numbered list above plus an explicit **`0) leave unassigned`** option. Ask the user
to pick a number. Map their pick back to that user's `id` (re-parse `USERS` with node and read
`list[pick-1].id`) into `ASSIGNEE_ID`; for `0` leave `ASSIGNEE_ID` empty.

If `GET /api/users` returns an empty list or the node call exits non-zero (e.g. forbidden),
**fall back to unassigned**, tell the user "no assignable users available — leaving
unassigned", and continue. Do not block on this.

**d. Priority.** Ask for one of: `urgent / high / medium / low / none` (default `none`).
Validate against exactly that set; re-prompt on anything else. Capture into `PRIORITY`.

**e. AI-notes (optional).** If the user volunteers initial AI build notes, capture into
`AINOTES`; otherwise leave it empty and skip.

---

## 4. Create the task

Build the payload with `node` / `JSON.stringify` — never hand-build JSON with `echo`. Only
include `assigneeId` when set and `aiNotes` when set.

```bash
PAYLOAD="$(node -e '
  const [projectCode,title,description,priority,assigneeId,aiNotes]=process.argv.slice(1);
  const o={projectCode,title,description,priority};
  if(assigneeId) o.assigneeId=assigneeId;
  if(aiNotes)    o.aiNotes=aiNotes;
  process.stdout.write(JSON.stringify(o));
' "$QX_PROJECT_CODE" "$TITLE" "$DESC" "$PRIORITY" "$ASSIGNEE_ID" "$AINOTES")"
RESP="$(qapi POST /api/tasks "$PAYLOAD")" || exit 1
```

Parse the new task's human identifier from the response (prefer `identifier`; else compose
from `code`/`number`, e.g. `SMA-3`):

```bash
IDENTIFIER="$(node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  if(o.identifier){process.stdout.write(String(o.identifier));process.exit(0)}
  if(o.code && (o.number!=null)){process.stdout.write(`${o.code}-${o.number}`);process.exit(0)}
  process.exit(1)
' "$RESP")" || IDENTIFIER="(see kanban)"
echo "Created $IDENTIFIER in Backlog."
```

---

## 5. Confirm and stop

Tell the user:
- the new task identifier and that it was created in **Backlog**,
- its assignee (the chosen user's name, or "unassigned"),
- its priority.

Then remind them this **did not start any work** — the task sits in Backlog until someone
picks it up.

---

## Error-handling rules

- Any `qapi` or resolver non-zero exit → the helper already printed the correct user-facing
  message. Just stop; do not add your own auth/access explanation.
- Empty title → re-prompt. Bad priority → re-prompt. Empty/forbidden user list → unassigned.
- Never print or echo the bearer token. Never run `set -x` around `qapi`.
- Build every JSON payload with `node` / `JSON.stringify`, never `echo`.
