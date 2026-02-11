# Team Orchestration Protocol

**Version:** 1.0
**Owner:** Glen Barnhardt
**Effective:** 2026-02-10
**Referenced by:** Autonomous pipeline runner, /build-feature skill, CLAUDE.md

This protocol governs how agent teams are created, coordinated, and dissolved.
It is the single source of truth for team orchestration. Both the automated
pipeline runner and interactive terminal skills reference this file.

---

## Phase 1: Planning (Before TeamCreate)

### 1.1 Requirement Analysis

Before creating any agents:
1. Read the issue description, plan, or user request in full
2. Identify every deliverable (files to create, files to modify, tests to write)
3. Map the dependency chain: which deliverables depend on which
4. Determine the layers involved (DB, API, UI, shared types, tests)

### 1.2 File Ownership Map

Assign each file to exactly ONE agent. No two agents write to the same file.

```
File Ownership Map (example):
  developer-1:
    - src/db/schema/users.ts
    - src/db/queries/users.ts
  developer-2:
    - src/app/api/users/route.ts
    - src/components/UserCard.tsx
  tester:
    - src/__tests__/users.test.ts
  NOBODY TOUCHES:
    - tsconfig.json, biome.json, next.config.ts (HARD RULES)
```

Violation: If two agents need the same file, the lead refactors the plan so
each agent owns distinct files, or sequences their work on that file.

### 1.3 Contract Definition

For every boundary between agents, the lead defines exact contracts BEFORE
spawning any agent:

- **TypeScript interfaces** for shared data shapes
- **API request/response types** for route handlers
- **Function signatures** for shared utilities
- **Database table shapes** for schema consumers

```typescript
// Example contract: defined by lead, consumed by developer-1 and developer-2
interface UserRow {
  id: string;
  email: string;
  display_name: string;
  created_at: Date;
}

// API contract
// GET /api/users → { users: UserRow[] }
// POST /api/users → { user: UserRow }
// Request body: { email: string; display_name: string }
```

The lead writes contracts into task descriptions. Agents implement to match.

---

## Phase 2: Staggered Team Creation

Do NOT spawn all agents simultaneously. Spawn in dependency waves.

### 2.1 Wave Order

| Wave | Agents | Purpose | Starts When |
|------|--------|---------|-------------|
| 1 | Foundation developers | Core logic, shared types, DB schema | Immediately |
| 2 | Dependent developers | API routes, UI components consuming Wave 1 | Wave 1 critical path complete |
| 3 | Tester | Writes and runs tests | Implementation complete |
| 4 | Reviewer | Reads all code, quality verdict | Tests pass |

### 2.2 Spawn Prompt Template

Every agent spawn message MUST include:

```
## Your Assignment
[Specific deliverables with acceptance criteria]

## Contracts to Implement
[Exact TypeScript types this agent must export]

## Contracts to Consume
[Exact TypeScript types this agent imports from other agents' work]

## Files You Own (ONLY modify these)
- path/to/file1.ts
- path/to/file2.ts

## Files You Must NOT Touch
- tsconfig.json, biome.json, next.config.ts (HARD RULES)
- [Any files owned by other agents]

## Quality Gate
Run before marking any task complete:
npm run type-check && npm run lint
```

### 2.3 Task Dependencies

Use addBlockedBy and addBlocks when creating tasks:

```
Task 1: "Create user schema" (developer-1)
Task 2: "Create user API route" (developer-2) → addBlockedBy: [Task 1]
Task 3: "Write user tests" (tester) → addBlockedBy: [Task 1, Task 2]
Task 4: "Review all user code" (reviewer) → addBlockedBy: [Task 3]
```

Never create tasks without explicit dependency relationships.

### 2.4 Waiting Between Waves

After spawning Wave N:
1. Monitor TaskList for completion of Wave N critical tasks
2. When a Wave N agent completes, read their output files to verify contract compliance
3. Only spawn Wave N+1 agents after verifying Wave N contracts are correct
4. If a contract is wrong, fix it with the Wave N agent before proceeding

---

## Phase 3: Coordination

### 3.1 Contract Relay

