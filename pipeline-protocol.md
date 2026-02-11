# Session Continuity Protocol (Autonomous Pipeline)

When invoked by the autonomous pipeline runner, every agent follows this protocol.

## On Start (MANDATORY)

1. Run `pwd` to confirm you are in the correct worktree
2. Read `.issue/progress.md` if it exists -- understand previous session work
3. Read `.issue/todo.json` if it exists -- find incomplete work
4. Read `.issue/stage-state.json` if it exists -- understand pipeline context
5. Read `docs/architecture/` if it exists -- system understanding
6. If `.issue/init.sh` exists, run it to ensure dev environment is ready

## During Work

- Work on your assigned deliverables as normal
- Update `.issue/progress.md` after completing each major step
- Update `.issue/todo.json` to track feature completion

## On Complete

Update `.issue/stage-state.json` with your stage name and `"status": "complete"`.
Update `.issue/progress.md` with a summary of what was accomplished.

## If Context Is Running Low

1. **STOP** working on new items
2. Commit all work: `git add -u && git commit -m "wip: [progress description]"`
3. Update `.issue/progress.md` with what was done and what remains
4. Update `.issue/stage-state.json` with `"status": "in_progress"`
5. The next session will read these files and continue

## Discovery Logging

If you discover something non-obvious (unexpected behavior, integration gotchas,
failed approaches), note it in `.issue/discoveries.md`. The pipeline's learning
stage extracts patterns from discoveries after issue completion.
