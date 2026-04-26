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
- **Concurrency cap: 3.** Three agents in flight at once. "In flight" = actively implementing or addressing review. An agent that has set automerge and returned `MERGED-PENDING` does not count toward the cap — the orchestrator monitors the merge from there.

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
- Branch name: `<author>/<short-slug>` if the project's recently-merged PRs show a different convention; otherwise default to `<username>/<short-slug>` where `<username>` is the GitHub login of the authenticated user (`gh api user --jq .login`). The slug is a 2-4 word description of the change.
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
- **DCO sign-off**: every commit needs `Signed-off-by:` if the project has a DCO check (`git commit -s` or `git config --local format.signoff true`).
- **Comment reply prefix**:
  - Implementing agent: `Claude: `
  - Independent code-review subagent: `Claude Reviewer: `

### CI discipline

- Read failure logs before acting (`gh run view <run-id> --log-failed`).
- Fix the root cause; don't pin around it, disable the check, or retry blindly.
- Environmental / flaky failures (infra outage, rate limit, unrelated to this PR's diff) get reported but not retried — surface the issue rather than re-running.

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

Compile observations into a "Current PR conventions (observed)" block and inject it into every dispatched agent's prompt — this beats relying on `CLAUDE.md` being current.

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
- On `MERGED-PENDING`: leave the task `in_progress`; flip to `completed` when the orchestrator's monitor confirms the merge.
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

3. **Dispatch agent** with `isolation: worktree`, `run_in_background: true`. Use the **dispatch prompt template** below.

4. **Monitor** — Claude Code notifies the orchestrator when each background agent completes. On notification:
   - **MERGED**: GitHub closed the issue via `Closes #<n>`. Mark task done; pick up the next eligible issue.
   - **MERGED-PENDING**: agent set automerge and exited. Slot is now free — pick up the next eligible issue. The orchestrator schedules a wakeup (`ScheduleWakeup` ~270s) to poll PR state until merged. On `BEHIND`: `gh api --method PUT 'repos/.../pulls/<pr#>/update-branch'`. On new CI failures: investigate (don't bypass) and either fix locally or re-dispatch a small fix-up agent.
   - **BLOCKED**: ensure `blocked` label set, `in-progress` removed; record the question for batched surfacing in Phase 7.
   - **PAUSED**: ensure `paused` (or `blocked`) label is set; record the reset time. Re-dispatch a resumption agent (Phase 5 step 0 path) after the condition clears.
   - **ERRORED**: surface immediately to user; do not retry without instruction.

5. **Continue** until all terminal.

### Progress reporting

The TaskCreate list (Phase 4) is the durable surface. Augment it with a chat-visible digest so the user sees PR links, review status, and CI state without polling GitHub themselves. Keep digests terse — one line per in-flight issue, no headers, no surrounding narration.

**Cadence:**

- On every orchestrator wakeup tick (~270s) while at least one issue is in-flight (`in-progress` or `merge_pending`). Schedule a recurring `ScheduleWakeup(delaySeconds: 270)` whenever the in-flight count > 0 and no wakeup is already pending.
- Immediately on every dispatched-agent terminal return (`MERGED`, `MERGED-PENDING`, `BLOCKED`, `PAUSED`, `ERRORED`) — emit a digest of the remaining in-flight set so the user sees the new state without waiting for the next tick.

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

4. **Merge state** — `mergeable` + `mergeStateStatus` from the same `gh pr list` query (the dispatch pipeline already has remediation logic for the non-clean cases in step 10 — this signal just surfaces them to the user):

   - `mergeable == "CONFLICTING"` or `mergeStateStatus == "DIRTY"` → `merge: conflict`. The dispatched agent (or its post-merge monitor) will resolve via the merge-conflict path in step 10; surfacing it here means the user notices before then if a conflict has sat unresolved across ticks.
   - `mergeStateStatus == "BEHIND"` → `merge: behind`. Auto-resolvable via `update-branch`; usually transient.
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

<if any deps merged: Dependency context — these issues already merged and may have introduced helpers / types / files you should reuse:
- #<dep>: <PR title>. Summary: <one-line summary of what merged>.>

## Pipeline

You run in an isolated worktree (Claude Code's `isolation: worktree` already created it). Confirm with `git status` and `pwd`. Branch off latest `main`:

  git fetch origin main && git reset --hard origin/main
  git checkout -b <branch-name>

Branch naming: detect the project's convention from recent merged PRs (`gh pr list --state merged --limit 10 --json headRefName --jq '.[].headRefName'`) and follow it if there's a clear pattern. Otherwise default to `<username>/<short-slug>`, where `<username>` is the authenticated user (`gh api user --jq .login`) and `<short-slug>` is a 2-4 word description of the change.

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

### 6. Code-review subagent

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

Wait for it to complete.

### 7. Address review comments

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

### 8. Address CI failures

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

### 9. Set automerge and hand off

Once review comments are addressed AND CI is green:

  gh pr merge <pr#> --auto --squash

The merge happens automatically once all required checks pass.

**Default: hand off to the orchestrator now.** Return `MERGED-PENDING <pr-url>` and exit. The orchestrator monitors the merge from here (handles `BEHIND`, conflict resolution, and final merge confirmation). This frees your slot for the next issue ~10 minutes sooner per PR.

Only continue to step 10 if the orchestrator's dispatch prompt explicitly told you to "stay alive through merge."

### 10. (Optional) Monitor until merged

If asked to stay through merge, loop every ~5 minutes:

  sleep 270
  gh pr view <pr#> --json state,mergeable,mergeStateStatus,statusCheckRollup

**Stay silent in the loop.** Do NOT emit text or schedule a new turn between polls — only output your structured return ONCE, when `state == "MERGED"`. Narrating progress between polls breaks the structured-output contract; the orchestrator interprets any non-structured text as a premature exit.

Until merged:

- **`mergeStateStatus == "BEHIND"`**: GitHub auto-merge waits when the branch is behind base. Re-fire CI on a fresh merge commit:

      gh api --method PUT 'repos/{owner}/{repo}/pulls/<pr#>/update-branch'

  Same one-shot remedy used in step 8 — merges base in via the API and re-fires every workflow on the new SHA.

- **Merge conflict** (`mergeStateStatus == "DIRTY"` or `mergeable == "CONFLICTING"`):
  - `git fetch origin <base>`.
  - `git merge origin/<base>` (prefer merge over rebase on review branches — preserves review history).
  - Resolve conflicts minimally; keep the intent of both sides unless one clearly supersedes.
  - Run the project's check task (`task check`, `scripts/lint.sh`, `npm test`, etc.) to confirm.
  - Commit the merge, push.

- **CI failure after automerge**: investigate per step 8, push fix.

When `state == "MERGED"`: return `MERGED <pr-url>`. The worktree is automatically cleaned up by `isolation: worktree`.

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
3. Apply `paused` (or `blocked` if no `paused` label exists) and remove `in-progress`:

       gh issue edit <N> --add-label paused --remove-label in-progress

4. Return `PAUSED <N> usage cap until <time>`.

The orchestrator can re-dispatch with a resumption prompt (Phase 5 step 0) once the cap clears.

## Output

Return EXACTLY ONE of these strings, ONCE, at the very end. Do not narrate progress between polls — any non-structured text is interpreted by the orchestrator as a premature exit.

- `MERGED <pr-url>` — PR has actually merged.
- `MERGED-PENDING <pr-url>` — automerge is set, no findings outstanding, CI green or in flight. Orchestrator monitors the merge from here.
- `BLOCKED <N> <question>` — parked on a public-break ambiguity awaiting clarification.
- `PAUSED <N> <reason>` — environmentally paused (usage cap, infra outage). Orchestrator may re-dispatch when the condition clears.
- `ERRORED <N> <error>` — non-recoverable failure.
```

## Phase 6 — Post-completion housekeeping

When the orchestrator detects a merged PR (via Phase 5 monitoring):

- Confirm the issue closed (`gh issue view <n> --json state` should report `CLOSED`).
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
  "merge_pending": {"281": "https://github.com/o/r/pull/91"},
  "in_progress": [282],
  "blocked": {"283": "needs schema decision"},
  "paused": {"284": "usage cap until 2026-04-25T10:10Z"},
  "deps": {"281": [280], "282": [280]}
}
```

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
| Set automerge | `gh pr merge <n> --auto --squash` |
| Check CI | `gh pr checks <n>` / `gh pr view --json statusCheckRollup` |
| List PR review comments | `gh api repos/.../pulls/<n>/comments` |
| Reply to review comment | `gh api --method POST repos/.../pulls/<n>/comments/<id>/replies` |

When extending: copy this skill, swap the operations table for the new tracker, document the equivalent label semantics. Don't abstract into a runtime adapter until at least two trackers actually need it.
