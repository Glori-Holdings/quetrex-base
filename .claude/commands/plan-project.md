---
description: "Plan a new greenfield project: gather requirements, generate PRD, create a Linear project and all tasks with dependencies"
---

# Plan Project: From Idea to Linear

## Overview

This command guides you through planning any new software project. A conversational interview captures requirements, a comprehensive PRD is generated, a new Linear project is created, then all tasks are created with correct priorities, sort order, and dependencies. Issue creation uses Python to guarantee reliable JSON escaping.

---

## Phase 1: Discovery Interview

Ask ONE question at a time. After every answer, confirm what you heard in one sentence before moving on. Never ask all questions at once. Adapt depth to project type — skip irrelevant rounds entirely.

### Round 1: The Big Picture

**Q1** — "Tell me about your project in a few sentences. What does it do and who is it for?"

Classify as: Script/CLI · API/Backend · Web App · Mobile App · Library/Package · Full Platform. Tell the user which type you detected and confirm before continuing.

**Q2** — "What's the main pain point this solves? Why would someone use this instead of what already exists?"

**Q3** — "Describe your ideal user. Technical or non-technical? Individual or team? What's their experience level?"

### Round 2: Scope and Features

**Q4** — "List the 3-5 most important things this needs to do on day one. What's the bare minimum to be genuinely useful?"

**Q5** — "What features are tempting but should wait for later? What's explicitly out of v1?"

### Round 3: Technical Preferences

**Q6** — "Do you have a preferred tech stack, or should I recommend one based on your project type?"

If no preference: recommend based on project type and CLAUDE.md defaults. Present a short recommendation and confirm. Example: "For a web app like this, I'd suggest Next.js with TypeScript and PostgreSQL. Does that work?"

**Q7** — "Are we starting from scratch, or building on top of something that exists?"

### Round 4: Design and UX (UI projects only — skip for CLI/API/Library)

**Q8** — "What vibe are you going for? Clean/minimal, bold/colorful, dark mode, corporate, playful, developer-focused? Or share a site you admire."

**Q9** — "Walk me through the main screens. What does a user see first? Where do they go next? What's the most important view?"

### Round 5: Infrastructure and Integrations

**Q10** — "Do users need accounts? If so, how do they sign in — email/password, Google, GitHub, magic link?" (skip for scripts and libraries)

**Q11** — "Will this have paid features or subscriptions? What's free vs paid?" (only if the project suggests monetization)

**Q12** — "Does this connect to any external services? Email, AI APIs, payments, analytics, file storage?"

**Q13** — "Where should this run? Vercel, Fly.io, AWS, a VPS, or local only?"

### Round 6: Quality and Process

**Q14** — "How thorough should testing be? Basic (smoke tests only), standard (unit + integration), or comprehensive (full coverage with E2E)?"

**Q15** — "Anything I missed? Hard constraints, strong opinions, or requirements that haven't come up?"

---

## Phase 2: PRD Generation

Write a comprehensive PRD to `.claude/prds/{project-slug}-prd.md`. Adapt section depth to project type.

Every PRD must include:

1. **Executive Summary** — What it is, why it exists, who it serves (2-3 paragraphs)
2. **Mission** — Core purpose and 3-5 guiding principles
3. **Target Users** — Personas, pain points, skill level
4. **MVP Scope** — Checklist: `- [x]` in scope, `- [ ]` deferred
5. **User Stories** — 5-8 stories: "As a [user], I want to [action], so that [benefit]"
6. **Core Architecture** — Directory structure, data flow, key patterns
7. **Feature Specifications** — Detailed spec per feature
8. **Technology Stack** — Specific libraries and versions
9. **Security and Configuration** — Auth approach, env vars, rate limiting
10. **API Specification** — Endpoints, request/response shapes (if applicable)
11. **Database Schema** — Full schema with ORM notation (if applicable)
12. **Success Criteria** — Measurable outcomes
13. **Implementation Phases** — 3-4 ordered phases with deliverables
14. **Risks and Mitigations** — 3-5 key risks

For UI projects, also include: design system (colors, typography, spacing), page specifications, interaction and animation notes.

Present a summary and ask: "Does this capture everything accurately? Anything to add or change before I create the Linear tasks?" Wait for explicit confirmation.

---

## Phase 3: Task Breakdown

Break the PRD into discrete, implementable tasks.

**Rules:**
- Each task = 2-4 hours of AI implementation time
- Dependencies are explicit — each task lists which indices it blocks on (0-based)
- Tasks are self-contained — enough context to implement without follow-up questions
- Tests are specified in every task description
- Tasks are ordered by execution sequence — earlier tasks unblock later ones

**Priority assignment:**

