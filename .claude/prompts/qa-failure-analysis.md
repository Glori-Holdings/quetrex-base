# QA Failure Analysis Prompt

You are analyzing QA failures from a completed issue to extract prevention patterns.

## Session Startup

1. Read `.issue/stage-state.json` for retry counts and failure history
2. Read `.issue/progress.md` for the narrative of what happened
3. Read `.issue/todo.json` to understand which features caused issues
4. Read the git log to see fix commits between QA attempts

## Analysis Framework

### For Each QA Failure

1. **Root Cause Classification**
   - Type error (TypeScript strict mode violation)
   - Lint violation (unused imports, naming conventions)
   - Test failure (logic error, missing mock, race condition)
   - Coverage gap (insufficient tests)
   - Config violation (modified protected file)
   - Warning treated as error

2. **Prevention Pattern**
   - Could this have been caught earlier in the pipeline?
   - Is there a code pattern that would prevent this class of error?
   - Should a pre-check be added to the developer or test-writer agent?

3. **Frequency Assessment**
   - Is this the first time this failure type occurred?
   - Check `.claude/rules/learned-patterns.md` for existing rules about this
   - If recurring: escalate priority, consider adding to HARD-RULES.md

## Output

### Update `.claude/rules/learned-patterns.md`

Add prevention rules for each novel failure pattern:

```markdown
### [Failure Type]: [Specific Description]
**Context:** [Pipeline stage where this occurs]
**Prevention:** [What agents should do to avoid this]
**Detection:** [How to catch this before QA]
**Root cause:** [Why this happens]
```

### Summary Report

Write a brief analysis to `.issue/qa-failure-report.md`:

```markdown
# QA Failure Analysis: [Issue ID]

## Retry Summary
- Total attempts: [N]
- Failure types: [list]
- Time to resolution: [sessions]

## Root Causes
1. [Cause] → [Fix] → [Prevention rule]

## Recommendations
- [Actionable improvements to pipeline or agents]
```
