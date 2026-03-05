---
description: "Plan a new project from scratch: gather requirements, generate PRD, create Linear tasks"
---

# Plan Project: From Idea to Linear Tasks

## Overview

This command guides you through planning any software project -- from a simple Python script to a full-stack platform. A conversational interview captures requirements, a comprehensive PRD is generated, then all tasks are created in Linear with correct priorities, sort order, and dependencies. Issue creation uses an embedded Python script to guarantee reliable JSON escaping and no shell quoting failures.

---

## Phase 1: Discovery Interview

Use conversational questions for each topic below. Ask ONE question at a time, wait for the answer, confirm what you understood, then continue. Adapt depth based on project type -- skip irrelevant rounds entirely.

**IMPORTANT**: Never ask all questions at once. Never skip confirming your understanding after each answer. After every answer, summarize in one sentence what you heard before moving on.

### Round 1: The Big Picture

**Q1 - What are we building?**

Ask: "Tell me about your project in a few sentences. What does it do and who is it for?"

Based on the answer, classify the project as one of:
- **Script/CLI** - Automation or command-line tool
- **API/Backend** - REST/GraphQL service, data processing pipeline
- **Web App** - Full-stack application with browser UI
- **Mobile App** - iOS, Android, or cross-platform
- **Library/Package** - Reusable code published for other developers
- **Full Platform** - Multi-feature product with auth, payments, teams, etc.

Tell the user the type you detected and confirm before proceeding.

**Q2 - What problem does this solve?**

Ask: "What's the main pain point this solves? Why would someone use this instead of what already exists?"

**Q3 - Who are the users?**

Ask: "Describe your ideal user. Are they technical or non-technical? Individual or part of a team? What's their skill level with this kind of tool?"

### Round 2: Scope and Features

**Q4 - Core features for v1:**

Ask: "List the 3-5 most important things this needs to do on day one. What's the bare minimum for it to be genuinely useful?"

**Q5 - What is NOT in v1:**

Ask: "What features are tempting but should wait for later? Anything you've thought about but want to keep out of the first version?"

### Round 3: Technical Preferences

**Q6 - Tech stack:**

Ask: "Do you have a preferred tech stack, or should I recommend one based on your project type?"

If they have no preference, recommend based on project type and the defaults in CLAUDE.md. Present a short, clear recommendation:
- "For a web app like this, I'd suggest Next.js with TypeScript and PostgreSQL. Does that work, or do you have a different preference?"

**Q7 - Starting fresh or existing code?**

Ask: "Are we starting from scratch or building on top of something that already exists?"

### Round 4: Design and UX (ONLY for projects with a user interface)

Skip this entire round for scripts, CLIs, backend APIs without UI, and libraries.

**Q8 - Design direction:**

Ask: "What vibe are you going for? Pick any that apply: clean/minimal, bold/colorful, dark mode, corporate/professional, playful/fun, developer-focused. Or share a site you admire."

**Q9 - Key pages or screens:**

Ask: "Walk me through the main screens. What does a user see first? Where do they go next? What is the most important page or view?"

### Round 5: Infrastructure and Integrations

**Q10 - Authentication:** (skip for scripts and libraries)

Ask: "Do users need accounts? If so, how do they sign in -- email/password, Google, GitHub, magic link?"

**Q11 - Payments:** (only ask if the project suggests paid features)

Ask: "Will this have paid features or subscriptions? What is free vs paid?"

**Q12 - Third-party services:**

Ask: "Does this need to connect to any external services? Email, AI APIs, payment processors, analytics, file storage, etc.?"

**Q13 - Deployment target:**

Ask: "Where should this run? Vercel, Fly.io, AWS, a VPS, or local only?"

### Round 6: Quality and Process

**Q14 - Testing expectations:**

Ask: "How thorough should testing be? Options: basic (smoke tests only), standard (unit + integration), comprehensive (full coverage with E2E tests)."

**Q15 - Anything else?**

Ask: "Anything I missed? Any hard constraints, strong opinions, or requirements that haven't come up?"

---

## Phase 2: PRD Generation

After the interview, write a comprehensive PRD to `.claude/prds/{project-slug}-prd.md`.

