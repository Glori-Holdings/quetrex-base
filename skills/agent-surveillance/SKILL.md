---
name: agent-surveillance
description: Launch a real-time web dashboard to monitor Claude Code agent teams. Shows live agent roster, message feeds, and task kanban board with SSE updates. Persists historical sessions to SQLite for post-mortem analysis.
disable-model-invocation: true
---

# Agent Surveillance Dashboard

## When to Invoke

**ALWAYS invoke this skill automatically before:**
- Any `TeamCreate` operation
- Any multi-agent workflow
- Any time you're about to spawn multiple agents to work in parallel

**Why:** This gives you (Claude) and the user real-time visibility into what agents are doing, what messages they're exchanging, and what tasks are in flight. It's your mission control center.

**Do NOT wait for the user to ask** — proactively launch the dashboard as part of your multi-agent workflow setup.

---

## Quick Launch Protocol

### Step 1: Check if Already Running

```bash
lsof -ti:3847
```

If this returns a PID, the server is already running. Skip to Step 4 (verify and open browser).

### Step 2: Start the Server

```bash
cd ~/.claude/skills/agent-surveillance && node scripts/server.js &
```

The server will:
- Start on port 3847
- Initialize SQLite database at `~/.claude/skills/agent-surveillance/surveillance.db`
- Watch `~/.claude/teams/` and `~/.claude/tasks/` directories
- Auto-open the dashboard in the default browser

### Step 3: Verify Server is Live

Wait 2 seconds, then test:

```bash
curl -s http://localhost:3847/api/state | head -c 100
```

You should see JSON output (even if empty). If you get "Connection refused", the server failed to start — see Troubleshooting.

### Step 4: Open Browser (if not auto-opened)

```bash
# macOS
open http://localhost:3847

# Linux
xdg-open http://localhost:3847

# Windows
start http://localhost:3847
```

### Step 5: Proceed with TeamCreate

Now that the dashboard is live, create your team. The dashboard will immediately show:
- New agents appearing in the roster
- Messages flowing between agents
- Tasks moving across the kanban board

---

## What the User Sees

### Live Mode (Default)

**3-panel layout:**

```
┌─────────────────────────────────────────────────────┐
│  Agent Dashboard          [Live] [History]  ☀ ● Live │
├──────────┬──────────────────────────────────────────┤
│  AGENT   │  MESSAGES                           (12) │
│  ROSTER  │  ┌─────────────────────────────────┐     │
│          │  │ researcher → team-lead    2m ago │     │
│ ┌──────┐ │  │ Task completed: Research done    │     │
│ │ R    │ │  └─────────────────────────────────┘     │
│ │ resea│ │                                          │
│ └──────┘ │  TASK BOARD                              │
│ ┌──────┐ │  Pending (1)  │ In Progress (2) │ Done(3)│
│ │ T    │ │  ┌──────────┐ │ ┌─────────────┐ │       │
│ │ team-│ │  │ Task #4   │ │ │ Task #2     │ │       │
│ └──────┘ │  └──────────┘ │ └─────────────┘ │       │
└──────────┴──────────────────────────────────────────┘
```

**Features:**
- **Agent Roster (left)**: Colored avatar circles with agent names, model badges, and lead indicators
- **Messages (top right)**: Chronological feed of all inter-agent messages with auto-scroll
  - Protocol messages (task assignments, shutdown requests) rendered as styled cards
  - Plain text messages get markdown rendering (bold, italic, code blocks)
  - Click any message to open a thread modal showing full conversation between two agents
- **Task Board (bottom right)**: Kanban with 3 columns (Pending, In Progress, Completed)
  - System-generated agent-tracking tasks are automatically filtered out
  - Shows task ID, subject, owner, and blocked/blocks relationships

**Updates:**
- All changes pushed via SSE (Server-Sent Events) in real-time
- No polling from the browser — instant updates as agents work

### History Mode

Click "History" in the header to view past sessions.

**Session grid:**
- Each card shows: team name, agent count, message count, task count, date range, ENDED badge
- Hover to reveal Delete button (cascade delete through all related tables)
- Click a card to load the full session into the same 3-panel layout

**Session detail view:**
- Same layout as live mode, but with historical data
- Banner: "Viewing historical session — {team} — {date} to {date}"
- "Back to History" button to return to grid

**Why this matters:** After a multi-agent team finishes its work, you can review the entire message history, see what tasks were completed, and understand the flow of work. This is invaluable for debugging failed workflows or learning from successful ones.

---

## Architecture Reference

### File Structure

```
~/.claude/skills/agent-surveillance/
  SKILL.md           ← This file (skill definition)
  package.json       ← Single dependency: better-sqlite3
  surveillance.db    ← SQLite database (auto-created)
  scripts/
    server.js        ← Entire application (~1700 lines)
```

### Design Philosophy

**Single-file monolith:** The entire dashboard (server + client HTML/CSS/JS) is one Node.js file. No build step, no bundler, no framework. The server embeds all HTML, CSS, and JavaScript inside a template literal returned by a `getHTML()` function.

