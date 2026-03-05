---
name: issue-requeue
description: Reset a failed runner issue so it gets picked up again
argument-hint: /issue-requeue SMA-54
disable-model-invocation: true
allowed-tools: Bash, Read, Edit
---

# Requeue a Failed Runner Issue

## Input Validation

Issue identifier: `$ARGUMENTS`

If `$ARGUMENTS` is empty or missing, say: "Usage: `/issue-requeue SMA-{N}` — please provide an issue ID." and STOP.

Parse the identifier. It must match the pattern `SMA-{number}` (e.g., `SMA-54`). If parsing fails, say: "Could not parse issue ID from `$ARGUMENTS`. Expected format: SMA-54" and STOP.

## Step 1: Read Runner State

Read `~/.claude-runner/state.json` using the Read tool.

Find the task entry in `tasks` where `identifier` matches `$ARGUMENTS` (case-insensitive comparison on the identifier).

If **not found**, say: "**$ARGUMENTS** not found in runner state (never attempted or not queued)." and STOP.

Record the task's **UUID** (the key in the `tasks` object) and its current `status`, `attempt`, and the corresponding `failure_counts[UUID]` value.

Display the current state:
- **Issue**: {identifier} — {title}
- **Status**: {status}
- **Attempts**: {attempt}
- **Failure count**: {failure_counts[UUID]}

If `status` is `"pending"` and `failure_counts[UUID]` is `0`, say: "**$ARGUMENTS** is already pending with 0 failures — nothing to reset." and STOP.

## Step 2: Reset the Task in state.json

Use the Edit tool to make these changes in `~/.claude-runner/state.json`:

1. In `failure_counts`, set the value for the task UUID to `0`
2. In the task object:
   - Set `"status"` to `"pending"`
   - Set `"attempt"` to `0`
   - Set `"started_at"` to `""`
   - Set `"completed_at"` to `""`
   - Set `"exit_code"` to `null`
   - Set `"outcome"` to `null`
   - Set `"error"` to `null`
   - Set `"last_failure_summary"` to `""`
   - Set `"next_retry_after"` to `""`
   - Set `"continuation_count"` to `0`

After editing, read the file again to verify the changes took effect.

## Step 3: Verify Linear Status

Check that the issue is in "Queued" status with the "ai" label on Linear, so the runner will actually pick it up.

First, read the LINEAR_API_KEY. Try the environment variable first; if not set, extract it from `.env.local` in the project root:

```bash
grep LINEAR_API_KEY .env.local | cut -d= -f2
```

Store the key for use in the curl call below.

Use the SMA team UUID `55e6dc25-090c-4731-82c2-44549801a709`:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ team(id: \"55e6dc25-090c-4731-82c2-44549801a709\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title state { name id } labels { nodes { name } } } } } }"}'
```

Replace `ISSUE_NUMBER` with the numeric part of the identifier. **IMPORTANT**: Inline the actual API key value directly in the `-H` flag — do NOT rely on shell variable expansion across `&&` chains (the Bash tool does not persist variables).

Check the response:
- If the issue status is **not** "Queued", warn: "**Warning:** $ARGUMENTS is in '{status}' status, not 'Queued'. The runner only picks up 'Queued' issues. You may need to set it to Queued in Linear first."
- If the issue does **not** have the "ai" label, warn: "**Warning:** $ARGUMENTS does not have the 'ai' label. The runner filters by this label and will not pick it up."
- If both are correct, say: "Linear status confirmed: Queued with 'ai' label."

## Step 4: Restart the Runner

The runner loads state into memory at startup and never re-reads state.json. We must restart it:

```bash
launchctl kickstart -k gui/$(id -u)/com.quetrex.claude-runner
```

This kills the current process; launchd's `KeepAlive: true` immediately relaunches it with the fresh state.

If the command fails, report the error and suggest manual restart.

## Step 5: Verify Restart

Wait 5 seconds, then check the runner logs:

```bash
sleep 5 && tail -30 ~/.claude-runner/logs/launchd-stdout.log
```

Look for:
- **Good**: startup messages, poll cycle starting — the runner restarted successfully
- **Bad**: "Skipping $ARGUMENTS" messages — the reset didn't take effect

Report what you see.

## Step 6: Confirm

Report EXACTLY:

> **$ARGUMENTS requeued successfully.**
> - Failure count: reset to 0
> - Task status: pending (was {old_status}, attempt {old_attempt})
> - Runner: restarted — will pick up on next poll (~60s)
> {any Linear warnings from Step 3}

Then STOP.

## Rules

- NEVER modify any task other than the one matching `$ARGUMENTS`
- If state.json is malformed or unreadable, report the error and STOP — do not attempt to reconstruct it
- If the Edit tool can't make a unique match (state.json has repeated patterns), fall back to using Bash with `python3 -c` to do a targeted JSON update
- Always verify the edit by re-reading state.json before restarting the runner
