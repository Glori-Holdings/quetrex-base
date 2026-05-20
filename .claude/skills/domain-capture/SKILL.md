---
name: domain-capture
description: Build a structured business logic knowledge base for a project through codebase analysis and developer interview
argument-hint: <brownfield|greenfield> [path-to-prd-for-greenfield]
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep, Agent, Write, Edit, AskUserQuestion
---

# Domain Knowledge Capture

## Input Validation

Mode: `$ARGUMENTS`

If `$ARGUMENTS` is empty or missing, say: "Usage: `/domain-capture brownfield` or `/domain-capture greenfield path/to/prd.md`" and STOP.

Parse the first word as the mode. It must be either `brownfield` or `greenfield` (case-insensitive).

If mode is `greenfield`, the second argument must be a path to a PRD file. If missing, say: "Greenfield mode requires a PRD path: `/domain-capture greenfield .claude/prds/PROJECT-PRD.md`" and STOP.

If mode is `brownfield`, no additional arguments needed — the current working directory IS the project.

## Step 1: Initialize Knowledge Base

Check if `.claude/knowledge-base/` exists in the current project. If not, create the directory structure:

```bash
mkdir -p .claude/knowledge-base/entities
mkdir -p .claude/knowledge-base/rules
mkdir -p .claude/knowledge-base/workflows
mkdir -p .claude/knowledge-base/vocabulary
mkdir -p .claude/knowledge-base/webhooks
```

If the directory already exists, read the existing files to understand what has already been captured. Report to the user:
- "Resuming knowledge capture. Already documented: {list of existing files}"
- "Starting fresh knowledge capture for {project directory name}"

## Step 2: Codebase Analysis (BROWNFIELD) or PRD Analysis (GREENFIELD)

### If BROWNFIELD:

Launch **three parallel research agents** to map the complete application surface:

**Agent 1: Human Actions**
> Explore this codebase thoroughly to find every human-triggered action in the UI.
> For each action found, document:
> - File path and line number
> - What the user sees (button text, menu item, page name)
> - What function, server action, or API call it triggers
> - What database operations happen as a result
> - Any status changes or count updates
> - Any side effects on other entities
>
> Organize by feature area (e.g., "Pages", "Conversations", "Messaging", "Settings").
> Read the actual handler code — do not just list file names.
> Focus on: onClick handlers, onSubmit handlers, form actions, server actions,
> Link/navigation, router.push, toggles, drag-and-drop, menu selections.

**Agent 2: Automated Triggers**
> Explore this codebase thoroughly to find every non-human trigger.
> For each trigger found, document:
> - File path and line number
> - What external system sends data (Facebook, Twilio, Stripe, etc.)
> - What data comes in (payload structure)
> - What processing and validation happens
> - What database operations occur
> - What side effects happen (notifications, status changes, count updates)
> - What cascading effects touch other entities
>
> Cover: webhook endpoints, cron jobs, event listeners, middleware,
> database triggers, real-time connections (WebSocket, SSE, polling),
> queue workers, automated status transitions.

**Agent 3: Data Model**
> Explore this codebase thoroughly to map the complete data model.
> For each table/entity, document:
> - Table name, file path, all columns with types
> - Primary keys, foreign keys, unique constraints
> - Relations to other tables
> - External ID fields (Facebook IDs, Twilio SIDs, etc.)
> - Status fields and their possible values
> - Count fields that are maintained (pending_count, message_count, etc.)
> - Soft delete patterns
> - Multi-tenancy/scoping patterns (agency, tenant, etc.)
> - Enums and their values
>
> Also find: migration files, seed data, raw SQL queries.

**Wait for all three agents to complete before proceeding.**

Compile the results into a structured summary organized by feature area. This becomes the basis for the interview.

### If GREENFIELD:

Read the PRD file specified in the arguments.

Extract from the PRD:
- All user stories and user types
- All described features and pages
- All mentioned entities and data structures
- All described workflows and flows
- All integrations with external systems
- All described business rules and constraints

Organize these into a feature area list. This becomes the basis for the interview.

## Step 3: Generate Interview Questions

Based on the analysis, generate a structured question set. Questions fall into categories:

### Category A: Entity Behavior
For each entity (table/data structure) found, prepare:
- "When a {entity} is created, what else must happen?"
- "When a {entity} is updated, what cascading effects occur?"
- "When a {entity} is deleted, what cleanup is needed?"
- "Are there any fields on {entity} that must ALWAYS be set a certain way?"
- "Are there any fields that should NEVER be used for lookups?" (like UUID vs external_id)

