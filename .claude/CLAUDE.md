# quetrex-base

This repo IS the Quetrex engine — the hooks, agents, commands and installer that other repos run. Work here edits enforcement machinery, not application code.

- Hook scripts live in `.claude/hooks/`, agent contracts in `.claude/agents/`, slash commands in `.claude/commands/`, shared shell in `.claude/lib/`.
- A committed hook command must resolve from a fresh clone: write `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/<name>.sh"`, NEVER `~/.claude/...` — a cloud routine only ever sees what is committed.
- **A change to a hook's blocking behavior ships in the same commit as a test under `test/` that proves both the new block and the new allow.**
- Adding, removing or re-wiring a hook means updating the hook table in `SECURITY.md` in the same change — that table is a customer-facing contract, not documentation.
- Generic pipeline doctrine (agent roles, branch rules, permission model) lives in `.claude/quetrex-doctrine.md`, which ships to every machine. Keep this file to what is true of THIS repo only.

# LESSONS

- Customer-facing explainers must show the real machinery (agents' specializations, the architect's PRD-decomposition that kills drift/hallucination, hooks, skills, exact commands), grounded in the actual source files — never shallow marketing gloss, and structured so the reader never hits a boring paragraph before the substance lands.
- Before explaining or depicting how Quetrex works for the user, re-ground in the CURRENT product model from memory: it is a routine-fired kanban (plan → tap Approve on scope from the phone → automated build → review → auto-merge → manual deploy; needs_human→SMS), where the board is watch-plus-gate-taps. NEVER depict the old "run a terminal command and watch the AI type" model — that is exactly what Quetrex replaces.

## Verification

```
npm run check:js
npm run check:sh
npm run check:json
npm test
```
