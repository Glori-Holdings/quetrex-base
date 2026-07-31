# CLAUDE.md

This is YOUR file. Quetrex seeds it once, when it is absent, and never touches it
again — not on upgrade, not on reinstall. Everything below is yours to edit.

The line under it imports the Quetrex operating doctrine (agent roles, branch
rules, permission model, the pipeline). That file IS replaced on every upgrade,
which is exactly why the doctrine lives there and your notes live here.

@quetrex-doctrine.md

## Where things belong

- **Here** — how you personally want Claude to work across every project.
- **`<repo>/.claude/CLAUDE.md`** — what is true of one repository: its stack, its
  verification commands, its conventions.
- **`<repo>/.claude/CLAUDE.local.md`** — machine- or company-specific details you
  must not commit: deploy tokens, account names, local paths. Git-ignored.

## Verification

Project verification commands belong in the project's own `.claude/CLAUDE.md`,
under its own `## Verification` heading, or in that repo's `.quetrex/verify.json`.
Do not put them here — they differ per repo, and the gates read them per repo.

# LESSONS

<!-- When you correct Claude, the correction is added here as a one-line rule so
     it does not recur. Keep them short and imperative. -->