When Agent A completes a contract-producing task:
1. Lead reads the produced file
2. Lead verifies it matches the planned contract (types, exports, signatures)
3. If correct: lead notifies Agent B that their dependency is met
4. If incorrect: lead sends Agent A specific fix instructions, waits for fix

### 3.2 Progress Monitoring

After every teammate message:
1. Run TaskList to see current state
2. Identify newly completed tasks
3. Check if any blocked tasks are now unblocked
4. Notify unblocked agents: "Your dependency [task] is complete. You can proceed."

### 3.3 Issue Resolution

| Issue | Resolution |
|-------|------------|
| Contract mismatch | Lead reads both sides, determines which is wrong, assigns fix to the offending agent |
| Technical blocker | Lead creates a fix task, assigns to the appropriate developer |
| Requirements ambiguity | INTERACTIVE: ask the human. AUTONOMOUS: decide and document the decision in .issue/progress.md |
| Agent stuck or unresponsive | Send another message with clarified instructions. If still stuck after 2 attempts, reassign to another agent |
| Type error in consumed contract | Lead determines source, fixes at the producer, notifies all consumers |

### 3.4 Communication Rules

- Lead NEVER writes code. Lead reads, verifies, coordinates, and delegates.
- Lead sends targeted messages to specific agents (not broadcasts) unless announcing team-wide state changes.
- Agents report completion by updating their tasks and messaging the lead.
- Agents do NOT message each other directly. All coordination flows through the lead.

---

## Phase 4: Validation

### 4.1 Pre-Review Contract Verification

