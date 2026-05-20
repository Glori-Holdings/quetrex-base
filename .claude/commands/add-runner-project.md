# Add Project to Quetrex Runner

Register the current project with the Quetrex Runner so it picks up Linear issues automatically. This skill handles everything from empty directory to fully configured runner project — including GitHub repo creation if needed.

## Instructions

### Phase 1: Git & GitHub Repository Setup

1. **Check if this directory is a git repository:**

```bash
git rev-parse --is-inside-work-tree 2>&1
```

2. **If NOT a git repo**, initialize one and bootstrap it:

   a. Run `git init` and create a default `main` branch:
   ```bash
   git init -b main
   ```

   b. **Check if a GitHub remote repo exists** for this directory name:
   ```bash
   gh repo view <owner>/<repo-name> 2>&1
   ```
   Use the directory basename as the default repo name.

   c. **If no GitHub repo exists**, determine where to create it:

      - Query the user's GitHub account and all orgs they belong to:
      ```bash
      gh api user -q '.login'
      gh api user/orgs -q '.[].login'
      ```

      - Present an interactive selection to the user using AskUserQuestion. Format it as a numbered list:
        ```
        Where should the GitHub repo be created?

        1. personaluser (personal account)
        2. SomeOrg
        3. AnotherOrg

        Enter the number of your choice:
        ```

      - Also ask whether the repo should be **public** or **private** (default private).

      - Also ask what the **repo name** should be (default to the directory basename).

   d. **Create the GitHub repo** under the selected owner:
   ```bash
   gh repo create <owner>/<repo-name> --private --description "Project description"
   ```
   Use `--public` if the user chose public.

   e. **Set the remote origin:**
   ```bash
   git remote add origin https://github.com/<owner>/<repo-name>.git
   ```

   f. **Create a README.md** with a basic project title (use the repo name).

   g. **Bootstrap via branch workflow** (hooks prevent direct commits to main):
      - Create an `initialize` branch:
        ```bash
        git checkout -b chore/initialize
        ```
      - Stage and commit the README:
        ```bash
        git add README.md
        git commit -m "chore: initialize repository with README"
        ```
      - Push the branch:
        ```bash
        git push -u origin chore/initialize
        ```
      - Create a PR:
        ```bash
        gh pr create --title "chore: initialize repository" --body "Initialize repository with README.md"
        ```
      - Merge the PR:
        ```bash
        gh pr merge --merge --delete-branch
        ```
      - Switch back to main and pull:
        ```bash
        git checkout main
        git pull origin main
        ```

3. **If it IS a git repo**, verify it has a GitHub remote:
   ```bash
   git remote -v
   ```
   If no remote exists, follow steps 2c–2e above to create a GitHub repo and set the remote.

### Phase 2: Runner Config Registration

4. Read the current runner config:

```bash
cat ~/.claude-runner/config.json
```

5. Determine the **Linear project name** and the **local repo directory name**:
   - Linear project name: If `$1` is provided, use it as the Linear project name. Otherwise, ask the user.
   - Local repo directory: Use the current directory's basename (e.g., if CWD is `/Users/barnent1/Projects/zero-lines-demo`, the dir name is `zero-lines-demo`).

6. Check if the project is already in `project_map`. If it is, tell the user and stop.

7. Add the mapping to `project_map` in `~/.claude-runner/config.json` using the Edit tool. The format is:

```json
"project_map": {
  "Linear Project Name": "local-repo-directory"
}
```

8. Verify the config is valid JSON:

```bash
python3 -c "import json; json.load(open('$HOME/.claude-runner/config.json')); print('Config is valid JSON')"
```

### Phase 3: GitHub Actions Workflows

