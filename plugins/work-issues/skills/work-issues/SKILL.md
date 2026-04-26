---
name: work-issues
description: Process one or more GitHub issues end-to-end through implementation and merge. Triggered by /work-issues with optional args (issue numbers, --label, --milestone, --parent). Self-contained orchestration — embeds the full work pipeline (worktree, plan, PR, self-review, code-review subagent, CI babysitting, automerge) so it works without project-specific CLAUDE.md scaffolding. Defaults: 3 concurrent agents, park-and-continue on blockers, sequential dependency-aware execution.
---

# work-issues

Take one or more GitHub issues from intake to merge in a self-managing loop. Invoke when stepping away while several issues land.

The skill is self-contained: every dispatched agent receives the full work pipeline in its prompt, so it does not require the host project's `CLAUDE.md` to define the workflow. Project-level docs (`CLAUDE.md`, `.claude/instructions/*.md`, `CONTRIBUTING.md`) are consulted by the agent for project-specific conventions (language, tooling, commit-message scopes), but the orchestration logic and PR pipeline are defined here.

## Invocation

`/work-issues [<args>]`

| Form | Behaviour |
|---|---|
| `/work-issues 280 281 282` | Process the listed issues. |
| `/work-issues --label <name>` | Process all open issues carrying the label. |
| `/work-issues --milestone "<title>"` | Process all open issues in the milestone. |
| `/work-issues --parent <n>` | Process all sub-issues of the parent issue. |
| `/work-issues` | Default: equivalent to `--label scheduled`. |

Selectors compose: `/work-issues --milestone "MS-2 General" --label scheduled` intersects them.

## Operating principles

- **Sequential phases.** Don't skip; if a phase yields no work, log and continue.
- **Park, don't block.** A blocker on issue A never stops independent issues B and C.
- **Public-break = blocker, internal = self-resolve.** Anything that would change a publicly-observable surface (API shape, file path, schema, naming convention, semver bump) is a blocker requiring user clarification. Internal implementation choices the agent makes itself with a one-line justification in the PR body.
- **Strict isolation.** Every dispatched agent runs with `isolation: worktree`. No file-state collisions.
- **Best-effort context sharing.** When B declares a dependency on A and A has merged, B's dispatch prompt includes A's PR summary and any new types/helpers A introduced. Independent issues start cold.
- **Concurrency cap: 3.** Three agents in flight at once. "In flight" = actively implementing or addressing review. An agent that has set automerge and returned `AUTOMERGE_SET` does not count toward the cap — the orchestrator's shell monitor (Phase 5b) drives the PR to merge from there, escalating to focused mini-agents only when judgment is required.

## Universal work conventions

These rules are embedded in every dispatched agent's prompt so the skill works for users without project-level convention docs.

### Git discipline

