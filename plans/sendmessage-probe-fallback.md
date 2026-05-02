# Plan: probe for `SendMessage` at startup, fall back to mini-agent (#99)

## Context

`workflow:implement`'s warm-agent path uses Claude Code's `SendMessage` tool to wake the warm implementing agent after review (LGTM acknowledgement, or address-findings dispatch). Per the official tools-reference, `SendMessage` is gated behind `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. When the flag is unset the tool is not exposed at all — not in the loaded tool list, not in the deferred-tool list, and `ToolSearch select:SendMessage` returns no matches. Hit on 2026-05-01 in session `wfi-2026-05-01-b959`; the existing address-review mini-agent fallback was the right behaviour but the skill didn't route to it on absent-tool.

## Approach

Probe at session startup, cache the result, route Phase 5 step 5's review-result branches by the cached value. Document the prereq in the skill preamble.

## Steps

1. **Preamble note** near the invocation table — explain `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` requirement and that the orchestrator auto-routes to fallback when the flag is unset.
2. **Phase 1.0a — `SendMessage`-availability probe** subsection added between the session-ID generation and issue-list resolution. Probe shape: `ToolSearch query:"select:SendMessage" max_results:1`. Cache `sendmessage_available = "yes" | "no"`. Probe runs once at session start (eager) for simpler mental model rather than lazily on first heartbeat. Resumed sessions re-probe (per-orchestrator-session fact, not per-run; result not persisted).
3. **Phase 5 step 5 LGTM/FINDINGS routing** — modify the existing `READY_FOR_REVIEW`-branch decision points to consult `sendmessage_available`:
   - LGTM + `yes` → existing warm-agent path (`SendMessage(<id>, "Review LGTM, exit with READY_TO_MERGE.")`).
   - LGTM + `no` → review LGTM directly satisfies automerge-gate condition 1 (no warm-agent ack needed when nothing to address); verify CI; run merge handoff. Warm agent's slot frees on next merge handoff (it stopped on `READY_FOR_REVIEW`, never resumed, harness GCs it).
   - FINDINGS + `yes` → existing warm-agent path.
   - FINDINGS + `no` → dispatch address-review mini-agent directly (no `SendMessage` attempted).
4. **Phase 5 step 5 reconstruction probe Branch 3** — document that "agent_id absent" and "SendMessage tool absent" share the same fallback (address-review mini-agent). Branch 3 reads both signals; if either fails, falls back identically.
5. **Address-review mini-agent fallback** — extend the trigger enumeration from two cases to three: (1) `SendMessage` tool absent at session start (#99), (2) malformed-terminal recovery probe with `agent_id` gone (#51), (3) user-requested fresh take.
6. **Automerge gate (invariant) condition 1** — update to enumerate the warm-agent path and the fallback path explicitly, preserving the invariant ("review has run and either signed off or had every finding addressed") while making it clear who signals post-review-work is complete in each route.
7. **Notification-relay policy** — minor edit so the address-review-fallback line covers both cases (agent_id unreachable, SendMessage absent).

## Out of scope (per issue body / task brief)

- No new helper script — the probe is an orchestrator action.
- No unit tests — the probe is harness-level prose, not script logic.
- Dispatch template / mini-agent templates / operating-principles unchanged — implementing agent contract does not change.

## Test plan

- [ ] Read final diff against `main` for clarity of the probe-caching strategy.
- [ ] Read final diff against `main` for clarity of the LGTM-no-`SendMessage` immediate-merge-handoff path — must not contradict the existing automerge-gate invariant.
- [ ] Verify the dispatch template's "do NOT set automerge / run gh pr merge" prose stays unchanged.