Adapt section depth to what is relevant for this project type. Every PRD must include:

1. **Executive Summary** - What it is, why it exists, who it serves (2-3 paragraphs)
2. **Mission** - Core purpose and 3-5 guiding principles
3. **Target Users** - Personas from Q3 answers, pain points, skill level
4. **MVP Scope** - Checklist: use `- [x]` for in-scope, `- [ ]` for deferred
5. **User Stories** - 5-8 stories in "As a [user], I want to [action], so that [benefit]" format
6. **Core Architecture** - Directory structure, data flow, key patterns
7. **Feature Specifications** - Detailed spec for each feature discussed
8. **Technology Stack** - Specific libraries and versions
9. **Security and Configuration** - Auth approach, env vars, rate limiting
10. **API Specification** - If applicable: endpoints, request/response shapes
11. **Database Schema** - If applicable: full schema with ORM notation
12. **Success Criteria** - Measurable outcomes
13. **Implementation Phases** - 3-4 ordered phases with deliverables
14. **Risks and Mitigations** - 3-5 key risks

For UI projects, also include:
- Design system: colors, typography, spacing derived from Q8-Q9
- Page/screen specifications from Q9
- Interaction and animation notes

Present a summary and ask: "Does this capture everything accurately? Anything to add or change before I create the Linear tasks?"

Wait for explicit confirmation before proceeding.

---

## Phase 3: Task Breakdown

Break the PRD into discrete, implementable tasks. Rules:

1. **Each task = 2-4 hours of AI implementation time**
2. **Dependencies are explicit** -- each task lists which task indices it depends on (0-based)
3. **Tasks are self-contained** -- enough context to implement without questions
4. **Tests are built into every task description**
5. **Tasks are ordered by execution sequence** -- earlier tasks unblock later ones

Group tasks into epics (logical feature areas).

### Priority Assignment Rules

Assign a priority to every task based on the implementation phase:

| Phase | Priority Label | Priority Value | Meaning |
|-------|---------------|----------------|---------|
| Phase 1 - Foundation / Setup | Urgent | 1 | Must complete first; blocks everything else |
| Phase 2 - Core Features | High | 2 | Primary user value delivery |
| Phase 3 - Secondary Features | Medium | 3 | Important but not blocking launch |
| Phase 4 - Polish and Launch | Low | 4 | Final touches and refinements |

Within each phase, tasks that block the most other tasks get the higher priority value (lower number = higher urgency).

### Sort Order Rules

```
sortOrder = task_execution_index * 100
```

The `*100` multiplier leaves space to insert tasks between existing ones later. Task 0 gets sortOrder 0, task 1 gets 100, task 2 gets 200, etc.

### Task Format for Review

Present each task in this format before creating them in Linear:

```
[0] Setup: Initialize repository and tooling (Phase 1 | Urgent | 1pt | sortOrder: 0)
    Deps: none
    Tests: Verify all scripts run without errors

[1] Database: Create schema and migrations (Phase 1 | Urgent | 2pt | sortOrder: 100)
    Deps: [0]
    Tests: Migration runs cleanly, rollback works

[2] Auth: Implement sign-up and sign-in (Phase 2 | High | 3pt | sortOrder: 200)
    Deps: [0], [1]
    Tests: Unit tests for token generation, E2E tests for login flow
```

Estimate mapping: 2h = 1pt, 3h = 2pt, 4h = 3pt.

Ask: "Here are the {N} tasks I will create in Linear. Want to review or adjust anything before I create them?" Wait for confirmation.

---

## Phase 4: Linear Integration

### Step 1: Get API Key from Keychain

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
```

If the key is not found, tell the user exactly:

> "No Linear API key found in your keychain. Add one with:
> `security add-generic-password -s 'linear-api-key' -a '$(whoami)' -w 'YOUR_LINEAR_API_KEY'`
> Then run this command again."

Stop here if no key is found.

### Step 2: Fetch and Select Team

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ teams { nodes { id name key } } }"}'
```

Present the team list and ask: "Which team should these tasks go under?"

### Step 3: Fetch Projects, Labels, and States

