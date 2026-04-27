---
name: implement
description: Process one or more GitHub issues end-to-end. Triggered by /workflow:implement with optional args (issue numbers, --label, --milestone, --parent). The implementing agent runs in an isolated worktree and stays warm through review (worktree → plan → PR → self-review → `READY_FOR_REVIEW` heartbeat → await SendMessage → address findings if any → `READY_TO_MERGE`); the orchestrator owns review dispatch, CI fix-up, automerge handoff, and post-merge monitoring. Self-contained — embeds the full pipeline in dispatched-agent prompts so it works without project-specific CLAUDE.md scaffolding. Defaults: 3 concurrent implementing agents (counted through merge handoff), park-and-continue on blockers, sequential dependency-aware execution.
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
| `/workflow:implement --resume <id>` | Reattach to a prior session. Restores selector, resolved issue list, dep graph, and per-issue terminal state from `~/.claude/state/workflow-implement/<id>.json`, then re-enters Phase 5. |
| `/workflow:implement --session list` | List resumable sessions in the per-user state directory: ID, repo, last-modified timestamp, selector summary, in-flight issue count. |

Selectors compose: `/workflow:implement --milestone "MS-2 General" --label scheduled` intersects them. **`--resume` does not compose with selectors** — the resumed state file already encodes the original selector, so passing both is a hard error. Pass `--resume <id>` alone.

### Session lifecycle (orchestrator-level)

Every `/workflow:implement` invocation owns a **session ID** of the form `wfi-YYYY-MM-DD-<4 hex chars>` (e.g. `wfi-2026-04-27-a1b2`). The orchestrator generates one at intake (Phase 1) for fresh runs, or reuses the supplied ID for `--resume`. Orchestrator-level state — selector, resolved issue list, dep graph, per-issue dispatch context, progress-digest tail — is persisted under that ID at `~/.claude/state/workflow-implement/<id>.json` so a conversation lost mid-run (Claude Code crash, host disconnect, deliberate `/clear`, context exhaustion, the user closing the laptop) can be resumed without re-typing the original selector.

This is a different surface from **Phase 5 step 0 (per-issue resumption)**: that step recovers the *agent layer* (an in-flight branch / open PR) on a per-issue basis whenever it sees one. `--resume` rehydrates the *orchestrator layer* (selector, dep graph, task list, digest history) before Phase 5 runs at all. The two compose: `--resume` rehydrates orchestrator state, then Phase 5 step 0 still runs per-issue inside the rehydrated session and continues to discourage agent-level restart. See **§ Session state** below for the file shape and **§ Bail-outs** for the missing-state-file behaviour.

> **Out of scope (future):** a concurrency guard that detects when two `/workflow:implement` invocations claim overlapping issues. With distinct session IDs it would be cheap to add — each session's state file lists its in-flight issue numbers — but it isn't implemented yet. A second invocation against an overlapping selector will silently race; the user is responsible for not starting one.

## Operating principles