| Phase | Priority Label | Value |
|---|---|---|
| Phase 1 — Foundation / Setup | Urgent | 1 |
| Phase 2 — Core Features | High | 2 |
| Phase 3 — Secondary Features | Medium | 3 |
| Phase 4 — Polish and Launch | Low | 4 |

Within each phase: tasks that block the most others get higher priority (lower number).

**Sort order:** `sortOrder = task_execution_index * 100`

**Task format for review:**

```
[0] Setup: Initialize repository and tooling (Phase 1 | Urgent | 1pt | sortOrder: 0)
    Deps: none
    Tests: All scripts run without errors

[1] Database: Create schema and migrations (Phase 1 | Urgent | 2pt | sortOrder: 100)
    Deps: [0]
    Tests: Migration runs cleanly, rollback works

[2] Auth: Implement sign-up and sign-in (Phase 2 | High | 3pt | sortOrder: 200)
    Deps: [0], [1]
    Tests: Unit tests for token generation, E2E for login flow
```

Estimate mapping: 2h = 1pt, 3h = 2pt, 4h = 3pt.

Ask: "Here are the {N} tasks I will create in Linear. Want to review or adjust anything before I create them?" Wait for confirmation.

---

## Phase 4: Linear Integration

### Step 1: Verify API Key

```bash
echo "${LINEAR_API_KEY:+set}"
```

If `$LINEAR_API_KEY` is not set, stop and tell the user:
> "LINEAR_API_KEY is not set. Run /quetrex-setup to configure it, or run `/secrets add LINEAR_API_KEY` if you have already run setup."

### Step 2: Fetch and Select Team

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ teams { nodes { id name key } } }"}'
```

Present the team list and ask: "Which team should this project go under?"

### Step 3: Fetch States and Labels, Create the Linear Project

Using the selected team ID, fetch workflow states and labels:

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_ID\") { labels { nodes { id name } } states { nodes { id name type } } } }"}'
```

Identify the Backlog state (type: `backlog`).