Using the selected team ID:

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_ID\") { projects { nodes { id name } } labels { nodes { id name } } states { nodes { id name type } } } }"}'
```

Present the project list and ask: "Which project should these tasks be added to?"

Identify the "Backlog" state (type: `backlog`) -- this is the default state for new issues.

Check if an "ai" label exists in the response. If it does not exist, create it:

```bash
LINEAR_API_KEY=$(security find-generic-password -s "linear-api-key" -a "$(whoami)" -w 2>/dev/null)
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueLabelCreate(input: { teamId: \"TEAM_ID\", name: \"ai\", color: \"#6366f1\" }) { success issueLabel { id name } } }"}'
```

Record the "ai" label ID for use in issue creation.

### Step 4: Create Issues Using Python

**CRITICAL**: Do not use bash or curl to create issues. The task descriptions contain multi-line text, special characters, and code blocks that will break shell quoting and JSON embedding. Use Python instead.

#### Step 4a: Write the task data to a JSON file

Build the complete tasks array from Phase 3 and write it to `/tmp/linear-tasks.json`. The structure must be:

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

Write every task from Phase 3 into this array. Include the full description in each task -- not a summary. The `deps` field is a list of 0-based indices into the tasks array.

#### Step 4b: Write the Python script

Write this exact script to `/tmp/create-linear-issues.py`:

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
    # Use json.dumps to guarantee safe escaping of title and description
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
        time.sleep(0.3)  # Respect Linear rate limits

    # Set dependency relationships after all issues exist
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

    # Write results for the calling agent to read
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

#### Step 4c: Execute the script

```bash
python3 /tmp/create-linear-issues.py
```

#### Step 4d: Read results

```bash
cat /tmp/linear-issues-result.json
```

If any issues failed, report which tasks failed and why (from stderr output). Offer to retry failed tasks.

### Step 5: Commit the PRD

If the current directory is a git repository, commit the PRD file:

```bash
git add .claude/prds/
git commit -m "docs: add PRD for {project-name}"
```

If not a git repo, skip this step silently.

---

## Phase 5: Summary

After all issues are created, present a clear summary:

```
Project planned.

PRD: .claude/prds/{project-slug}-prd.md
Linear: {N} issues created in {Team} / {Project}

Epics:
  - {Epic 1}: {N} issues
  - {Epic 2}: {N} issues
  ...

Execution order:
  Batch 1 (can run in parallel): {issue identifiers}
  Batch 2 (after Batch 1): {issue identifiers}
  Batch 3 (after Batch 2): {issue identifiers}
  ...

Next steps:
  - Review issues in Linear: https://linear.app
  - Set the first task to "Queued" to hand it to the AI runner
  - Or run /issue-prd {FIRST-ISSUE-ID} to generate a detailed implementation PRD
```

Batches are groups of tasks with no mutual dependencies that can run simultaneously. Show which identifiers belong to each batch to make parallelization obvious.

---

## Adaptive Behavior

Adjust interview depth and task count to project scope:

| Project Type | Interview Rounds | Typical Task Count | PRD Depth |
|---|---|---|---|
| Script / CLI | 1, 2, 3, 6 only | 5-10 | Minimal |
| API / Backend | 1, 2, 3, 5, 6 | 10-20 | Standard |
| Web App | All rounds | 15-25 | Full |
| Full Platform | All rounds + follow-ups | 25-45 | Comprehensive |

- Do not ask about color schemes for a CLI tool.
- Do not skip auth questions for a platform.
- Do not ask about deployment for a library.
- If the user does not know an answer, make a concrete recommendation and confirm it.

---

## Notes

- The Linear API key MUST come from the macOS keychain at runtime -- never hardcoded, never from env vars
- Python handles all JSON escaping via `json.dumps` -- do not attempt to escape descriptions manually
- `sortOrder` places tasks in execution sequence in Linear's UI -- always set it
- `priority` is set on every issue -- never leave it as the Linear default
- `deps` indices in the JSON are 0-based and refer to position in the `tasks` array
- The PRD is the source of truth -- tasks are derived from it, not the other way around
- This command never writes application code, only planning documents and Linear issues
- If Linear API calls fail due to rate limits, add `time.sleep(1)` between batches in the Python script
