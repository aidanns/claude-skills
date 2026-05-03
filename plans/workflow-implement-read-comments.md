# Plan: workflow:implement reads issue comments (#114)

## Goal

Make `workflow:implement` read GitHub issue comments — not just the body — when selecting issues, building dispatch prompts, and detecting out-of-band edits. Treat a maintainer-authored `## Agent Brief` comment (when present) as the dispatched agent's spec, with explicit Spec / Context partitioning. Fall back to body + maintainer-authored comments otherwise.

The full design contract lives in the agent brief on issue #114 (https://github.com/aidanns/claude-skills/issues/114#issuecomment-4365891726). This plan operationalises it as concrete touch points across the skill's files.

## Background

The dispatched implementing agent's prompt currently embeds `gh issue view --json body` verbatim. Triage (`engineering:triage`) posts the agent brief as a *comment* — invisible to the dispatched agent today. The parked-issue poll snapshots `body_snapshot` and `labels_snapshot` on `BLOCKED`; comment changes are not detected. Issue #114 closes both gaps.

The `--resume blocked` carve-out (SKILL.md:157) — which fetches the latest `Claude: Blocked — <question>` comment for parked issues — is orthogonal and stays untouched.

## Design summary (from the brief)

- **Case A — Brief present.** A comment is treated as a brief iff its body matches `(?m)^## Agent Brief\b` AND its `author.login` equals `gh repo view --json owner --jq .owner.login`. Latest by `createdAt` wins. Dispatch prompt frames the brief as **Spec**, body as **Context: original issue body**. No other comments included.
- **Case B — No brief.** Dispatch prompt frames the body as **Spec**, with all maintainer-authored comments (author.login == owner) appended as **Context: maintainer comments** in chronological order. Non-maintainer comments excluded.
- **Snapshot.** New `comments_snapshot` field captured wherever `body_snapshot` is captured today (currently the BLOCKED transition only). Value is the canonical-string representation of the comments that *would be included in the next dispatch* under the rule above. Parked-issue poll compares all three snapshot fields.
- **Token cap.** None. If Case B and included-comments byte count > 20 KB, orchestrator emits a one-line non-blocking warning suggesting the maintainer triage to a written brief.

## Touch-point inventory

### `plugins/workflow/skills/implement/SKILL.md` (1823 lines)

| Phase / line | Change |
| --- | --- |
| **§ Phase 1.0a (line ~124)** | Add new sibling subsection **Phase 1.0b — repo-owner cache**. Probe shape: `gh repo view --json owner --jq .owner.login`. Cache result in session-scoped `repo_owner_login`. Run on fresh runs and on `--resume`. |
| **§ Phase 1, ~line 211** | Update issue-fetch JSON spec from `--json number,title,body,labels,milestone,state,assignees` to `--json number,title,body,labels,milestone,state,assignees,comments`. |
| **§ Phase 1.0 (line ~149-167) overlap detection (line ~323)** | Wherever `body_snapshot` is read for overlap-detection / clarification-detection, also read `comments_snapshot`. Treat a populated value on either field as evidence of prior Phase 2 / `Claude: Blocked` work. |
| **§ Phase 2 (line ~521 "Read each issue body in full")** | Restate as "Read each issue's full thread — body and comments — in full." Document the brief-detection rule (regex + author check, latest wins) and the Spec/Context partition that flows downstream into Phase 5's dispatch prompt. |
| **§ Phase 5 step 4 dispatch template (around line 686 / 784)** | Replace single body-embed with **Spec / Context** partition. New template skeleton:<br/>```<br/>## Spec<br/><br/><brief body OR issue body><br/><br/>## Context: <"original issue body" if Case A, else "maintainer comments"><br/><br/><body if Case A, else comment list><br/>```<br/>If Case B and zero qualifying comments, omit the Context section entirely (keeps trivial issues unchanged from today). |
| **§ Phase 5 step 4 stale-path scan (line ~660-680)** | Extend the path scan to scan brief comment body (Case A) or maintainer comment bodies (Case B), not just issue body. Stale-paths preamble surfaces stale paths from the same content set. |
| **§ Phase 5 step 5 BLOCKED transition (line ~711)** | Update the `update-issue ... blocked ...` example to also write `comments_snapshot="<canonical string>"`. Document the canonical-string definition (Case A: just the brief comment body; Case B: chronological concatenation of maintainer comment bodies, separated by a stable sentinel like `\n---\n`). |
| **§ Session state §  Per-issue dispatch-context fields (line ~454)** | Add `comments_snapshot` to the field list. Document semantics: "captures the comments that would be included in the next dispatch — case-flips (brief deleted, brief newly added) produce a different canonical string and trip the parked-issue poll." |
| **§ Session state initial template (line ~431-432)** | Add `"comments_snapshot": null` alongside the existing two snapshot fields. |
| **§ Session state state-machine row for `blocked` (line ~449)** | Update to mention all three snapshot fields. |
| **§ Session state `update-issue` row (line ~475)** | Add `comments_snapshot` to allow-listed keys. |
| **§ Parked-issue poll (line ~824)** | Extend the "tick compares body and labels" to "tick compares body, labels, and comments". Same re-fire semantics; the existing single-message "issue changed" notification surface stays unchanged (no per-field disambiguation). |
| **§ ~line 831 (`gh issue view <N> --json state,body,labels` in poll)** | Add `comments` to the JSON spec. |
| **§ Phase 5 (after the dispatch step) — new note** | Document the 20-KB Case-B warning: at dispatch time, if Case B applies and `len(canonical_comments_string) > 20480`, orchestrator emits one-line warning naming issue number and byte count. Non-blocking; dispatch proceeds. |

