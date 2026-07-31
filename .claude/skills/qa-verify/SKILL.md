---
name: qa-verify
description: >
  Prove a change is actually done — run the project's own verify chain, prove no test
  was weakened to make it pass, scan for leaked secrets, and report PASS/FAIL with the
  evidence attached. Use whenever a change is finished, before committing, before
  opening or updating a PR, when asked to "verify my work", "check this", "is this
  done", or "is this ready to ship" — and whenever a rename or removal needs unfiltered
  proof that zero traces of the old term remain. Never call work done without it.
allowed-tools: Bash, Read, Grep, Glob
---

# QA Verify

## Why this skill exists

Agents were marking rename/removal tasks complete while references remained in shell
scripts, config files, and directory names that were invisible to file-type-filtered
searches. This closes that gap by requiring unfiltered, repo-wide output as proof.

It has since grown a second job that matters more: proving **no test was quietly
loosened to turn the chain green**. Running the suite and seeing green is not enough —
a test can be skipped, an assertion deleted, a rule ignored. Done is not "the diff
looks right." **Done is the gates being run and observed, with the results stated.**

## Run it

The script does every mechanical check and hardcodes no stack — it resolves the chain
from `.quetrex/verify.json`, else `.claude/CLAUDE.md` `## Verification`, else the
manifest, so it runs the right commands in a Node, Python, Rust or Go repo alike.

```bash
SKILL_DIR="$(dirname "$(ls -1 "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/qa-verify/SKILL.md" \
  "${CLAUDE_PROJECT_DIR:-.}/.claude/skills/qa-verify/SKILL.md" \
  "$HOME/.claude/skills/qa-verify/SKILL.md" 2>/dev/null | head -1)")"

bash "$SKILL_DIR/scripts/qa-verify.sh"                       # standard
bash "$SKILL_DIR/scripts/qa-verify.sh" --term OLDNAME        # + rename/removal proof
bash "$SKILL_DIR/scripts/qa-verify.sh" --base origin/develop # non-default base
```

## Read its output

- Exit `0` = clean · `1` = a check FAILed, the task is not done · `2` = it could not run
  (no git repo, or no verify chain declared anywhere). **Never read `2` as a pass.**
- `FAIL` blocks. `WARN` does not block but must be repeated in your report.
- **`NOT VERIFIED` is the most important block** — copy it verbatim. Stating what you did
  *not* check is part of the result.
- Paste the raw summary into the PR body; do not paraphrase. Zero-result output is proof.

## Failure protocol

1. Fix it — never by weakening the check — then re-run the script from the top.
2. A genuinely pre-existing or intended FAIL: annotate the offending line with
   `qa-verify: allow <reason>` (the script honours it) **and** say so in the PR body.
   An unexplained annotation is itself a defect.
3. Exit `2` is a **setup** failure. Report it; never self-heal by inventing commands.

Per-check rationale and the annotation contract: [reference.md](reference.md).
