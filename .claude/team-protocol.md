# Agent Team Protocol

## When to use a team
- Work touches 3+ files across layers (UI + API + DB)
- For simpler work, use a single subagent or work directly

## Roles
- **Lead**: Plans, creates tasks, coordinates. Never writes code.
- **Teammates**: Independent Claude instances that claim and complete tasks. They don't inherit the lead's conversation — every teammate's brief must include what to build, the files they own, and relevant patterns.

## Plan
- Each task = a clear deliverable (file, function, or test), small enough to be independently testable
- **File ownership is the #1 rule: no two teammates edit the same file**
- Split work along file boundaries; shared types/interfaces go in a dependency task that completes first
- Declare task dependencies and include acceptance criteria

## Team size
- Start with 3–5 teammates for most workflows

## Coordinate
- Monitor via TaskList
- Send targeted messages — don't broadcast

## Validate
- Each teammate runs the verification chain in `~/.claude/CLAUDE.md` before marking complete
- Tests are part of the task that owns the code (or hand off to a `test-writer` agent in the same task)
- Lead runs the same verification chain before opening the PR
- On failure, send feedback to the responsible teammate