Check if an "ai" label exists. If not, create it:

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueLabelCreate(input: { teamId: \"TEAM_ID\", name: \"ai\", color: \"#6366f1\" }) { success issueLabel { id name } } }"}'
```

**Create the new Linear project** for this greenfield work:

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { projectCreate(input: { teamIds: [\"TEAM_ID\"], name: \"PROJECT_NAME\", description: \"PROJECT_DESCRIPTION\", state: planned }) { success project { id name } } }"}'
```

Use the project name from the PRD and a one-sentence description from the Executive Summary. Record the returned project ID.

### Step 4: Create Issues Using Python

**CRITICAL**: Use Python — not bash or curl — to create issues. Task descriptions contain multi-line text, special characters, and code blocks that break shell quoting.

#### Step 4a: Write task data to `/tmp/linear-tasks.json`

```json
{
  "teamId": "TEAM_UUID",
  "projectId": "PROJECT_UUID",
  "stateId": "BACKLOG_STATE_UUID",
  "labelIds": ["AI_LABEL_UUID"],
  "tasks": [
    {
      "title": "Setup: Initialize repository and tooling",
      "description": "Full task description with all context, subtasks, and test requirements.\n\n## Subtasks\n- [ ] ...\n\n## Tests\n- ...",
      "estimate": 1,
      "priority": 1,
      "sortOrder": 0,
      "deps": []
    },
    {
      "title": "Database: Create schema and migrations",
      "description": "...",
      "estimate": 2,
      "priority": 1,
      "sortOrder": 100,
      "deps": [0]
    }
  ]
}
```

Write every task from Phase 3 into this array with full descriptions — not summaries.

#### Step 4b: Write the Python script to `/tmp/create-linear-issues.py`

```python
#!/usr/bin/env python3
"""Create Linear issues from a task JSON file."""
import json
import subprocess
import urllib.request
import sys
import time


def get_api_key():
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s", "linear-api-key",
            "-a", subprocess.check_output(["whoami"]).decode().strip(),
            "-w",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print("ERROR: No Linear API key found in keychain", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def gql(api_key, query):
    data = json.dumps({"query": query}).encode()
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=data,
        headers={
            "Authorization": api_key,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def create_issue(api_key, team_id, project_id, state_id, label_ids, task):
    title = json.dumps(task["title"])[1:-1]
    desc = json.dumps(task["description"])[1:-1]
    labels_str = ", ".join(f'"{lid}"' for lid in label_ids)

    query = f'''mutation {{
      issueCreate(input: {{
        teamId: "{team_id}",
        projectId: "{project_id}",
        title: "{title}",
        description: "{desc}",
        estimate: {task["estimate"]},
        priority: {task["priority"]},
        sortOrder: {task["sortOrder"]},
        stateId: "{state_id}",
        labelIds: [{labels_str}]
      }}) {{
        success
        issue {{
          id
          identifier
        }}
      }}
    }}'''

    result = gql(api_key, query)
    issue_data = result.get("data", {}).get("issueCreate", {})
    if issue_data.get("success"):
        issue = issue_data["issue"]
        return {"id": issue["id"], "identifier": issue["identifier"]}
    else:
        print(
            f"FAILED: {task['title'][:60]} - {json.dumps(result)[:300]}",
            file=sys.stderr,
        )
        return None


def create_dependency(api_key, blocked_id, blocker_id):
    query = f'''mutation {{
      issueRelationCreate(input: {{
        issueId: "{blocked_id}",
        relatedIssueId: "{blocker_id}",
        type: blocks
      }}) {{
        success
      }}
    }}'''
    gql(api_key, query)


def main():
    with open("/tmp/linear-tasks.json") as f:
        config = json.load(f)

    api_key = get_api_key()
    team_id = config["teamId"]
    project_id = config["projectId"]
    state_id = config["stateId"]
    label_ids = config["labelIds"]
    tasks = config["tasks"]

    print(f"Creating {len(tasks)} issues...")
    created = []

    for i, task in enumerate(tasks):
        result = create_issue(api_key, team_id, project_id, state_id, label_ids, task)
        if result:
            created.append(result)
            print(f"  [{i}] Created: {result['identifier']} - {task['title'][:60]}")
        else:
            created.append(None)
        time.sleep(0.3)

    print("\nSetting dependencies...")
    dep_count = 0
    for i, task in enumerate(tasks):
        if not created[i]:
            continue
        for dep_idx in task.get("deps", []):
            if dep_idx < len(created) and created[dep_idx]:
                create_dependency(api_key, created[i]["id"], created[dep_idx]["id"])
                print(
                    f"  {created[i]['identifier']} blocked by {created[dep_idx]['identifier']}"
                )
                dep_count += 1
                time.sleep(0.2)

    if dep_count == 0:
        print("  No dependencies to set.")

    output = {
        "issues": [c for c in created if c],
        "total": len([c for c in created if c]),
        "failed": len([c for c in created if c is None]),
    }
    with open("/tmp/linear-issues-result.json", "w") as f:
        json.dump(output, f, indent=2)

    print(f"\nDone. Created {output['total']} issues, {output['failed']} failed.")


if __name__ == "__main__":
    main()
```

#### Step 4c: Execute

```bash
python3 /tmp/create-linear-issues.py
cat /tmp/linear-issues-result.json
```

If any issues failed, report which tasks failed and offer to retry.

### Step 5: Commit the PRD

```bash
git add .claude/prds/
git commit -m "docs: add PRD for {project-name}"
```

Skip silently if not in a git repository.

---

## Phase 5: Summary

```
Project planned.

PRD:    .claude/prds/{project-slug}-prd.md
Linear: {N} issues created in {Team} / {Project Name}

Epics:
  - {Epic 1}: {N} issues
  - {Epic 2}: {N} issues

Parallel execution batches:
  Batch 1 (start here, no dependencies): {identifiers}
  Batch 2 (after Batch 1 completes):     {identifiers}
  Batch 3 (after Batch 2 completes):     {identifiers}

To start implementation:
  Run /issue-prd {FIRST-ISSUE-IDENTIFIER} to work the first issue through the full pipeline.
  Work issues in batch order. Issues within the same batch can run in parallel.
```

Show batches as groups of tasks with no mutual dependencies. This tells you exactly which issues can be worked simultaneously and which must wait.

---

## Adaptive Behavior

| Project Type | Interview Rounds | Typical Task Count | PRD Depth |
|---|---|---|---|
| Script / CLI | 1, 2, 3, 6 only | 5-10 | Minimal |
| API / Backend | 1, 2, 3, 5, 6 | 10-20 | Standard |
| Web App | All rounds | 15-25 | Full |
| Full Platform | All rounds + follow-ups | 25-45 | Comprehensive |

- Do not ask about color schemes for a CLI tool
- Do not skip auth questions for a platform
- Do not ask about deployment for a library
- If the user does not know an answer, make a concrete recommendation and confirm it

---

## Notes

- Linear API key must come from macOS keychain — never hardcoded, never from env vars
- Python handles all JSON escaping via `json.dumps` — never escape descriptions manually
- `sortOrder` places tasks in execution sequence in Linear's UI — always set it
- `priority` is set on every issue — never leave it as the Linear default
- `deps` indices are 0-based and refer to position in the `tasks` array
- The PRD is the source of truth — tasks are derived from it, not the other way around
- This command never writes application code, only planning documents and Linear issues
- If Linear API calls fail due to rate limits, increase `time.sleep()` delays in the Python script