**Why monolithic?**
- Zero build complexity — no webpack, no vite, no React
- Instant startup — `node server.js` and you're live
- Easy to ship as a skill — copy one directory
- Claude Code agents can read and edit a single file easily

### Data Sources

Claude Code stores team/agent/task data as JSON files on disk:

```
~/.claude/teams/{team-name}/config.json    ← Team config with member list
~/.claude/teams/{team-name}/inbox/         ← Message files per agent
~/.claude/tasks/{team-name}/                ← Task JSON files
```

The server watches these directories and transforms raw files into a unified state object that the frontend renders.

### File Watching Strategy

**Do NOT rely solely on `fs.watch()`**. On macOS, `fs.watch({ recursive: true })` silently misses events.

**Dual strategy:**
1. `fs.watch()` for instant detection when it works
2. Polling every 2 seconds as a safety net that always works

All filesystem callbacks are debounced (200ms) to avoid processing the same change multiple times.

### Real-Time Push: SSE

Uses Server-Sent Events (SSE) over WebSockets for simplicity and auto-reconnect.

**Event types pushed to clients:**
- `full_state` — Complete state refresh
- `team_updated` — Single team changed
- `team_removed` — Team deleted
- `inbox_updated` — New messages for an agent
- `task_updated` — Task status changed
- `task_deleted` — Task removed
- `lock_changed` — Task file lock status

All SSE handlers on the client are guarded: only call render functions when `currentMode === 'live'` to prevent live data from overwriting historical views.

### SQLite Persistence

Uses `better-sqlite3` for synchronous, fast SQLite access. Wrapped in try/catch for graceful degradation — if SQLite fails to load (native module issues), the dashboard still works in memory-only mode.

**Schema:**
- `sessions` — One row per team lifecycle (created → ended)
- `agents` — Team members, linked to session
- `messages` — All inbox messages, deduplicated by (session, agent, from, timestamp)
- `tasks` — Task snapshots, deduplicated by (session, task_id)
- `agent_events` — Status changes (joined, idle, shutdown)

**Session lifecycle:**
1. When a new team appears in `~/.claude/teams/`, create a session row
2. Upsert agents, messages, and tasks as they change
3. When the team directory disappears, set `ended_at` on the session
4. Historical sessions persist forever in SQLite until manually deleted

**Deduplication:** Uses `INSERT OR REPLACE` with unique indexes to avoid duplicate rows when polling re-reads the same data.

### API Endpoints

```
GET  /                              → Serve the HTML page
GET  /api/state                     → Full live state object
GET  /api/events                    → SSE stream
GET  /api/sessions                  → List historical sessions with counts
GET  /api/sessions/:id              → Session detail with agents array
GET  /api/sessions/:id/messages     → Paginated messages (?limit=N&offset=N)
GET  /api/sessions/:id/tasks        → All tasks for a session
DELETE /api/sessions/:id            → Delete session (cascade all related data)
POST /api/messages/:id/read         → Mark message as read
POST /api/threads/read              → Mark thread as read (body: {session_id, thread_id})
```

**Cache headers:** `Cache-Control: no-store, no-cache, must-revalidate` on HTML response to prevent stale browser pages.

---

## Troubleshooting

### Server Won't Start

**Problem:** Port 3847 already in use by a stale process.

**Fix:**
```bash
# Kill existing process
kill $(lsof -ti:3847)

# Wait 2 seconds
sleep 2

# Start server again
cd ~/.claude/skills/agent-surveillance && node scripts/server.js &
```

### SQLite Native Module Error

**Problem:** `better-sqlite3` fails to load (common on ARM64 or after Node.js version changes).

**Fix 1 — Rebuild native modules:**
```bash
cd ~/.claude/skills/agent-surveillance
npm rebuild better-sqlite3
```

**Fix 2 — Memory-only mode:**

The server is designed to degrade gracefully. If SQLite fails to load, it will:
- Log a warning: "SQLite failed to load, running in memory-only mode"
- Continue functioning for live monitoring
- Skip persistence (no historical sessions)

This is acceptable for short-lived debugging sessions. For production use, fix the native module.

### Dashboard Shows No Data

**Problem:** Teams/tasks exist but dashboard is empty.

**Check 1 — Verify data files exist:**
```bash
ls -la ~/.claude/teams/
ls -la ~/.claude/tasks/
```

**Check 2 — Check server logs:**

The server logs to stdout. If you started it in the background, check the terminal where you launched it.

**Check 3 — Verify SSE connection:**

Open browser DevTools → Network tab → Filter by "events". You should see an active EventSource connection with periodic data chunks. If the connection is closed or failing, the browser won't receive updates.

**Fix:**
- Restart the server (kill port 3847, start again)
- Hard refresh the browser (Cmd+Shift+R on macOS)

### Messages/Tasks Not Updating

**Problem:** Live mode shows stale data.

**Cause:** Filesystem events missed by `fs.watch()` and polling hasn't caught up yet.

**Wait:** Polling runs every 2 seconds. Wait up to 4 seconds for updates to appear.

