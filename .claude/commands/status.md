---
description: Show every task on this repo's Quetrex project as one board-ordered table — identifier, title, status, priority, type, assignee — with per-status counts and a link to the kanban board. Display only; never asks, never writes. Usage: /quetrex:status [--all]
---

# Project Status

Print the current project's tasks as one table in board order, then the counts per
status, then the board link. This command is **display-only**: it asks nothing, writes
nothing, and changes no task.

Argument: `$ARGUMENTS` is optional. `--all` includes tasks already in **Complete**;
by default those are hidden and only counted.

---

## 1. Fetch and render

Run this single bash block. `quetrex-api` (on the plugin's PATH) owns all auth/access
messaging; the JSON→table rendering is done in `node` so the block behaves identically
under bash and zsh (no shell word-splitting of API data).

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)"     || exit 1   # prints "Run /quetrex-setup:login" on failure
QX_PROJECT_CODE="$(quetrex-api project-code)" || exit 1   # prints "Run /quetrex-setup:init" on failure
quetrex-api GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
QX_SHOW_ALL=0
case "$ARGUMENTS" in *--all*) QX_SHOW_ALL=1 ;; esac
QX_TASKS="$(quetrex-api GET "/api/tasks?project=$QX_PROJECT_CODE")" || exit 1
printf '%s' "$QX_TASKS" | node -e '
  const [code, kanbanUrl, showAllRaw] = process.argv.slice(1);
  const showAll = showAllRaw === "1";
  const ORDER = ["backlog","queued","in_progress","pr_ready","merged","deployed","needs_clarity","complete"];
  const LABEL = { backlog:"Backlog", queued:"Queued", in_progress:"In Progress", pr_ready:"PR Ready",
                  merged:"Merged", deployed:"Deployed", needs_clarity:"Needs Clarity", complete:"Complete" };
  const PRIO = ["urgent","high","medium","low","none"];
  const board = String(kanbanUrl || "").replace(/\/+$/, "") + "/board";
  let raw = ""; try { raw = require("fs").readFileSync(0, "utf8"); } catch {}
  let all; try { all = JSON.parse(raw); } catch { console.log("Quetrex API returned an unreadable task list for " + code + "."); console.log("Board: " + board); process.exit(1); }
  if (!Array.isArray(all)) all = Array.isArray(all && all.tasks) ? all.tasks : [];
  const idx = (list, v) => { const i = list.indexOf(v); return i < 0 ? list.length : i; };
  all = all.map((t, i) => ({ t, i })).sort((a, b) =>
      idx(ORDER, a.t.status) - idx(ORDER, b.t.status)
   || idx(PRIO, a.t.priority) - idx(PRIO, b.t.priority)
   || (Number(a.t.number) || 0) - (Number(b.t.number) || 0)
   || a.i - b.i).map((x) => x.t);
  const hiddenComplete = showAll ? 0 : all.filter((t) => t.status === "complete").length;
  const shown = showAll ? all : all.filter((t) => t.status !== "complete");
  const norm = (s) => String(s == null ? "" : s).replace(/\s+/g, " ").trim();
  const esc  = (s) => s.replace(/\|/g, "\\|");
  const cell = (s) => esc(norm(s));
  const clip = (s) => { const a = Array.from(s); return a.length > 60 ? a.slice(0, 59).join("") + "…" : s; };
  const out = [];
  if (all.length === 0) {
    out.push("No tasks in " + code);
  } else if (shown.length === 0) {
    out.push("No open tasks in " + code + " · " + hiddenComplete + " complete (hidden — use --all)");
  } else {
    out.push("| Task | Title | Status | Priority | Type | Assignee |");
    out.push("| --- | --- | --- | --- | --- | --- |");
    for (const t of shown) {
      const id = cell(t.identifier || (t.projectCode && t.number != null ? t.projectCode + "-" + t.number : ""));
      const assignee = t.assignee && t.assignee.name ? cell(t.assignee.name) : "—";
      out.push("| " + [id, esc(clip(norm(t.title))), LABEL[t.status] || cell(t.status), cell(t.priority || "none"),
                        cell(t.type || "—"), assignee].join(" | ") + " |");
    }
    const counts = new Map();
    for (const t of shown) counts.set(t.status, (counts.get(t.status) || 0) + 1);
    const parts = ORDER.filter((s) => counts.has(s)).map((s) => counts.get(s) + " " + LABEL[s].toLowerCase());
    for (const s of counts.keys()) if (!ORDER.includes(s)) parts.push(counts.get(s) + " " + cell(s));
    if (hiddenComplete > 0) parts.push(hiddenComplete + " complete (hidden — use --all)");
    out.push("");
    out.push(parts.join(" · "));
  }
  out.push("");
  out.push("Board: " + board);
  console.log(out.join("\n"));
' "$QX_PROJECT_CODE" "$QX_KANBAN_URL" "$QX_SHOW_ALL"
```

---

## 2. Print and stop

Print the block's output **verbatim** — the table, the counts line, and the `Board:` link
exactly as emitted — and add nothing: no commentary, no summary, no suggestions, no
questions. If the block exited non-zero, `quetrex-api` already printed the correct
user-facing line (`Run /quetrex-setup:login`, `Run /quetrex-setup:init`,
`No access — contact your administrator`, or `Quetrex API error (HTTP <code>)`); surface
it verbatim and stop.

## Rules

- Display-only: never call any write endpoint, never edit a file, never ask a question.
- Never print or echo the bearer token. Never run `set -x` around `quetrex-api`.
- All JSON handling happens in `node`; never parse API output with shell word-splitting.