Before spawning the reviewer, the lead MUST:
1. Read every file at a contract boundary (imports/exports between agents' work)
2. Verify that TypeScript interfaces match on both sides
3. Verify that API request/response shapes are consistent
4. Fix any mismatches by assigning correction tasks

### 4.2 Reviewer Gate

The reviewer reads ALL modified files and runs quality checks:

```bash
npm run type-check   # Zero errors, zero warnings
npm run lint         # Zero errors, zero warnings
npm run test         # All tests pass
```

Reviewer sends one of:
- **APPROVED** with a summary of what was reviewed
- **REJECTED** with specific issues (file, line, description, fix suggestion)

### 4.3 Rejection Cycle

On REJECTED:
1. Lead creates fix tasks from the reviewer's specific issues
2. Lead assigns fix tasks to the appropriate developer(s)
3. Developer fixes and re-runs quality gates
4. Lead verifies fixes, then re-assigns to tester if needed
5. Tester confirms tests still pass
6. Back to reviewer for re-review

Maximum 3 rejection cycles. After 3:
- **AUTONOMOUS mode:** Output `OUTCOME:BLOCKED reason="3 reviewer rejections"` and stop
- **INTERACTIVE mode:** Ask the human for guidance

### 4.4 Final Quality Gate

After APPROVED, the lead runs the final gate:

```bash
npm run type-check && npm run lint && npm run test
```

All must pass. If any fail, loop back to the appropriate developer. Do NOT create the PR until the gate passes cleanly.

### 4.5 PR Creation

Only after all quality gates pass:
1. Stage all modified files (specific files, not `git add -A`)
2. Commit with a descriptive message
3. Push the feature branch
4. Create PR with summary of changes, test plan, and files modified
5. PR requires human review before merge (HARD RULE)

---

## Phase 5: Cleanup

### 5.1 Shutdown Sequence

1. Send `shutdown_request` to every teammate
2. Wait for each agent to confirm with `shutdown_response`
3. Verify all tasks are marked completed or explicitly cancelled
4. Verify the worktree has no uncommitted changes (or commit them)

### 5.2 Post-Completion

- Update `.issue/progress.md` with final summary
- Update `.issue/stage-state.json` to reflect completion
- The worktree remains until the human merges or closes the PR

---

## Mode Awareness

Your session prompt declares whether you are in AUTONOMOUS or INTERACTIVE mode.

### AUTONOMOUS Mode

- Skip /agent-surveillance (no browser available)
- Never ask questions -- decide and document every decision in `.issue/progress.md`
- Stop gracefully on hard blockers with machine-readable OUTCOME signal
- Document all decisions with rationale
- Budget-aware: if approaching token limits, commit work-in-progress and update progress files

### INTERACTIVE Mode

- Launch /agent-surveillance before TeamCreate
- Ask clarifying questions when requirements are ambiguous
- Report progress to the user at key milestones (wave completion, review verdict)
- User can intervene at any point to redirect work

---

## OUTCOME Signals (Autonomous Mode)

The pipeline runner parses these machine-readable lines from the lead's final output.
Output exactly one OUTCOME line as the last substantive line before shutdown.

| Signal | Meaning |
|--------|---------|
| `OUTCOME:PR_READY` | PR created successfully, awaiting human review |
| `OUTCOME:BLOCKED reason="<description>"` | Cannot proceed, requires human intervention |
| `OUTCOME:BUDGET_EXCEEDED` | Token or cost budget reached before completion |
| `OUTCOME:TESTS_FAILED` | Tests fail after maximum retry attempts |

---

## Team Sizing Guide

Match team size to task scope. Bigger is not better -- coordination overhead grows with team size.

| Scope | Team Composition |
|-------|-----------------|
| 1-2 files, single layer | 1 developer. Lead runs tests and reviews. Skip separate reviewer. |
| 3-5 files, 2 layers | 2 developers (one per layer), 1 tester, 1 reviewer |
| 6+ files, 3+ layers | 3-4 developers (by layer/domain), 1 tester, 1 reviewer |

Hard cap: maximum 4 implementation agents running simultaneously.

For single-developer teams, the lead acts as reviewer but still follows
the quality gate checklist (type-check, lint, test) before creating the PR.

---

## Anti-Patterns (NEVER Do These)

1. **Spawning all agents at once** before contracts are defined.
   Agents will build to different assumptions. Define contracts first.

2. **Letting two agents write to the same file.**
   This causes merge conflicts and lost work. One file, one owner.

3. **Spawning the reviewer before implementation is complete.**
   The reviewer reviews finished work. Partial reviews waste cycles.

4. **Skipping contract verification before review.**
   If interfaces mismatch, the reviewer will reject. Catch it earlier.

5. **Sending vague task descriptions.**
   "Implement the feature" is not a task. Specify files, types, behavior.

6. **Creating tasks without dependency relationships.**
   Unblocked tasks run immediately. If order matters, use addBlockedBy.

7. **Letting agents modify config files.**
   HARD-RULES.md violation. Protected files are sacred.

8. **Continuing after 3 reviewer rejections without stopping.**
   Something is fundamentally wrong. Stop and analyze (or ask the human).

9. **Committing without running quality gates.**
   `npm run type-check && npm run lint && npm run test` every time.

10. **Asking questions in autonomous mode.**
    Decide, document the decision, continue. Questions block the pipeline.

11. **Lead writing code directly.**
    The lead coordinates. If code needs writing, delegate to a developer.

12. **Agents messaging each other directly.**
    All coordination flows through the lead to prevent confusion.

---

## Quick Reference: Lead Checklist

### Before TeamCreate
- [ ] All deliverables identified
- [ ] File ownership map created (no overlaps)
- [ ] Contracts defined (TypeScript types, API shapes)
- [ ] Tasks created with dependency chains
- [ ] Mode determined (AUTONOMOUS or INTERACTIVE)
- [ ] /agent-surveillance launched (INTERACTIVE only)

### During Execution
- [ ] Waves spawned in order (not all at once)
- [ ] Each wave verified before spawning next
- [ ] Contract relay performed after each completion
- [ ] TaskList checked after every teammate message
- [ ] Blocked agents notified when unblocked

### Before PR
- [ ] All contract boundaries verified (types match)
- [ ] Reviewer sent APPROVED
- [ ] `npm run type-check` passes (zero errors, zero warnings)
- [ ] `npm run lint` passes (zero errors, zero warnings)
- [ ] `npm run test` passes (all tests green)
- [ ] Commit made with descriptive message
- [ ] PR created with summary and test plan

### After PR
- [ ] All agents sent shutdown_request
- [ ] All shutdown_response confirmations received
- [ ] .issue/progress.md updated
- [ ] .issue/stage-state.json updated
- [ ] OUTCOME signal emitted (AUTONOMOUS only)

---

*This protocol is referenced by CLAUDE.md and enforced by team lead agents.
Last updated: 2026-02-10.*
