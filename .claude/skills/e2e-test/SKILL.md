---
name: e2e-test
description: Comprehensive end-to-end testing command. Launches parallel sub-agents to research the codebase (structure, database schema, potential bugs), then uses Claude's native MCP browser tools to test every user journey — taking screenshots, validating UI/UX, and querying the database to verify records. Run after implementation to validate everything before code review.
disable-model-invocation: true
---

# End-to-End Application Testing

## Pre-flight Check

### 1. Platform Check

MCP browser tools require **Linux, WSL, or macOS**. Check the platform:
```bash
uname -s
```
- `Linux` or `Darwin` → proceed
- Anything else (e.g., `MINGW`, `CYGWIN`, or native Windows) → stop with:

> "MCP browser tools only support Linux, WSL, and macOS. Please run this command from WSL or a Linux/macOS environment."

Stop execution if the platform is unsupported.

### 2. Frontend Check

Verify the application has a browser-accessible frontend. Check for:
- A `package.json` with a dev/start script serving a UI
- Frontend framework files (pages/, app/, src/components/, index.html, etc.)
- Web server configuration

If no frontend is detected:
> "This application doesn't appear to have a browser-accessible frontend. E2E browser testing requires a UI to visit. For backend-only or API testing, a different approach is needed."

Stop execution if no frontend is found.

### 3. MCP Browser Tools Setup

Load the browser tools with ToolSearch before starting:

```
select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__find,mcp__claude-in-chrome__browser_batch,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__read_console_messages,mcp__claude-in-chrome__resize_window,mcp__claude-in-chrome__tabs_close_mcp
```

Requires Chrome with the Claude Code extension installed.

If the MCP tools are not available, stop with:
> "MCP browser tools are not available. Ensure Chrome is running with the Claude Code extension installed, then re-run this command."

## Phase 1: Parallel Research

Launch **three sub-agents simultaneously** using the Task tool. All three run in parallel.

### Sub-agent 1: Application Structure & User Journeys

> Research this codebase thoroughly. Return a structured summary covering:
>
> 1. **How to start the application** — exact commands to install dependencies and run the dev server, including the URL and port it serves on
> 2. **Authentication/login** — if the app has protected routes, how to create a test account or log in (credentials from .env.example, seed data, or sign-up flow)
> 3. **Every user-facing route/page** — each URL path and what it renders
> 4. **Every user journey** — complete flows a user can take (e.g., "sign up → create profile → view public page"). For each journey, list the specific steps, interactions (clicks, form fills, navigation), and expected outcomes
> 5. **Key UI components** — forms, modals, dropdowns, pickers, toggles, and other interactive elements that need testing
>
> Be exhaustive. Testing will only cover what you identify here.

### Sub-agent 2: Database Schema & Data Flows

> Research this codebase's database layer. Read `.env.example` to understand environment variables for database connections. DO NOT read `.env` directly. Return a structured summary covering:
>
> 1. **Database type and connection** — what database is used (Postgres, MySQL, SQLite, etc.) and the environment variable name for the connection string (from .env.example)
> 2. **Full schema** — every table, its columns, types, and relationships
> 3. **Data flows per user action** — for each user-facing action (form submit, button click, etc.), document exactly what records are created, updated, or deleted and in which tables
> 4. **Validation queries** — for each data flow, provide the exact query to verify records are correct after the action

### Sub-agent 3: Bug Hunting

> Analyze this codebase for potential bugs, issues, and code quality problems. Focus on:
>
> 1. **Logic errors** — incorrect conditionals, off-by-one errors, missing null checks, race conditions
> 2. **UI/UX issues** — missing error handling in forms, no loading states, broken responsive layouts, accessibility problems
> 3. **Data integrity risks** — missing validation, potential orphaned records, incorrect cascade behavior
> 4. **Security concerns** — SQL injection, XSS, missing auth checks, exposed secrets
>
> Return a prioritized list with file paths and line numbers.

**Wait for all three sub-agents to complete before proceeding.**

## Phase 2: Start the Application

Using Sub-agent 1's startup instructions:

1. Install dependencies if needed
2. Start the dev server **in the background** (e.g., `npm run dev &`)
3. Wait for the server to be ready
4. Create a new browser tab using `mcp__claude-in-chrome__tabs_create_mcp`
5. Navigate to the app URL using `mcp__claude-in-chrome__navigate` and confirm it loaded using `mcp__claude-in-chrome__read_page`

## Phase 3: Create Task List

Using the user journeys from Sub-agent 1 and findings from Sub-agent 3, create a task (using TaskCreate) for each user journey. Each task should include:

