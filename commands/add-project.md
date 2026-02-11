---
name: add-project
description: Add a project to the quetrex runner pipeline with all required setup
argument-hint: [project name]
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Glob
---

# Add Project to Quetrex Runner Pipeline

Sets up a project so the autonomous runner can work on its Linear issues.

## Usage

```
/add-project
/add-project my-new-app
```

## Instructions

### Step 1: Determine Scenario

Ask the user which scenario applies:

1. **Brand new project** — Nothing exists yet. Create everything from scratch.
2. **Local project, not on Linear** — Directory exists in ~/Projects but no Linear project.
3. **Linear project, not local** — Project exists in Linear but no local directory.
4. **Both exist, need mapping** — Project exists in both Linear and ~/Projects, just needs the runner config mapping.

### Step 2: Gather Information Based on Scenario

#### Scenario 1: Brand New Project

If `$ARGUMENTS` is provided, use it as the project name. Otherwise ask.

1. Ask for the **project name** (will be used as directory name, kebab-case)
2. Query Linear for available teams:
   ```bash
   LINEAR_API_KEY=$(security find-generic-password -a "quetrex-runner" -s "LINEAR_API_KEY" -w)
   ```
   Then use the Linear GraphQL API to fetch teams:
   ```
   { teams { nodes { id name key } } }
   ```
3. Present team options to the user with AskUserQuestion
4. Ask for the **Linear project display name** (e.g., "My New App") — defaults to a title-cased version of the directory name

Then execute:
- `mkdir -p ~/Projects/<project-name>`
- `cd ~/Projects/<project-name> && git init`
- `gh repo create Barnhardt-Enterprises-Inc/<project-name> --private --source ~/Projects/<project-name> --push`
- Create the Linear project via GraphQL mutation:
  ```
  mutation { projectCreate(input: { name: "<display name>", teamIds: ["<team-id>"] }) { project { id name } } }
  ```
- Add mapping to `~/.claude-runner/config.json`

#### Scenario 2: Local Project, Not on Linear

1. List git repos in ~/Projects:
   ```bash
   for d in ~/Projects/*/; do [ -d "$d/.git" ] && basename "$d"; done
   ```
2. Present the list for the user to select from with AskUserQuestion (show first 4, they can type "Other")
3. Check if a GitHub repo exists. If not, ask if they want to create one:
   ```bash
   gh repo view Barnhardt-Enterprises-Inc/<dir-name> 2>/dev/null
   ```
   If missing: `gh repo create Barnhardt-Enterprises-Inc/<dir-name> --private --source ~/Projects/<dir-name> --push`
4. Query Linear teams and ask which team
5. Ask for the **Linear project display name**
6. Create the Linear project via GraphQL
7. Add mapping to `~/.claude-runner/config.json`

#### Scenario 3: Linear Project, Not Local

1. Query Linear for all projects:
   ```
   { projects(first: 50) { nodes { id name teams { nodes { id name } } } } }
   ```
2. Present projects for the user to select
3. Ask for the **local directory name** (defaults to kebab-case of Linear project name)
4. `mkdir -p ~/Projects/<dir-name> && cd ~/Projects/<dir-name> && git init`
5. `gh repo create Barnhardt-Enterprises-Inc/<dir-name> --private --source ~/Projects/<dir-name> --push`
6. Add mapping to `~/.claude-runner/config.json`

#### Scenario 4: Both Exist, Need Mapping

1. Query Linear for all projects
2. List local git repos in ~/Projects
3. Ask user to select the Linear project
4. Ask user to select the local directory
5. Add mapping to `~/.claude-runner/config.json`

### Step 3: Update Runner Config

Read `~/.claude-runner/config.json`, add the new entry to `project_map`, and write it back.

Use the Read tool to read the file, parse the JSON, add the mapping, then use the Write tool to save.

The mapping format is:
```json
{
  "project_map": {
    "Linear Project Display Name": "local-directory-name"
  }
}
```

### Step 4: Verify

1. Confirm the local directory exists and is a git repo:
   ```bash
   git -C ~/Projects/<dir-name> remote -v
   ```
2. Read `~/.claude-runner/config.json` and confirm the mapping is present
3. Report success:

```
## Project Added

**Local:** ~/Projects/<dir-name>
**GitHub:** Barnhardt-Enterprises-Inc/<dir-name>
**Linear:** <display-name> (<team-key>)
**Runner mapping:** "<display-name>" -> "<dir-name>"

The runner will now pick up Queued issues with the "ai" label from this project.
```

### Important Notes

- All GitHub repos go under **Barnhardt-Enterprises-Inc** organization, **private**
- LINEAR_API_KEY is always retrieved from macOS Keychain: `security find-generic-password -a "quetrex-runner" -s "LINEAR_API_KEY" -w`
- Never store API keys in plaintext
- The Linear GraphQL endpoint is `https://api.linear.app/graphql` with header `Authorization: <key>`