9. **Set up GitHub Actions workflows.** Check if `.github/workflows/pr-checks.yml` and `.github/workflows/quality-gate.yml` exist in the current repo. If either is missing, create them. The job names MUST match the `blocking_checks` in the runner config or CI monitoring will fail with "no checks reported."

   Create a feature branch, add the workflows, commit, push, PR, and merge. Hooks prevent direct commits to main.

   ```bash
   git checkout -b chore/add-ci-workflows
   ```

   #### `.github/workflows/pr-checks.yml`

   ```yaml
   name: Pull Request Checks

   on:
     pull_request:
       types: [opened, synchronize, reopened]
       branches:
         - main

   jobs:
     type-check:
       name: TypeScript Type Check
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-node@v4
           with:
             node-version: '22'
             cache: 'npm'
         - run: npm ci
         - run: npm run type-check

     lint-check:
       name: ESLint Check
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-node@v4
           with:
             node-version: '22'
             cache: 'npm'
         - run: npm ci
         - run: npx biome check .

     branch-name-check:
       name: Validate Branch Name
       runs-on: ubuntu-latest
       steps:
         - name: Check branch name
           run: |
             BRANCH_NAME="${{ github.head_ref }}"
             if [[ "$BRANCH_NAME" == "main" ]]; then
               echo "ERROR: Cannot create PR from main branch!"
               exit 1
             fi
             if [[ ! "$BRANCH_NAME" =~ ^(feature|fix|refactor|docs|test|chore|issue|feat)/.+ ]]; then
               echo "WARNING: Branch name should follow pattern: type/description"
               echo "   Valid types: feature, fix, refactor, docs, test, chore, issue, feat"
             else
               echo "Branch name follows convention: $BRANCH_NAME"
             fi
   ```

   #### `.github/workflows/quality-gate.yml`

   ```yaml
   name: Quality Gate
   on:
     pull_request:
       branches: [main]

   concurrency:
     group: ${{ github.workflow }}-${{ github.ref }}
     cancel-in-progress: true

   jobs:
     test:
       name: Unit & Integration Tests
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-node@v4
           with:
             node-version: 22
             cache: 'npm'
         - run: npm ci
         - run: npm run test -- --coverage

     security:
       name: Security Scan
       runs-on: ubuntu-latest
       container:
         image: semgrep/semgrep
       steps:
         - uses: actions/checkout@v4
         - run: semgrep scan --config p/typescript --error

     build:
       name: Production Build
       runs-on: ubuntu-latest
       needs: [test, security]
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-node@v4
           with:
             node-version: 22
             cache: 'npm'
         - run: npm ci
         - run: npm run build
   ```

   **IMPORTANT:** The job `name` fields must exactly match the `blocking_checks` array in `~/.claude-runner/config.json`:
   - `TypeScript Type Check`
   - `ESLint Check` (runs Biome but name must match for CI monitoring)
   - `Unit & Integration Tests`
   - `Security Scan`
   - `Production Build`

   After creating the workflow files:
   ```bash
   git add .github/
   git commit -m "chore: add CI workflow files for runner integration"
   git push -u origin chore/add-ci-workflows
   gh pr create --title "chore: add CI workflows" --body "Add pr-checks.yml and quality-gate.yml for Quetrex Runner CI monitoring"
   gh pr merge --merge --delete-branch
   git checkout main
   git pull origin main
   ```

### Phase 4: Restart Runner

10. **Kill and restart the runner.** The runner loads config once at startup and does NOT hot-reload. You MUST kill and restart it or the new mapping will be ignored.

```bash
# Kill the current runner process
pkill -f "quetrex_runner"

# Restart it from the quetrex-runner project directory
cd ~/Projects/quetrex-runner && python3 -m quetrex_runner
```

11. Verify the runner restarted and loaded the new config by checking the log:

```bash
tail -5 ~/.claude-runner/logs/runner.log
```

12. Confirm to the user:

> **Project setup complete!**
>
> - GitHub repo: `<owner>/<repo-name>` (created/verified)
> - Runner mapping: **"{Linear Project Name}"** → **"{local-repo-directory}"**
> - GitHub Actions: `pr-checks.yml` + `quality-gate.yml` installed
> - Runner restarted to pick up the new mapping