- **subject:** The journey name (e.g., "Test profile creation flow")
- **description:** Steps to execute, expected outcomes, database records to verify, and any related bug findings from Sub-agent 3
- **activeForm:** Present continuous (e.g., "Testing profile creation flow")

Also create a final task: "Responsive testing across viewports."

## Phase 4: User Journey Testing

For each task, mark it `in_progress` with TaskUpdate and execute the following.

### 4a. Browser Testing

Use the Claude MCP browser tools for all browser interaction:

| Action | Tool |
|---|---|
| Navigate to page | `mcp__claude-in-chrome__navigate` |
| Find interactive elements | `mcp__claude-in-chrome__find` |
| Click element | `mcp__claude-in-chrome__browser_batch` with click action |
| Fill form field | `mcp__claude-in-chrome__form_input` |
| Take screenshot | `mcp__claude-in-chrome__computer` (screenshot action) — save description of what you see |
| Wait for page to settle | `mcp__claude-in-chrome__read_page` |
| Check console errors | `mcp__claude-in-chrome__read_console_messages` with pattern for errors |
| Get page text | `mcp__claude-in-chrome__get_page_text` |
| Set viewport | `mcp__claude-in-chrome__resize_window` |

For each step in a user journey:

1. Use `mcp__claude-in-chrome__find` to locate current interactive elements
2. Perform the interaction via the appropriate MCP tool
3. Wait for the page to settle using `mcp__claude-in-chrome__read_page`
4. **Take a screenshot** using `mcp__claude-in-chrome__computer` — record a description of what you see, organized by journey (e.g., "profile-creation step 3: form submitted successfully, showing confirmation banner")
5. **Analyze the screenshot** — check for visual correctness, UX issues, broken layouts, missing content, error states
6. Check `mcp__claude-in-chrome__read_console_messages` periodically for JavaScript errors

Be thorough. Go through EVERY interaction, EVERY form field, EVERY button. The goal is that by the time this finishes, every part of the UI has been exercised.

### 4b. Database Validation

After any interaction that should modify data (form submits, deletions, updates):

1. Query the database to verify records. Use the environment variable from Sub-agent 2's research for the connection string and the schema docs to know what to check.
   - **Postgres:** use `psql` directly — e.g., `psql "$DATABASE_URL" -c "SELECT theme FROM profiles WHERE username = 'testuser'"`
   - **SQLite:** use `sqlite3` directly — e.g., `sqlite3 db.sqlite "SELECT theme FROM profiles WHERE username = 'testuser'"`
   - **Other databases:** write a small ad hoc script in the application's language, run it, then delete it
2. Verify:
   - Records created/updated/deleted as expected
   - Values match what was entered in the UI
   - Relationships between records are correct
   - No orphaned or duplicate records

### 4c. Issue Handling

When an issue is found (UI bug, database mismatch, JS error):

1. **Document it:** what was expected vs what happened, screenshot description, relevant DB query results
2. **Fix the code** — make the correction directly
3. **Re-run the failing step** to verify the fix worked
4. **Take a new screenshot** confirming the fix

### 4d. Responsive Testing

For the responsive testing task, revisit key pages at these viewports using `mcp__claude-in-chrome__resize_window`:

- **Mobile:** width 375, height 812
- **Tablet:** width 768, height 1024
- **Desktop:** width 1440, height 900

At each viewport, screenshot every major page. Analyze for layout issues, overflow, broken alignment, and touch target sizes on mobile.

After completing each journey, mark its task as `completed` with TaskUpdate.

## Phase 5: Cleanup

After all testing is complete:
1. Stop the dev server background process
2. Close the browser tab using `mcp__claude-in-chrome__tabs_close_mcp`

## Phase 6: Report

### Text Summary (always output)

Present a concise summary:

```
## E2E Testing Complete

**Journeys Tested:** [count]
**Screenshots Captured:** [count]
**Issues Found:** [count] ([count] fixed, [count] remaining)

### Issues Fixed During Testing
- [Description] — [file:line]

### Remaining Issues
- [Description] — [severity: high/medium/low] — [file:line]

### Bug Hunt Findings (from code analysis)
- [Description] — [severity] — [file:line]
```

### Markdown Export (ask first)

After the text summary, ask the user:

> "Would you like me to export the full testing report to a markdown file? It includes per-journey breakdowns, screenshot descriptions, database validation results, and detailed findings — useful as context for follow-up fixes or GitHub issues."

If yes, write a detailed report to `e2e-test-report.md` in the project root containing:
- Full summary with stats
- Per-journey breakdown: steps taken, screenshot descriptions, database checks, issues found
- All issues with full details, fix status, and file references
- Bug hunt findings from the code analysis sub-agent
- Recommendations for any unresolved issues