### `plugins/workflow/skills/implement/scripts/session-state.sh` (555 lines)

| Line | Change |
| --- | --- |
| **~line 25-44 doc block** | Add `comments_snapshot` to the documented allow-listed keys in the doc-comment for `update-issue`. |
| **~line 189-190 (init template)** | Add `comments_snapshot: null` to the per-issue init template alongside the two existing snapshot fields. |
| **~line 241-243 (allow-list validator)** | Add `comments_snapshot` to the allow-list regex/case branch. Update the rejection error message to list it. |

### `plugins/workflow/skills/implement/scripts/tests/test-session-state.sh`

Add regression tests:
1. `update-issue ... comments_snapshot=foo` is accepted; the value round-trips into the state file.
2. `update-issue ... comments_snapshot=` clears the field (mirrors existing patterns for `body_snapshot` if present, or treats empty-string as canonical clear per the existing convention).
3. `update-issue` rejects an unknown key the same way it does today (regression — confirm the new key didn't loosen the validator).

### Other files

- **`plugins/workflow/skills/implement/scripts/digest-line.sh`**, **`monitor-behind-resolve.sh`**, **`phase15-conventions.sh`**, **`triage-ci-failure.sh`** — touch only if they reference `body_snapshot` / `labels_snapshot` (verify with grep). Expected: none reference those fields. No change.

## Implementation order

Order is structured so any partial commit leaves the system functional:

1. **session-state.sh + tests first.** Add `comments_snapshot` to allow-list + init + tests. Self-contained; no SKILL.md changes need it yet. Tests pass before moving on.
2. **SKILL.md state-machine schema docs.** Update the per-issue field list, init template, and `update-issue` allow-list rows. Pure docs, must agree with step 1's code change.
3. **SKILL.md Phase 1 fetch + Phase 1.0b cache.** Add `comments` to the issue-fetch JSON, add the new repo-owner probe subsection.
4. **SKILL.md Phase 2 brief-detection rule.** Document the rule (regex + author check, latest wins) so it's defined before Phase 5 references it.
5. **SKILL.md Phase 5 dispatch prompt restructure.** Apply Spec / Context partitioning to the dispatch template. Reference the Phase 2 rule.
6. **SKILL.md Phase 5 stale-path scan extension.** Extend to brief / maintainer-comment content.
7. **SKILL.md Phase 5 BLOCKED transition.** Add `comments_snapshot` to the BLOCKED `update-issue` example. Document canonical-string definition.
8. **SKILL.md parked-issue poll.** Extend three-field comparison and update the JSON spec.
9. **SKILL.md overlap-detection.** Extend `body_snapshot` reads to also consider `comments_snapshot`.
10. **SKILL.md 20-KB warning.** Document the non-blocking warning.

Each step a separate commit on the branch (or a single rolled-up commit if the diff stays small enough — single-commit is preferred for `gh pr create` clarity).

## Tests

- **session-state.sh**: new regression tests as above. Run `bash plugins/workflow/skills/implement/scripts/tests/test-session-state.sh` and verify all tests pass (existing + new).
- **SKILL.md**: no executable test surface — the skill is a markdown spec consumed by the model. Verification path:
  - `grep` confirms every BLOCKED-transition reference writes `comments_snapshot`.
  - `grep` confirms every `gh issue view` call that's spec-relevant includes `comments`.
  - `grep` confirms the dispatch template uses the new Spec/Context partition.
  - Read-through pass: walk the SKILL.md sequentially and confirm internal consistency (no contradictions between phases).

## Risks and mitigations

- **Surface-area sprawl.** ~12 distinct touch points in a 1823-line file. Mitigation: do the changes in order (above), running grep after each step to confirm no orphaned references.
- **Breaking the `--resume blocked` carve-out.** That flow has its own narrowly-scoped comment fetch (line 157, 173) and is functionally orthogonal. Mitigation: explicitly preserve and reference it in the Phase 2 update.
- **Snapshot canonical-string ambiguity.** Need a stable separator for concatenated comments in Case B so `body_snapshot` comparisons are deterministic. Mitigation: pick an unambiguous one (e.g. `\n---comments-snapshot-separator---\n`) and document it in the canonical-string definition.
- **20-KB warning premature.** This repo today has ~zero issues with that much comment content. The warning may never fire. Mitigation: document the threshold and rationale; future tuning is a one-line change.

## Out of scope (per the agent brief)

- Configurable allowlist of trusted brief authors for multi-maintainer or org-owned repos. Owner-only is v1.
- Finer-grained bot/non-maintainer comment filtering beyond the author-equals-owner rule.
- Truncation or summarisation of long comment threads.
- Changes to `## Agent Brief` heading or `AGENT-BRIEF.md` format.
- Surfacing *which* snapshot field triggered a parked-issue resume.
- Backwards-compat shims for issues whose body has prior triage clarifications applied.