- **Conventional commits** for every commit (`feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `chore:`, `test:`, `build:`, `ci:`, `style:`, `revert:`).
- **No `--no-verify`** to skip hooks. If a hook fails, fix the underlying issue.
- **No `--amend`** on commits that have been pushed.
- **No force-push** on branches under review.
- **Investigate, don't bypass**: when CI fails, find the root cause; don't retry blindly or disable the check.
- **Stage explicitly**: prefer adding files by name over `git add -A` / `git add .` to avoid sweeping in unrelated changes.

### Worktree workflow

- Each dispatched agent runs in an isolated worktree (`isolation: worktree` on the Agent call). The worktree is created fresh from the latest `main`.
- Within the worktree: `git fetch origin main && git reset --hard origin/main` before the first edit (defensive — `isolation: worktree` already does this, but the agent confirms).
- Branch name: default to `<username>/<short-slug>` where `<username>` is the GitHub login of the authenticated user (`gh api user --jq .login`) and `<short-slug>` is a 2-4 word description. Projects that care about a different convention can encode it in `CLAUDE.md`.
- After merge, the worktree is cleaned up automatically by Claude Code.

### Issue label lifecycle

- **`scheduled`**: applied at intake (Phase 4) for every in-scope issue.
- **`in-progress`**: applied when an agent picks up the issue (Phase 5, immediately after worktree creation, before drafting the plan). `scheduled` is removed at the same time.
- **`blocked`**: applied when an agent parks the issue awaiting clarification (Phase 7). `in-progress` is removed.
- **Issue closure**: when the PR merges with a `Closes #<n>` footer, GitHub closes the issue automatically and the `in-progress` label persists on the closed issue (intentional — preserves the audit trail of who picked it up).

If a label doesn't exist in the repo, create it once via `gh label create` (see Phase 4 commands).

### PR conventions

- **Title**: conventional commits (`type(scope): subject`). The PR title becomes the squash-merge commit subject.
- **Body**: follows the project's PR template if present (`.github/PULL_REQUEST_TEMPLATE.md` or `.github/pull_request_template.md`). Otherwise: 1–3 bullet summary, plus a "Test plan" checklist. Always include a `Closes #<n>` footer to wire the merge to issue closure.
- **DCO sign-off**: every commit needs a `Signed-off-by:` trailer if the project has a DCO check. Use `git commit -s` for every commit. Git has no native config that makes `git commit` auto-sign-off — `format.signoff` only affects `git format-patch`, and `commit.signoff` is silently ignored. If you'd rather not type `-s` each time, alias it: `git config --local alias.c 'commit -s'`. If a commit lands without `Signed-off-by:`, fix the whole branch with `git rebase origin/main --signoff && git push --force-with-lease`.
- **Comment reply prefix**:
  - Implementing agent: `Claude: `
  - Independent code-review subagent: `Claude Reviewer: `

### CI discipline

- Read failure logs before acting (`gh run view <run-id> --log-failed`).
- Fix the root cause; don't pin around it, disable the check, or retry blindly.
- Environmental / flaky failures (infra outage, rate limit, unrelated to this PR's diff) get reported but not retried — surface the issue rather than re-running.

**A check passing 'success' isn't the same as the check doing its job.** If a workflow has a "check secrets" guard and exits 0 when secrets are missing, the side effect (committed file, set label, posted comment) won't happen. When you see a downstream check fail because an upstream artifact is missing (e.g. `changelog-lint` failing because no `pr-<N>-*.yml` exists, when a `changelog-bot` workflow ran and reported success), look at the upstream workflow's logs for `secrets not configured`-style notices before assuming a race or retrying.

### Common gotchas

**Trigger-surface widening triggers retroactive CodeQL findings.** If your PR adds `workflow_run` or `pull_request_target` as a trigger to any workflow file, audit *every* `run:` block in that file for inline `${{ steps.* }}`, `${{ github.event.* }}`, or `${{ inputs.* }}` interpolations. CodeQL will treat values flowing from the new trigger as untrusted, and existing safe-looking interpolations become `js/actions/command-injection` findings. Convert affected interpolations to the `env:` block + `${VAR}` shell expansion pattern that the rest of the file likely already uses. Run the local CodeQL action if available, or expect a CI failure on first push.

## Phase 1 — Intake

Resolve the issue list:

```bash
# Explicit numbers — fetch each.
gh issue view <n> --json number,title,body,labels,milestone,state,assignees

# Label-based:
gh issue list --state open --label <name> --json number,title,body,labels,milestone

# Milestone-based:
gh issue list --state open --milestone "<title>" --json number,title,body,labels,milestone

# Parent / sub-issue:
gh api "repos/:owner/:repo/issues/<n>/sub_issues" --jq '.[].number'
# then fetch each sub-issue body
```

Exclude any issue that is closed, has the `released` label, or is currently labelled `in-progress` by a different active session (check the comment trail to disambiguate). Surface a one-line note for each excluded issue.

### Auto-memory sweep for known-broken CI / manual workarounds

Sweep `~/.claude/projects/<project-slug>/memory/` for entries matching `*_bot_secrets*`, `*_broken*`, `*_pending*`, or whose body contains `manual workaround` / `skip silently` / `secrets not configured`. Inject any matches into every dispatch prompt under a "Known-broken CI / manual workarounds in this project" section.

An inline `find` + `grep` pipeline is sufficient — no helper script required. For example:

```bash
slug=$(pwd | sed 's:/:-:g')
mem="$HOME/.claude/projects/${slug}/memory"
{
  find "$mem" -maxdepth 1 -type f \( -name '*_bot_secrets*' -o -name '*_broken*' -o -name '*_pending*' \) 2>/dev/null
  grep -lE 'manual workaround|skip silently|secrets not configured' "$mem"/*.md 2>/dev/null
} | sort -u
```

If the sweep returns hits, paste each matched file's body verbatim into the dispatched agent's prompt under the "Known-broken CI / manual workarounds in this project" heading (see the dispatch template below). If the sweep returns nothing, omit the section.

## Phase 1.5 — Observe current PR conventions

`CLAUDE.md` can lag behind reality — new conventions ship on main before the doc gets updated. Before dispatching, snapshot what the most recent merged PRs actually do:

```bash
gh pr list --state merged --limit 5 --json number,title,body,labels --jq '.[]'
```

Look for patterns the dispatched agent needs to match that may not be in `CLAUDE.md`:

- **Title prefix style** — Conventional Commits (`feat:`, `fix:`) vs. a project-specific allowlist (`feature:`, `improvement:`, `chore:`). Use whatever recently-merged titles consistently use.
- **Body format** — does the body wrap the commit message in a delimited block (e.g. `==COMMIT_MSG==`)? Where do `Closes #N` and `Signed-off-by:` sit (inside the block, or outside)?
- **Labels at merge time** — is there a `no changelog` / `automerge` / similar label that's consistently applied? Does the project use a merge-bot that requires a specific label?
- **Manual changelog entry** — do recently-merged PRs touch `changelog/@unreleased/pr-<N>-<slug>.yml` or similar? If so, the dispatched agent must hand-author one (or apply a `no changelog` label for non-user-visible changes).
- **Merge mechanism** — does the project rely on a label-triggered merge-bot, or on GitHub's native auto-merge? See the detection heuristic below; this finding is surfaced as a `Merge mechanism:` line so sub-step 6.4 can act on it without hardcoding a command.

### Detecting the merge mechanism

Some projects flip `allow_squash_merge=false` and route merges through a merge-bot triggered by a label (e.g. `automerge`); on those projects, `gh pr merge --auto --squash` is at best a no-op and at worst skips the bot's commit-message extraction. To classify the project's mechanism from recent merged PRs:

1. **Workflow probe.** Does the repo have a workflow whose `on:` block listens to a `pull_request: types: [labeled]` event with a label-name filter? Common paths: `.github/workflows/merge-bot.yml`, `.github/workflows/automerge*.yml`. If yes, capture the label name from the workflow's `if:` guard.

   ```bash
   gh api 'repos/{owner}/{repo}/contents/.github/workflows' \
     --jq '.[].name' 2>/dev/null
   # then read each candidate workflow's `on:` and `if:` blocks
   ```

2. **PR-label cross-check.** Does the captured label appear consistently on the most recent merged PRs?

   ```bash
   gh pr list --state merged --limit 5 --json number,labels \
     --jq '.[] | {n: .number, labels: [.labels[].name]}'
   ```

   If the label appears on essentially every merged PR, the project uses the merge-bot. If the label is absent or sporadic, default to native auto-merge.

If both signals agree on a label-triggered bot, record the finding as `Merge mechanism: apply <label> label (merge-bot picks it up)`. Otherwise default to `Merge mechanism: gh pr merge --auto --squash` (native auto-merge).

Compile observations into a "Current PR conventions (observed)" block — including the `Merge mechanism:` line — and inject it into every dispatched agent's prompt. This beats relying on `CLAUDE.md` being current, and sub-step 6.4 of the dispatch template reads the `Merge mechanism:` line to decide what to do.

## Phase 2 — Pre-flight clarification

Read each issue body in full. Identify *only* gaps that would cause a publicly-observable break if guessed wrong:

- Undecided naming for files, APIs, schemas, env vars, labels.
- Required context marked `TBD`, `?`, "decide in this issue", or similar placeholders.
- Open questions explicitly listed in the issue body's "Decisions to make" sections.

Internal implementation choices (test layout within a package, helper function names, internal refactor decisions) are NOT clarification triggers — the dispatched agent resolves those itself.

If clarifications exist:

1. Compile into ONE batched message: numbered, grouped by issue.
2. Surface to user. Wait for answers.
3. After answers, update each affected issue body via `gh issue edit <n> --body "<updated>"` so the dispatched agent has full context without needing this orchestrator's conversation history.
4. Proceed.

If no clarifications: continue silently.

## Phase 3 — Dependency analysis

For each issue, identify dependencies:

- Explicit `Depends on #N` / `Blocked by #N` lines in body.
- Sub-issue / parent relationships.
- Implicit: if two issues both edit the same schema or file, flag for ordering.

Update the tracker:

```bash
# Add explicit dependency line if missing:
gh issue edit <n> --body "<existing body>\n\nDepends on #<m>"
```

Native sub-issue links via `POST /repos/:owner/:repo/issues/<n>/sub_issues` are preserved.

Build a directed acyclic graph; topologically order. Cycles are a hard error — surface to user, abort.

## Phase 4 — Scheduling

Apply `scheduled` to every in-scope issue and create one orchestrator task per issue via `TaskCreate` so progress is visible in the main session's task list:

```bash
gh issue edit <n> --add-label scheduled
```

```text
TaskCreate(subject: "Process issue #<n> (<short title>)",
           description: "<one-line scope>",
           activeForm: "Processing #<n>")
```

Track task lifecycle in lockstep with the issue label lifecycle:

- On dispatch (Phase 5 step 3): `TaskUpdate(status: "in_progress")`.
- On `MERGED` notification (Phase 5 step 4): `TaskUpdate(status: "completed")`.
- On `AUTOMERGE_SET`: leave the task `in_progress`; flip to `completed` when the Phase 5b shell monitor emits `MERGED`.
- On `BLOCKED` / `PAUSED`: leave `in_progress`; the task surfaces the parked state to the user.

For dependencies declared in Phase 3, set `addBlockedBy` on the dependent task so the task list reflects the dispatch order.

Create the labels on first run if missing:

```bash
gh label create scheduled --color 0E8A16 \
  --description "A running Claude Code session has scheduled this issue" 2>/dev/null || true
gh label create blocked --color B60205 \
  --description "Awaiting clarification before work can resume" 2>/dev/null || true
gh label create in-progress --color FBCA04 \
  --description "A running Claude Code session is working on this issue" 2>/dev/null || true
gh label create paused --color D4C5F9 \
  --description "A running Claude Code session is paused on this issue (recoverable — usage cap, infra outage)" 2>/dev/null || true
```

## Phase 5 — Execution loop

Loop until every issue is terminal (merged, parked, or excluded):

0. **Resumption check** — before dispatching a fresh agent, look for state from a prior aborted attempt:

   - Issue already labelled `in-progress` or `paused` (carried over from a halted run).
   - Open PR with `Closes #<N>` in its body.
   - Branch on origin matching the project's branch convention for this issue.

   If any exist, the prior agent partially completed work. Dispatch with a *resumption* prompt instead of the standard one: name the existing branch / PR explicitly and tell the agent "do NOT restart — check out the existing branch, fix what's incomplete, push, drive to merge." This avoids duplicate PRs and clobbered work.

1. **Pick next issue** — topologically eligible (all declared deps merged), not already in-progress / parked / merged. If nothing eligible but in-flight count < 3, the loop waits for a current agent to terminate.

2. **Mark in-progress**:

   ```bash
   gh issue edit <n> --add-label in-progress --remove-label scheduled
   ```

2a. **Pre-dispatch stale-path scan** — applies *only* to issues whose declared deps merged after Phase 1 intake (i.e. mid-run). Skip otherwise.

   When a dep PR rearranges code (renames a package, collapses one module into another), file paths quoted in the dependent issue's body — `packages/foo/src/foo/bar.py:78–91`, `src/auth/login.ts`, etc. — go stale. The dispatched agent reads the issue body verbatim, so a stale path either burns tokens hunting for files that no longer exist or, worse, leads the agent to recreate the moved structures rather than editing the new ones.

   Scan the issue body before building the dispatch prompt:

   1. Extract candidate paths via `grep -oE`. Cover three shapes: `packages/...`, `src/...`, and bare repo-root files (e.g. `Cargo.toml`, `pyproject.toml`). Line-number suffixes `:NN` or `:NN-NN` (or em-dash `:NN–NN`) are common in this repo and must be stripped before the existence check.
   2. For each candidate, check existence in the *post-merge* tree with `git ls-tree HEAD <path>` (or `test -e <path>` if a worktree is already checked out at the repo root).
   3. If any path is stale, **prefer injecting a `Stale paths (deps merged mid-run)` preamble into the dispatch prompt** over editing the public issue body. The preamble keeps the issue body unchanged (no public-state churn) while still naming each missing path for the dispatched agent. The preamble is rendered just below the `Dependency context` block — see the dispatch template's `<if any deps merged: ...>` placeholder.
   4. Fallback option: if the orchestrator wants the architecture refresh visible to humans browsing the issue (e.g. the dep PR's restructure is non-obvious and future readers benefit), append a one-line `Architecture refresh (after #<dep> merged): <old-path> moved to <new-path>` note via `gh issue edit <n> --body "<existing>\n\n<note>"`. This mutates public state, so reach for the preamble first.

   Worked example — issue #332 quotes `packages/gpg-backend-cli-host/src/gpg_backend_cli_host/gpg.py:78–91` and dep #316 collapsed that package into `gpg-bridge`:

   ```bash
   body=$(gh issue view <n> --json body --jq .body)

   # 1. Extract candidate paths. Strip optional :NN[-NN] / :NN–NN suffix in a second pass.
   paths=$(printf '%s\n' "$body" \
     | grep -oE '(packages/[A-Za-z0-9_./-]+|src/[A-Za-z0-9_./-]+|\b[A-Za-z0-9_-]+\.(toml|yaml|yml|json|md|lock))(:[0-9]+(-[0-9]+|–[0-9]+)?)?' \
     | sed -E 's/:[0-9]+(-[0-9]+|–[0-9]+)?$//' \
     | sort -u)

   # 2. Existence check against post-merge HEAD. Collect stale paths.
   stale=()
   while IFS= read -r p; do
     [[ -z "$p" ]] && continue
     if ! git ls-tree -r HEAD --name-only | grep -qxF "$p"; then
       stale+=("$p")
     fi
   done <<<"$paths"

   # 3. If stale paths found, render the preamble for the dispatch prompt.
   if (( ${#stale[@]} > 0 )); then
     printf 'Stale paths (deps merged mid-run): the following paths in the issue body no longer exist in HEAD — locate the new home before editing:\n'
     printf -- '- %s\n' "${stale[@]}"
   fi
   ```

   Inject the preamble's stdout into the dispatch prompt (see the dispatch template below). If the array is empty, omit the section — exactly the same convention the Phase 1 auto-memory sweep uses.

3. **Dispatch agent** with `isolation: worktree`, `run_in_background: true`. Use the **dispatch prompt template** below.

4. **Monitor** — Claude Code notifies the orchestrator when each background agent completes. On notification:
   - **MERGED**: GitHub closed the issue via `Closes #<n>`. Mark task done; pick up the next eligible issue.
   - **AUTOMERGE_SET**: agent set automerge and exited. Slot is now free — pick up the next eligible issue. The orchestrator hands off to **Phase 5b** (post-automerge monitoring): a thin shell monitor polls the PR; auto-resolves `BEHIND` in-shell; emits events that the orchestrator routes to focused mini-agents for `CONFLICT` / `CI_FAILURE` / `NEW_COMMENT`; exits on `MERGED`. **Review-fallback check:** if the PR body contains a `### Self-review only` section (the implementing agent's harness lacked the `Task` / `general-purpose` subagent type), dispatch a separate review subagent at the orchestrator level *before* the merge lands. Use the same review prompt the dispatch template's 6.1 would have used and treat its output as a normal review pass — any findings flow back to the PR via inline `Claude Reviewer: ` comments and the Phase 5b monitor's `NEW_COMMENT` event will route them to the review-comment mini-agent.
   - **BLOCKED**: ensure `blocked` label set, `in-progress` removed; record the question for batched surfacing in Phase 7.
   - **PAUSED**: ensure `paused` (or `blocked`) label is set; record the reset time. Re-dispatch a resumption agent (Phase 5 step 0 path) after the condition clears.
   - **ERRORED**: surface immediately to user; do not retry without instruction.

   The harness occasionally fires duplicate `task-notification` events for an agent after it has already terminated — recognisable by 0 tool uses and a generic-sounding result string. Ignore these; rely on your own Monitor task or PR-state polling for ground truth.

5. **Continue** until all terminal.

### Progress reporting

The TaskCreate list (Phase 4) is the durable surface. Augment it with a chat-visible digest so the user sees PR links, review status, and CI state without polling GitHub themselves. Keep digests terse — one line per in-flight issue, no headers, no surrounding narration.

**Cadence:**

- On every orchestrator wakeup tick (~270s) while at least one issue is in-flight (`in-progress` or `automerge_set`). Schedule a recurring `ScheduleWakeup(delaySeconds: 270)` whenever the in-flight count > 0 and no wakeup is already pending.
- Immediately on every dispatched-agent terminal return (`MERGED`, `AUTOMERGE_SET`, `BLOCKED`, `PAUSED`, `ERRORED`) — emit a digest of the remaining in-flight set so the user sees the new state without waiting for the next tick.
- Immediately on every Phase 5b monitor event (`MERGED`, `CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`, mini-agent `RESOLVED` / `FIXED` / `ADDRESSED`) — same digest line so the user sees what the shell monitor and its mini-agents are doing.

**Per-issue probe** — for each in-flight issue `<N>`:

1. **Find the PR** (created in step 5 of the dispatch pipeline):

   ```bash
   gh pr list --state open --search "Closes #<N> in:body" \
     --json number,url,statusCheckRollup,mergeable,mergeStateStatus --limit 1
   ```

   Empty result → agent hasn't pushed yet → emit `#<N>: implementing` and skip the rest of the probe.

2. **Review status** — count `Claude Reviewer:` comments. The review subagent (step 6 of the dispatch pipeline) posts either inline review comments or a single LGTM PR-level comment with the `Claude Reviewer: ` prefix (the implementing agent uses `Claude: `, so the prefix discriminates):

   ```bash
   gh api 'repos/{owner}/{repo}/pulls/<pr#>/comments' \
     --jq '[.[] | select(.body | startswith("Claude Reviewer: "))] | length'
   gh api 'repos/{owner}/{repo}/issues/<pr#>/comments' \
     --jq '[.[] | select(.body | startswith("Claude Reviewer: "))] | length'
   ```

   - Both 0 → `review: pending`.
   - Inline count ≥ 1 → `review: done (<n> findings)`.
   - Inline 0 and exactly one issue-level comment matching `Claude Reviewer: LGTM` → `review: done (LGTM)`.

3. **CI state** — aggregate `statusCheckRollup` from the `gh pr list` query above:

   - All entries `conclusion == "SUCCESS"` → `CI: green`.
   - Any `conclusion == "FAILURE"` → `CI: red (<m> failing)`.
   - Any `status == "IN_PROGRESS"` or `"QUEUED"` → `CI: pending (<done>/<total>)`.
   - Rollup empty → `CI: not started`.

4. **Merge state** — `mergeable` + `mergeStateStatus` from the same `gh pr list` query (Phase 5b's shell monitor handles remediation for the non-clean cases — this signal just surfaces them to the user):

   - `mergeable == "CONFLICTING"` or `mergeStateStatus == "DIRTY"` → `merge: conflict`. The Phase 5b shell monitor will emit a `CONFLICT` event and the orchestrator will dispatch the conflict-resolution mini-agent; surfacing it here means the user notices if a conflict sits unresolved across ticks.
   - `mergeStateStatus == "BEHIND"` → `merge: behind`. Auto-resolved in-shell by Phase 5b's monitor (`git fetch origin main && git merge --no-edit origin/main && git push`); usually transient.
   - `mergeable == "MERGEABLE"` (any non-conflicting `mergeStateStatus`) → `merge: clean`.
   - `mergeable == "UNKNOWN"` → `merge: computing`. GitHub hasn't finished computing mergeability yet; will resolve on the next tick.

**Line format:**

```
#<N> <pr-url> — review: <state> — CI: <state> — merge: <state>
```

One line per in-flight issue. Merged / blocked / paused / errored issues drop out of the digest — their terminal state is in the task list and is summarised in Phase 8's final report.

Example tick output:

```
#337 https://github.com/aidanns/agent-auth/pull/450 — review: done (3 findings) — CI: pending (8/12) — merge: clean
#338 https://github.com/aidanns/agent-auth/pull/451 — review: done (LGTM) — CI: green — merge: behind
#339 https://github.com/aidanns/agent-auth/pull/452 — review: pending — CI: red (1 failing) — merge: conflict
#340 — implementing
```

### Dispatch prompt template (embedded in every Agent call)

The orchestrator constructs the per-agent prompt by filling in the placeholders below. The full text — not a reference — goes into the Agent call so the dispatched agent has everything it needs without consulting this skill.

```
You are implementing GitHub issue #<N> end-to-end. The issue body follows verbatim:

---
<full body refreshed via `gh issue view <N> --json body --jq .body`>
---

Project context: this repo's conventions are described in `CLAUDE.md` (root), `.claude/instructions/*.md` (if present), and `CONTRIBUTING.md`. Read these before editing — they define language, tooling, commit-message scopes, and any project-specific rules.

Current PR conventions (observed from the most recent merged PRs — `CLAUDE.md` may not yet reflect these):
<orchestrator's Phase 1.5 observations: title prefix style, body-block format like ==COMMIT_MSG==, label requirements like `no changelog` / `automerge`, manual changelog YAML entries, etc.>
Merge mechanism: <one of `apply <label> label (merge-bot picks it up)` or `gh pr merge --auto --squash` — sub-step 6.4 below reads this line, do not hardcode a merge command>

<if any deps merged: Dependency context — these issues already merged and may have introduced helpers / types / files you should reuse:
- #<dep>: <PR title>. Summary: <one-line summary of what merged>.>

<if the Phase 5 step 2a stale-path scan found stale paths in the issue body (only when deps merged mid-run):
Stale paths (deps merged mid-run): the following paths quoted in the issue body above no longer exist in HEAD — locate the new home before editing instead of recreating the moved structures:
- <path 1>
- <path 2>
The dep PR(s) listed under Dependency context above rearranged the relevant code; check those PR diffs for the new layout.>

<if the Phase 1 auto-memory sweep returned hits:
Known-broken CI / manual workarounds in this project (swept from `~/.claude/projects/<slug>/memory/` — assume current unless the entry is dated stale):
- <verbatim body of each matched memory entry, separated by `---`>
Treat these as ground truth for known gaps in this project's CI / bots — don't waste time rediscovering them, and follow any documented manual workaround.>

## Pipeline

You run in an isolated worktree (Claude Code's `isolation: worktree` already created it). Confirm with `git status` and `pwd`. Branch off latest `main`:

  git fetch origin main && git reset --hard origin/main
  git checkout -b <branch-name>

Default branch name: `<username>/<short-slug>` where `<username>` is `gh api user --jq .login` and `<short-slug>` is a 2-4 word description. Projects that care about a different convention can encode it in `CLAUDE.md`.

### 1. Plan (if non-trivial)

If the project has `.claude/instructions/plan-template.md`, write a plan against that template before editing. Otherwise: skip the formal plan for changes under ~50 lines; for larger changes, write a 5-10 line plan in the issue as a comment for visibility.

### 2. Implement

Follow project conventions documented in `.claude/instructions/*.md`, `CLAUDE.md`, `CONTRIBUTING.md`. Resolve internal implementation choices yourself; record any non-obvious decision in the PR body with one-line justification.

### 3. Self-review BEFORE push

Read your full diff as if reviewing someone else's PR:

  git diff main...HEAD

Fix anything that wouldn't pass your own review bar: dead code, unclear names, missing tests, unhelpful comments, scope creep. Iterate until the diff is clean.

### 4. Commit + push

Conventional commit messages with `Signed-off-by:` if the project has DCO. Commit-msg trailers (`Closes #<N>`, `Co-authored-by:`) at the end of the body, not the subject.

  git add <specific files>
  git commit -s
  git push -u origin <branch-name>

### 5. Open the PR

  gh pr create --title "<conventional-commits subject>" \
               --body "<body matching project's PR template; include Closes #<N>>"

### 6. Review and merge loop

Steps 6.1 through 6.4 form a single phase: spawn the review subagent, address whatever it finds, address any CI failures, then set automerge. **The review subagent's findings are not your final output** — they are the *start* of the merge loop. The only valid terminal returns from this phase are `AUTOMERGE_SET`, `MERGED`, `BLOCKED`, `PAUSED`, or `ERRORED` (see Output section). Setting automerge in 6.4 is your terminal step — the orchestrator's Phase 5b shell monitor drives the PR the rest of the way to merge.

#### 6.1 Spawn review subagent

Spawn ONE Agent (subagent_type: general-purpose, run_in_background: false) to review the PR. Use this prompt:

  > You are reviewing PR #<pr#> on <repo>. Fetch the diff with `gh pr diff <pr#>`. Review it against the project's conventions documented in `CLAUDE.md`, `.claude/instructions/*.md`, and `CONTRIBUTING.md`. Look for: scope creep, undocumented decisions, missing tests, dead code, unclear naming, breaking changes that aren't called out, security issues, and convention violations.
  >
  > Post each finding as an inline comment via the GitHub API:
  >
  >   gh api --method POST 'repos/{owner}/{repo}/pulls/{pr#}/comments' \
  >     -f body='Claude Reviewer: <finding>' \
  >     -f commit_id='<head sha>' \
  >     -f path='<file>' \
  >     -f line=<line>
  >
  > Use the `Claude Reviewer: ` prefix on every comment. If the diff is clean (no findings), post a single PR comment via `gh pr comment <pr#> --body 'Claude Reviewer: LGTM. <one-line summary of what you checked>'` and return.

**Fallback if the `Task` / `general-purpose` subagent type is unavailable in your harness.** Do NOT skip review. Self-review the diff against the same checklist the subagent would use (scope creep, undocumented decisions, missing tests, dead code, unclear naming, breaking changes that aren't called out, security issues, convention violations) and add a `### Self-review only` section to the PR body explicitly stating the subagent was unavailable and listing what you checked. Then proceed to 6.2 normally and return `AUTOMERGE_SET` as normal — the orchestrator's Phase 5 monitoring greps for `### Self-review only` and dispatches a review subagent at its own level to fill the gap.

Wait for it to complete. **When it returns, do NOT report its findings back to the orchestrator — proceed immediately to 6.2.**

#### 6.2 Address findings

Fetch unaddressed comments:

  gh api 'repos/{owner}/{repo}/pulls/{pr#}/comments' --paginate

A comment is *unaddressed* when `in_reply_to_id == null` (top-level reviewer comment) AND no other comment's `in_reply_to_id` equals its `id`. For each unaddressed `Claude Reviewer: ` comment:

1. Make the code change (or document why the suggestion shouldn't be adopted).
2. Commit with a conventional-commit message.
3. `git pull --rebase origin <branch>` then `git push`. Retry up to 3x on non-fast-forward.
4. Post a threaded reply:

   gh api --method POST 'repos/{owner}/{repo}/pulls/{pr#}/comments/{id}/replies' \
     -f body='Claude: Done!'

   If the suggestion was adopted as-is, use `Claude: Done!`. If you took a different approach, use `Claude: <one-line explanation>`.

Also check issue-level PR comments:

  gh api 'repos/{owner}/{repo}/issues/{pr#}/comments' --paginate

Issue-level comments don't have thread replies — reply with a new issue comment prefixed `Claude: `.

If the only review output is a single `Claude Reviewer: LGTM` issue-level comment, there are no findings to address — proceed to 6.3.

**Note on conflict resolution.** A merge conflict that surfaces *before* you set automerge is yours to resolve in this loop. After you set automerge in 6.4, conflict resolution is delegated to the orchestrator's Phase 5b shell monitor, which dispatches a focused conflict-resolution mini-agent.

#### 6.3 Address CI failures

Fetch PR status:

  gh pr view <pr#> --json statusCheckRollup

For each entry with `conclusion == "FAILURE"`:

1. Get logs: `gh run view <databaseId> --log-failed`.
2. Diagnose root cause. Do NOT bypass the check.
3. Fix; commit with a conventional-commit message referencing the failing check.
4. `git pull --rebase` + `git push`.

**Trap to avoid:** `gh run rerun --failed` re-uses the original event snapshot. If the failure was caused by an outdated PR body or a missing label, `--failed` will re-fail with the same stale context — even after you've edited the body or applied the label. After fixing a label or body issue, fire a fresh `synchronize` event by either pushing a new commit or running:

  gh api --method PUT 'repos/{owner}/{repo}/pulls/<pr#>/update-branch'

That merges the latest base into the PR branch and re-fires every workflow on the new HEAD SHA — picking up the current body and label state.

If the failure is environmental (infra outage, rate limit, unrelated to your diff): report it in the PR body and skip — do not retry blindly.

#### 6.4 Set automerge — TERMINAL STEP

Once review comments are addressed AND CI is green (or known-environmental), hand off to merge by reading the `Merge mechanism:` line from the "Current PR conventions (observed)" block above:

- If `Merge mechanism: apply <label> label (merge-bot picks it up)` — apply the label and let the project's merge-bot drive the merge:

      gh pr edit <pr#> --add-label <observed-label>

- If `Merge mechanism: gh pr merge --auto --squash` (or the line is absent / unrecognised — default to native auto-merge):

      gh pr merge <pr#> --auto --squash

This is your last action. The merge happens asynchronously once all required checks pass (and, for the merge-bot path, once the bot picks up the label). **Return immediately** with one of:

- `AUTOMERGE_SET <pr-url>` — merge handoff complete (label applied or `--auto` set), no findings outstanding, CI green or in flight. The orchestrator's Phase 5b shell monitor takes over from here (handles `BEHIND`, conflicts, CI failures, new review comments via focused mini-agents).
- `MERGED <pr-url>` — the PR merged synchronously between you handing off and exiting (rare but possible — `gh pr merge --auto` may immediately complete the merge if all required checks were already green; merge-bot paths typically don't merge synchronously).

If the native-auto-merge branch errors out (the repo doesn't have automerge enabled), fall back to `gh pr merge <pr#> --squash` (immediate squash-merge) and return `MERGED <pr-url>`. The label-triggered path has no equivalent fallback — if applying the label errors out, surface the error rather than guessing.

**Do not poll for merge state. Do not narrate progress.** The whole point of returning here is to free your slot — narrating between polls is what Phase 5b is designed to eliminate.

#### Worked example: review came back clean

When the 6.1 subagent returns and the only output is `Claude Reviewer: LGTM`, the next tool calls in this turn should be (no narration to the orchestrator in between):

```bash
# 6.2 — confirm there are no inline findings to address.
gh api 'repos/{owner}/{repo}/pulls/<pr#>/comments' --paginate \
  --jq '[.[] | select(.body | startswith("Claude Reviewer: "))] | length'
# expected: 0

# 6.3 — confirm CI is green (or only environmental failures).
gh pr view <pr#> --json statusCheckRollup \
  --jq '[.statusCheckRollup[] | select(.conclusion=="FAILURE")] | length'
# expected: 0 (or only known-environmental — see 6.3 for handling)

# 6.4 — hand off to merge per the `Merge mechanism:` line in the observed-PR-conventions block.
# If the line says `apply automerge label (merge-bot picks it up)`:
gh pr edit <pr#> --add-label automerge
# Otherwise (native auto-merge — the default):
gh pr merge <pr#> --auto --squash
```

Then return `AUTOMERGE_SET <pr-url>` as the structured output (or `MERGED <pr-url>` if the PR merged synchronously). Do not summarise the review back to the orchestrator; the LGTM comment is on the PR for the orchestrator's digest to pick up directly.

**You have only completed your task when you return `AUTOMERGE_SET`, `MERGED`, `BLOCKED`, `PAUSED`, or `ERRORED`. Returning the review subagent's findings is not a valid output. If the review is clean (only `Claude Reviewer: LGTM`), immediately set automerge and exit. Do not summarise the review back to the orchestrator. Do not poll for merge state — the orchestrator's Phase 5b shell monitor owns that.**

## Blocker handling

If at ANY point you hit a *publicly-observable* ambiguity that would change file paths, API shapes, schemas, or naming conventions — STOP. Do NOT guess.

1. Post a comment on the issue describing exactly what you need (be specific — name the file, the field, the option):

   gh issue comment <N> --body 'Claude: Blocked — <specific question>'

2. Apply the `blocked` label, remove `in-progress`:

   gh issue edit <N> --add-label blocked --remove-label in-progress

3. Return a structured report to the orchestrator: `BLOCKED: <issue> <question>`.

Internal implementation decisions (test layout, helper names, internal refactor choices) are NOT blockers — resolve them yourself with one-line justification in the PR body.

### Usage-cap exhaustion (recoverable pause)

If you hit a usage / quota cap mid-implementation (e.g. "out of extra usage · resets <time>"), treat it as a recoverable PAUSE, not an error:

1. Push whatever in-progress work is committable (commit the partial diff so the next agent can resume).
2. Comment on the issue: `gh issue comment <N> --body 'Claude: Paused — usage cap, resumes <reset-time>. Branch: <branch-name>'`
3. Apply `paused` and remove `in-progress`:

       gh issue edit <N> --add-label paused --remove-label in-progress

4. Return `PAUSED <N> usage cap until <time>`.

The orchestrator can re-dispatch with a resumption prompt (Phase 5 step 0) once the cap clears.

## Output

Return EXACTLY ONE of these strings, ONCE, at the very end. Do not narrate progress — any non-structured text is interpreted by the orchestrator as a premature exit.

- `AUTOMERGE_SET <pr-url>` — merge handoff complete (label applied or native automerge set per the `Merge mechanism:` observation), no findings outstanding, CI green or in flight. The orchestrator's Phase 5b shell monitor takes over and drives the PR to merge. **This is the default success exit.**
- `MERGED <pr-url>` — PR has actually merged. Possible when automerge isn't enabled and you fell back to `gh pr merge --squash`, or when the PR merged synchronously between you handing off and exiting.
- `BLOCKED <N> <question>` — parked on a public-break ambiguity awaiting clarification.
- `PAUSED <N> <reason>` — environmentally paused (usage cap, infra outage). Orchestrator may re-dispatch when the condition clears.
- `ERRORED <N> <error>` — non-recoverable failure.

If you find yourself thinking "the review is done, I should report back" — don't. The review is the *start* of the merge loop, not the end. If you find yourself thinking "I should poll until the PR merges" — don't. Setting automerge is the end of your job; Phase 5b owns the rest.
```

## Phase 5b — Post-automerge monitoring

Once an implementing agent returns `AUTOMERGE_SET <pr-url>`, the orchestrator owns the PR until merge. The goal is to spend as few tokens as possible on the wait-for-CI / wait-for-automerge tail without giving up the ability to recover from `BEHIND`, conflicts, CI failures, or new review comments.

### Trade-off rationale (why a shell monitor + mini-agents, not a warm agent)

The previous design kept the implementing agent warm through the entire wait-for-merge tail — burning hundreds of thousands of tokens per PR on polling that an LLM adds no value to. The current design swaps that warm agent for a thin shell monitor for the trivial cases (`BEHIND` auto-merge, `MERGED` detection, `green + waiting` no-op), escalating to a focused mini-agent only when the monitor sees something requiring judgment (`CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`).

Each escalation pays a cold-start cost (~30–50k tokens loading project conventions). A PR with 3 escalations during its life pays 3× that. The always-warm-agent approach paid that cost once but spent ~400k tokens monitoring. The crossover is around 6–8 escalations per PR, which essentially never happens for normal PRs. So the thin-monitor approach wins for the realistic distribution (most PRs: 0–2 escalations); the always-warm approach is only better for pathological PRs.

The other resilience win: a crashed monitor doesn't lose pipeline state — it just stops polling, and the orchestrator can relaunch it. A crashed always-warm agent loses the entire PR's monitoring state and may not resume cleanly. **If the workload distribution shifts (e.g. a project where most PRs hit 5+ conflicts) re-evaluate this split — the crossover point is the relevant signal.**

### Handoff

When step 4 of the Phase 5 execution loop receives `AUTOMERGE_SET <pr-url>` from a dispatched agent:

1. Mark the issue as `automerge_set` in internal state (the slot is free; `in-flight` count drops).
2. Launch the **shell monitor** (below) for that PR via the `Monitor` tool. The monitor's stdout is an event stream the orchestrator consumes.
3. Continue the Phase 5 execution loop — pick up the next eligible issue.

### Shell monitor recipe

The monitor is a single bash script. Stdout lines are events; the orchestrator routes each event line to the appropriate handler. Stderr is for the script's own diagnostics (logged but not interpreted as events).

Save as `monitor-pr.sh` (or paste inline into the `Monitor` tool's command — both work). Invocation: `monitor-pr.sh <pr#> <pr-branch> <repo-base-branch>` (e.g. `monitor-pr.sh 451 aidanns/foo-fix main`).

```bash
#!/usr/bin/env bash
#
# Phase 5b shell monitor: drive a PR to merge, escalating to mini-agents on judgment cases.
#
set -uo pipefail  # NOT -e: a single failed gh call shouldn't kill the loop.

pr="${1:?pr number required}"
branch="${2:?pr branch required}"
base="${3:-main}"
poll="${POLL_INTERVAL:-45}"  # seconds between polls.

emit() { printf '%s\n' "$*"; }  # one event per line, line-buffered by default.

# Track which CI failures and review comments we've already escalated, so we
# don't re-emit on every tick.
seen_failures=""   # space-separated run IDs.
seen_comments=""   # space-separated comment IDs.

while :; do
  state_json=$(gh pr view "$pr" --json state,url,mergeable,mergeStateStatus,statusCheckRollup,headRefOid 2>/dev/null || true)
  if [[ -z "$state_json" ]]; then
    # Transient network blip — sleep and retry without crashing.
    sleep "$poll"; continue
  fi

  state=$(jq -r '.state' <<<"$state_json")
  url=$(jq -r '.url' <<<"$state_json")
  mergeable=$(jq -r '.mergeable' <<<"$state_json")
  msstatus=$(jq -r '.mergeStateStatus' <<<"$state_json")

  # ---- Terminal: PR merged. Emit and exit. ----
  if [[ "$state" == "MERGED" ]]; then
    emit "MERGED $url"
    exit 0
  fi
  if [[ "$state" == "CLOSED" ]]; then
    emit "CLOSED $url"  # PR was closed without merging — orchestrator decides.
    exit 0
  fi

  # ---- BEHIND + MERGEABLE: auto-resolve in-shell (no LLM). ----
  # Automerge does NOT auto-update behind branches. We catch it up locally.
  if [[ "$msstatus" == "BEHIND" && "$mergeable" != "CONFLICTING" ]]; then
    (
      tmpdir=$(mktemp -d)
      cd "$tmpdir"
      gh repo clone "$(gh repo view --json nameWithOwner -q .nameWithOwner)" repo -- --branch "$branch" --depth 50 >/dev/null 2>&1 || exit 0
      cd repo
      git fetch origin "$base" >/dev/null 2>&1 || exit 0
      if git merge --no-edit "origin/$base" >/dev/null 2>&1; then
        git push origin "$branch" >/dev/null 2>&1 || true
        emit "BEHIND_RESOLVED $pr"
      else
        # The merge produced conflicts — escalate via the CONFLICT path below
        # on the next tick (don't double-emit here).
        git merge --abort >/dev/null 2>&1 || true
      fi
      rm -rf "$tmpdir"
    )
  fi

  # ---- DIRTY / CONFLICTING: escalate to conflict-resolution mini-agent. ----
  if [[ "$mergeable" == "CONFLICTING" || "$msstatus" == "DIRTY" ]]; then
    files=$(gh pr view "$pr" --json files --jq '[.files[].path] | join(",")' 2>/dev/null || echo "")
    emit "CONFLICT $pr $branch $base $files"
    # Sleep longer after escalating — give the mini-agent time to push a fix
    # before we re-detect the same conflict.
    sleep $((poll * 4)); continue
  fi

  # ---- CI failure: escalate per failing check (deduplicated by run ID). ----
  while read -r failure; do
    [[ -z "$failure" ]] && continue
    run_id=$(jq -r '.databaseId' <<<"$failure")
    name=$(jq -r '.name' <<<"$failure")
    if [[ -n "$run_id" && "$run_id" != "null" && " $seen_failures " != *" $run_id "* ]]; then
      emit "CI_FAILURE $pr $name $run_id"
      seen_failures="$seen_failures $run_id"
    fi
  done < <(jq -c '.statusCheckRollup[]? | select(.conclusion == "FAILURE")' <<<"$state_json")

  # ---- New top-level review comment from a non-bot reviewer: escalate. ----
  while read -r comment; do
    [[ -z "$comment" ]] && continue
    cid=$(jq -r '.id' <<<"$comment")
    if [[ -n "$cid" && "$cid" != "null" && " $seen_comments " != *" $cid "* ]]; then
      emit "NEW_COMMENT $pr $cid"
      seen_comments="$seen_comments $cid"
    fi
  done < <(
    gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate 2>/dev/null \
      | jq -c '.[]? | select(.in_reply_to_id == null)
                    | select((.user.type // "User") != "Bot")
                    | select((.body // "") | startswith("Claude") | not)'
  )

  sleep "$poll"
done
```

Key behaviours:

- **`BEHIND` auto-resolution stays in-shell.** Uses the same local-merge approach the implementing agent uses (`git fetch origin main && git merge --no-edit origin/main && git push`) — no `update-branch` API call, consistent with the rest of this skill.
- **Transient `gh` failures** (network blips, rate-limit retries) don't crash the loop — `|| true` and an empty-result check keep polling.
- **Deduplication** — failing run IDs and review comment IDs are tracked, so a persistent failure escalates exactly once per ID, not on every tick.
- **`Claude` -prefixed comments are skipped** so the monitor doesn't re-escalate on the implementing agent's or reviewer subagent's own comments.

### Orchestrator event routing

The `Monitor` tool surfaces each stdout line of `monitor-pr.sh` as a notification. The orchestrator routes events as follows:

| Event line | Orchestrator action |
|---|---|
| `MERGED <pr-url>` | Mark issue task `completed`. Stop the monitor. Trigger Phase 6 housekeeping. |
| `CLOSED <pr-url>` | Surface to user — PR was closed without merging. Stop the monitor. |
| `BEHIND_RESOLVED <pr#>` | Log only. Refresh the next progress digest. |
| `CONFLICT <pr#> <branch> <base> <files>` | Dispatch the **conflict-resolution mini-agent** (template below). |
| `CI_FAILURE <pr#> <check> <run-id>` | Dispatch the **CI-failure-fix mini-agent** (template below). |
| `NEW_COMMENT <pr#> <comment-id>` | Dispatch the **review-comment mini-agent** (template below). |

Mini-agents run in their own isolated worktrees with `run_in_background: true`. They do **not** count against the implementing-agent concurrency cap of 3 — they're focused, short-lived, and are part of a PR that has already cleared the implementing-agent slot. (Cap them informally if you observe contention; defer formal limits until needed.)

When a dispatched mini-agent returns `RESOLVED` / `FIXED` / `ADDRESSED`, the shell monitor — still polling — will eventually observe the underlying state has cleared (conflict gone, CI green, comment threaded) and stop emitting that event. If a mini-agent returns `BLOCKED <question>` or `ENVIRONMENTAL <reason>`, the orchestrator surfaces it to the user and may stop the monitor (treat the PR as parked, just like a `BLOCKED` from the implementing agent).

### Mini-agent dispatch templates

These are intentionally tighter than the main dispatch template — no full pipeline scaffolding, no plan step, no review subagent. Each is a focused prompt for a single narrow job. Project conventions are still consulted (the agent reads `CLAUDE.md` if it has to commit), but the prompt does not re-embed them in full.

#### Conflict-resolution mini-agent

```
You are resolving a merge conflict on PR #<pr#> in <repo>. Branch: `<branch>`. Base: `<base>`. Conflicting files (best estimate): <files>.

You run in an isolated worktree (`isolation: worktree`). Your first command is, verbatim:

  git fetch origin && git checkout <branch> && git pull && git merge origin/<base>

This WILL produce conflict markers — that is expected. Do not try to "fix" anything before reproducing the conflict locally. If the merge unexpectedly succeeds (someone else resolved it), push and return `RESOLVED`.

Resolve the conflicts minimally:

- Keep the intent of both sides where possible.
- Prefer the side that clearly supersedes if one is newer / more correct.
- Read `CLAUDE.md` only if the conflict is in code where project conventions matter (e.g. naming, file layout). Skip otherwise.
- Run the project's check task (`task check`, `scripts/lint.sh`, `npm test`, etc.) if there's an obvious one — skip if not.
- Commit the merge with a conventional-commits message: `chore(merge): resolve conflicts with <base>`.
- Push.

Return EXACTLY ONE of:
- `RESOLVED <pr-url>` — merge committed and pushed.
- `BLOCKED <question>` — the conflict requires a public-break decision (e.g. two competing API shapes). Comment on the PR with `Claude: Blocked — <question>` first.
- `ERRORED <reason>` — non-recoverable.
```

#### CI-failure-fix mini-agent

```
You are fixing a CI failure on PR #<pr#> in <repo>. Failing check: `<check>`. Run ID: <run-id>. Branch: `<branch>`.

You run in an isolated worktree (`isolation: worktree`). Check out the PR branch:

  gh pr checkout <pr#>

<if the orchestrator's Phase 1 auto-memory sweep returned hits:
Known-broken CI / manual workarounds in this project (swept from `~/.claude/projects/<slug>/memory/`):
- <verbatim body of each matched memory entry, separated by `---`>
If the failing check matches one of these, follow the documented workaround instead of trying to fix the underlying check.>

Pipeline:

1. Read the failure logs: `gh run view <run-id> --log-failed`.
2. Diagnose the root cause. Do NOT bypass the check, disable it, or retry blindly.
3. **A check passing 'success' isn't the same as the check doing its job.** If the failing check depends on an upstream artifact (e.g. `changelog-lint` failing because no `pr-<N>-*.yml` exists), look at the upstream workflow's logs for `secrets not configured`-style notices before concluding it's a real failure.
4. Fix the root cause. Commit with a conventional-commits message referencing the failing check (e.g. `fix(ci): correct lint config for <check>`).
5. `git pull --rebase origin <branch>` then `git push`.

Return EXACTLY ONE of:
- `FIXED <pr-url>` — fix pushed.
- `BLOCKED <question>` — fixing requires a public-break decision. Comment on the PR with `Claude: Blocked — <question>` first.
- `ENVIRONMENTAL <reason>` — failure is infra / rate-limit / unrelated to the diff. Comment on the PR with `Claude: <reason>` and exit; do NOT retry.
- `ERRORED <reason>` — non-recoverable.
```

#### Review-comment mini-agent

```
You are addressing a review comment on PR #<pr#> in <repo>. Comment ID: <comment-id>.

You run in an isolated worktree (`isolation: worktree`). Check out the PR branch:

  gh pr checkout <pr#>

Pipeline:

1. Read the comment:

     gh api 'repos/{owner}/{repo}/pulls/comments/<comment-id>'

2. Make the requested change, OR document why the suggestion shouldn't be adopted.
3. Commit with a conventional-commits message describing the change.
4. `git pull --rebase origin <branch>` then `git push`.
5. Reply to the comment thread:

     gh api --method POST 'repos/{owner}/{repo}/pulls/<pr#>/comments/<comment-id>/replies' \
       -f body='Claude: Done!'  (or `Claude: <one-line explanation of the alternative approach>`)

Return EXACTLY ONE of:
- `ADDRESSED <pr-url>` — change pushed and reply posted.
- `BLOCKED <question>` — the suggestion requires a public-break decision. Comment on the PR with `Claude: Blocked — <question>` first.
- `ERRORED <reason>` — non-recoverable.
```

## Phase 6 — Post-completion housekeeping

When the orchestrator detects a merged PR (via Phase 5 monitoring):

- Confirm the issue closed (`gh issue view <n> --json state` should report `CLOSED`). **If still OPEN, close manually:**

  ```bash
  gh issue close <n> --comment "Closed by merge of PR #<P> (squash commit <sha>). Auto-close didn't fire — closing manually."
  ```

  GitHub's auto-close-on-`Closes #N` is unreliable for App-token-mediated API merges (observed in repos using a merge-bot pattern with bypass-actor App tokens). Don't wait for it; verify and close yourself.
- The `in-progress` label persists on the closed issue (intentional — preserves audit trail).
- Update internal state; pick up the next eligible issue.

## Phase 7 — Block handling

When an agent reports `BLOCKED`:

- Verify the `blocked` label is set on the issue and the issue has a `Claude: Blocked` comment.
- Record the question in a parked-questions list (in-memory; optionally write to `.claude/work-issues-state.json` for resumability).
- Continue with other ready issues.

When the loop drains (no more eligible issues, in-flight count = 0):

1. Compile parked questions into ONE batched message to user, numbered and grouped by issue.
2. Wait for answers.
3. After answers: update affected issue bodies via `gh issue edit <n> --body`, remove `blocked` labels, restart agents on those issues. Re-enter Phase 5.

## Phase 8 — Completion

Final report to user:

- N issues processed: X merged, Y parked, Z excluded.
- Links to merged PRs.
- Outstanding parked questions (if any) — `blocked` label remains, awaiting attention.
- Suggested next step: `/work-issues --label blocked` to resume parked issues after answering.

## Bail-outs (stop the entire run)

The skill stops the run rather than parking when:

- The user-provided selector resolves to zero issues.
- The repo's default-branch ruleset rejects merges persistently across 3+ retries (likely environmental).
- A dispatched agent reports a *non-recoverable* environmental error (cannot clone, cannot authenticate, missing required CLI tool).
- The dependency graph contains a cycle.

In each case: leave labels as-is, surface immediately to user, do not proceed.

**Recoverable** environmental conditions are NOT bail-outs:

- **Usage-cap exhaustion**: agent returns `PAUSED`. Orchestrator records the reset time and re-dispatches a resumption agent (Phase 5 step 0 path) once the cap clears.
- **Transient CI infra blips** (one-off rate limits, single workflow timeout): agent investigates per step 8 and pushes a fix or surfaces to the user; this is not a run-wide halt.

## State persistence

For runs that may span context windows, persist minimal state at `.claude/work-issues-state.json` in the project root:

```json
{
  "in_scope": [280, 281, 282, 283, 284],
  "merged": [280],
  "automerge_set": {"281": "https://github.com/o/r/pull/91"},
  "in_progress": [282],
  "blocked": {"283": "needs schema decision"},
  "paused": {"284": "usage cap until 2026-04-25T10:10Z"},
  "deps": {"281": [280], "282": [280]}
}
```

The `automerge_set` map tracks PRs handed off to Phase 5b's shell monitor; entries clear when the monitor emits `MERGED`.

Read on start (if present, resume); write on every label change. Delete on Phase 8 completion.

## Tracker abstraction

This skill is gh-specific. To extend to another tracker (Linear, Jira, etc.) the following operations need an adapter:

| Operation | gh today |
|---|---|
| List by selector | `gh issue list / gh api` |
| Read body | `gh issue view <n> --json body` |
| Update body | `gh issue edit <n> --body` |
| Add/remove labels | `gh issue edit <n> --add-label / --remove-label` |
| Comment | `gh issue comment <n>` |
| Native sub-issue / dep primitive | `gh api repos/.../issues/<n>/sub_issues` |
| Hand off to merge | `gh pr merge <n> --auto --squash` (native) or `gh pr edit <n> --add-label <bot-label>` (label-triggered merge-bot — see Phase 1.5 detection) |
| Check CI | `gh pr checks <n>` / `gh pr view --json statusCheckRollup` |
| List PR review comments | `gh api repos/.../pulls/<n>/comments` |
| Reply to review comment | `gh api --method POST repos/.../pulls/<n>/comments/<id>/replies` |

When extending: copy this skill, swap the operations table for the new tracker, document the equivalent label semantics. Don't abstract into a runtime adapter until at least two trackers actually need it.
