---
name: implement
description: Process one or more GitHub issues end-to-end through implementation and merge. Triggered by /workflow:implement with optional args (issue numbers, --label, --milestone, --parent). Self-contained orchestration — embeds the full work pipeline (worktree, plan, PR, self-review, code-review subagent, CI babysitting, automerge) so it works without project-specific CLAUDE.md scaffolding. Defaults: 3 concurrent agents, park-and-continue on blockers, sequential dependency-aware execution.
---

# implement

Take one or more GitHub issues from intake to merge in a self-managing loop. Invoke when stepping away while several issues land.

The skill is self-contained: every dispatched agent receives the full work pipeline in its prompt, so it does not require the host project's `CLAUDE.md` to define the workflow. Project-level docs (`CLAUDE.md`, `.claude/instructions/*.md`, `CONTRIBUTING.md`) are consulted by the agent for project-specific conventions (language, tooling, commit-message scopes), but the orchestration logic and PR pipeline are defined here.

## Invocation

`/workflow:implement [<args>]`

| Form | Behaviour |
|---|---|
| `/workflow:implement 280 281 282` | Process the listed issues. |
| `/workflow:implement --label <name>` | Process all open issues carrying the label. |
| `/workflow:implement --milestone "<title>"` | Process all open issues in the milestone. |
| `/workflow:implement --parent <n>` | Process all sub-issues of the parent issue. |
| `/workflow:implement` | Default: equivalent to `--label scheduled`. |

Selectors compose: `/workflow:implement --milestone "MS-2 General" --label scheduled` intersects them.

## Operating principles

- **Sequential phases.** Don't skip; if a phase yields no work, log and continue.
- **Park, don't block.** A blocker on issue A never stops independent issues B and C.
- **Public-break = blocker, internal = self-resolve.** Anything that would change a publicly-observable surface (API shape, file path, schema, naming convention, semver bump) is a blocker requiring user clarification. CI/security config paths (`.github/`, branch-protection rulesets, `SECURITY.md`, lockfile pinning rules, build-system config) are also blockers — see the dispatch template's "Blocker handling" section for the full enumeration. Internal implementation choices the agent makes itself with a one-line justification in the PR body.
- **Strict isolation.** Every dispatched agent runs with `isolation: worktree`. No file-state collisions.
- **Best-effort context sharing.** When B declares a dependency on A and A has merged, B's dispatch prompt includes A's PR summary and any new types/helpers A introduced. Independent issues start cold.
- **Concurrency cap: 3.** Three agents in flight at once. "In flight" = actively implementing or addressing review. An agent that has set automerge and returned `AUTOMERGE_SET` does not count toward the cap — the orchestrator's shell monitor (Phase 5b) drives the PR to merge from there, escalating to focused mini-agents only when judgment is required.
- **Drop the cap to 1 on hot-main / shared-path batches.** The default of 3 assumes the in-flight PRs touch independent code paths, so each merges cleanly without disturbing the others. If the in-scope PRs all touch release-relevant or shared paths (anything that triggers a release-PR refresh, version-file edits, lockfile updates, or the same hot file), or the project's `main` is observed to move more than ~2 commits during a typical PR's CI cycle, run with concurrency cap = 1 (serial dispatch) instead. The failure mode to recognise: a release-PR refresh loop where every merge to `main` fires another release-PR update that itself moves `main` again, leaving each in-flight PR stuck cycling through `BEHIND → resolve → CI re-run (~5–10 min) → still BEHIND because main moved again`. With cap > 1, the *last* PR pays for `n−1` CI cycles as `main` moves underneath it; with cap = 1, each PR pays for exactly one CI cycle. Keep the default at 3 — for independent code paths the parallel default is the right call; this is a hint for the specific distribution.

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
- After merge, the orchestrator removes the worktree in Phase 6 (see `/close-worktree`). The auto-clean behavior of `isolation: worktree` only fires when the agent made no changes — which is never the case for a successful run — so explicit cleanup is required.

### Issue label lifecycle

- **`scheduled`**: applied at intake (Phase 4) for every in-scope issue.
- **`in-progress`**: applied when an agent picks up the issue (Phase 5, immediately after worktree creation). Persists through PR creation, review, automerge-set, and merge confirmation. Only swapped out on `BLOCKED` (→ `blocked`) or `PAUSED` (→ `paused`). On merge, the label remains on the closed issue as the audit trail.
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