### Category B: Action Consequences
For each human action or trigger found, prepare:
- "When a user {action}, what EXACTLY should happen? Walk me through every step."
- "Are there any count fields that need updating when this happens?"
- "Are there any status fields on OTHER entities that change?"
- "What should happen if this action fails halfway through? Is it atomic?"

### Category C: Scoping and Tenancy
- "What is the primary scoping/isolation boundary? (agency, tenant, org, user)"
- "Are there any entities that cross scope boundaries?"
- "What field should ALWAYS be used to look up {entity}? What should NEVER be used?"

### Category D: Workflows
For each workflow identified, prepare:
- "Walk me through the complete lifecycle of {workflow} from start to finish"
- "What status transitions are valid? What transitions should NEVER happen?"
- "Can this workflow be reversed or cancelled? What happens to related entities?"

### Category E: Vocabulary
- "Are there any terms in this project that mean something different from their obvious meaning?"
- "Are there any terms the team uses that an outsider wouldn't understand?"

### Category F: Gotchas (CRITICAL)
- "What are the things that have caused bugs before?"
- "What are the rules that seem obvious to you but an AI would get wrong?"
- "Are there any 'always do this' or 'never do that' rules that aren't in the code?"

## Step 4: Conduct Interview

Present the questions to the developer ONE CATEGORY AT A TIME. Do not dump all questions at once.

Start with: "I've analyzed the codebase and have questions organized into {N} categories. Let's start with **Entity Behavior** for {first entity}."

**Interview Rules:**
- Ask one question at a time
- Wait for the full answer before asking the next question
- If an answer reveals a new entity, workflow, or rule you didn't find in the codebase, add follow-up questions
- If the developer says "I don't know" or "I'll get back to you", mark that item as UNKNOWN and move on
- If the developer says "skip this" or "not important", respect that and move on
- If the developer volunteers information beyond what you asked, capture ALL of it
- After each category, summarize what you captured and ask "Did I miss anything in this area?"

**For BROWNFIELD specifically:**
Before each question, share what you found in the code:
"I see that when a user clicks 'Reply', the code calls `handleReply()` in `components/messaging/reply-form.tsx:45` which calls the `sendReply` server action. The server action updates the message table and calls `updateConversationCounts()`. **Is this the complete picture, or does more need to happen?**"

This is critical — showing what you found gives the developer something concrete to correct or confirm, rather than asking them to recall everything from memory.

**For GREENFIELD specifically:**
Walk through each user story from the PRD:
"The PRD says users can 'create a new project'. Walk me through what should happen when they click Create — what entities are created, what defaults are set, what notifications fire, what counts update?"

## Step 5: Write Knowledge Base Files

After each category of the interview is complete (do NOT wait until the end), write the captured knowledge to YAML files.

### Entity Files

For each entity discussed, create `.claude/knowledge-base/entities/{entity-name}.yaml`:

```yaml
entity: page
table: pages
description: "Represents a connected Facebook page managed by an agency"
scoping: "Always scoped to agency. Lookup by external_id (Facebook Page ID), NEVER by UUID."
fields_of_note:
  - field: external_id
    note: "The Facebook Page ID. This is the PRIMARY lookup field. Never use uuid for page lookups."
  - field: pending_count
    note: "Count of unreplied messages across all conversations. Decremented when agent replies."
  - field: status
    values: ["active", "paused", "disconnected"]
    transitions:
      - from: active
        to: paused
        trigger: "User pauses page in settings"
      - from: paused
        to: active
        trigger: "User reactivates page"
relations:
  - target: conversations
    type: one-to-many
    note: "A page has many conversations"
  - target: agency
    type: many-to-one
    note: "A page belongs to one agency"
created: "{today's date}"
last_validated: "{today's date}"
source: "developer interview"
```

### Rule Files

For each business rule captured, create `.claude/knowledge-base/rules/{rule-name}.yaml`:

```yaml
rule: agent_reply_cascade
domain: messaging
trigger: "Agent submits a reply to a conversation"
entities_affected:
  - entity: message
    field: status
    action: "Flag ALL messages where status='pending' in this conversation as 'agent_replied'"
    scope: "All unreplied messages, not just the latest"
  - entity: conversation
    field: message_count
    action: "Set message_count to 0"
  - entity: page
    field: pending_count
    action: "Decrement by exact count of messages flagged"
invariants:
  - "pending_count >= 0 always"
  - "flagged count must equal decrement amount"
  - "atomic — all succeed or none"
why: "Business tracks agent responsiveness at page level"
gotchas:
  - "Must flag ALL unreplied messages, not just the most recent"
  - "The count decrement must match exactly — do not hardcode 1"
created: "{today's date}"
last_validated: "{today's date}"
source: "developer interview"
```