- **Sequential phases.** Don't skip; if a phase yields no work, log and continue.
- **Park, don't block.** A blocker on issue A never stops independent issues B and C.
- **Public-break = blocker, internal = self-resolve.** Anything that would change a publicly-observable surface (API shape, file path, schema, naming convention, semver bump) is a blocker requiring user clarification. CI/security config paths (`.github/`, branch-protection rulesets, `SECURITY.md`, lockfile pinning rules, build-system config) are also blockers — see the dispatch template's "Blocker handling" section for the full enumeration. Internal implementation choices the agent makes itself with a one-line justification in the PR body.
- **Strict isolation.** Every dispatched agent runs with `isolation: worktree`. No file-state collisions.
- **Best-effort context sharing.** When B declares a dependency on A and A has merged, B's dispatch prompt includes A's PR summary and any new types/helpers A introduced. Independent issues start cold.
- **Concurrency cap: 3.** Three implementing agents in flight at once. "In flight" = **from dispatch through merge handoff** — the implementing agent stays warm through review and (if findings landed) address-review, only freeing its slot when it returns `READY_TO_MERGE` and the orchestrator runs the merge handoff. `READY_FOR_REVIEW` is now a **heartbeat**, not a slot release: the agent emits it and stops its turn, the orchestrator dispatches the review subagent in parallel (`run_in_background: true`, short-lived, does not count toward the cap — orchestrator-level and orthogonal to the implementing-agent slot accounting), and `SendMessage`s the result back to the implementing agent which then exits cleanly. The Phase 5b shell monitor drives the PR to merge after automerge is set, escalating to focused mini-agents only when judgment is required.

  **Trade-off — the warm-agent restructure (#93).** Keeping the implementing agent warm through review reduces parallelism: with cap=3, three issues at any phase (implementing, reviewing, addressing findings) occupy all three slots, so a fourth issue waits for the orchestrator to run the merge handoff after one of them returns `READY_TO_MERGE` (i.e. the `automerge_set` transition) rather than queueing onto `READY_FOR_REVIEW` as it did under the previous (#75/#76) split. The win is **review context preservation**: when the review surfaces a design-intent finding ("reconsider this whole approach", "this naming is wrong because of X"), the original implementing agent has the unstated reasoning behind the original choice and can either defend it or change course knowingly — a fresh address-review agent reading the diff cold cannot. On runs where review tends to surface design-intent findings, the context preservation is worth the throughput cost. On runs where reviews are mostly trivial wording / typo fixes and throughput dominates, this is a regression — but `cap=1` already handles the "throughput doesn't matter" case (serial dispatch, hot-shared-file batches), so the asymmetry is acceptable: the binding constraint on observed batch runs is the review-tail wall-clock, not implementation parallelism.
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

- Read failure logs before acting (`bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/triage-ci-failure.sh" <repo> <run-id>` — emits a focused ~30-line summary; the CI-failure-fix mini-agent (Phase 5b) is the canonical caller).
- Fix the root cause; don't pin around it, disable the check, or retry blindly.
- Environmental / flaky failures (infra outage, rate limit, unrelated to this PR's diff) get reported but not retried — surface the issue rather than re-running.

**A check passing 'success' isn't the same as the check doing its job.** If a workflow has a "check secrets" guard and exits 0 when secrets are missing, the side effect (committed file, set label, posted comment) won't happen. When you see a downstream check fail because an upstream artifact is missing (e.g. `changelog-lint` failing because no `pr-<N>-*.yml` exists, when a `changelog-bot` workflow ran and reported success), look at the upstream workflow's logs for `secrets not configured`-style notices before assuming a race or retrying.

### Common gotchas

**Trigger-surface widening triggers retroactive CodeQL findings.** If your PR adds `workflow_run` or `pull_request_target` as a trigger to any workflow file, audit *every* `run:` block in that file for inline `${{ steps.* }}`, `${{ github.event.* }}`, or `${{ inputs.* }}` interpolations. CodeQL will treat values flowing from the new trigger as untrusted, and existing safe-looking interpolations become `js/actions/command-injection` findings. Convert affected interpolations to the `env:` block + `${VAR}` shell expansion pattern that the rest of the file likely already uses. Run the local CodeQL action if available, or expect a CI failure on first push.

**CWD discipline — prefer absolute paths and `--repo <owner>/<repo>` over CWD-derived defaults.** A stranded CWD (the bash session sitting in a directory that has been moved or deleted) is a classic source of opaque `git`/`gh` errors — typically `git: fatal: unknown error occurred while reading the configuration files` or similar. The Phase 6 worktree removal is the most common trigger (the orchestrator may have `cd`'d into the worktree earlier to push an empty commit, manually resolve `BEHIND`, or check git state, and the cleanup then deletes that directory under it), but anything that moves or removes a directory the bash session is sitting in produces the same failure mode. Two-pronged defence: (a) Phase 6 step 3 ends with a `cd` back to the repo root so the next command lands in a known-good CWD, and (b) the orchestrator should otherwise prefer absolute paths and explicit `--repo <owner>/<repo>` flags on `gh` calls — and `git -C <abs-path>` for `git` — rather than relying on CWD-derived defaults, so a stranded CWD degrades gracefully instead of producing cryptic errors.

## Phase 1 — Intake

### Phase 1.0 — Session ID

Two paths, mutually exclusive:

- **Fresh run (no `--resume`).** Generate a session ID and log it once, chat-visible, before resolving the issue list. The user uses this ID later if they need to `/workflow:implement --resume <id>` or `--session forget <id>` (see § Session state).

  ```bash
  session_id=$(printf 'wfi-%s-%s' \
    "$(date -u +%Y-%m-%d)" \
    "$(openssl rand -hex 2 2>/dev/null || head -c2 /dev/urandom | xxd -p)")
  printf 'workflow:implement session: %s\n' "$session_id"
  ```

  Then proceed to issue-list resolution below.

- **Resume (`--resume <id>`).** Load the persisted state file:

  ```bash
  bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" get <id>
  ```

  If the file is missing, **bail out hard** — see § Bail-outs. Do not auto-create. On success, the file contains everything Phase 1 / Phase 2 / Phase 3 would otherwise re-derive: selector args, resolved issue list, dep graph, per-issue terminal state, and the progress-digest tail. Skip the issue-list resolution and the Phase 3 dep-analysis pass (deps were declared and persisted on the original run). Re-enter the pipeline at Phase 4 — but **only to apply labels and create TaskList tasks for issues whose persisted state is `scheduled` or `in-progress`**; merged / paused / errored / externally_closed issues keep their existing state and are surfaced in the next progress digest. Phase 5 step 0 (per-issue resumption check) then runs as normal for every non-terminal issue.

  **Phase 2 on `--resume` is selective, not skipped.** Issues whose persisted state is one of `merged`, `errored`, `paused`, `in-progress`, or `scheduled` already had their clarifications applied to the issue body on the original run (or weren't holding any outstanding clarification), so re-asking would be noise — use the cached body and skip Phase 2 for those. Issues whose persisted state is **`blocked`** are different: they parked on a clarification request that the *prior* (now-gone) conversation held in chat, and the question never made it onto the issue body. The state file's `blocked_question` field has it, and a `Claude: Blocked — <question>` comment was posted to the issue at the park (see Phase 7 / the dispatch template's "Blocker handling" — both write the same comment). Re-run Phase 2 selectively for the resumed-`blocked` set:

  1. For each issue with `state == "blocked"`, re-fetch the issue body fresh (`gh issue view <n> --json body --jq .body`) — the user may have edited it out-of-band while the session was gone. Read the latest `Claude: Blocked — <question>` comment via `gh issue view <n> --comments` (or `gh api repos/:owner/:repo/issues/<n>/comments` if a tighter probe is needed) and prefer that as the canonical question text; fall back to the state file's `blocked_question` only if the comment is missing (e.g. the user deleted it).
  2. Compile the resumed-`blocked` questions into the same single batched message Phase 2 already uses — numbered, grouped by issue — alongside any other resumed-blocked issues in the run. Surface to the user. Wait for answers.
  3. After answers, apply each answer via `gh issue edit <n> --body "<updated>"` (so a future dispatch reads the resolved context from the issue body, not from chat history) and remove the `blocked` label.
  4. **Flip the per-issue state in the session state file from `blocked` back to `scheduled`** so Phase 5 dispatch picks the issue up on the next loop tick — and clear the now-stale `blocked_question` field on the same call so a future progress digest, `--session list`, or any downstream state-file reader doesn't surface a question that has already been answered:

     ```bash
     bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" update-issue \
       "$session_id" <n> scheduled blocked_question=
     ```

     The `update-issue` allow-list already permits the `blocked → scheduled` transition and accepts an empty string for `blocked_question` (the helper's allow-list at `scripts/session-state.sh` only validates string values, so an empty string is the canonical "cleared" representation — there is no `null` passthrough). No schema change is needed.

  Worked example. State file says `#412` is `blocked` with `blocked_question: "Should the new export use kebab-case or snake_case for the env var name?"`. On `--resume`:

  ```bash
  # 1. Fresh fetch (body may have changed while we were gone) + latest Claude: Blocked comment.
  gh issue view 412 --json body --jq .body
  gh issue view 412 --comments  # find the latest "Claude: Blocked — …" comment
  # Latest comment: "Claude: Blocked — Should the new export use kebab-case or snake_case…"

  # 2. Orchestrator batches this question with any other resumed-blocked issues into ONE message:
  #    "Resumed clarifications:
  #       1. #412 — Should the new export use kebab-case or snake_case for the env var name?
  #       2. #418 — …"
  #    Surfaces to user, waits.

  # 3. User answers "kebab-case". Orchestrator applies it to the issue body and drops the gate label:
  gh issue edit 412 --body "<existing body + 'Decision: env var name uses kebab-case (CLAUDE_FOO_BAR).'>"
  gh issue edit 412 --remove-label blocked

  # 4. Flip the session state from blocked → scheduled so Phase 5 picks it up,
  #    and clear the parked-question field on the same call.
  bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" update-issue \
    "$session_id" 412 scheduled blocked_question=
  ```

  **Ordering — selective Phase 2 runs *before* Phase 4 re-entry.** Run the selective re-Phase-2 above to completion (questions surfaced, answers applied, `blocked → scheduled` flips written) *before* the Phase 4 re-entry pass at line 121, not after. Phase 4 attaches the `scheduled` label and creates a TaskList task for every issue whose persisted state is `scheduled` or `in-progress` at the time it runs; an issue freshly flipped from `blocked → scheduled` only picks up its label and TaskList row if Phase 4 sees it as `scheduled` — i.e. after the flip. If Phase 4 ran first, newly-unblocked issues would slip straight to Phase 5 dispatch with no TaskList task tracking them.

  Phase 5 then dispatches `#412` on its next loop tick exactly as it would for any freshly-scheduled issue. (The `Closes #N` PR will reach merge through the normal pipeline; nothing about the resumed-from-`blocked` path differs after this point.)

  Log the resumed session ID once, chat-visible, with a one-line summary so the user can confirm:

  ```text
  workflow:implement resumed: <id> — repo=<owner/repo> selector=<...> in-flight=<n>
  ```

### Phase 1.1 — Resolve the issue list

Resolve the issue list (fresh runs only — `--resume` skips this):

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
- **Merge mechanism** — emitted as the `Merge mechanism:` trailer. The orchestrator's Phase 5 step 5 LGTM / `READY_TO_MERGE` branches parse this line to decide which merge-handoff command to run. Three possible values, picked in this order: (1) `apply <label> label (merge-bot picks it up)` — emitted when the two-signal label-triggered merge-bot heuristic fires (a workflow listens to `pull_request: types: [labeled]` with a label-name guard, **and** that label appears on at least half of the recent merged PRs); (2) `gh pr merge --auto --squash` — emitted when the merge-bot heuristic doesn't fire and the script's `allow_auto_merge` probe (`gh api repos/<owner>/<repo> --jq '.allow_auto_merge'`) returns `true`; (3) `gh pr merge --squash` — emitted when the merge-bot heuristic doesn't fire **and** the probe returns `false` (or fails). The third branch exists because GitHub auto-merge is a per-repository setting: when it's disabled, `gh pr merge --auto --squash` fails with the GraphQL error `Auto merge is not allowed for this repository (enablePullRequestAutoMerge)` — `allow_auto_merge: false` is the cause, that error is the symptom. Emitting `gh pr merge --squash` (immediate squash-merge, no `--auto` flag) up-front avoids the round-trip and the per-PR hand-edit fallback. **The trailer is consumed at the post-review automerge gate (Phase 5 step 5), not earlier in the pipeline** — the implementing agent does not parse it, and Phase 1.5 itself never triggers a merge. Snapshotting the value at intake time keeps a single deterministic answer for the whole run; the orchestrator only acts on it once review (and address-review, if needed) has completed.

If the helper script is unavailable for any reason (e.g. the plugin install is corrupted), the orchestrator can fall back to running the steps inline — but treat that as a degraded path and flag it. The script's output is the contract; the orchestrator's merge handoff depends on the `Merge mechanism:` trailer being present.

## Session state

The orchestrator persists per-run state under `~/.claude/state/workflow-implement/<id>.json` so a run can be resumed across conversations without re-deriving selector / issue list / dep graph / dispatch context. The file is created once at the end of Phase 3 (after dependency analysis is complete and the issue list is final), and updated at every Phase 5 state transition.

### Path

`$HOME/.claude/state/workflow-implement/<session-id>.json`

Per-user (not per-project) so a user with multiple repo checkouts under `~/Projects` keeps a single state directory. The `repo` field inside the file scopes each session to a specific `<owner>/<repo>`, so cross-repo sessions don't collide. The `--session list` subcommand surfaces the `repo` field in its output for disambiguation.

### Shape

```json
{
  "session_id": "wfi-2026-04-27-a1b2",
  "repo": "aidanns/claude-skills",
  "created_at": "2026-04-27T11:42:00Z",
  "updated_at": "2026-04-27T12:18:33Z",
  "selector": {"label": "scheduled", "milestone": "MS-2 General"},
  "deps": {"282": [281], "283": [281]},
  "issues": {
    "281": {
      "number": 281,
      "state": "merged",
      "branch": "aidanns/foo",
      "worktree": "/home/aidanns/Projects/claude-skills/.claude/worktrees/agent-xyz",
      "pr_number": "91",
      "pr_url": "https://github.com/aidanns/claude-skills/pull/91",
      "agent_id": null,
      "blocked_question": null,
      "paused_reason": null,
      "errored_reason": null,
      "body_snapshot": null,
      "labels_snapshot": null
    },
    "282": {"number": 282, "state": "in-progress", "branch": "aidanns/bar", "worktree": "...", "pr_number": null, "pr_url": null, "agent_id": "agent-a98681219485b754d", "...": null},
    "283": {"number": 283, "state": "scheduled", "...": null}
  },
  "digest_tail": [
    {"ts": "2026-04-27T12:18:00Z", "line": "#282 https://… — review: pending — CI: pending (3/8) — merge: clean"}
  ]
}
```

Per-issue `state` field — terminal token from the orchestrator's perspective:

- `scheduled` — Phase 4 applied the label, no agent dispatched yet.
- `in-progress` — agent dispatched (Phase 5 step 4), PR may or may not be open yet.
- `automerge_set` — orchestrator set automerge after review completed (Phase 5 step 5). Phase 5b's shell monitor is now driving the PR to merge.
- `merged` — Phase 5b shell monitor emitted `MERGED`; Phase 6 housekeeping is done or in progress.
- `blocked` — agent returned `BLOCKED <question>` (Phase 7). `blocked_question` carries the parked question. The `body_snapshot` and `labels_snapshot` fields are populated at this transition (used by the parked-issue poll — see § Progress reporting § Parked-issue poll).
- `paused` — agent returned `PAUSED <reason>` (Phase 5 step 5 PAUSED branch). `paused_reason` carries the pause cause.
- `errored` — agent returned `ERRORED <error>`. `errored_reason` carries the error string.
- `externally_closed` — the parked-issue poll observed `state == CLOSED` on GitHub (issue closed externally — duplicate, no-repro, etc.) while the issue was `blocked`. Terminal; treated as fully-resolved for Phase 8 garbage collection (the issue is gone — re-dispatch would produce orphan work).

Per-issue dispatch-context fields (`branch`, `worktree`, `pr_number`, `pr_url`, `agent_id`, `blocked_question`, `paused_reason`, `errored_reason`, `body_snapshot`, `labels_snapshot`) are written by `update-issue` as state advances. `agent_id` is the harness-assigned ID of the warm implementing agent — populated when the agent is dispatched (Phase 5 step 4) and cleared when the agent terminates (`READY_TO_MERGE`, `BLOCKED`, `PAUSED`, `ERRORED`). The malformed-terminal recovery probe (Phase 5 step 5) uses this field to decide whether to `SendMessage` the warm agent or fall back to dispatching the address-review mini-agent fresh.

The `digest_tail` keeps the last 50 progress-digest lines so a `--resume` reattachment can show the user where the run was last time without re-polling GitHub.

### Helper script

Read / write the state file via the colocated helper:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" <subcommand> ...
```

Subcommands:

| Subcommand | Use |
|---|---|
| `init <id> <repo> <selector-json> <issues-json> [<deps-json>]` | Phase 3 → create the state file from the resolved issue list. Per-issue state defaults to `scheduled` and dispatch-context fields default to `null`. |
| `get <id>` | Phase 1 (`--resume`) → print the state file, or exit 1 if missing. |
| `path <id>` | Print the absolute path (whether or not the file exists). |
| `update-issue <id> <issue#> <new-state> [<key=value> ...]` | Phase 5 / Phase 6 → flip per-issue state and patch dispatch-context fields. Allow-listed keys: `branch`, `worktree`, `pr_number`, `pr_url`, `agent_id`, `blocked_question`, `paused_reason`, `errored_reason`, `body_snapshot`, `labels_snapshot`. Allow-listed `<new-state>` values: `scheduled`, `in-progress`, `automerge_set`, `merged`, `blocked`, `paused`, `errored`, `externally_closed`. |
| `append-digest <id> <line>` | Phase 5 progress reporting → append a digest line to `digest_tail` (capped at 50 entries). |
| `list` | `--session list` → enumerate every state file with ID, repo, last-modified timestamp, selector summary, in-flight count. |
| `delete <id>` | Phase 8 → remove the state file once every issue is terminal. |

The script keeps all JSON manipulation inside `jq`; the orchestrator should not parse / format the JSON itself.

### Garbage collection

The state file is deleted in Phase 8 once every issue is **fully resolved** — `merged`, `errored`, or `externally_closed`. `blocked` and `paused` do not count as fully resolved (the user is expected to come back via `--resume <id>`); see Phase 8.1 for the rule. The `externally_closed` outcome is terminal in the same sense `merged` is — the issue is gone, no further orchestrator action is possible — so it qualifies for GC alongside `merged`/`errored` (otherwise an externally-closed issue would orphan the state file). A leftover file means a run aborted before reaching Phase 8 *or* parked on user input; `--session list` will surface it and the user can `--resume <id>` or manually clear it. A future `--session forget <id>` flag could expose the `delete` subcommand directly for explicit cleanup, but until then `rm ~/.claude/state/workflow-implement/<id>.json` is the manual escape hatch.

### Recovering a corrupted state file

A long-running session that survives a kernel panic / disk-full / SIGKILL can leave the state file truncated mid-write or otherwise unparseable. The orchestrator detects this on `--resume <id>` (see § Bail-outs) and `--session list` flags the file with `(corrupted — see § Session state recovery)` instead of silently skipping it, so the user has a clear signal that something is wrong. There is no in-skill auto-repair today — the user explicitly chooses between "fix the JSON by hand" (preserves dep graph + digest history) and "delete and re-derive" (loses both, but unblocks). Manual recovery sequence:

1. **Back up the file before touching it.** A surprise edit that makes things worse is recoverable from the backup; an in-place botched repair is not:
   ```bash
   cp ~/.claude/state/workflow-implement/<id>.json{,.bak}
   ```
2. **Try to fix the JSON manually.** `jq . ~/.claude/state/workflow-implement/<id>.json` is the quickest validator — it points at the line / column where parsing failed. Common breakage patterns:
   - **Truncated mid-write** — the closing `}` (or `]` on `digest_tail`) is missing because a SIGKILL caught the process between `jq` finishing and `mv` committing the temp file. Fix: append the missing brackets in nesting order; re-run `jq .` until it parses.
   - **Partial array element** — a `digest_tail` entry was half-serialised (`{"ts": "..."` with no `line` field and no closing `}`). Fix: trim the dangling fragment and the trailing comma so the array closes cleanly.
   - **Corrupted UTF-8** — a non-UTF-8 byte landed in a string field (typically `blocked_question` or a `digest_tail` line). Fix: open in an editor that can show byte offsets and replace the offending byte; or `iconv -f utf-8 -t utf-8 -c` to drop invalid sequences.
   Validate after each edit: `jq . ~/.claude/state/workflow-implement/<id>.json >/dev/null` should exit 0.
3. **If unfixable, delete and start over.** This loses the dep graph and the `digest_tail` (the per-issue terminal state can be re-derived from GitHub labels on the next run, but the orchestrator-only context cannot):
   ```bash
   rm ~/.claude/state/workflow-implement/<id>.json
   /workflow:implement <original selector>   # fresh ID; same labels still on the issues
   ```
   The fresh run will re-resolve the issue list, re-build the dep graph from `Depends on:` markers in issue bodies, and pick up `in-progress` issues via Phase 5 step 0's per-issue resumption probe. The lost `digest_tail` only affected `--resume`-time context display; it has no functional impact on the run.
4. **(Future)** A future `--session repair <id>` flag could automate steps 1-3 — parse-validate the file, back it up to `<id>.json.broken-<timestamp>`, and re-derive a minimal state from GitHub (the resolved issue list, current per-issue states from labels) with empty `digest_tail` and empty `deps`. The user would accept the dep-graph / digest loss explicitly. Tracked separately; not in this skill today.

### Layering with Phase 5 step 0

`--resume` and Phase 5 step 0 cover different layers and compose cleanly:

- **`--resume <id>`** rehydrates the **orchestrator layer**: selector, resolved issue list, dep graph, per-issue terminal state, progress-digest tail. It is invoked once at session start.
- **Phase 5 step 0** rehydrates the **agent layer** per-issue: an existing branch / open PR / `in-progress` label. It runs once per issue inside the active session (whether fresh or resumed) and dispatches a *resumption prompt* instead of a *fresh prompt* when it detects partial work.

A resumed session re-enters Phase 5 with rehydrated orchestrator state; Phase 5 step 0 then runs as normal per-issue. The two are not redundant — orchestrator state cannot be reconstructed from GitHub alone (selector args and dep graph aren't on the issues; the dispatch history isn't surfaced anywhere), and per-issue resumption can't be reconstructed from the state file alone (the dispatched agent's branch may have advanced past what the state file recorded). Treat them as a pair.

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

On `--resume`, this same flow runs **selectively** — only for issues whose persisted state is `blocked` (they parked on a question the prior conversation held in chat, never persisted to the issue body). All other resumed issues skip Phase 2 and use the cached body. See Phase 1.0's `--resume` branch for the selective-re-run mechanics and worked example.

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

### Initialise session state

At the end of Phase 3 (after the issue list is final and the dep graph is built), persist the orchestrator-level state file. **Fresh runs only — `--resume` reuses the existing file untouched.**

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" init \
  "$session_id" \
  "<owner/repo>" \
  '<selector-json — e.g. {"label":"scheduled","milestone":"MS-2 General"}>' \
  '<issues-json — e.g. [281,282,283]>' \
  '<deps-json — e.g. {"282":[281],"283":[281]}>'
```

Every issue is initialised with `state: "scheduled"` and empty dispatch-context fields. Subsequent state transitions (Phase 4 onwards) update the file via `update-issue` / `append-digest`.

## Phase 4 — Scheduling

Apply `scheduled` to every in-scope issue and create one orchestrator task per issue via `TaskCreate` so progress is visible in the main session's task list:

```bash
gh issue edit <n> --add-label scheduled
```

```text
TaskCreate(subject: "Process issue #<n> (<short title>)",
           description: "[<session-id>] <one-line scope>",
           activeForm: "Processing #<n>")
```

The `[<session-id>]` prefix on the `description` field surfaces the session ID alongside every TaskList row so the user can find it again without grepping the state directory — important because `--resume <id>` is the only way to reattach to a lost run, and the chat-visible intake log line scrolls off quickly. (The `subject` stays clean — adding the prefix there would clutter the TaskList and the same information is already in `description`.)

Track task lifecycle in lockstep with the issue label lifecycle:

- On dispatch (Phase 5 step 2): `TaskUpdate(status: "in_progress")` — issued as a **standalone tool call**, not bundled with the `gh issue edit` label flip or the `Agent` dispatch. See Phase 5 step 2 and the "Why standalone TaskUpdate" note in Phase 6 for the cancellation hazard.
- On `MERGED` notification (Phase 5 step 5): `TaskUpdate(status: "completed")` — issued as a **standalone tool call** in Phase 6 step 1, not bundled with the worktree / pull / label cleanup. Same reasoning.
- On `READY_FOR_REVIEW` heartbeat (the implementing agent paused mid-pipeline awaiting `SendMessage`) and on `READY_TO_MERGE` (the implementing agent's terminal-success token after addressing any review findings): leave the task `in_progress`. The orchestrator dispatches the next phase (review subagent on heartbeat, merge handoff on `READY_TO_MERGE`) and flips to `completed` only when the Phase 5b shell monitor emits `MERGED`.
- On orchestrator-internal `automerge_set` state (after the orchestrator runs the merge handoff): same — leave `in_progress`; flip to `completed` when the Phase 5b shell monitor emits `MERGED`.
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

0. **Resumption check (per-issue, agent layer)** — before dispatching a fresh agent, look for state from a prior aborted attempt:

   - Issue already labelled `in-progress` or `paused` (carried over from a halted run).
   - Open PR with `Closes #<N>` in its body.
   - Branch on origin matching the project's branch convention for this issue.
   - **Session state file** for this run records `branch` / `pr_number` / `pr_url` for the issue (rehydrated on `--resume`, or written by the current run earlier in the session).

   If any exist, the prior agent partially completed work. Dispatch with a *resumption* prompt instead of the standard one: name the existing branch / PR explicitly and tell the agent "do NOT restart — check out the existing branch, fix what's incomplete, push, drive to merge." This avoids duplicate PRs and clobbered work.

   **How this composes with `--resume <id>`.** `--resume` rehydrates the orchestrator layer — selector, dep graph, per-issue terminal state — *before* Phase 5 runs. This step then runs per-issue inside the rehydrated session and continues to discourage agent-level restart whenever it spots an existing branch / PR. The orchestrator-vs-agent layering is intentional: orchestrator state lives in the session state file (because it cannot be reconstructed from GitHub), agent state lives on GitHub (because it's the source of truth for branches / PRs / labels). Treat them as a pair — the state file's per-issue dispatch context (`branch`, `pr_number`) is *one* of the four signals this step considers, not the only one.

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

5. **Monitor** — Claude Code notifies the orchestrator when each background agent completes. On notification, route by terminal token. The state machine across the implementing → reviewing → (LGTM | addressing) → merging pipeline keeps the implementing agent **warm** through review and address-review (issue #93 — the implementing agent owns its branch end-to-end so review-finding fixes preserve the original implementing agent's design context):

   ```
   implementing  --[READY_FOR_REVIEW heartbeat]-->  reviewing
   reviewing     --[LGTM]-->                        SendMessage(implementing): "LGTM, exit"  -->  implementing returns READY_TO_MERGE  -->  merging
   reviewing     --[FINDINGS]-->                    SendMessage(implementing): "address findings"  -->  implementing addresses, returns READY_TO_MERGE  -->  merging
   merging       --[Phase 5b shell monitor drives the PR to MERGED]
   ```

   Each orchestrator-side transition is parsed from a literal terminal token in the agent's `result` field. `READY_FOR_REVIEW` is a **heartbeat** — the implementing agent emits it and stops its turn, the orchestrator dispatches the review subagent in parallel, and the implementing agent resumes when the orchestrator's `SendMessage` lands. `READY_TO_MERGE` is the implementing agent's **terminal-success token**: it means "I have addressed every review finding (or there were none) and pushed; please run the merge handoff." The implementing agent never sets automerge; the orchestrator does, after the warm agent returns `READY_TO_MERGE`.

   **State-file persistence on every transition.** Every state change below — `dispatch` (in-progress), `automerge_set`, `merged`, `blocked`, `paused`, `errored`, `externally_closed` — is mirrored into the session state file via the helper script *as part of the same orchestrator step that fires the transition*. This is what makes `--resume` viable: the file is the durable record of where the run is. Concretely:

   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" update-issue \
     "$session_id" <issue#> <new-state> [branch=... worktree=... pr_number=... pr_url=... agent_id=... blocked_question=... paused_reason=... errored_reason=...]
   ```

   - On dispatch (Phase 5 step 4): `update-issue <id> <n> in-progress branch=<b> worktree=<wt> agent_id=<harness-agent-id>`. The `agent_id` is the harness's identifier for the dispatched agent, used by Phase 5 step 5's review-result routing (`SendMessage(<agent_id>, ...)`) and by the malformed-terminal recovery probe (Branch 3) to decide whether to message the warm agent or fall back to dispatching the address-review mini-agent fresh.
   - On the implementing agent's `READY_FOR_REVIEW` heartbeat: `update-issue <id> <n> in-progress pr_number=<p> pr_url=<u>` (state stays `in-progress`; only the dispatch context advances; `agent_id` stays populated because the agent is paused awaiting `SendMessage`, not terminated).
   - On the implementing agent's `READY_TO_MERGE` terminal: `update-issue <id> <n> in-progress agent_id=` (the warm agent has terminated; clear `agent_id` so the malformed-terminal probe doesn't try to `SendMessage` a gone agent on a future tick). The orchestrator then runs the merge handoff — see automerge-gate below.
   - On automerge set (the orchestrator runs the merge handoff after the warm agent's `READY_TO_MERGE` return): `update-issue <id> <n> automerge_set`.
   - On the Phase 5b shell monitor's `MERGED` event: `update-issue <id> <n> merged` (Phase 6 housekeeping then runs).
   - On `BLOCKED`: `update-issue <id> <n> blocked blocked_question="<question>" agent_id= body_snapshot="<issue body>" labels_snapshot="<comma-joined sorted labels>"`. Clear `agent_id` (the agent terminated). The `body_snapshot` / `labels_snapshot` fields seed the parked-issue poll (see § Progress reporting § Parked-issue poll § Snapshot persistence) so the first post-park tick has something to compare against — and so a `/clear` + `--resume <id>` reattachment doesn't lose the comparison baseline.
   - On `PAUSED`: `update-issue <id> <n> paused paused_reason="<reason>" agent_id=`. Clear `agent_id` (the agent terminated).
   - On `ERRORED`: `update-issue <id> <n> errored errored_reason="<error>" agent_id=`. Clear `agent_id` (the agent terminated).
   - On `externally_closed` (parked-issue poll observed `state == CLOSED`): `update-issue <id> <n> externally_closed`. No further state-file fields are required — the existing `blocked_question` survives in the file as the audit trail of what the issue had been parked on before it was closed externally; `agent_id` was already cleared when the issue parked on `BLOCKED`.

   Treat the state-file write as part of the transition, not a follow-up: a Claude Code crash *between* the transition and the file write would leave the orchestrator and the file out of sync, which is the exact failure mode `--resume` is meant to prevent.

   **Automerge gate (invariant).** The orchestrator sets automerge ONLY after BOTH of these hold:

   1. **Independent review has completed** — either the orchestrator-level review subagent returned `LGTM` (single `Claude Reviewer: LGTM` PR-level comment, zero inline findings) AND the warm implementing agent has returned `READY_TO_MERGE` after acknowledging the `SendMessage`, OR every `Claude Reviewer:` finding has a threaded reply addressing it AND the warm implementing agent has returned `READY_TO_MERGE` after applying the fixes. (In the rare fallback path where the address-review mini-agent runs instead of the warm agent — see Phase 5b § Address-review mini-agent for when — that mini-agent's `READY_TO_MERGE` return satisfies condition 1 the same way.)
   2. **CI is acceptable** — rollup is green, OR every failing check is an environmental / flaky failure (infra outage, rate limit, unrelated to the diff) that the orchestrator's CI-failure pathway has classified as `ENVIRONMENTAL`, OR there are no CI workflows on the PR (the rollup is empty).

   **Crucially: the no-CI case does NOT short-circuit condition 1.** Repos without CI workflows have the review subagent as the only safety net; firing automerge before review runs would mean the merge lands with zero independent verification. The implementing agent's self-review is not a substitute — that's an internal code-quality pass on its own diff, not the independent verification this gate enforces. Apply both conditions in the order written: gate on review-completion first, then on CI-acceptable, then run the merge handoff.

   Routing per token:

   - **READY_FOR_REVIEW (heartbeat)**: implementing agent finished step 6 (PR open, self-review of own diff complete) and stopped its turn awaiting the orchestrator's `SendMessage`. The agent is **paused, not terminated** — its `agent_id` is still populated in the state file, the implementing-agent slot is still occupied (cap=3 binds through the full pipeline; see Operating principles § "Concurrency cap: 3"), and the next eligible issue does NOT get picked up off the back of this heartbeat. Dispatch the **review subagent** at the orchestrator level (template embedded below — same prompt the previous dispatch step 6.1 used) with **`run_in_background: true`**. The review subagent does not count against the implementing-agent concurrency cap of 3 (review subagent and address-review fallback mini-agent are orchestrator-level, short-lived, and orthogonal to the cap). Background dispatch is load-bearing: with cap=3, three implementing agents can heartbeat `READY_FOR_REVIEW` near-simultaneously, and a foreground review dispatch would block the orchestrator on the first review while the next two PRs sit waiting. Background lets all three reviews run concurrently while the orchestrator stays responsive on its event loop.

     When the review subagent's terminal notification arrives, the orchestrator parses the `result` field by literal prefix (same shape as the implementing-agent terminal-return routing) and branches by `SendMessage`-ing the warm implementing agent rather than dispatching a fresh address-review:
     - **Zero findings (LGTM)** — the only review output is a single `Claude Reviewer: LGTM` PR-level comment and there are zero inline `Claude Reviewer:` comments. `SendMessage(<implementing-agent-id>, "Review LGTM, exit with READY_TO_MERGE.")` — the warm implementing agent receives the message, runs whatever final acknowledgment it needs (no code changes), and returns `READY_TO_MERGE <pr-url>` via its own terminal notification, which the orchestrator routes through the `READY_TO_MERGE` branch below to satisfy condition 1 of the automerge gate.
     - **≥1 finding (`FINDINGS <pr-url> <count>`)** — at least one inline `Claude Reviewer:` comment landed. `SendMessage(<implementing-agent-id>, "Review posted <count> findings inline. Fetch unaddressed Claude Reviewer: comments, address each (commit, push, threaded Claude: Done! reply), then return READY_TO_MERGE <pr-url>.")`. The warm implementing agent — which still has its full original design context — addresses each finding on its own branch, pushes, threads the replies, and returns `READY_TO_MERGE <pr-url>` via its own terminal notification (which the orchestrator routes through the `READY_TO_MERGE` branch below). The fresh-address-review path (a separate cold-start mini-agent reading the diff cold) is the **fallback**, not the default — see Phase 5b § Address-review mini-agent for the two cases that trigger it (warm-agent unreachable, user-requested fresh take).
     - **Malformed `result`** — the review subagent's `result` field doesn't start with `LGTM`, `FINDINGS`, or `ERRORED`. Route through the same **PR state reconstruction probe** described in the malformed-terminal branch below; its branches (no PR, review never ran, unaddressed `Claude Reviewer:` comments exist, CI red, merge-trigger not applied) already cover the recovery surface for a review subagent that exited without a clean token.

     Do **not** fire a `PushNotification` for `LGTM` / `FINDINGS` / `READY_TO_MERGE` — these are mid-pipeline transitions, not user-action handoffs. The TaskList badge stays `in_progress` through review and the warm-agent address-review pass; the digest's `review:` field surfaces progress. (`ERRORED` from the review subagent or the warm implementing agent does fire a `PushNotification` per the existing `ERRORED` branch below — same rationale as an implementing agent's `ERRORED` under the previous contract.)
   - **READY_TO_MERGE (terminal)**: the warm implementing agent has acknowledged the `SendMessage` and (if findings landed) addressed every `Claude Reviewer:` finding on its branch — its turn ends with this token, the `agent_id` field is cleared, and the slot will free once the orchestrator runs the merge handoff and hands off to Phase 5b. The orchestrator parses this notification's `result` field by literal prefix match on `READY_TO_MERGE`, with malformed returns routing through the reconstruction probe. Condition 1 of the automerge gate is now satisfied. Verify condition 2 (CI acceptable, same rules as the LGTM branch above): if CI is red with non-environmental failures, run the CI-failure-fix pathway first; otherwise the orchestrator sets automerge per the observed `Merge mechanism:` line — one of three values: apply the configured label (`gh pr edit <pr#> --add-label <label>`), run `gh pr merge --auto --squash` (native auto-merge, when the repo allows it), or run `gh pr merge --squash` (immediate squash-merge, when the repo has auto-merge disabled) — then hands off to **Phase 5b** (post-automerge monitoring). Mark `automerge_set`. Do **not** fire a `PushNotification`. (In the rare fallback path where the address-review mini-agent ran in place of the warm agent, its `READY_TO_MERGE` return is routed identically — same automerge gate, same merge handoff.)
   - **MERGED**: GitHub closed the issue via `Closes #<n>`. Mark task done; pick up the next eligible issue. Do **not** fire a `PushNotification` — heartbeat-grade once the TaskList badge flips to `completed`. (This token is normally emitted by the Phase 5b shell monitor, not by an implementing agent.)
   - **BLOCKED**: ensure `blocked` label set, `in-progress` removed; record the question for batched surfacing in Phase 7. Fire one `PushNotification` summarising the parked issue and question — e.g. `PushNotification(message: "/implement: #<n> blocked — <question>")`. This is a terminal handoff back to the user; the OS notification is the bell that "user action needed" wants.
   - **PAUSED**: ensure `paused` (or `blocked`) label is set; record the reset time. Re-dispatch a resumption agent (Phase 5 step 0 path) after the condition clears. Fire one `PushNotification` summarising the pause — e.g. `PushNotification(message: "/implement: #<n> paused — <reason>")`. Same rationale as `BLOCKED`.
   - **ERRORED**: surface immediately to user; do not retry without instruction. Fire one `PushNotification` summarising the error — e.g. `PushNotification(message: "/implement: #<n> errored — <error>")`. Same rationale as `BLOCKED`.
   - **Malformed terminal (no literal-prefix match)**: the agent's `result` field doesn't start with one of the recognised terminal tokens (`READY_FOR_REVIEW` heartbeat, `READY_TO_MERGE`, `MERGED`, `BLOCKED`, `PAUSED`, `ERRORED`). The realistic distribution is "agent narrated 'polling for CI to finish' instead of returning a token" — every bit of state needed to drive the PR home is observable on the PR itself. Run the **PR state reconstruction probe** below before falling back to ERRORED; the user only sees the malformed result string if the probe can't classify the state. **Review subagent and address-review fallback mini-agent malformed returns also route through this probe** — their tokens (`LGTM` / `FINDINGS` for the review subagent, `READY_TO_MERGE` for the address-review fallback mini-agent) are different from the implementing agent's, but the underlying recovery branches (no PR, review never ran, unaddressed comments, CI red, merge-trigger not applied) already cover whatever state a botched orchestrator-level dispatch could leave the PR in.

     Reconstruction probe — sequential checks, **first match wins**. All branches route to existing recovery infrastructure; no new mini-agent templates are introduced.

     1. **No PR exists yet.** `gh pr list --search "Closes #<n>" --state all --json number` returns `[]`. Re-dispatch with the resumption prompt (Phase 5 step 0 path); the agent died before opening a PR, so a fresh attempt is the only recovery.
     2. **PR exists, zero `Claude Reviewer:` comments (review never ran).** The implementing agent likely died after `gh pr create` but before heartbeating `READY_FOR_REVIEW`. Treat as if the heartbeat was the (recovered) state: dispatch the orchestrator-level review subagent (same path the `READY_FOR_REVIEW` branch above takes). After it returns, the LGTM / findings branch logic in step 5 picks up — note that the warm-agent `SendMessage` path will not be available here (the agent's `agent_id` is gone or unreachable), so re-enter this probe and Branch 3 will route to the fresh address-review mini-agent fallback.
     3. **Unaddressed `Claude Reviewer:` comments exist.** Top-level reviewer comments with no replying comment in their thread. **Try the warm-agent path first**: read `agent_id` from the per-issue state file; if it's populated and reachable, `SendMessage(<agent_id>, "Review posted <count> findings inline. Fetch unaddressed Claude Reviewer: comments, address each (commit, push, threaded Claude: Done! reply), then return READY_TO_MERGE <pr-url>.")` — same message the LGTM/FINDINGS branch above sends. If the agent is gone or unreachable (Claude Code crash, `--resume` after the original session ended, malformed terminal that left no trace, the harness no longer recognising the ID), **fall back to dispatching the address-review mini-agent** (Phase 5b template — see § Address-review mini-agent for the fallback contract). When the warm agent or the fallback mini-agent returns `READY_TO_MERGE`, the orchestrator sets automerge per the observed `Merge mechanism:` line and hands off to Phase 5b's shell monitor.
     4. **CI red.** `gh pr view <pr#> --json statusCheckRollup` shows any check with `conclusion == "FAILURE"`. Apply the **CI-failure sizing rule** (Phase 5b): ≤50-line / 1–2-file fix in place at the orchestrator level, otherwise dispatch the **CI-failure-fix mini-agent** (Phase 5b template). Same stale-aggregator short-circuit applies.
     5. **CI green, review done, merge-trigger not applied.** The pipeline reached the merge handoff but didn't return cleanly. Apply the merge-trigger per the PR's observed `Merge mechanism:` line — one of three commands: `gh pr edit <pr#> --add-label <label>` (label-triggered merge-bot), `gh pr merge <pr#> --auto --squash` (native auto-merge), or `gh pr merge <pr#> --squash` (immediate squash-merge — when the repo has auto-merge disabled) — and launch the **Phase 5b shell monitor**.
     6. **Reconstruction can't classify** (e.g. PR exists, review done, no unaddressed comments, CI green, automerge label already applied — yet the agent's malformed result string suggests something is wrong). Fall through to ERRORED: fire the `PushNotification` with the captured `result` string verbatim and surface to the user. This is the safety net — never silently drop a malformed terminal.

     Each branch except (6) maps 1:1 to existing recovery infrastructure already wired up elsewhere in this skill — the probe is a router, not new behaviour.

   The harness occasionally fires duplicate `task-notification` events for an agent after it has already terminated — recognisable by 0 tool uses and a generic-sounding result string. Ignore these; rely on your own Monitor task or PR-state polling for ground truth. (And do not re-fire `PushNotification` on a duplicate — the bell already rang on the real terminal.) **Distinguish a duplicate from a malformed terminal:** duplicates have 0 tool uses and follow a real terminal that already parsed cleanly; a malformed terminal is the agent's *first and only* terminal notification, with non-zero tool uses, and its `result` simply doesn't prefix-match. Only the latter triggers the reconstruction probe.

   **Why `PushNotification` here, not `Stop`.** The orchestrator is a long-lived loop on `Monitor` / `TaskOutput` events; the model finishes a turn and goes briefly idle waiting for the next async event many times during a run. In Claude Code that idle transition fires the `Stop` hook on every cycle, so users with a bell-on-`Stop` configuration hear a constant drip even though no action is required. `Stop` cannot reliably distinguish "model is done with the whole orchestration" from "model finished this Monitor tick and will resume on the next event" — both are turn boundaries, and the hook payload doesn't carry a reliable signal. `PushNotification` is the surface the harness reserves for "user action needed" (permission prompts, idle, and explicit `PushNotification` tool calls), so firing it from the skill at the known-meaningful transitions — `BLOCKED` / `PAUSED` / `ERRORED` here, and the Phase 8 final-report bell — gives users with `Stop` removed the visibility they actually want without the heartbeat noise. `READY_FOR_REVIEW` (heartbeat), `READY_TO_MERGE` (mid-pipeline terminal), and `MERGED` (per-issue success) are intentionally silent on the OS-notification channel: the TaskList badge already conveys progress, and a bell on every mid-pipeline transition or per-issue success would re-introduce the same drip the move away from `Stop` was meant to fix. `READY_FOR_REVIEW` being a heartbeat (the implementing agent is paused, not done) does not change this rule — the user already sees the PR-opened transition via the digest, and an OS bell would still be noise.

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
- Immediately on every dispatched-agent state transition (`READY_FOR_REVIEW` heartbeat, `READY_TO_MERGE`, `MERGED`, `BLOCKED`, `PAUSED`, `ERRORED`) — emit a digest of the remaining in-flight set so the user sees the new state without waiting for the next tick. (`READY_FOR_REVIEW` is a heartbeat, not a terminal — the agent is paused awaiting `SendMessage` — but it still warrants an immediate digest because the PR-opened transition is what the user is watching for.)
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
| Run drained (in-flight count == 0) but at least one issue parked **on a clarification question** (`state == "blocked"`) awaiting user input | **3600s**     | Long-interval fallback so the orchestrator notices out-of-band changes to a `blocked` issue (label removed, body edited, issue closed externally) without requiring the user to re-invoke the skill. Each tick runs the parked-issue poll (see § Parked-issue poll below). `paused` issues do not match this row — `paused` is a wall-clock wait on an environmental condition (rate-limit / cap), recovered by the Phase 5 step 5 PAUSED branch's resumption-agent re-dispatch, not by polling GitHub for body / label / state changes. A run with only `paused` issues and no `blocked` issues falls through to the next-matching row (typically the implementing-only or default row). The user can opt out of the parked-issue poll with "stop polling, I'll re-invoke explicitly when ready" — the orchestrator then skips the `ScheduleWakeup` call entirely and reverts to the original "no wakeup" behaviour. |
| Default (mixed in-flight, none of the above special cases)                                    | **270s**      | Cache-TTL-aligned baseline.                                                                                                          |

**Examples — predicting the cadence from a run shape:**

- One PR in `automerge_set`, CI green, awaiting the GitHub merge bot → **90s**. (See `STALLED_GREEN` in Phase 5b — if the bot fails to fire within `STALL_THRESHOLD_SECONDS` of green, the monitor escalates; the 90s interval surfaces the `MERGED` transition before that threshold even matters.)
- One PR in `automerge_set` with `STALLED_GREEN` having fired and tier 2 (label-flip) just dispatched → **60s**. The next tick checks whether the label-flip nudged the bot into firing.
- Two PRs in `automerge_set`, one with CI green and one with CI in progress → **90s** (the green-and-merge-pending row matches first; the in-progress PR will be re-checked on the same tick).
- Three implementing agents in flight, no PRs opened yet → **600s**. The orchestrator wakes on each agent's terminal return; polling at 270s would just re-emit `#<N>: implementing` lines until the first PR appears.
- Run drained (last PR merged) but two issues `blocked` on user-input questions → **3600s**. Each tick polls each `blocked` issue's `state`/`body`/`labels` (see § Parked-issue poll below); a label flip, body edit, or external close re-enters Phase 5 for the affected issue. `paused` issues are not polled by this row — they're handled by the PAUSED-branch resumption-agent re-dispatch.
- Same run shape as above but the user explicitly said "stop polling, I'll re-invoke explicitly when ready" → **no wakeup**. The orchestrator skips `ScheduleWakeup` and awaits a user message; the parked-issue poll does not run.
- Mixed run: one implementing agent + one PR in `automerge_set` with CI in progress → **270s** (the in-progress-CI row matches before the agents-only row).

**Parked-issue poll:**

When the all-parked row matches and the user has not opted out of polling, the 3600s wakeup tick runs a lightweight check against each `blocked` issue's GitHub state. Without it, an orchestrator that drained to all-`blocked` is dead-on-arrival: someone (or another tool) editing the issue body, removing the `blocked` label, or closing the issue externally would never reach the run, and the user would have to remember to `--resume <id>` themselves.

What it queries — for each issue in `state == "blocked"`:

```bash
gh issue view <N> --json state,body,labels
```

**Snapshot persistence.** The poll's change-detection compares against `body_snapshot` and `labels_snapshot` fields persisted on the per-issue record in the session state file (allow-listed in `update-issue`). The snapshot is captured at the BLOCKED transition (Phase 5 step 5's BLOCKED branch — alongside the `blocked_question` write) and refreshed on every poll tick after the comparison. This makes the poll durable across `/clear` + `--resume <id>`: a resumed session reads the snapshot back from the state file and the next poll tick compares against it instead of either firing spuriously (snapshot empty ⇒ first-poll fallback) or skipping comparison entirely.

Concretely, the BLOCKED-branch state-file write extends to:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" update-issue \
  "$session_id" <n> blocked \
  blocked_question="<question>" \
  body_snapshot="<issue body at park time>" \
  labels_snapshot="<comma-joined label names at park time>"
```

`labels_snapshot` is stored as a single string (comma-joined sorted label names) rather than a JSON array to keep the allow-list value type uniform; the comparison splits and re-sorts before diffing. `body_snapshot` is the raw issue body at park time. Both are refreshed in the same `update-issue` call after each poll-tick comparison (regardless of whether a change was detected), so a quiescent issue keeps producing "no change" without re-firing on prior diffs and a noisy issue's snapshot stays current.

What counts as "changed" (any one of the following, compared against the snapshot):

- **Label removed** — the `blocked` label (or any label the user said they would flip to unblock) is no longer present. The user effectively answered the parked question by removing the gate.
- **Body updated** — the issue body differs from `body_snapshot`. The user or another tool answered the parked question by editing the body in place (the most common pattern when `/refine-issues` records a clarification).
- **State == CLOSED** — the issue was closed externally (e.g. as a duplicate or no-repro). The clarification will never come; the run should not sit parked forever.

Action on change:

- **Label removed or body updated** → re-enter Phase 5 with the affected issue: clear the `blocked` label if still present, flip per-issue state from `blocked` back to `scheduled` and clear `blocked_question` on the same call (`update-issue <id> <n> scheduled blocked_question=`) so progress digests / `--session list` don't keep surfacing an already-answered question. The `body_snapshot` / `labels_snapshot` fields stay in the file but are ignored once `state != "blocked"` (the next BLOCKED transition, if any, will overwrite them). Then let the next tick pick the issue up via the normal Phase 5 dispatch path. Surface a chat line summarising what changed ("`#<N>: blocked label removed externally — resuming`" / "`#<N>: body edited externally — resuming`").
- **State == CLOSED** → flip per-issue state from `blocked` to the terminal `externally_closed` outcome (`update-issue <id> <n> externally_closed`), drop it from the in-flight set, and surface to the user (`#<N>: closed externally — not re-dispatched`). Do **not** open a PR or re-dispatch — the issue is gone, and re-entering Phase 5 against a closed issue would either fail or produce orphan work. `externally_closed` qualifies for Phase 8 garbage collection alongside `merged`/`errored` (see § Garbage collection).

**Steady-state ticks are silent.** The digest-emission rule above (line 540) gates digests on `at least one issue is in-flight (in-progress or automerge_set)`, so the all-parked row by definition emits no digest on tick. Likewise the parked-issue poll only emits a chat line on a *change* (the three "Action on change" branches above) — a no-change tick is silent. This is intentional: an hourly heartbeat with nothing to report would be noise. Do not add a "no change" digest line to this branch; the next signal the user sees is either a real change event or the run completing.

Cost note: one `gh issue view` per `blocked` issue per hour is negligible — the all-parked branch is already low-frequency, and a typical run parks 1–3 issues at most. The poll is bounded above by the 3600s cadence and below by the size of the `blocked` set.

Opt-out: when the user says something like "stop polling, I'll re-invoke explicitly when ready," skip `ScheduleWakeup` for the all-parked row entirely (revert to the old `none` behaviour). The opt-out is per-run and is forgotten on `--resume`; the user can re-state it on resume if they still want it.

**Per-issue probe** — for each in-flight issue `<N>`, invoke the digest-line script and emit its stdout verbatim, then append it to the session state file's `digest_tail`:

```bash
line=$(plugins/workflow/skills/implement/scripts/digest-line.sh <owner/repo> <N>)
printf '%s\n' "$line"
bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" \
  append-digest "$session_id" "$line"
```

Capping `digest_tail` at 50 entries (handled by the helper) keeps the file bounded — the tail is for `--resume`-time context, not a full run log.

The script encodes the full mapping (PR lookup, review-comment counts, CI rollup aggregation, merge-state derivation, edge cases) and emits exactly one line on stdout per the format below. The orchestrator does **not** run gh queries inline or format the line itself — that work moved into the script so each tick costs ~one bash invocation per in-flight issue instead of ~500-1K tokens of inline JSON inference.

The script's exit code is always `0`; the orchestrator distinguishes outcomes via the output string. State mapping (preserved verbatim from the prior inline implementation):

1. **PR lookup** — `gh pr list --state all --search "Closes #<N> in:body" --json number,url,state,statusCheckRollup,mergeable,mergeStateStatus --limit 1`. `--state all` (not `--state open`) so a PR that merged between ticks still appears with `state: MERGED` instead of dropping out of the result set — otherwise the empty-result branch is ambiguous between "no PR opened yet" and "PR merged".

   - Empty result → `#<N> — implementing` (drop the rest of the probe).
   - `state == MERGED` → `#<N> <pr-url> — merged` (drop the issue from the in-flight set on subsequent ticks).
   - `state == CLOSED` (without merge) → `#<N> <pr-url> — closed (not merged)` (drop the issue from the in-flight set on subsequent ticks).
   - `state == OPEN` → continue with the per-state formatting below.

2. **Review status** — count `Claude Reviewer:` comments via `gh api repos/<owner>/<repo>/pulls/<pr#>/comments` (inline) and `…/issues/<pr#>/comments` (PR-level). The orchestrator-level review subagent (dispatched on the `READY_FOR_REVIEW` heartbeat) posts either inline review comments or a single LGTM PR-level comment with the `Claude Reviewer: ` prefix (the implementing agent uses `Claude: `, so the prefix discriminates):

   - Both 0 → `review: pending`.
   - Inline count ≥ 1 → `review: done (<n> findings)`.
   - Inline 0 and exactly one `Claude Reviewer: LGTM` issue-level comment, regardless of how many other PR-level comments exist (the implementing agent posts its own `Claude: ` notes — e.g. environmental-CI retries — and gating on the total PR-level count would suppress this branch whenever such a note exists) → `review: done (LGTM)`.

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
- Implementing-agent state transitions: `READY_FOR_REVIEW` heartbeat (PR open, agent paused awaiting `SendMessage` — surfaced because the user wants to see the state transition, even though the agent is not done), `READY_TO_MERGE` (terminal-success — every review finding addressed, orchestrator is about to set automerge), `BLOCKED`, `PAUSED`, `ERRORED`.
- Orchestrator-level review subagent finished: `LGTM` (review state moves to `done (LGTM)`) or `FINDINGS <count>` (review state moves to `done (<count> findings)`).
- Address-review fallback mini-agent terminal return (rare — only on the warm-agent-unreachable path): `READY_TO_MERGE` (orchestrator is about to set automerge).
- Orchestrator sets automerge (the warm agent's `READY_TO_MERGE` return — or, in the fallback path, the address-review mini-agent's `READY_TO_MERGE` — fires the merge handoff per the observed `Merge mechanism:` line) — this is the "merging" state in the state machine.
- Phase 5b shell-monitor events: `MERGED`, `CLOSED` (PR closed without merging — surface so the user notices the run won't reach all-terminal), `CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`, `BEHIND_RESOLVE_FAILED` (the monitor's `git push` was rejected after a local catch-up — usually a PAT-scope issue; the PR is parked until the user intervenes), `STALLED_GREEN` (the merge bot didn't fire after CI went green; the orchestrator is running the tier 2 / 3 / 4 ladder).
- Phase 5b mini-agent terminal returns: `RESOLVED` (conflict-resolution), `FIXED` (CI-failure-fix), `ADDRESSED` (review-comment), `ENVIRONMENTAL` (CI-failure-fix flake/infra).
- A new check `conclusion == "FAILURE"` newly observed in the rollup (the digest's `CI: red` count goes up).
- A new merge conflict newly observed (`mergeStateStatus == "DIRTY"` newly seen — the digest's `merge: conflict` first appears).
- Merge bot didn't fire after CI went green (the tier 2 / tier 3 escalation under "Tiered remediation when automerge stalls" — the user needs to see that the orchestrator is escalating).

**Suppress** — these are heartbeats; the TaskList badge is already conveying them and a chat line would be doubly redundant:

- Repeated `BEHIND_RESOLVED` events from Phase 5b's shell monitor beyond the first occurrence in a given monitor session (the auto-resolve is working as designed; one notification establishes that, the rest are noise).
- The harness's spurious post-termination "agent completed" notifications after a dispatched agent has already returned its terminal token (per the duplicate-notification note — the agent is already done, the second fire is harness-level noise).
- Progress-tick lines whose state hasn't changed since the prior tick (every digest field — review / CI / merge — produces the same string as last tick). Skip the chat-visible emission; the next tick that surfaces a real change re-emits the full digest.
- Per-check-pass heartbeats from any agent or monitor ("`unit` passed, 2 more pending", "More checks passing"). The aggregate `CI: pending (<done>/<total>)` field already renders progress in the digest; per-check chatter doesn't add information.

When in doubt, suppress. The user can always `gh pr view <pr#>` if they want raw detail; the orchestrator's job is to surface transitions, not narrate the wait.

### Dispatch prompt template (embedded in every Agent call)

The orchestrator constructs the per-agent prompt by filling in the placeholders below. The full text — not a reference — goes into the Agent call so the dispatched agent has everything it needs without consulting this skill.

```
You are implementing GitHub issue #<N> end-to-end. Session: <session-id>. The issue body follows verbatim:

---
<full body refreshed via `gh issue view <N> --json body --jq .body`>
---

Project context: this repo's conventions are described in `CLAUDE.md` (root), `.claude/instructions/*.md` (if present), and `CONTRIBUTING.md`. Read these before editing — they define language, tooling, commit-message scopes, and any project-specific rules.

<stdout of `phase15-conventions.sh <owner/repo>` embedded verbatim — a header line "Current PR conventions (observed from the N most recent merged PRs on <repo>)…" followed by bullets covering title prefix style, title length limit, ==COMMIT_MSG== block usage, label histogram, and manual-changelog status, terminated by a `Merge mechanism:` trailer that the *orchestrator* parses when running the merge handoff (you, the implementing agent, do not — your terminal-success token is `READY_TO_MERGE`, not the merge command itself). The trailer is embedded for context: convention-aware PR bodies (e.g. picking the right `==COMMIT_MSG==` shape) still depend on it.>

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

### 6. Heartbeat ready for review, await SendMessage, address findings, return READY_TO_MERGE

The PR is open. **Open the PR, do a self-review pass, emit `READY_FOR_REVIEW <pr-url>` as a heartbeat, and stop the turn.** Do **not** spawn a review subagent yourself. Do **not** check CI. Do **not** apply automerge. **This applies even in repos without CI workflows** — never reach for `gh pr merge --auto --squash` or a merge-trigger label as a "shortcut" because nothing is gating the merge on the GitHub side. The orchestrator's automerge gate (Phase 5 step 5) requires independent review to complete first; in a no-CI repo, that review is the *only* safety net, so an implementing agent that sets automerge would land the merge synchronously and skip review entirely. The orchestrator owns review dispatch, CI-fix, and merge-handoff at its own level — that's a deliberate split so review always runs at full subagent-type access (a constraint the implementing agent's harness can't guarantee), and so the no-CI synchronous-merge race is impossible by construction.

**Heartbeat, not terminal.** `READY_FOR_REVIEW` is now a *heartbeat*: you emit it, your turn stops, and the orchestrator's next `SendMessage` resumes you with the review result. You stay warm — you are still the implementing agent, your branch is still yours, and the design context behind the original implementation is still in your head where it belongs. Returning `READY_FOR_REVIEW` does **not** free your concurrency-cap slot; the slot frees when you return `READY_TO_MERGE` and the orchestrator runs the merge handoff.

**Before heartbeating, do one last self-review pass on your own diff.** This is a code-quality step, not a review step — the orchestrator's review subagent is the independent reviewer. Re-read `git diff main...HEAD` and self-correct any obvious problems (dead code, unclear names, missing tests, scope creep, undocumented decisions). The earlier step 3 self-review covered pre-push; this is one more pass after the PR is up so you can address anything that only became visible in the PR view (e.g. a file you forgot to stage, a stray debug print). Push any fixes before heartbeating. **Don't iterate forever** — one pass; if you spot something genuinely contentious, leave it for the review subagent.

Once the diff is clean, heartbeat and stop:

- `READY_FOR_REVIEW <pr-url>` — PR is open, your self-review pass is done. **Stop your turn here.** The orchestrator dispatches the independent review subagent in parallel and will `SendMessage` you the result.

**Do not poll for CI. Do not narrate progress. Do not run a review subagent yourself.** Heartbeating `READY_FOR_REVIEW` hands the PR to the orchestrator's review pipeline; you sit warm awaiting the orchestrator's `SendMessage`.

#### Resume on SendMessage

When the orchestrator's `SendMessage` lands, you have one of two messages:

- **`Review LGTM, exit with READY_TO_MERGE.`** The review subagent posted a single `Claude Reviewer: LGTM` PR-level comment and zero inline findings. No code changes are needed. Acknowledge briefly if you like, then return `READY_TO_MERGE <pr-url>` as your terminal-success token. The orchestrator runs the merge handoff per the observed `Merge mechanism:` line.
- **`Review posted <count> findings inline. Fetch unaddressed Claude Reviewer: comments, address each (commit, push, threaded Claude: Done! reply), then return READY_TO_MERGE <pr-url>.`** The review subagent posted `<count>` inline `Claude Reviewer:` comments. Address each on your own branch:

  1. Fetch unaddressed inline comments — those with `in_reply_to_id == null` (top-level reviewer comment) AND no other comment's `in_reply_to_id` equals their `id` AND a body starting with `Claude Reviewer: `:

         gh api 'repos/{owner}/{repo}/pulls/<pr#>/comments' --paginate

  2. For each unaddressed `Claude Reviewer:` comment: make the code change, OR document why the suggestion shouldn't be adopted. Commit with a conventional-commits message describing the change (one commit per finding is fine; squashing related findings into one commit is also fine). Then post a threaded reply:

         gh api --method POST 'repos/{owner}/{repo}/pulls/<pr#>/comments/<id>/replies' \
           -f body='Claude: Done!'

     Use `Claude: Done!` if the suggestion was adopted as-is; use `Claude: <one-line explanation>` if you took a different approach. Because you have the original design context, you can say "Done!" with confidence on the trivial findings and push back substantively on the design-intent findings — that's the whole point of the warm-agent restructure (#93).

  3. After all findings are addressed: `git pull --rebase origin <branch>` then `git push`. Retry up to 3x on non-fast-forward.

  4. Also check issue-level PR comments:

         gh api 'repos/{owner}/{repo}/issues/<pr#>/comments' --paginate

     Issue-level comments don't have thread replies — reply with a new issue comment prefixed `Claude: `. Skip the single `Claude Reviewer: LGTM` comment if present (no findings there to address).

  5. Return `READY_TO_MERGE <pr-url>` as your terminal-success token.

In either case, do **NOT** set automerge yourself. Do **NOT** run `gh pr merge`. Do **NOT** apply a merge-trigger label. The orchestrator owns the merge handoff after you return `READY_TO_MERGE` — that's the whole point of the token. The orchestrator's automerge gate (Phase 5 step 5) verifies that every `Claude Reviewer:` finding has been addressed before it fires the handoff; your `READY_TO_MERGE` is the signal that condition is satisfied. **This applies in no-CI repos too** — a synchronous merge there would still land the moment automerge is enabled, and skipping the orchestrator's gate would short-circuit the verification.

#### Worked example: PR open, self-review clean

After `gh pr create` returns the PR URL and your post-push self-review pass on `git diff main...HEAD` finds nothing to fix, the next action in this turn is the heartbeat — no further tool calls:

```text
READY_FOR_REVIEW https://github.com/o/r/pull/91
```

Stop your turn here. Do not summarise what you implemented; the PR body already does that. Do not run a review subagent yourself — the orchestrator does that at its own level. Do not poll merge state — the orchestrator owns the merge pipeline from here. The next thing that happens in your context is the orchestrator's `SendMessage` arriving with the review result.

**You have only completed your task when you return `READY_TO_MERGE`, `BLOCKED`, `PAUSED`, or `ERRORED`. `READY_FOR_REVIEW` is a heartbeat, not a terminal — the agent stays warm awaiting the orchestrator's `SendMessage`. Reporting "the PR is open and looks fine" is not a valid output. The tokens are the contract.**

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

You produce two kinds of structured returns: a **heartbeat** that pauses your turn awaiting the orchestrator's `SendMessage`, and a **terminal** that ends your work on this issue. Both are parsed by literal prefix match on the `result` field of your final notification for that turn. Do not narrate progress around the token — any non-structured text on the same line is interpreted by the orchestrator's literal-prefix parse as malformed.

**Heartbeat (mid-pipeline pause):**

- `READY_FOR_REVIEW <pr-url>` — PR is open, the diff has had a final self-review pass for code-quality, and you are stopping your turn awaiting the orchestrator's `SendMessage` with the review result. The orchestrator dispatches the review subagent in parallel and resumes you with either `Review LGTM, exit with READY_TO_MERGE.` or `Review posted <count> findings inline. ...`. **You stay warm — your branch, your context, your slot.**

**Terminals (end of work on this issue):**

- `READY_TO_MERGE <pr-url>` — every `Claude Reviewer:` finding has been addressed (or there were none — the LGTM path), the branch is pushed, and the threads are replied to. The orchestrator runs the merge handoff per the observed `Merge mechanism:` line. **This is the default success exit.**
- `BLOCKED <N> <question>` — parked on a public-break ambiguity awaiting clarification.
- `PAUSED <N> <reason>` — environmentally paused (usage cap, infra outage). Orchestrator may re-dispatch when the condition clears.
- `ERRORED <N> <error>` — non-recoverable failure.

There is no `AUTOMERGE_SET` or `MERGED` token from the implementing agent — the orchestrator owns the merge handoff after you return `READY_TO_MERGE`. If you ever find yourself reaching for `gh pr merge` or `gh pr edit --add-label automerge`, stop: that's the orchestrator's job. **The "no CI workflows on this repo, so a merge-bot will not gate me" reasoning is the trap to watch for** — in a no-CI repo, the orchestrator's review subagent is the only safety net, and an implementing agent that sets automerge would skip past it (synchronous merge before review even runs). Heartbeating `READY_FOR_REVIEW` and then returning `READY_TO_MERGE` after `SendMessage` is the contract regardless of CI configuration.

### Returning your heartbeat or terminal status

The orchestrator parses **only** the `result` field of the relevant notification, and it parses by literal prefix match. Format discipline is load-bearing — and the heartbeat-vs-terminal distinction matters because the orchestrator routes them differently:

- The `result` field of your *heartbeat* notification (the one that ends with `READY_FOR_REVIEW`) MUST start with `READY_FOR_REVIEW <pr-url>` and contain no leading prose, quoting, or markdown. After emitting it, your turn stops; the orchestrator's `SendMessage` resumes you on its next move.
- The `result` field of your *terminal* notification MUST start with one of the literal terminal tokens (`READY_TO_MERGE`, `BLOCKED`, `PAUSED`, `ERRORED`) followed by the relevant args. Same format discipline — no leading prose, the token is the first thing the orchestrator sees.
- Heartbeat-style progress notifications during steps 1–6 (e.g. "ran tests", "pushed branch", "PR opened") are fine and encouraged — they let the user see progress. Only the `READY_FOR_REVIEW` notification is the orchestrator-routed heartbeat; only the terminal notification is the orchestrator-routed terminal.
- If you find yourself wanting to narrate ("the PR is open and looks ready for review, heartbeating READY_FOR_REVIEW ..."), don't. The contract is the literal token plus its args, nothing else. Freeform prose around the token breaks the orchestrator's parse — the orchestrator has a backstop that reconstructs PR state and routes to existing recovery paths (review dispatch, warm-agent SendMessage with fallback to address-review mini-agent, CI-failure sizing, automerge handoff), but treat the backstop as a safety net for genuinely unexpected exits, not a license to be sloppy. The clean token is still the contract; the backstop just keeps a malformed return from immediately surfacing to the user.

If you find yourself thinking "I should run a review subagent before heartbeating" — don't. The orchestrator dispatches the review subagent at its own level, exactly to avoid the recurring problem where the implementing agent's harness lacks `Task` / `general-purpose` access. If you find yourself thinking "I should poll until CI is green" — don't. Opening the PR, heartbeating `READY_FOR_REVIEW`, awaiting `SendMessage`, addressing any findings, and returning `READY_TO_MERGE` is the full scope of your job; the orchestrator owns the rest.
```

## Phase 5b — Post-automerge monitoring

Once the orchestrator has set automerge (the warm implementing agent returned `READY_TO_MERGE` in Phase 5 step 5 and the orchestrator ran the merge handoff per the observed `Merge mechanism:` line), it owns the PR until merge. The goal is to spend as few tokens as possible on the wait-for-CI / wait-for-automerge tail without giving up the ability to recover from `BEHIND`, conflicts, CI failures, or new review comments.

### Trade-off rationale (why a shell monitor + mini-agents, not a warm agent)

The previous design kept the implementing agent warm through the entire wait-for-merge tail — burning hundreds of thousands of tokens per PR on polling that an LLM adds no value to. The current design swaps that warm agent for a thin shell monitor for the trivial cases (`BEHIND` auto-merge, `MERGED` detection, `green + waiting` no-op), escalating to a focused mini-agent only when the monitor sees something requiring judgment (`CONFLICT`, `CI_FAILURE`, `NEW_COMMENT`).

Each escalation pays a cold-start cost (~30–50k tokens loading project conventions). A PR with 3 escalations during its life pays 3× that. The always-warm-agent approach paid that cost once but spent ~400k tokens monitoring. The crossover is around 6–8 escalations per PR, which essentially never happens for normal PRs. So the thin-monitor approach wins for the realistic distribution (most PRs: 0–2 escalations); the always-warm approach is only better for pathological PRs.

The other resilience win: a crashed monitor doesn't lose pipeline state — it just stops polling, and the orchestrator can relaunch it. A crashed always-warm agent loses the entire PR's monitoring state and may not resume cleanly. **If the workload distribution shifts (e.g. a project where most PRs hit 5+ conflicts) re-evaluate this split — the crossover point is the relevant signal.**

### Handoff

**Precondition for entering Phase 5b: the automerge gate in Phase 5 step 5 has fired.** That gate requires (1) independent review completed (LGTM acknowledged by the warm implementing agent's `READY_TO_MERGE`, or every `Claude Reviewer:` finding addressed by the warm agent and signalled via `READY_TO_MERGE` — or, in the rare fallback path, by the address-review mini-agent's `READY_TO_MERGE`) AND (2) CI acceptable (green / only environmental failures / no CI workflows on the PR). Phase 5b never sets automerge on its own — it monitors the PR after Phase 5 step 5 has set it. Re-read the gate definition at Phase 5 step 5 if there's any doubt about whether the handoff should fire; in particular, **a no-CI repo does not let you skip the review check** — review is the only safety net in that configuration.

When step 5 of the Phase 5 execution loop sets automerge (after the warm implementing agent's `READY_TO_MERGE` return, or — in the fallback path — the address-review mini-agent's `READY_TO_MERGE` return):

1. Run the merge handoff per the observed `Merge mechanism:` line (snapshotted at Phase 1.5 — one of three values, picked deterministically by the script's `allow_auto_merge` probe so the handoff doesn't try `--auto` on a repo that has it disabled):
   - `gh pr edit <pr#> --add-label <observed-label>` for label-triggered merge-bots.
   - `gh pr merge <pr#> --auto --squash` when the repo has GitHub auto-merge enabled (`allow_auto_merge: true`). The Phase 5b monitor observes `MERGED` once the merge lands. **Note:** in a no-CI repo, this command resolves synchronously — the merge lands the moment automerge is enabled. That's why the gate above must hold *before* this command runs; once it runs, there is no further opportunity for review to intervene.
   - `gh pr merge <pr#> --squash` (immediate squash-merge, no `--auto` flag) when the repo has GitHub auto-merge disabled (`allow_auto_merge: false`). This is the primary command for that branch — not a fallback — because `gh pr merge --auto --squash` on such a repo fails with the GraphQL error `Auto merge is not allowed for this repository (enablePullRequestAutoMerge)`. The Phase 5b monitor observes `MERGED` on the next poll. The gate-before-command rule applies the same way: this command also resolves synchronously.
2. Mark the issue as `automerge_set` in internal state. The implementing-agent slot frees here — the warm agent terminated with `READY_TO_MERGE`, the orchestrator just ran the merge handoff, and the next eligible issue can be picked up. (Cap=3 binds through merge handoff per Operating principles § "Concurrency cap: 3"; this is the moment that binding releases.)
3. Launch the **shell monitor** (below) for that PR via the `Monitor` tool. The monitor's stdout is an event stream the orchestrator consumes.
4. Continue the Phase 5 execution loop — the slot is already free; pick up the next eligible issue if there is one.

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
  # The PR is in the steady state that the automerge-stall remediation
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
- **Stall detection collapses the latency tail.** When the PR sits in (`mergeable == MERGEABLE`, all checks `SUCCESS`/`SKIPPED`/`NEUTRAL`, `automerge` label present, `state == OPEN`) for longer than `STALL_THRESHOLD_SECONDS` (default 180), the monitor emits `STALLED_GREEN <pr#> green-for=<seconds>`. The orchestrator routes the first emit to tier 2 of the automerge-stall ladder immediately rather than waiting for its next progress-tick wakeup (which can be up to the current state-based interval away — see Phase 5 § Progress reporting § State-based wakeup interval). Re-emits use exponential backoff (1x / 3x / 6x of the threshold — default 3 / 9 / 18 minutes) so a persistent stall escalates through tier 3 and tier 4 without spamming the orchestrator on every poll, and any state change (new commit, label flip, check transition) resets the timer so transient stalls don't accumulate. The threshold is configurable via the `STALL_THRESHOLD_SECONDS` env var when launching the monitor.

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
| `STALLED_GREEN <pr#> green-for=<s>` | Run the **automerge-stall** ladder *now* rather than waiting for the next progress-tick wakeup. **First** `STALLED_GREEN` for a given PR → apply tier 2 immediately (toggle the merge-trigger label). **Second** `STALLED_GREEN` for the same PR (the monitor's exponential-backoff re-emit means tier 2 didn't take) → escalate to tier 3 (`workflow_dispatch` break-glass on the merge workflow). **Third** and beyond → tier 4 (probe the merge bot's run log) and surface the finding to the user. The shell monitor handles tier 1 (`BEHIND` auto-resolve) before this event ever fires, so a `STALLED_GREEN` always means the bot is the problem, not a stale base. See **Tiered remediation when automerge stalls** below for the per-tier mechanics. |

#### CI-failure stale-aggregator short-circuit

Before dispatching the CI-failure-fix mini-agent, check the stale-aggregator pattern (CodeQL stale aggregator — same logic the CI-failure-fix mini-agent template documents below). If the failing check is `CodeQL` and the `analyze (...)` sub-jobs are SUCCESS, compare `completed_at` timestamps. Aggregator before analyzes = stale, will self-clear in ~5–10 min on the next analyze cycle or alert-resolution background job — don't dispatch. Let the shell monitor keep polling; the next `gh pr view` tick will observe the cleared rollup. Aggregator after analyzes = real alert, fall through to the sizing rule below.

The `gh api repos/.../code-scanning/alerts` endpoint requires `security_events` scope on the orchestrator's token; a 403 here means fall back to the Security tab in the GitHub UI (or `gh auth refresh -s security_events` if this pattern recurs).

#### CI-failure sizing rule

On a `CI_FAILURE` event during the wait-for-merge tail, investigate before dispatching: `bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/triage-ci-failure.sh" <repo> <run-id>` (focused ~30-line summary — see the **CI-failure-fix mini-agent** template below for the script's contract), find root cause, don't bypass. Then size the fix:

- **≤50-line fix in 1-2 files** (typecheck error, lint violation, missing import, sub-block in same file): **fix in place at the orchestrator level.** Do not pay the mini-agent cold-load. Use the existing branch — the implementing agent's worktree may still exist on disk at `.claude/worktrees/agent-<id>` and is reusable; otherwise check out the branch into a fresh worktree. Commit, push, let CI re-fire. The implementing agent is gone but the branch and PR are still yours.
- **Larger fix, multi-file refactor, or new test surface required**: dispatch the CI-failure-fix mini-agent (template below). Pays a cold-load but safer for non-trivial changes.

Either way, the implementing agent's terminal `READY_TO_MERGE` return is final — don't try to "wake it up." The slot was freed when the orchestrator ran the merge handoff, and Phase 5b's monitor and mini-agents own everything from here.

Mini-agents run in their own isolated worktrees with `run_in_background: true`. They do **not** count against the implementing-agent concurrency cap of 3 — they're focused, short-lived, and are part of a PR that has already cleared the implementing-agent slot. (Cap them informally if you observe contention; defer formal limits until needed.)

When a dispatched mini-agent returns `RESOLVED` / `FIXED` / `ADDRESSED` / `READY_TO_MERGE`, the shell monitor — still polling — will eventually observe the underlying state has cleared (conflict gone, CI green, comment threaded) and stop emitting that event. The `READY_TO_MERGE` return from the address-review fallback mini-agent (rare — only when the warm implementing agent is unreachable; see Phase 5b § Address-review mini-agent) additionally tells the orchestrator to set automerge (per the observed `Merge mechanism:` line) before Phase 5b's monitor can drive the PR to merge — see Phase 5 step 5's `READY_TO_MERGE` branch. If a mini-agent returns `BLOCKED <question>` or `ENVIRONMENTAL <reason>`, the orchestrator surfaces it to the user and may stop the monitor (treat the PR as parked, just like a `BLOCKED` from the implementing agent).

### Tiered remediation when automerge stalls

When a PR sits in the orchestrator's internal `automerge_set` state longer than ~5 minutes after CI rollup is fully green and the shell monitor's `green + waiting` no-op state has persisted, the merge bot has likely failed to fire (or fired and exited cleanly waiting for a re-trigger that never came). Work through these tiers **in order — don't loop on the early ones**. If a tier fails twice, escalate to the next; don't retry the same tier indefinitely.

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

These are intentionally tighter than the main dispatch template — no full pipeline scaffolding, no plan step, no spawn-another-subagent step. Each is a focused prompt for a single narrow job. Project conventions are still consulted (the agent reads `CLAUDE.md` if it has to commit), but the prompt does not re-embed them in full.

#### Review subagent (orchestrator-level)

Dispatched on the `READY_FOR_REVIEW` heartbeat (Phase 5 step 5) and on the reconstruction probe's "review never ran" branch. Runs at the orchestrator's level so it always has `general-purpose` / `Task` access — that's the whole reason this dispatch lives on the orchestrator, not the implementing agent. Use `subagent_type: "general-purpose"`, **`run_in_background: true`**. Background dispatch is required, not optional: a foreground review dispatch would block the orchestrator's event loop on the first review while the next two implementing agents in a cap=3 run sit paused on their `READY_FOR_REVIEW` heartbeats. The review subagent doesn't count against the implementing-agent cap of 3 (Operating principles § "Concurrency cap: 3" — review subagent and the address-review fallback mini-agent are orchestrator-level, short-lived, and orthogonal to the cap), so dispatching it in the background is purely additive concurrency. The orchestrator routes the terminal notification's `result` field by literal prefix match — see Phase 5 step 5's `READY_FOR_REVIEW` branch for the LGTM / FINDINGS / malformed routing rules. Both LGTM and FINDINGS branches `SendMessage` the warm implementing agent rather than dispatching a fresh address-review (the address-review mini-agent below is the fallback, not the default).

```
You are reviewing PR #<pr#> on <repo>. Fetch the diff with `gh pr diff <pr#>`. Review it against the project's conventions documented in `CLAUDE.md`, `.claude/instructions/*.md`, and `CONTRIBUTING.md`. Look for: scope creep, undocumented decisions, missing tests, dead code, unclear naming, breaking changes that aren't called out, security issues, and convention violations.

Post each finding as an inline comment via the GitHub API:

  gh api --method POST 'repos/{owner}/{repo}/pulls/{pr#}/comments' \
    -f body='Claude Reviewer: <finding>' \
    -f commit_id='<head sha>' \
    -f path='<file>' \
    -f line=<line>

Use the `Claude Reviewer: ` prefix on every comment. If the diff is clean (no findings), post a single PR comment via `gh pr comment <pr#> --body 'Claude Reviewer: LGTM. <one-line summary of what you checked>'` and return.

Return EXACTLY ONE of:
- `LGTM <pr-url>` — diff is clean; the single `Claude Reviewer: LGTM` PR comment is posted.
- `FINDINGS <pr-url> <count>` — `<count>` inline `Claude Reviewer:` comments posted.
- `ERRORED <reason>` — non-recoverable.
```

The orchestrator routes the return:

- `LGTM` → `SendMessage(<implementing-agent-id>, "Review LGTM, exit with READY_TO_MERGE.")`. The warm implementing agent acknowledges and returns `READY_TO_MERGE`; the orchestrator then sets automerge per the observed `Merge mechanism:` line and hands off to Phase 5b.
- `FINDINGS` → `SendMessage(<implementing-agent-id>, "Review posted <count> findings inline. Fetch unaddressed Claude Reviewer: comments, address each (commit, push, threaded Claude: Done! reply), then return READY_TO_MERGE <pr-url>.")`. The warm implementing agent addresses the findings on its own branch and returns `READY_TO_MERGE`; the orchestrator then sets automerge and hands off. **Fallback**: if the implementing agent's `agent_id` is gone/unreachable (Claude Code crash, `--resume` after the original session ended, malformed terminal that left no trace), the orchestrator falls back to dispatching the **address-review mini-agent** (below) on the implementing agent's branch.
- `ERRORED` → surface to user, park the PR.

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

1. Read a focused failure summary:

       bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/triage-ci-failure.sh" <repo> <run-id>

   The script emits ~30 lines: failing step name, deduplicated error markers (top 10), and the last 10 lines of the failing step. This replaces the prior `gh run view <run-id> --log-failed` slicing — the actual error is guaranteed to be in scope and ~3-5K tokens of unrelated log noise are skipped. Empty output is a signal in itself (log unattached / green-but-failed run / API quirk) — fall back to `gh run view <run-id>` without `--log-failed` for the high-level summary, or treat the failure as `ENVIRONMENTAL` if the run-level metadata also looks degenerate.
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

Dispatched by the Phase 5b shell monitor's `NEW_COMMENT` event — i.e. a *single* review comment landed mid-pipeline (typically a human reviewer comment after the orchestrator-level review pass and after the warm implementing agent has already returned `READY_TO_MERGE`). For the bulk-address pass right after the orchestrator-level review subagent posts its findings, the orchestrator now `SendMessage`s the warm implementing agent so the original design context is preserved (Phase 5 step 5's `FINDINGS` branch) — the **address-review mini-agent** below is the fallback path used only when the warm agent is unreachable.

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

#### Address-review mini-agent (fallback)

**Fallback path — not the default.** The warm-agent path (Phase 5 step 5's `FINDINGS` branch `SendMessage`-ing the implementing agent) is the default. The address-review mini-agent is dispatched in two cases only:

1. **Malformed-terminal recovery probe (#51).** When the implementing agent's `agent_id` is unknown or unreachable (Claude Code crash, `--resume` after the original session is gone, a malformed terminal that left no usable agent reference) and the reconstruction probe's Branch 3 ("Unaddressed `Claude Reviewer:` comments exist") fires. The probe tries `SendMessage(<agent_id>, ...)` first; if the agent is gone, it falls back to dispatching this mini-agent.
2. **User-requested fresh take.** Rare — e.g. the user explicitly wants an independent fresh-agent re-take of the address-review pass rather than the warm agent's own pass.

In all other cases the orchestrator routes review findings to the warm implementing agent so the original design context is preserved on every address-review (issue #93 — that's the whole rationale for keeping the agent warm through review).

When dispatched, this mini-agent bulk-addresses every unaddressed `Claude Reviewer:` comment posted by the review subagent on the implementing agent's branch, then signals back so the orchestrator can set automerge. Use `subagent_type: "general-purpose"`, **`run_in_background: true`**. Same rationale as the review subagent's background dispatch above: foreground dispatch would block the orchestrator's event loop on a single PR's address-review while the rest of the in-flight set sits idle. The address-review mini-agent doesn't count against the implementing-agent cap of 3 (Operating principles § "Concurrency cap: 3" — review and the address-review fallback are orchestrator-level, short-lived, and orthogonal to the cap), so background dispatch is purely additive concurrency. The orchestrator routes the terminal notification's `result` field by literal prefix match on `READY_TO_MERGE` (malformed routes through the reconstruction probe) — see Phase 5 step 5's `READY_TO_MERGE` branch for the automerge-gate routing.

```
You are addressing review findings on PR #<pr#> in <repo>. Branch: `<branch>`.

You run in an isolated worktree (`isolation: worktree`). Check out the PR branch:

  gh pr checkout <pr#>

Pipeline:

1. Fetch unaddressed inline comments:

     gh api 'repos/{owner}/{repo}/pulls/<pr#>/comments' --paginate

   A comment is *unaddressed* when `in_reply_to_id == null` (top-level reviewer comment) AND no other comment's `in_reply_to_id` equals its `id`. Filter to those with body starting `Claude Reviewer: ` (the review subagent's prefix).

2. For each unaddressed `Claude Reviewer:` comment:

   a. Make the code change, OR document why the suggestion shouldn't be adopted.
   b. Commit with a conventional-commits message describing the change. One commit per finding is fine; squashing related findings into one commit is fine too — use judgment.
   c. Post a threaded reply:

        gh api --method POST 'repos/{owner}/{repo}/pulls/<pr#>/comments/<id>/replies' \
          -f body='Claude: Done!'

      If the suggestion was adopted as-is, use `Claude: Done!`. If you took a different approach, use `Claude: <one-line explanation>`.

3. After all findings are addressed: `git pull --rebase origin <branch>` then `git push`. Retry up to 3x on non-fast-forward.

4. Also check issue-level PR comments:

     gh api 'repos/{owner}/{repo}/issues/<pr#>/comments' --paginate

   Issue-level comments don't have thread replies — reply with a new issue comment prefixed `Claude: `. Skip the single `Claude Reviewer: LGTM` comment if present (no findings there to address).

Do NOT set automerge. Do NOT run `gh pr merge`. Do NOT apply a merge-trigger label. The orchestrator owns the merge handoff after you return — that's the whole point of the `READY_TO_MERGE` signal. The orchestrator's automerge gate (Phase 5 step 5) verifies that every `Claude Reviewer:` finding has been addressed before it fires the handoff; your `READY_TO_MERGE` return is the signal that condition is satisfied. **This applies in no-CI repos too** — a synchronous merge there would still land the moment automerge is enabled, and skipping the orchestrator's gate would short-circuit the verification.

Return EXACTLY ONE of:
- `READY_TO_MERGE <pr-url>` — every `Claude Reviewer:` finding has been addressed, the branch is pushed, and the threads are replied to.
- `BLOCKED <question>` — at least one finding requires a public-break decision (e.g. competing API shapes). Comment on the PR with `Claude: Blocked — <question>` first.
- `ERRORED <reason>` — non-recoverable.
```

## Phase 6 — Post-completion housekeeping

When the orchestrator observes a `MERGED` event from the Phase 5b shell monitor (the `automerge_set → MERGED` handoff after the orchestrator-level merge handoff completes):

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
- Record the question in the session state file via `update-issue <id> <n> blocked blocked_question="<question>"` (Phase 5 step 5's `BLOCKED` branch already handles this; Phase 7 just confirms). The parked questions are now durable across conversations because the state file survives a `/clear`.
- Continue with other ready issues.

When the loop drains (no more eligible issues, in-flight count = 0):

1. Compile parked questions into ONE batched message to user, numbered and grouped by issue.
2. Wait for answers.
3. After answers: update affected issue bodies via `gh issue edit <n> --body`, remove `blocked` labels, and flip each newly-unblocked issue's state in the session state file from `blocked` back to `scheduled` — clearing the now-stale `blocked_question` field on the same call so downstream readers (progress digest, `--session list`) don't keep surfacing an already-answered question — so the next Phase 5 tick re-dispatches it:

   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" update-issue \
     "$session_id" <n> scheduled blocked_question=
   ```

   Then re-enter Phase 5. (Same `update-issue <n> scheduled blocked_question=` call the Phase 1.0 `--resume` selective-Phase-2 path uses for resumed-`blocked` issues — both paths converge on the same unblock-on-answer transition. The empty-string assignment is the canonical "cleared" representation; the helper allow-list only permits string values.)

## Phase 8 — Completion

The orchestrator's `TaskList` is the canonical state surface — every in-scope issue has a tracking task that flips through `pending` → `in_progress` → `completed` (or stays `in_progress` on `BLOCKED` / `PAUSED`). The chat-visible final report below is a one-shot snapshot at run end, not the source of truth; refer back to `TaskList` for live state.

### Phase 8.0 — TaskList ↔ GitHub reconciliation (defensive backstop)

Before emitting the final report, walk every in-scope issue (the list resolved in Phase 1) and reconcile the local `TaskList` against GitHub's view. This is a **backstop**, not the primary fix — the source-fix is the standalone `TaskUpdate` rule in Phase 6 step 1 (and Phase 5 steps 2–3) that prevents drift from arising in the first place. Phase 8.0 catches whatever slips through: harness cancellations on bundled tool-call groups, transient `gh` failures that wedged a state transition, manual close+reopen races, etc.

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

### Phase 8.1 — Session-state garbage collection

If every in-scope issue has reached a **fully-resolved** terminal state (`merged`, `errored`, or `externally_closed`), delete the session state file:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/implement/scripts/session-state.sh" delete "$session_id"
```

`blocked` and `paused` do **not** qualify as fully-resolved — the user is expected to answer the parked question or wait out the cap and come back via `--resume <id>`. Keep the state file in those cases so the resume path has something to reattach to. Same logic for `scheduled` / `in-progress` / `automerge_set` issues: the run hasn't reached its end state, and a Claude Code crash or a deliberate `/clear` should leave a recoverable file behind.

`externally_closed` (the parked-issue poll observed `state == CLOSED` while `blocked` — see § Progress reporting § Parked-issue poll) **does** qualify: the issue is gone from GitHub's perspective, no further orchestrator action is possible, and re-dispatching against a closed issue would just produce orphan work. Treating it as fully-resolved (alongside `merged`/`errored`) prevents orphan state files in the all-parked-then-externally-closed-out-of-band scenario.

Concretely: delete only when every issue is `merged`, `errored`, or `externally_closed`. Otherwise leave the file and let `--session list` surface it on the next invocation.

A future `--session forget <id>` flag could expose the same `delete` subcommand for explicit cleanup of stuck-but-abandoned sessions; until then the user's manual escape hatch is `rm ~/.claude/state/workflow-implement/<id>.json` (or `bash session-state.sh delete <id>`).

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
- **`--resume <id>` was passed but `~/.claude/state/workflow-implement/<id>.json` does not exist.** Do not auto-create — surface the error verbatim ("session state not found: <id>") and exit. The user typically wants to either (a) check for typos in the ID, (b) run `--session list` to see what is actually resumable, or (c) start a fresh run instead.
- **`--resume <id>` was passed and the state file exists but is unparseable JSON** (truncated mid-write after a crash / disk-full / SIGKILL, partial schema, corrupted UTF-8). Surface the error verbatim ("session state corrupted: <path>") and point the user at **§ Session state § Recovering a corrupted state file** for the manual recovery sequence. Do not attempt to repair in-place — re-deriving from a half-written file is how silent state-divergence happens. The user explicitly chooses between "fix the JSON by hand" and "delete the file and lose dep graph / digest history."
- **`--resume <id>` was combined with a selector flag** (`--label`, `--milestone`, `--parent`, or explicit issue numbers). The resumed state file already encodes the original selector; combining the two is ambiguous. Surface "--resume cannot be combined with selector flags" and exit.

In each case: leave labels as-is, surface immediately to user, do not proceed.

**Recoverable** environmental conditions are NOT bail-outs:

- **Usage-cap exhaustion**: agent returns `PAUSED`. Orchestrator records the reset time and re-dispatches a resumption agent (Phase 5 step 0 path) once the cap clears.
- **Transient CI infra blips** (one-off rate limits, single workflow timeout): the orchestrator's CI-failure-fix path (Phase 5b — either in-place ≤50-line fix or the CI-failure-fix mini-agent) investigates and either pushes a fix or returns `ENVIRONMENTAL` for the orchestrator to surface; this is not a run-wide halt.

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
| Hand off to merge | `gh pr merge <n> --auto --squash` (native auto-merge, when `allow_auto_merge: true`), `gh pr merge <n> --squash` (immediate squash-merge, when `allow_auto_merge: false`), or `gh pr edit <n> --add-label <bot-label>` (label-triggered merge-bot — see Phase 1.5 detection) |
| Check CI | `gh pr checks <n>` / `gh pr view --json statusCheckRollup` |
| List PR review comments | `gh api repos/.../pulls/<n>/comments` |
| Post inline review comment (orchestrator-level review subagent) | `gh api --method POST repos/.../pulls/<n>/comments` (with `body=Claude Reviewer: ...`, `commit_id`, `path`, `line`) |
| Reply to review comment | `gh api --method POST repos/.../pulls/<n>/comments/<id>/replies` |

When extending: copy this skill, swap the operations table for the new tracker, document the equivalent label semantics. Don't abstract into a runtime adapter until at least two trackers actually need it.