**CWD discipline — prefer absolute paths and `--repo <owner>/<repo>` over CWD-derived defaults.** A stranded CWD (the bash session sitting in a directory that has been moved or deleted) is a classic source of opaque `git`/`gh` errors — typically `git: fatal: unknown error occurred while reading the configuration files` or similar. The Phase 6 worktree removal is the most common trigger (the orchestrator may have `cd`'d into the worktree earlier to push an empty commit, manually resolve `BEHIND`, or check git state, and the cleanup then deletes that directory under it), but anything that moves or removes a directory the bash session is sitting in produces the same failure mode. Two-pronged defence: (a) Phase 6 step 3 ends with a `cd` back to the repo root so the next command lands in a known-good CWD, and (b) the orchestrator should otherwise prefer absolute paths and explicit `--repo <owner>/<repo>` flags on `gh` calls — and `git -C <abs-path>` for `git` — rather than relying on CWD-derived defaults, so a stranded CWD degrades gracefully instead of producing cryptic errors.

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

`CLAUDE.md` can lag behind reality — new conventions ship on main before the doc gets updated. Before dispatching, snapshot what the most recent merged PRs actually do by running the helper script colocated with this skill:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/phase15-conventions.sh" <owner/repo>
```

The script is the canonical implementation of this phase — it reads the 5 most recent merged PRs, computes a deterministic "Current PR conventions (observed)" block, and prints it on stdout. The orchestrator embeds that stdout *verbatim* into every dispatched agent's prompt (see the `Current PR conventions (observed)` placeholder in the dispatch template). Running the script once per orchestrator invocation (rather than re-inferring the conventions from raw PR-body JSON on each dispatch) saves ~5–10K tokens per run and guarantees byte-identical conventions across parallel dispatches.

The emitted block surfaces:

- **Title prefix style** — most-frequent leading token (`feat:`, `fix:`, `feature:`, `chore:` …) plus 2-3 sample titles, captured from the recent merged PRs.
- **Title length limit** — defaults to ≤72 chars; overridden if a commit-message-lint config in the repo (`.github/workflows/commit*lint*.yml`, `commitlint.config.*`, `.commitlintrc.*`) declares a different `subject-max-length`.
- **`==COMMIT_MSG==` block** — required / optional / not used, based on how many recent merged PR bodies wrap their commit message in that block. The same logic generalises to whatever named-block convention surfaces in the sample.
- **Labels at merge time** — a histogram of every label seen across the sample (label → `<n>/<sample-size>`), so the dispatched agent can spot consistently-applied ones (`automerge`, `no changelog`, etc.).
- **Manual changelog entries** — required / occasional / not observed, computed from how many recent PRs touched a `changelog/@unreleased/pr-<N>-<slug>.yml` file.
- **Merge mechanism** — emitted as the `Merge mechanism:` trailer. Sub-step 6.4 of the dispatch template parses this line. Two-signal heuristic (preserved verbatim from the prior prose): (1) a workflow that listens to `pull_request: types: [labeled]` with a label-name guard, (2) that label appearing on at least half of the recent merged PRs. If both signals agree, the value is `apply <label> label (merge-bot picks it up)`; otherwise the default is `gh pr merge --auto --squash` (native auto-merge).

If the helper script is unavailable for any reason (e.g. the plugin install is corrupted), the orchestrator can fall back to running the steps inline — but treat that as a degraded path and flag it. The script's output is the contract; sub-step 6.4 of the dispatch template depends on the `Merge mechanism:` trailer being present.

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

When dependencies are declared (e.g. `Depends on #N`), encode them via `addBlockedBy` on the corresponding TaskCreate task (Phase 4) so the harness's native dep tracking surfaces blocked / unblocked transitions in the task list rather than relying on a manually-maintained graph.

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

- On dispatch (Phase 5 step 2): `TaskUpdate(status: "in_progress")` — issued as a **standalone tool call**, not bundled with the `gh issue edit` label flip or the `Agent` dispatch. See Phase 5 step 2 and the "Why standalone TaskUpdate" note in Phase 6 for the cancellation hazard.
- On `MERGED` notification (Phase 5 step 5): `TaskUpdate(status: "completed")` — issued as a **standalone tool call** in Phase 6 step 1, not bundled with the worktree / pull / label cleanup. Same reasoning.
- On `AUTOMERGE_SET`: leave the task `in_progress`; flip to `completed` when the Phase 5b shell monitor emits `MERGED`.
- On `BLOCKED` / `PAUSED`: leave `in_progress`; update the task `description` with the parked question / pause reason so the task list surfaces *why* it is parked, not just that it is.

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

2. **Flip the task to `in_progress` — as a standalone tool call, not bundled with any other tool call.**

   ```text
   TaskUpdate(taskId: <task-id>, status: "in_progress")
   ```

   This MUST be its own tool-call group. Do not parallelise it with the `gh issue edit` call in step 3 or with the `Agent` dispatch in step 4. Same reasoning as Phase 6 step 1 — see "Why standalone TaskUpdate" at the end of Phase 6 for the cancellation hazard.

3. **Mark in-progress on the issue** (separate tool-call group from step 2):

   ```bash
   gh issue edit <n> --add-label in-progress --remove-label scheduled
   ```

3a. **Pre-dispatch stale-path scan** — applies *only* to issues whose declared deps merged after Phase 1 intake (i.e. mid-run). Skip otherwise.

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

4. **Dispatch agent** with `isolation: worktree`, `run_in_background: true`. Use the **dispatch prompt template** below. This is its own tool-call group — do not parallelise the `Agent` call with the `TaskUpdate` from step 2 or the `gh issue edit` from step 3.

5. **Monitor** — Claude Code notifies the orchestrator when each background agent completes. On notification:
   - **MERGED**: GitHub closed the issue via `Closes #<n>`. Mark task done; pick up the next eligible issue. Do **not** fire a `PushNotification` — heartbeat-grade once the TaskList badge flips to `completed`.
   - **AUTOMERGE_SET**: agent set automerge and exited. Slot is now free — pick up the next eligible issue. The orchestrator hands off to **Phase 5b** (post-automerge monitoring): a thin shell monitor polls the PR; auto-resolves `BEHIND` in-shell; emits events that the orchestrator routes to focused mini-agents for `CONFLICT` / `CI_FAILURE` / `NEW_COMMENT`; exits on `MERGED`. **Review-fallback check:** if the PR body contains a `### Self-review only` section (the implementing agent's harness lacked the `Task` / `general-purpose` subagent type), dispatch a separate review subagent at the orchestrator level *before* the merge lands. Use the same review prompt the dispatch template's 6.1 would have used and treat its output as a normal review pass — any findings flow back to the PR via inline `Claude Reviewer: ` comments and the Phase 5b monitor's `NEW_COMMENT` event will route them to the review-comment mini-agent. Do **not** fire a `PushNotification` — the slot-free transition is heartbeat-grade once the TaskList badge conveys it.
   - **BLOCKED**: ensure `blocked` label set, `in-progress` removed; record the question for batched surfacing in Phase 7. Fire one `PushNotification` summarising the parked issue and question — e.g. `PushNotification(message: "/implement: #<n> blocked — <question>")`. This is a terminal handoff back to the user; the OS notification is the bell that "user action needed" wants.
   - **PAUSED**: ensure `paused` (or `blocked`) label is set; record the reset time. Re-dispatch a resumption agent (Phase 5 step 0 path) after the condition clears. Fire one `PushNotification` summarising the pause — e.g. `PushNotification(message: "/implement: #<n> paused — <reason>")`. Same rationale as `BLOCKED`.
   - **ERRORED**: surface immediately to user; do not retry without instruction. Fire one `PushNotification` summarising the error — e.g. `PushNotification(message: "/implement: #<n> errored — <error>")`. Same rationale as `BLOCKED`.
   - **Malformed terminal (no literal-prefix match)**: the agent's `result` field doesn't start with one of the five terminal tokens above (`AUTOMERGE_SET`, `MERGED`, `BLOCKED`, `PAUSED`, `ERRORED`). The realistic distribution is "agent narrated 'polling for CI to finish' instead of returning AUTOMERGE_SET" — every bit of state needed to drive the PR home is observable on the PR itself. Run the **PR state reconstruction probe** below before falling back to ERRORED; the user only sees the malformed result string if the probe can't classify the state.

     Reconstruction probe — sequential checks, **first match wins**. All branches route to existing recovery infrastructure; no new mini-agent templates are introduced.

     1. **No PR exists yet.** `gh pr list --search "Closes #<n>" --state all --json number` returns `[]`. Re-dispatch with the resumption prompt (Phase 5 step 0 path); the agent died before opening a PR, so a fresh attempt is the only recovery.
     2. **PR body contains `### Self-review only`, zero `Claude Reviewer:` comments.** The implementing agent's harness lacked the `Task` / `general-purpose` subagent type and review never ran. Dispatch the orchestrator-level review subagent (the same review-fallback path the AUTOMERGE_SET branch above triggers — same prompt the dispatch template's 6.1 would have used). After it returns, re-enter the probe at step 4 (its inline `Claude Reviewer:` comments may now need addressing, and CI may have moved).
     3. **Unaddressed `Claude Reviewer:` comments exist.** Top-level reviewer comments with no replying comment in their thread. Dispatch the **review-comment mini-agent** (Phase 5b template) per unaddressed comment. The Phase 5b monitor — once launched in step 5 — will pick up subsequent comments via `NEW_COMMENT` events, but at this point no monitor is running so the orchestrator dispatches directly.
     4. **CI red.** `gh pr view <pr#> --json statusCheckRollup` shows any check with `conclusion == "FAILURE"`. Apply the **CI-failure sizing rule** (Phase 5b): ≤50-line / 1–2-file fix in place at the orchestrator level, otherwise dispatch the **CI-failure-fix mini-agent** (Phase 5b template). Same stale-aggregator short-circuit applies.
     5. **CI green, review done, `automerge` label not applied.** The agent reached the merge handoff but didn't return cleanly. Apply the merge-trigger label per the PR's observed `Merge mechanism:` line (typically `automerge`; read the merge workflow's `on:` block to confirm) and launch the **Phase 5b shell monitor** as if AUTOMERGE_SET had been returned cleanly.
     6. **Reconstruction can't classify** (e.g. PR exists, body has no `### Self-review only` marker, no review comments, CI green, automerge label already applied — yet the agent's malformed result string suggests something is wrong). Fall through to ERRORED: fire the `PushNotification` with the captured `result` string verbatim and surface to the user. This is the safety net — never silently drop a malformed terminal.

     Each branch except (6) maps 1:1 to existing recovery infrastructure already wired up elsewhere in this skill — the probe is a router, not new behaviour.

   The harness occasionally fires duplicate `task-notification` events for an agent after it has already terminated — recognisable by 0 tool uses and a generic-sounding result string. Ignore these; rely on your own Monitor task or PR-state polling for ground truth. (And do not re-fire `PushNotification` on a duplicate — the bell already rang on the real terminal.) **Distinguish a duplicate from a malformed terminal:** duplicates have 0 tool uses and follow a real terminal that already parsed cleanly; a malformed terminal is the agent's *first and only* terminal notification, with non-zero tool uses, and its `result` simply doesn't prefix-match. Only the latter triggers the reconstruction probe.

   **Why `PushNotification` here, not `Stop`.** The orchestrator is a long-lived loop on `Monitor` / `TaskOutput` events; the model finishes a turn and goes briefly idle waiting for the next async event many times during a run. In Claude Code that idle transition fires the `Stop` hook on every cycle, so users with a bell-on-`Stop` configuration hear a constant drip even though no action is required. `Stop` cannot reliably distinguish "model is done with the whole orchestration" from "model finished this Monitor tick and will resume on the next event" — both are turn boundaries, and the hook payload doesn't carry a reliable signal. `PushNotification` is the surface the harness reserves for "user action needed" (permission prompts, idle, and explicit `PushNotification` tool calls), so firing it from the skill at the known-meaningful transitions — `BLOCKED` / `PAUSED` / `ERRORED` here, and the Phase 8 final-report bell — gives users with `Stop` removed the visibility they actually want without the heartbeat noise. `MERGED` and `AUTOMERGE_SET` are intentionally silent on the OS-notification channel: the TaskList badge already conveys completion and a bell on every per-issue success would re-introduce the same drip the move away from `Stop` was meant to fix.

6. **Continue** until all terminal.

### Worked example: correct Phase 5 dispatch shape

Picking up issue #281 from `scheduled` for dispatch, the orchestrator's next three tool-call groups should be:

```text
# Group 1 — standalone TaskUpdate. Nothing else in this group.
TaskUpdate(taskId: "<task-id-for-281>", status: "in_progress")
```

```bash
# Group 2 — issue label flip. Cheap and recoverable on its own.
gh issue edit 281 --add-label in-progress --remove-label scheduled
```

```text
# Group 3 — dispatch the implementing agent.
Agent(subagent_type: "general-purpose", prompt: "<dispatch prompt>", isolation: "worktree", run_in_background: true)
```

A failure in the `gh issue edit` call cancels only itself, not the already-completed `TaskUpdate`. The label flip retries cleanly. Same logic for the `Agent` dispatch.

### Progress reporting

The TaskCreate list (Phase 4) is the durable surface. Augment it with a chat-visible digest so the user sees PR links, review status, and CI state without polling GitHub themselves. Keep digests terse — one line per in-flight issue, no headers, no surrounding narration.

**Cadence:**

- Emit a digest on every orchestrator wakeup tick while at least one issue is in-flight (`in-progress` or `automerge_set`). The next-wakeup interval is **state-based** rather than fixed — see the table below.
- Immediately on every dispatched-agent terminal return (`MERGED`, `AUTOMERGE_SET`, `BLOCKED`, `PAUSED`, `ERRORED`) — emit a digest of the remaining in-flight set so the user sees the new state without waiting for the next tick.
- Immediately on every Phase 5b monitor event (`MERGED`, `CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`, `STALLED_GREEN`, mini-agent `RESOLVED` / `FIXED` / `ADDRESSED`) — same digest line so the user sees what the shell monitor and its mini-agents are doing.

**State-based wakeup interval:**

At the **end of each tick** (after the digest is emitted and any state transitions have been processed), choose the next-wakeup interval by walking the table below top-to-bottom and taking the first matching row. Then call `ScheduleWakeup(delaySeconds: <interval>)` (or skip the call entirely for the no-wakeup row). Cancel any previously-pending wakeup before scheduling the new one so only one is outstanding at a time.

The 270s default is calibrated to the prompt-cache TTL (~5 min): it's the longest interval that still gets a cache hit on the next tick. Shorter intervals (60–90s) pay a guaranteed cache hit too (well inside the TTL) and are used when a near-term state transition is genuinely expected. Longer intervals (600s) and the no-wakeup case accept a cache miss on the next tick because there's no signal to poll for in the meantime — the orchestrator wakes on agent-termination or shell-monitor events instead.

| Run state                                                                                    | Next interval | Why                                                                                                                                  |
| -------------------------------------------------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Any PR in `automerge_set` with CI fully green (all checks `SUCCESS`/`SKIPPED`/`NEUTRAL`) and `mergeable == "MERGEABLE"`, awaiting the merge bot to fire | **90s**       | The `MERGED` transition is imminent (seconds-to-a-minute once the bot fires). A short interval catches it before a 270s tick would. |
| Any PR in tiered-remediation flow after a `STALLED_GREEN` emit (tier 2/3/4 in-flight)        | **60s**       | A label-flip or `workflow_dispatch` break-glass should produce a near-term state change; fast follow-up confirms it took.            |
| Any PR in `automerge_set` with CI still in progress (any check `IN_PROGRESS`/`QUEUED`)       | **270s**      | CI runs take 5–10 min; 270s is the cache-TTL-aligned default and there's nothing to gain from polling faster.                        |
| Only implementing agents in flight (no PRs in `automerge_set` yet)                            | **600s**      | The orchestrator gets notified directly on agent termination; per-tick polling adds no value, so widen the interval and accept a cache miss. |
| Run drained (in-flight count == 0) but parked questions outstanding awaiting user input      | **none**      | Skip the `ScheduleWakeup` call entirely. The orchestrator awaits the user's reply; nothing else will change state.                   |
| Default (mixed in-flight, none of the above special cases)                                    | **270s**      | Cache-TTL-aligned baseline.                                                                                                          |

**Examples — predicting the cadence from a run shape:**

- One PR in `automerge_set`, CI green, awaiting the GitHub merge bot → **90s**. (See `STALLED_GREEN` in Phase 5b — if the bot fails to fire within `STALL_THRESHOLD_SECONDS` of green, the monitor escalates; the 90s interval surfaces the `MERGED` transition before that threshold even matters.)
- One PR in `automerge_set` with `STALLED_GREEN` having fired and tier 2 (label-flip) just dispatched → **60s**. The next tick checks whether the label-flip nudged the bot into firing.
- Two PRs in `automerge_set`, one with CI green and one with CI in progress → **90s** (the green-and-merge-pending row matches first; the in-progress PR will be re-checked on the same tick).
- Three implementing agents in flight, no PRs opened yet → **600s**. The orchestrator wakes on each agent's terminal return; polling at 270s would just re-emit `#<N>: implementing` lines until the first PR appears.
- Run drained (last PR merged) but two issues parked on user-input questions → **no wakeup**. The orchestrator awaits the user's reply; the next event is a user message, not a tick.
- Mixed run: one implementing agent + one PR in `automerge_set` with CI in progress → **270s** (the in-progress-CI row matches before the agents-only row).

**Per-issue probe** — for each in-flight issue `<N>`, invoke the digest-line script and emit its stdout verbatim:

```bash
plugins/workflow/skills/implement/scripts/digest-line.sh <owner/repo> <N>
```

The script encodes the full mapping (PR lookup, review-comment counts, CI rollup aggregation, merge-state derivation, edge cases) and emits exactly one line on stdout per the format below. The orchestrator does **not** run gh queries inline or format the line itself — that work moved into the script so each tick costs ~one bash invocation per in-flight issue instead of ~500-1K tokens of inline JSON inference.

The script's exit code is always `0`; the orchestrator distinguishes outcomes via the output string. State mapping (preserved verbatim from the prior inline implementation):

1. **PR lookup** — `gh pr list --state all --search "Closes #<N> in:body" --json number,url,state,statusCheckRollup,mergeable,mergeStateStatus --limit 1`. `--state all` (not `--state open`) so a PR that merged between ticks still appears with `state: MERGED` instead of dropping out of the result set — otherwise the empty-result branch is ambiguous between "no PR opened yet" and "PR merged".

   - Empty result → `#<N> — implementing` (drop the rest of the probe).
   - `state == MERGED` → `#<N> <pr-url> — merged` (drop the issue from the in-flight set on subsequent ticks).
   - `state == CLOSED` (without merge) → `#<N> <pr-url> — closed (not merged)` (drop the issue from the in-flight set on subsequent ticks).
   - `state == OPEN` → continue with the per-state formatting below.

2. **Review status** — count `Claude Reviewer:` comments via `gh api repos/<owner>/<repo>/pulls/<pr#>/comments` (inline) and `…/issues/<pr#>/comments` (PR-level). The review subagent (step 6 of the dispatch pipeline) posts either inline review comments or a single LGTM PR-level comment with the `Claude Reviewer: ` prefix (the implementing agent uses `Claude: `, so the prefix discriminates):

   - Both 0 → `review: pending`.
   - Inline count ≥ 1 → `review: done (<n> findings)`.
   - Inline 0 and exactly one issue-level comment matching `Claude Reviewer: LGTM` → `review: done (LGTM)`.

3. **CI state** — aggregate `statusCheckRollup` from the `gh pr list` query above:

   - Rollup empty → `CI: not started`.
   - Any `conclusion == "FAILURE"` → `CI: red (<m> failing)`.
   - Any `status == "IN_PROGRESS"` or `"QUEUED"` → `CI: pending (<done>/<total>)`.
   - All entries `conclusion == "SUCCESS"` → `CI: green`.

4. **Merge state** — `mergeable` + `mergeStateStatus` from the same `gh pr list` query (Phase 5b's shell monitor handles remediation for the non-clean cases — this signal just surfaces them to the user):

   - `mergeable == "CONFLICTING"` or `mergeStateStatus == "DIRTY"` → `merge: conflict`. The Phase 5b shell monitor will emit a `CONFLICT` event and the orchestrator will dispatch the conflict-resolution mini-agent; surfacing it here means the user notices if a conflict sits unresolved across ticks.
   - `mergeStateStatus == "BEHIND"` → `merge: behind`. Auto-resolved in-shell by Phase 5b's monitor (`git fetch origin main && git merge --no-edit origin/main && git push`); usually transient.
   - `mergeable == "MERGEABLE"` (any non-conflicting `mergeStateStatus`) → `merge: clean`.
   - `mergeable == "UNKNOWN"` → `merge: computing`. GitHub hasn't finished computing mergeability yet; will resolve on the next tick.

**Line format** (the script's stdout — emit verbatim):

```
#<N> <pr-url> — review: <state> — CI: <state> — merge: <state>
```

One line per in-flight issue. The MERGED-transition tick emits `#<N> <pr-url> — merged` once and the issue drops out of the in-flight set on subsequent ticks. Blocked / paused / errored / closed-not-merged issues drop out the same way — their terminal state is in the task list and is summarised in Phase 8's final report. **If either the line format or the state mapping changes, update `scripts/digest-line.sh` in lockstep — they are a single contract.**

Example tick output:

```
#337 https://github.com/aidanns/agent-auth/pull/450 — review: done (3 findings) — CI: pending (8/12) — merge: clean
#338 https://github.com/aidanns/agent-auth/pull/451 — review: done (LGTM) — CI: green — merge: behind
#339 https://github.com/aidanns/agent-auth/pull/452 — review: pending — CI: red (1 failing) — merge: conflict
#340 — implementing
#341 https://github.com/aidanns/agent-auth/pull/453 — merged
#342 https://github.com/aidanns/agent-auth/pull/454 — closed (not merged)
```

#### Notification-relay policy

Phase 5b's shell monitor and progress-tick output produce a steady drip of events during the wait-for-CI / wait-for-merge tail. Most are heartbeats — they confirm "still going" but don't carry information the user needs to act on. The TaskList badge's `in_progress` rendering already conveys "this is still going"; relaying a chat line for every heartbeat is redundant noise on top of it. **TaskList rendering is the user-facing surface for in-progress state — silence is the default during heartbeat events.** Only emit a chat-visible line for state transitions.

Apply this filter before relaying any event to the user:

**Always relay** — these are state transitions worth surfacing as a chat line (and a digest tick):

- PR opened (URL first appears in the digest — agent transitioned out of `implementing`).
- Code-review subagent finished (review state moves from `pending` to `done`).
- Implementing-agent terminal returns: `AUTOMERGE_SET`, `MERGED`, `BLOCKED`, `PAUSED`, `ERRORED`.
- Phase 5b shell-monitor events: `MERGED`, `CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`, `BEHIND_RESOLVE_FAILED` (the monitor's `git push` was rejected after a local catch-up — usually a PAT-scope issue; the PR is parked until the user intervenes), `STALLED_GREEN` (the merge bot didn't fire after CI went green; the orchestrator is running the tier 2 / 3 / 4 ladder).
- Phase 5b mini-agent terminal returns: `RESOLVED` (conflict-resolution), `FIXED` (CI-failure-fix), `ADDRESSED` (review-comment), `ENVIRONMENTAL` (CI-failure-fix flake/infra).
- A new check `conclusion == "FAILURE"` newly observed in the rollup (the digest's `CI: red` count goes up).
- A new merge conflict newly observed (`mergeStateStatus == "DIRTY"` newly seen — the digest's `merge: conflict` first appears).
- Merge bot didn't fire after CI went green (the tier 2 / tier 3 escalation under "Tiered remediation when AUTOMERGE_SET stalls" — the user needs to see that the orchestrator is escalating).

**Suppress** — these are heartbeats; the TaskList badge is already conveying them and a chat line would be doubly redundant:

- Repeated `BEHIND_RESOLVED` events from Phase 5b's shell monitor beyond the first occurrence in a given monitor session (the auto-resolve is working as designed; one notification establishes that, the rest are noise).
- The harness's spurious post-termination "agent completed" notifications after a dispatched agent has already returned its terminal token (per the duplicate-notification note — the agent is already done, the second fire is harness-level noise).
- Progress-tick lines whose state hasn't changed since the prior tick (every digest field — review / CI / merge — produces the same string as last tick). Skip the chat-visible emission; the next tick that surfaces a real change re-emits the full digest.
- Per-check-pass heartbeats from any agent or monitor ("`unit` passed, 2 more pending", "More checks passing"). The aggregate `CI: pending (<done>/<total>)` field already renders progress in the digest; per-check chatter doesn't add information.

When in doubt, suppress. The user can always `gh pr view <pr#>` if they want raw detail; the orchestrator's job is to surface transitions, not narrate the wait.

### Dispatch prompt template (embedded in every Agent call)

The orchestrator constructs the per-agent prompt by filling in the placeholders below. The full text — not a reference — goes into the Agent call so the dispatched agent has everything it needs without consulting this skill.

```
You are implementing GitHub issue #<N> end-to-end. The issue body follows verbatim:

---
<full body refreshed via `gh issue view <N> --json body --jq .body`>
---

Project context: this repo's conventions are described in `CLAUDE.md` (root), `.claude/instructions/*.md` (if present), and `CONTRIBUTING.md`. Read these before editing — they define language, tooling, commit-message scopes, and any project-specific rules.

<stdout of `phase15-conventions.sh <owner/repo>` embedded verbatim — a header line "Current PR conventions (observed from the N most recent merged PRs on <repo>)…" followed by bullets covering title prefix style, title length limit, ==COMMIT_MSG== block usage, label histogram, and manual-changelog status, terminated by a `Merge mechanism:` trailer that sub-step 6.4 below parses. Do not hardcode a merge command — sub-step 6.4 reads the trailer.>

<if any deps merged: Dependency context — these issues already merged and may have introduced helpers / types / files you should reuse:
- #<dep>: <PR title>. Summary: <one-line summary of what merged>.>

<if the Phase 5 step 3a stale-path scan found stale paths in the issue body (only when deps merged mid-run):
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

**PR title must be ≤72 characters.** It becomes the squash-merge subject inside the `==COMMIT_MSG==` block (or the equivalent commit-subject convention in repos without that pattern). If your tentative title is longer, tighten it before opening the PR. Common compaction patterns:

- Drop redundant prepositions: "optional per-key signing passphrase **stored in** system keyring" → "optional per-key signing passphrase **via** keyring".
- Drop scope qualifiers already implied by the prefix: `feature(gpg-bridge): gpg-bridge supports …` → `feature(gpg-bridge): supports …`.

Failing the title-length check costs an amend + force-push and an extra CI cycle.

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

**CodeQL stale aggregator pattern.** If `analyze (python|actions|...)` checks are all SUCCESS but the top-level `CodeQL` check is FAILURE, compare `completed_at` timestamps:

- Aggregator completed *before* the analyzes → stale; it's reading old alert state. The next analyze cycle (or alert-resolution background job, ~5–10 min) will clear it. Don't dispatch an agent to investigate.
- Aggregator completed *after* the analyzes → real alert. Investigate.

The `gh api repos/.../code-scanning/alerts` endpoint requires `security_events` scope on the token; if you get 403, fall back to the Security tab in the GitHub UI or have the user dismiss the alert directly. If you hit this pattern often, consider running `gh auth refresh -s security_events` once at the orchestrator level so subsequent investigations can read the alert state via `gh api` directly.

If the failure is environmental (infra outage, rate limit, unrelated to your diff): report it in the PR body and skip — do not retry blindly.

#### 6.4 Set automerge — TERMINAL STEP

**Precondition — run this probe before applying any merge-trigger:**

    gh pr view <pr#> --json statusCheckRollup \
      --jq '[.statusCheckRollup[] | select(.conclusion=="FAILURE")] | length'
    # expected: 0

If the probe returns >0, loop back to 6.3 — **do not set automerge**. Your prose recollection of "all checks passed" is not a substitute; the rollup is the source of truth, and the contract here fails open if you skip this. (Observed in the wild: an agent returned `AUTOMERGE_SET` while three checks were still in `conclusion: FAILURE`, because it trusted its own summary instead of re-querying the rollup.)

*Known-environmental carve-out:* if every remaining failure is a documented infra/rate-limit issue per 6.3 (and noted in the PR body), you may proceed; otherwise the >0 result is blocking.

**Do NOT remove the `in-progress` label when applying `automerge`.** The label persists from worktree-creation through merge — that's the audit trail of who handled the issue. The label only comes off on `BLOCKED` (replaced by `blocked`) or `PAUSED` (replaced by `paused`); otherwise the orchestrator (or GitHub's auto-close) handles cleanup after merge confirmation.

Once review comments are addressed AND the probe above returns 0 (or only known-environmental failures remain), hand off to merge by reading the `Merge mechanism:` line from the "Current PR conventions (observed)" block above:

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

# 6.4 precondition — re-run the failure-count probe immediately before the merge-trigger
# (this is the hard gate from 6.4; the 6.3 run above is for diagnosis, this run is the contract):
gh pr view <pr#> --json statusCheckRollup \
  --jq '[.statusCheckRollup[] | select(.conclusion=="FAILURE")] | length'
# expected: 0 — if >0, loop back to 6.3, do not proceed.

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

Changes under any of the following are blockers — even with strong justification. Surface to the user with the proposed diff inline; do not self-justify in the PR body:

- `.github/` (workflows, actions, codeql config, dependabot config, issue/PR templates)
- branch-protection rulesets
- security policies (`SECURITY.md`, threat-model docs)
- dependency-lockfile pinning rules
- build-system config (`lefthook.yml`, `treefmt.toml`, taskfile target additions/removals)

The justification still belongs in the PR body — but the user gets to confirm before the change goes in. Nothing under `.github/` qualifies as an "internal" decision.

1. Post a comment on the issue describing exactly what you need (be specific — name the file, the field, the option; for the CI/security-config paths above, attach the proposed diff inline):

   gh issue comment <N> --body 'Claude: Blocked — <specific question>'

2. Apply the `blocked` label, remove `in-progress`:

   gh issue edit <N> --add-label blocked --remove-label in-progress

3. Return a structured report to the orchestrator: `BLOCKED: <issue> <question>`.

Internal implementation decisions (test layout, helper names, internal refactor choices) are NOT blockers — resolve them yourself with one-line justification in the PR body. The CI/security-config paths enumerated above are explicitly *not* internal, regardless of how narrowly scoped or well-justified the change is.

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

### Returning your terminal status

The orchestrator parses **only** the `result` field of your final notification, and it parses by literal prefix match. Format discipline is load-bearing:

- The `result` field of your final notification MUST start with one of the literal terminal tokens above (`AUTOMERGE_SET`, `MERGED`, `BLOCKED`, `PAUSED`, `ERRORED`) followed by the relevant args. No leading prose, no quoting, no markdown — the token is the first thing the orchestrator sees.
- Heartbeat notifications during 6.1 → 6.4 (e.g. "ran review subagent", "addressed CI failure", "applied automerge label") are fine and encouraged — they let the user see progress. Only the *final* notification is the terminal handoff; only its `result` is parsed.
- If you find yourself wanting to narrate ("the PR merged successfully, returning MERGED ..."), that's a heartbeat at best. The terminal contract is the literal token plus its args, nothing else. Freeform prose around the token breaks the orchestrator's parse — the orchestrator has a backstop that reconstructs PR state and routes to existing recovery paths (review subagent, review-comment mini-agent, CI-failure sizing, automerge handoff), but treat the backstop as a safety net for genuinely unexpected exits, not a license to be sloppy. The clean terminal token is still the contract; the backstop just keeps a malformed return from immediately surfacing to the user.

If you find yourself thinking "the review is done, I should report back" — don't. The review is the *start* of the merge loop, not the end. If you find yourself thinking "I should poll until the PR merges" — don't. Setting automerge is the end of your job; Phase 5b owns the rest.
```

## Phase 5b — Post-automerge monitoring

Once an implementing agent returns `AUTOMERGE_SET <pr-url>`, the orchestrator owns the PR until merge. The goal is to spend as few tokens as possible on the wait-for-CI / wait-for-automerge tail without giving up the ability to recover from `BEHIND`, conflicts, CI failures, or new review comments.

### Trade-off rationale (why a shell monitor + mini-agents, not a warm agent)

The previous design kept the implementing agent warm through the entire wait-for-merge tail — burning hundreds of thousands of tokens per PR on polling that an LLM adds no value to. The current design swaps that warm agent for a thin shell monitor for the trivial cases (`BEHIND` auto-merge, `MERGED` detection, `green + waiting` no-op), escalating to a focused mini-agent only when the monitor sees something requiring judgment (`CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`).

Each escalation pays a cold-start cost (~30–50k tokens loading project conventions). A PR with 3 escalations during its life pays 3× that. The always-warm-agent approach paid that cost once but spent ~400k tokens monitoring. The crossover is around 6–8 escalations per PR, which essentially never happens for normal PRs. So the thin-monitor approach wins for the realistic distribution (most PRs: 0–2 escalations); the always-warm approach is only better for pathological PRs.

The other resilience win: a crashed monitor doesn't lose pipeline state — it just stops polling, and the orchestrator can relaunch it. A crashed always-warm agent loses the entire PR's monitoring state and may not resume cleanly. **If the workload distribution shifts (e.g. a project where most PRs hit 5+ conflicts) re-evaluate this split — the crossover point is the relevant signal.**

### Handoff

When step 5 of the Phase 5 execution loop receives `AUTOMERGE_SET <pr-url>` from a dispatched agent:

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
stall_threshold="${STALL_THRESHOLD_SECONDS:-180}"  # first STALLED_GREEN emit.

emit() { printf '%s\n' "$*"; }  # one event per line, line-buffered by default.

# Track which CI failures and review comments we've already escalated, so we
# don't re-emit on every tick.
seen_failures=""   # space-separated run IDs.
seen_comments=""   # space-separated comment IDs.

# Track "time since the PR's observable state last changed" so we can detect
# the steady-state "green + automerge applied + open + mergeable" stall and
# escalate it to the orchestrator rather than silently re-observing it every
# poll. State hash is a stable digest of the JSON we already fetch — anything
# the GitHub API surfaces as a change (new commit, label toggle, check
# transition, mergeable flip) bumps the hash and resets the timer.
last_change_ts=$(date +%s)
prev_state_hash=""
# Highest STALLED_GREEN threshold (seconds) we've already emitted for this
# stall episode. Resets to "" on every state change so a fresh stall after a
# transient flip starts the escalation ladder over from the bottom.
emitted_stall_tier=""

while :; do
  state_json=$(gh pr view "$pr" --json state,url,mergeable,mergeStateStatus,statusCheckRollup,headRefOid,labels 2>/dev/null || true)
  if [[ -z "$state_json" ]]; then
    # Transient network blip — sleep and retry without crashing.
    sleep "$poll"; continue
  fi

  state=$(jq -r '.state' <<<"$state_json")
  url=$(jq -r '.url' <<<"$state_json")
  mergeable=$(jq -r '.mergeable' <<<"$state_json")
  msstatus=$(jq -r '.mergeStateStatus' <<<"$state_json")

  # Bump last_change_ts whenever any observable PR state has changed since the
  # previous tick. `del(.url)` drops the constant url field so it doesn't
  # contribute to the hash; `tojson` with `-S` gives a sort-stable digest so
  # equivalent JSON always hashes the same.
  state_hash=$(jq -S 'del(.url) | tojson' <<<"$state_json" | sha1sum | cut -c1-8)
  if [[ "$state_hash" != "$prev_state_hash" ]]; then
    last_change_ts=$(date +%s)
    prev_state_hash="$state_hash"
    emitted_stall_tier=""
  fi

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
        # Capture push stderr so we can surface failures (e.g. PAT missing
        # `workflow` scope rejecting changes under `.github/workflows/*`).
        # Only emit BEHIND_RESOLVED when the push actually landed; otherwise
        # the next tick would observe BEHIND again and silently loop.
        push_err=$(git push origin "$branch" 2>&1 >/dev/null)
        push_rc=$?
        if [[ $push_rc -eq 0 ]]; then
          emit "BEHIND_RESOLVED $pr"
        else
          # Collapse newlines/tabs so the event line stays single-line.
          reason=$(printf '%s' "$push_err" | tr '\n\t' '  ' | sed 's/  */ /g')
          emit "BEHIND_RESOLVE_FAILED $pr $reason"
        fi
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

  # ---- STALLED_GREEN: CI green + automerge applied + open + mergeable. ----
  # The PR is in the steady state that the AUTOMERGE_SET-stall remediation
  # ladder (tiers 2/3/4) is designed for: nothing is broken, but the merge
  # bot isn't firing. Emit once on first detection, then again at exponential
  # intervals (default 3 min / 9 min / 18 min) so the orchestrator can run
  # tier 2 immediately and escalate to tier 3 / tier 4 only if the stall
  # persists.
  # Treat pending checks (null conclusion / IN_PROGRESS / QUEUED status) as
  # NOT green — STALLED_GREEN is for "the rollup is fully resolved and the
  # bot still isn't merging", not for "checks are still running".
  green=$(jq -r '[.statusCheckRollup[]?
                   | select((.conclusion // "") != "SUCCESS"
                            and (.conclusion // "") != "SKIPPED"
                            and (.conclusion // "") != "NEUTRAL")] | length == 0' \
            <<<"$state_json")
  has_automerge=$(jq -r '[.labels[]?.name] | any(. == "automerge")' <<<"$state_json")
  is_open=$(jq -r '.state == "OPEN"' <<<"$state_json")
  mergeable_ok=$(jq -r '.mergeable == "MERGEABLE"' <<<"$state_json")
  age=$(( $(date +%s) - last_change_ts ))
  if [[ "$green" == "true" && "$has_automerge" == "true" \
        && "$is_open" == "true" && "$mergeable_ok" == "true" ]]; then
    # Pick the highest threshold the current age has crossed but that we
    # haven't already emitted for this stall episode. Thresholds derived from
    # STALL_THRESHOLD_SECONDS (default 180s) at 1x / 3x / 6x — exponential
    # backoff so the first emit is fast and re-emits get progressively rarer.
    t1=$stall_threshold
    t2=$((stall_threshold * 3))
    t3=$((stall_threshold * 6))
    next_tier=""
    if   (( age >= t3 )) && [[ "$emitted_stall_tier" != "$t3" ]]; then next_tier=$t3
    elif (( age >= t2 )) && [[ "$emitted_stall_tier" != "$t3" && "$emitted_stall_tier" != "$t2" ]]; then next_tier=$t2
    elif (( age >= t1 )) && [[ -z "$emitted_stall_tier" ]]; then next_tier=$t1
    fi
    if [[ -n "$next_tier" ]]; then
      emit "STALLED_GREEN $pr green-for=$age"
      emitted_stall_tier=$next_tier
    fi
  fi

  sleep "$poll"
done
```

Key behaviours:

- **`BEHIND` auto-resolution stays in-shell.** Uses the same local-merge approach the implementing agent uses (`git fetch origin main && git merge --no-edit origin/main && git push`) — no `update-branch` API call, consistent with the rest of this skill.
- **Push failures are surfaced, not swallowed.** `git push` stderr is captured and the exit code is checked. On failure, the monitor emits `BEHIND_RESOLVE_FAILED <pr#> <reason>` instead of `BEHIND_RESOLVED`, so a silently-rejected push (e.g. PAT missing `workflow` scope on `.github/workflows/*` changes) escalates to the user instead of the next tick re-observing BEHIND and looping. `BEHIND_RESOLVED` is only emitted when the push actually landed.
- **Transient `gh` failures** (network blips, rate-limit retries) don't crash the loop — `|| true` and an empty-result check keep polling.
- **Deduplication** — failing run IDs and review comment IDs are tracked, so a persistent failure escalates exactly once per ID, not on every tick.
- **`Claude` -prefixed comments are skipped** so the monitor doesn't re-escalate on the implementing agent's or reviewer subagent's own comments.
- **Stall detection collapses the latency tail.** When the PR sits in (`mergeable == MERGEABLE`, all checks `SUCCESS`/`SKIPPED`/`NEUTRAL`, `automerge` label present, `state == OPEN`) for longer than `STALL_THRESHOLD_SECONDS` (default 180), the monitor emits `STALLED_GREEN <pr#> green-for=<seconds>`. The orchestrator routes the first emit to tier 2 of the AUTOMERGE_SET-stall ladder immediately rather than waiting for its next progress-tick wakeup (which can be up to the current state-based interval away — see Phase 5 § Progress reporting § State-based wakeup interval). Re-emits use exponential backoff (1x / 3x / 6x of the threshold — default 3 / 9 / 18 minutes) so a persistent stall escalates through tier 3 and tier 4 without spamming the orchestrator on every poll, and any state change (new commit, label flip, check transition) resets the timer so transient stalls don't accumulate. The threshold is configurable via the `STALL_THRESHOLD_SECONDS` env var when launching the monitor.

> **Related, out of scope:** cloning the PR branch via SSH (`gh config set git_protocol ssh`) would sidestep PAT-scope issues for repo writes — SSH key auth doesn't enforce the `workflow` scope. Tracked as a separate consideration; the visibility fix above is the more general improvement, since silent push failures bite in lots of ways beyond the one scope issue.

### Orchestrator event routing

The `Monitor` tool surfaces each stdout line of `monitor-pr.sh` as a notification. The orchestrator routes events as follows:

| Event line | Orchestrator action |
|---|---|
| `MERGED <pr-url>` | Mark issue task `completed`. Stop the monitor. Trigger Phase 6 housekeeping. |
| `CLOSED <pr-url>` | Surface to user — PR was closed without merging. Stop the monitor. |
| `BEHIND_RESOLVED <pr#>` | Log only. Refresh the next progress digest. |
| `BEHIND_RESOLVE_FAILED <pr#> <reason>` | Surface to user — the monitor caught up the branch locally but the `git push` was rejected (commonly a PAT-scope issue, e.g. missing `workflow` scope when the PR touches `.github/workflows/*`). Stop the monitor; treat the PR as parked until the user resolves the auth/permission issue. Do **not** loop — the next tick would just re-observe BEHIND and fail the same way. |
| `CONFLICT <pr#> <branch> <base> <files>` | Dispatch the **conflict-resolution mini-agent** (template below). |
| `CI_FAILURE <pr#> <check> <run-id>` | Size the fix first (see **CI-failure sizing rule** below). If ≤50 lines / 1-2 files, fix in-place at the orchestrator level. Otherwise dispatch the **CI-failure-fix mini-agent** (template below). |
| `NEW_COMMENT <pr#> <comment-id>` | Dispatch the **review-comment mini-agent** (template below). |
| `STALLED_GREEN <pr#> green-for=<s>` | Run the **AUTOMERGE_SET stall** ladder *now* rather than waiting for the next progress-tick wakeup. **First** `STALLED_GREEN` for a given PR → apply tier 2 immediately (toggle the merge-trigger label). **Second** `STALLED_GREEN` for the same PR (the monitor's exponential-backoff re-emit means tier 2 didn't take) → escalate to tier 3 (`workflow_dispatch` break-glass on the merge workflow). **Third** and beyond → tier 4 (probe the merge bot's run log) and surface the finding to the user. The shell monitor handles tier 1 (`BEHIND` auto-resolve) before this event ever fires, so a `STALLED_GREEN` always means the bot is the problem, not a stale base. See **Tiered remediation when AUTOMERGE_SET stalls** below for the per-tier mechanics. |

#### CI-failure stale-aggregator short-circuit

Before dispatching the CI-failure-fix mini-agent, check the stale-aggregator pattern (see 6.3). If the failing check is `CodeQL` and the `analyze (...)` sub-jobs are SUCCESS, compare `completed_at` timestamps. Aggregator before analyzes = stale, will self-clear in ~5–10 min on the next analyze cycle or alert-resolution background job — don't dispatch. Let the shell monitor keep polling; the next `gh pr view` tick will observe the cleared rollup. Aggregator after analyzes = real alert, fall through to the sizing rule below.

The `gh api repos/.../code-scanning/alerts` endpoint requires `security_events` scope on the orchestrator's token; a 403 here means fall back to the Security tab in the GitHub UI (or `gh auth refresh -s security_events` if this pattern recurs).

#### CI-failure sizing rule

On a `CI_FAILURE` event during the wait-for-merge tail, investigate before dispatching: `gh run view <run-id> --log-failed`, find root cause, don't bypass. Then size the fix:

- **≤50-line fix in 1-2 files** (typecheck error, lint violation, missing import, sub-block in same file): **fix in place at the orchestrator level.** Do not pay the mini-agent cold-load. Use the existing branch — the implementing agent's worktree may still exist on disk at `.claude/worktrees/agent-<id>` and is reusable; otherwise check out the branch into a fresh worktree. Commit, push, let CI re-fire. The implementing agent is gone but the branch and PR are still yours.
- **Larger fix, multi-file refactor, or new test surface required**: dispatch the CI-failure-fix mini-agent (template below). Pays a cold-load but safer for non-trivial changes.

Either way, the implementing agent's terminal `AUTOMERGE_SET` return is final — don't try to "wake it up." The slot stays free for new issues.

Mini-agents run in their own isolated worktrees with `run_in_background: true`. They do **not** count against the implementing-agent concurrency cap of 3 — they're focused, short-lived, and are part of a PR that has already cleared the implementing-agent slot. (Cap them informally if you observe contention; defer formal limits until needed.)

When a dispatched mini-agent returns `RESOLVED` / `FIXED` / `ADDRESSED`, the shell monitor — still polling — will eventually observe the underlying state has cleared (conflict gone, CI green, comment threaded) and stop emitting that event. If a mini-agent returns `BLOCKED <question>` or `ENVIRONMENTAL <reason>`, the orchestrator surfaces it to the user and may stop the monitor (treat the PR as parked, just like a `BLOCKED` from the implementing agent).

### Tiered remediation when AUTOMERGE_SET stalls

When a PR sits in `AUTOMERGE_SET` longer than ~5 minutes after CI rollup is fully green and the shell monitor's `green + waiting` no-op state has persisted, the merge bot has likely failed to fire (or fired and exited cleanly waiting for a re-trigger that never came). Work through these tiers **in order — don't loop on the early ones**. If a tier fails twice, escalate to the next; don't retry the same tier indefinitely.

The trigger for entering this ladder is the shell monitor's `STALLED_GREEN <pr#> green-for=<s>` event (see the orchestrator event-routing table above) — the monitor emits it on the first poll where the steady state has held past `STALL_THRESHOLD_SECONDS` (default 180s) and re-emits at exponentially-spaced intervals while the stall persists. Each successive `STALLED_GREEN` for the same PR maps to the next tier in this list: first emit → tier 2, second → tier 3, third and beyond → tier 4. Don't wait for the next progress-tick wakeup to start tier 2 once a `STALLED_GREEN` arrives; the whole point of the event is to collapse that latency.

1. **Tier 1 — `mergeStateStatus == "BEHIND"`.** Already automated by the Phase 5b shell monitor's in-shell auto-resolve (`git fetch origin <base> && git merge --no-edit origin/<base> && git push`); usually clears in ~30s on the next monitor tick. The orchestrator only steps in here if the shell monitor crashed — in which case relaunch the monitor first, and only fall back to running the same `git fetch / merge / push` by hand if the monitor still won't run. **Do not** reintroduce the `update-branch` API call; the local-merge approach is the contract.

2. **Tier 2 — CI rollup truly green but the merge bot didn't fire.** Toggle the project's merge-trigger label (typically `automerge` — read the merge workflow's `on:` block to confirm the label name): remove the label, sleep ~3 seconds, re-add. This fires a fresh `pull_request: labeled` event the bot listens to. **Don't loop on tier 2 more than twice.** If two toggles haven't worked, the bot is probably losing a race against another `labeled`-triggered workflow — jump to tier 3.

3. **Tier 3 — toggle keeps losing a race.** When another workflow on the same repo also triggers on `pull_request: labeled` (e.g. a changelog bot, a notifier), every label toggle starts a new race that the merge bot can lose. Look for a project-specific **`workflow_dispatch` break-glass** on the merge workflow itself — most merge-bot patterns expose a manual dispatch input that takes a PR number and bypasses the `labeled` event entirely:

   ```bash
   gh workflow run <merge-workflow>.yml -f pr_number=<N>
   ```

   Read the merge workflow's `on:` block to see what `workflow_dispatch` inputs are available (typical input names: `pr_number`, `pr`, `pull_request_number`). This is the standard escape hatch from label-toggle races — don't keep re-toggling the label hoping the race resolves itself.

4. **Tier 4 — bot consistently exits "waiting for pending checks" but rollup looks green.** The bot may be reading a stale check entry from a prior commit. Probe the merge bot's own run log to see *which* check it considers pending:

   ```bash
   gh run view <merge-bot-run> --log
   ```

   If the bot is keying off a check name that no longer matches the current head SHA's checks (a common dedupe-aware-evaluation gap), the fix is project-specific — surface the finding to the user rather than guessing.

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

When the orchestrator observes a `MERGED` event — either from an implementing agent's terminal `MERGED <pr-url>` return (synchronous merge case) or from the Phase 5b shell monitor's `MERGED <pr-url>` event (the `AUTOMERGE_SET → MERGED` handoff):

1. **Flip the task to `completed` — as a standalone tool call, not bundled with any other tool call.**

   ```text
   TaskUpdate(taskId: <task-id>, status: "completed")
   ```

   This MUST be its own tool-call group. Do not parallelise it with the `gh issue view`, `gh issue close`, `gh issue edit`, `git worktree remove`, or `git pull` calls below. See "Why standalone TaskUpdate" at the end of this phase for the cancellation hazard this avoids.

2. **Confirm the issue closed** (`gh issue view <n> --json state` should report `CLOSED`). **If still OPEN, close manually:**

   ```bash
   gh issue close <n> --comment "Closed by merge of PR #<P> (squash commit <sha>). Auto-close didn't fire — closing manually."
   ```

   GitHub's auto-close-on-`Closes #N` is unreliable for App-token-mediated API merges (observed in repos using a merge-bot pattern with bypass-actor App tokens). Don't wait for it; verify and close yourself.

3. **Remove the worktree** at the path returned in the agent's notification. The existing `/close-worktree` skill encapsulates this — `cd` out of the worktree, `git worktree remove --force <path>`, then `git worktree prune`, then `cd` back to the repo root. Reuse that skill rather than re-deriving the steps. This step is required: `isolation: worktree` only auto-cleans when the agent made no changes, and a successful run always makes changes — so without explicit removal, every merged PR leaves a locked worktree under `.claude/worktrees/agent-<id>/` that grows disk and inode cost monotonically. The trailing `cd` back to the repo root is required for a different reason: if the orchestrator's bash session ever `cd`'d into the removed worktree earlier in the run (e.g. to push an empty commit, manually resolve `BEHIND`, or check git state), its CWD is now dangling and subsequent `git`/`gh` calls in that session fail with cryptic config-read errors.

4. **Pick up the next eligible issue.** The `in-progress` label persists on the closed issue (intentional — preserves audit trail).

### Worked example: correct Phase 6 shape

After the orchestrator observes `MERGED https://github.com/o/r/pull/91` for issue #281, the next two tool-call groups should be:

```text
# Group 1 — standalone TaskUpdate. Nothing else in this group.
TaskUpdate(taskId: "<task-id-for-281>", status: "completed")
```

```bash
# Group 2 — parallel cleanup. Failures here are recoverable; the task flip already landed.
gh issue view 281 --json state
gh issue close 281 --comment "..."        # only if step 2 found it OPEN
git worktree remove --force <worktree-path>
git worktree prune
cd <repo-root>                             # land in a known-good CWD post-removal
git pull origin main                       # in the orchestrator's checkout
```

The cleanup group can fail any of its calls without losing the task transition. Retry the failing call(s); the `TaskUpdate` is already done.

### Why standalone TaskUpdate

When `TaskUpdate(status: "completed")` is bundled into the same parallel tool-call group as the cleanup `Bash` calls (`git pull`, `git worktree remove`, `gh issue edit`, etc.), a failure in *any* of those Bash calls causes the harness to cancel every still-pending tool call in the batch — including the `TaskUpdate`. The Bash failure is visible and gets retried; the cancelled `TaskUpdate` is silently dropped, and the local task stays `in_progress` while the issue is closed on GitHub. The drift is invisible until run end.

`TaskUpdate` is cheap (a local harness call, not a network call) and never fails on its own, so isolating it costs nothing and protects the most important state transition in this phase. Future authors: do **not** "optimise" by re-bundling.

## Phase 7 — Block handling

When an agent reports `BLOCKED`:

- Verify the `blocked` label is set on the issue and the issue has a `Claude: Blocked` comment.
- Record the question in a parked-questions list (in-memory; optionally write to `.claude/workflow-implement-state.json` for resumability).
- Continue with other ready issues.

When the loop drains (no more eligible issues, in-flight count = 0):

1. Compile parked questions into ONE batched message to user, numbered and grouped by issue.
2. Wait for answers.
3. After answers: update affected issue bodies via `gh issue edit <n> --body`, remove `blocked` labels, restart agents on those issues. Re-enter Phase 5.

## Phase 8 — Completion

The orchestrator's `TaskList` is the canonical state surface — every in-scope issue has a tracking task that flips through `pending` → `in_progress` → `completed` (or stays `in_progress` on `BLOCKED` / `PAUSED`). The chat-visible final report below is a one-shot snapshot at run end, not the source of truth; refer back to `TaskList` for live state.

### Phase 8.0 — TaskList ↔ GitHub reconciliation (defensive backstop)

Before emitting the final report, walk every in-scope issue (the list resolved in Phase 1) and reconcile the local `TaskList` against GitHub's view. This is a **backstop**, not the primary fix — the source-fix is the standalone `TaskUpdate` rule in Phase 6 step 3 (and Phase 5 steps 2–3) that prevents drift from arising in the first place. Phase 8.0 catches whatever slips through: harness cancellations on bundled tool-call groups, transient `gh` failures that wedged a state transition, manual close+reopen races, etc.

For each in-scope issue `<n>`:

1. `gh issue view <n> --json state` to read the current GitHub state.
2. If `state == "CLOSED"` and the corresponding task is still `in_progress` or `pending`, flip it via a standalone `TaskUpdate(taskId: <task-id>, status: "completed")` call. Record the reconciliation in a list for the final-report log line.
3. If `state == "OPEN"` and the corresponding task is `completed`, **do not** auto-revert — log the inconsistency for the final report. This direction usually indicates a deeper bug (squash-merge dropped the `Closes #N` footer, manual close+reopen race, merge-bot rolled back) that warrants human investigation, not silent rewriting of local state.

Run reconciliation regardless of how Phase 5/6/7 ended — even on a clean run with zero observed errors, because the cancellation hazard is silent by definition. The cost is one `gh issue view` per in-scope issue.

The run is still considered **successful** even if reconciliation had to flip tasks; it's a backstop firing as designed. Surface a one-line log in the final report noting which task IDs / issue numbers were reconciled (and which OPEN-but-completed inconsistencies were detected), so the user can investigate if a particular dispatch keeps drifting — repeated reconciliations for the same code path is a signal that the Phase 6 source-fix has regressed.

Final report to user:

- N issues processed: X merged, Y parked, Z excluded.
- Links to merged PRs.
- Outstanding parked questions (if any) — `blocked` label remains, awaiting attention.
- Reconciliation log (one line, only if Phase 8.0 flipped anything or detected an OPEN-but-completed inconsistency).
- Suggested next step: `/workflow:implement --label blocked` to resume parked issues after answering.

After emitting the final-report message, fire one `PushNotification` summarising the run outcome — this is the bell for "the orchestration is done." Examples:

- All clean: `PushNotification(message: "/implement: all <N> issues merged")`.
- Mixed: `PushNotification(message: "/implement: <X> merged, <Y> parked, <Z> errored")` (omit zero categories — `<X> merged, <Y> parked` is fine when nothing errored).

Same rationale as the Phase 5 step 5 terminal-handoff notifications (see "Why `PushNotification` here, not `Stop`" there): `Stop` fires on every Monitor-tick boundary during the long-lived orchestration loop, so users who configure a bell on `Stop` hear it constantly. `PushNotification` is the surface for "user action needed / orchestration finished" transitions — exactly the moment after the final report. Fire exactly once per run (in addition to any per-issue `BLOCKED` / `PAUSED` / `ERRORED` bells already emitted in Phase 5 — this one signals the run itself is over).

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

For runs that may span context windows, persist minimal state at `.claude/workflow-implement-state.json` in the project root:

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