### Workflow Files

For each workflow captured, create `.claude/knowledge-base/workflows/{workflow-name}.yaml`:

```yaml
workflow: inbound_lead
description: "A new lead arrives via Facebook webhook"
trigger: "Facebook sends webhook to /api/webhooks/facebook"
steps:
  - step: 1
    action: "Validate webhook signature"
    entity: null
    note: "Reject if signature invalid"
  - step: 2
    action: "Find or create conversation"
    entity: conversation
    note: "Match by sender ID + page external_id"
  - step: 3
    action: "Create message record"
    entity: message
    note: "Status defaults to 'pending'"
  - step: 4
    action: "Increment conversation.message_count"
    entity: conversation
  - step: 5
    action: "Increment page.pending_count"
    entity: page
    note: "This makes the page show in the agent's queue"
error_handling: "If any step fails after message creation, log error but do NOT lose the message"
created: "{today's date}"
last_validated: "{today's date}"
source: "developer interview"
```

### Webhook Files

For each webhook/trigger captured, create `.claude/knowledge-base/webhooks/{webhook-name}.yaml`:

```yaml
webhook: facebook_message_received
endpoint: "/api/webhooks/facebook"
source: "Facebook Graph API"
payload_key_fields:
  - field: "entry[].messaging[].sender.id"
    maps_to: "conversation.external_sender_id"
  - field: "entry[].messaging[].recipient.id"
    maps_to: "page.external_id"
processing:
  - "Validate X-Hub-Signature-256 header"
  - "Extract message text, attachments, sender ID"
  - "Find page by recipient ID (external_id)"
  - "Find or create conversation"
  - "Create message record"
  - "Update counts"
side_effects:
  - "page.pending_count incremented"
  - "conversation.message_count incremented"
  - "real-time notification sent to assigned agent"
created: "{today's date}"
last_validated: "{today's date}"
source: "developer interview"
```

### Vocabulary Files

Create `.claude/knowledge-base/vocabulary/terms.yaml`:

```yaml
terms:
  - term: "page"
    meaning: "A connected Facebook/Instagram business page, NOT a web page or UI page"
    context: "Always scoped to an agency"
  - term: "external_id"
    meaning: "The ID from the external platform (Facebook Page ID, Twilio number, etc.)"
    context: "This is the primary lookup field for pages, NOT the internal UUID"
```

## Step 6: Write Summary Index

After all categories are complete, create `.claude/knowledge-base/INDEX.md`:

```markdown
# Knowledge Base: {Project Name}

Generated: {today's date}
Mode: {brownfield|greenfield}
Interview status: {complete|partial — list remaining areas}

## Entities
{list each entity file with one-line description}

## Business Rules
{list each rule file with one-line description}

## Workflows
{list each workflow file with one-line description}

## Webhooks / Triggers
{list each webhook file with one-line description}

## Vocabulary
{list any non-obvious terms}

## Known Gaps
{list any areas marked UNKNOWN during interview}
{list any areas the developer said to skip}
```

## Step 7: Commit Knowledge Base

```bash
git add .claude/knowledge-base/
git commit -m "docs: add domain knowledge base from capture session"
```

Report to the user:

> **Domain knowledge capture complete.**
> - Entities documented: {count}
> - Business rules captured: {count}
> - Workflows mapped: {count}
> - Webhooks/triggers documented: {count}
> - Vocabulary terms defined: {count}
> - Known gaps: {count}
>
> Run `/domain-capture brownfield` again to fill gaps or add new areas.

Then STOP.

## Rules

- NEVER invent business rules — only document what the developer confirms
- NEVER skip the interview — the codebase analysis is a starting point, not the answer
- If the developer corrects your understanding of the code, update your analysis immediately
- Write knowledge base files incrementally after each category, not all at the end
- If the session is interrupted, the partially-written files are still valuable — they can be resumed
- For brownfield: ALWAYS show what you found in the code before asking the question
- For greenfield: ALWAYS reference specific PRD sections when asking questions
- Mark anything uncertain as UNKNOWN rather than guessing
- Include the `source` field on every file ("developer interview", "codebase analysis", etc.)
- Include `gotchas` on rules where the developer flags non-obvious behavior
- Use today's date for `created` and `last_validated` fields
- If resuming a previous capture, update `last_validated` on re-confirmed items