**If still not updating:**
- Restart the server (filesystem watchers may have crashed)
- Check that team/task JSON files are actually being written to `~/.claude/`

### Browser Tab Crashes / Out of Memory

**Problem:** Long-running session with thousands of messages.

**Fix:**
- Use History mode instead of Live mode for reviewing old sessions
- Delete old sessions from History mode to free up browser memory
- Server performance is fine (SQLite handles millions of rows), but the browser DOM has limits

---

## CRITICAL: Template Literal Coding Rules

**Context:** The entire client-side code lives inside a Node.js template literal (`getHTML()` returns a backtick string). This means you MUST follow special rules for regex patterns and special characters.

### The Problem

In JavaScript template literals, a backslash `\` followed by a character that isn't a recognized escape sequence **silently drops the backslash**. So `\*` becomes `*`, `\.` becomes `.`, `\w` becomes `w`, etc.

This means `/\*\*(.+?)\*\*/g` (match bold markdown) becomes `/**(.+?)**/g` — a broken regex that crashes at runtime. And `node -c` syntax checking **PASSES** because the template literal is valid Node.js — the error only shows up in the browser.

### The Rules

**When editing server.js, NEVER write these patterns inside the template literal:**

| NEVER write this | Write this instead | Why it works |
|-----------------|-------------------|--------------|
| `\w` | `[a-zA-Z0-9_]` | Character class, no backslash |
| `\d` | `[0-9]` | Character class, no backslash |
| `\s` | `[ \t\n\r]` | Character class, no backslash |
| `\b` | Restructure the regex | Word boundary breaks silently |
| `\*` | `[*]` | `*` is literal inside `[]` |
| `\.` | `[.]` | `.` is literal inside `[]` |
| `` ` `` (backtick) | `\x60` | `\x` is a RECOGNIZED hex escape |
| `(?<!...)` | Avoid entirely | Lookbehinds crash some browsers |

### Why `\x60` Works But `\*` Doesn't

`\x` is a recognized JavaScript escape sequence (hex escape). So `\x60` is properly processed into the backtick character (U+0060). But `\*` is NOT a recognized escape — JavaScript says "I don't know what `\*` means" and drops the backslash.

### Testing Template Literal Output

Always verify your template literal output by fetching the served HTML and inspecting the regex patterns:

```bash
curl -s http://localhost:3847/ | grep 'replace'
```

If you see `/**(.+?)**/g` instead of `/[*][*](.+?)[*][*]/g`, the template literal ate your backslashes.

**ALWAYS test in the actual browser** after editing server.js. The template literal mangling is invisible to `node -c`, invisible to linters, invisible to tests. The only way to catch it is to serve the HTML and inspect what the browser receives.

---

## Example Usage in Multi-Agent Workflow

Here's how you (Claude) should use this skill:

```
User: "Use a team of agents to research our top 3 competitors and write a summary report."

Claude:
1. First, I'll launch the agent surveillance dashboard so we can monitor the team's work in real-time.

[Invoke agent-surveillance skill]
- Check port 3847: not in use
- Start server: cd ~/.claude/skills/agent-surveillance && node scripts/server.js &
- Verify: curl http://localhost:3847/api/state
- Dashboard is live at http://localhost:3847

2. Now I'll create a team with a lead and 3 researcher agents.

[TeamCreate with 4 agents]

3. The dashboard is now showing your agents in the roster. You'll see messages
   appear as they communicate, and tasks moving across the kanban board as
   work progresses.

[Continue with workflow...]
```

**Key point:** Launch the dashboard BEFORE creating the team, so the user doesn't miss any of the initial agent activity.

---

## Advanced Usage

### Monitoring Multiple Teams Simultaneously

The dashboard shows ALL active teams at once. If you create multiple teams (e.g., one for research, one for implementation), they'll all appear in the roster with their respective messages and tasks.

**Limitation:** The task board combines tasks from all teams. If you need per-team task isolation, use History mode to review individual sessions after they complete.

### Debugging Failed Workflows

If a multi-agent workflow fails or produces unexpected results:

1. Switch to History mode
2. Find the session for the failed team
3. Click to load full session detail
4. Review the message feed chronologically to see where things went wrong
5. Check the task board to see which tasks were blocked or never completed

The SQLite database preserves the entire session, so you can do post-mortem analysis even if the team was deleted hours ago.

### Cleaning Up Old Sessions

History mode shows a Delete button (on hover) for each session card. Clicking it will:
- Cascade delete through all related tables (agents, messages, tasks, agent_events)
- Free up disk space in the SQLite database
- Remove the session from the history grid

There's no undo — be sure before deleting.

---

## Summary

**When:** Always launch before multi-agent workflows
**How:** Check port, start server, verify, open browser
**What:** Real-time 3-panel dashboard with roster, messages, and tasks
**Why:** Visibility into agent activity + historical session analysis
**Troubleshooting:** Kill port, rebuild native deps, memory-only fallback
**Gotcha:** Template literal regex rules — always test in browser

**The dashboard is your mission control. Use it every time you spawn agents.**
