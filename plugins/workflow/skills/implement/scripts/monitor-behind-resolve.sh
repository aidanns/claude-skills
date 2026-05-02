#!/usr/bin/env bash

# Phase 5b BEHIND auto-resolve subroutine. Runs the local-merge catch-up
# (`gh repo clone` → `git fetch` → `git merge` → `git push`) for a PR whose
# `mergeStateStatus` is `BEHIND`, emitting one event line on stdout to be
# routed by the outer monitor loop.
#
# Emits one of:
#   BEHIND_RESOLVED <pr#>                          -- push landed, branch caught up.
#   BEHIND_RESOLVE_FAILED <pr#> <reason>           -- push was rejected (PAT scope, etc.).
#   MONITOR_DEGRADED <pr#> <step> <reason>         -- an upstream step (clone/fetch/merge)
#                                                     failed. Deduplicated per
#                                                     `<step>:<pr>` via the dedupe
#                                                     file so a persistent failure
#                                                     surfaces once per monitor session.
#
# Returns 0 in all cases; emits exactly one event per invocation (or zero, in
# the case of a deduplicated MONITOR_DEGRADED that's already been surfaced, a
# `git merge` that conflicts and falls through to the outer loop's CONFLICT
# detection on the next tick, or a CI-not-fully-green precheck that defers the
# resolve to a later tick — see the precheck block below).
#
# CI-green precheck: before doing any work, the helper queries
# `statusCheckRollup` and requires that every check is fully resolved AND
# fully green (`conclusion ∈ {SUCCESS, SKIPPED, NEUTRAL}`). If any check is
# still pending (null / IN_PROGRESS conclusion) or has a non-green resolved
# conclusion (FAILURE / CANCELLED / TIMED_OUT / etc.), the helper exits 0
# silently — emit nothing, wait for the next tick. This mirrors a
# project-side merge-bot's `recheck` gate: don't push a merge commit that
# would restart the in-flight CI cycle, and don't try to catch up a branch
# whose CI is already failing for non-BEHIND reasons.
#
# The precheck queries `gh pr view --json statusCheckRollup` itself rather
# than accepting the rollup as a 5th positional argument. The duplicate
# query (the outer monitor already fetches the rollup each tick) costs ~one
# `gh` call per BEHIND tick — rare in practice, since BEHIND ticks only
# happen when `main` has moved out from under the PR — and keeps the
# helper's signature unchanged. Threading the rollup through as a JSON
# blob argument would tangle the helper's contract with the outer
# monitor's JSON shape and make standalone invocation harder to reason
# about.
#
# Usage: monitor-behind-resolve.sh <pr#> <pr-branch> <base-branch> <dedupe-file>
#
# The dedupe file is shared with the parent monitor process (which created it
# with `mktemp`) and lives for the lifetime of that monitor. Each line is a
# `<step>:<pr>` marker; the helper appends on first failure and short-circuits
# on subsequent ones so the orchestrator gets exactly one MONITOR_DEGRADED per
# `<step>:<pr>` per session.

set -uo pipefail
# NOTE: Deliberate deviation from the project bash convention `set -euo
# pipefail` (documented in `~/.claude/CLAUDE.md`). `-e` is omitted because
# the helper's contract is to capture non-zero exit codes from `gh` / `git`
# and surface them as `MONITOR_DEGRADED` / `BEHIND_RESOLVE_FAILED` event
# lines. Re-adding `-e` would silently break the failure-surfacing contract
# -- the script would die on the first `gh` failure rather than emitting
# the corresponding event. Do not "fix" this back to `-euo pipefail`.

pr="${1:?pr number required}"
branch="${2:?pr branch required}"
base="${3:?base branch required}"
dedupe_file="${4:?dedupe file path required}"

emit() { printf '%s\n' "$*"; }

# Collapse multi-line stderr into a single space-separated line so the event
# stays on one line for the Monitor tool's per-line notification surface.
collapse() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed 's/  */ /g' | sed 's/^ //; s/ $//'
}

# Emit a MONITOR_DEGRADED event at most once per <step>:<pr> per monitor
# session. The dedupe file is the parent monitor's tempfile; we read it to
# check and append to it on first emit. Concurrency is fine here -- the outer
# monitor only invokes this helper at most once per tick, sequentially.
emit_degraded_once() {
  local step="$1" reason="$2"
  local marker="${step}:${pr}"
  if [[ -f "$dedupe_file" ]] && grep -Fxq "$marker" "$dedupe_file"; then
    return 0
  fi
  emit "MONITOR_DEGRADED $pr $step $(collapse "$reason")"
  printf '%s\n' "$marker" >>"$dedupe_file"
}

# CI-green precheck. Defer the local-merge catch-up until the most recent
# fully-completed CI run is green; otherwise we'd push a merge commit that
# restarts an in-flight CI cycle (slowing the merge instead of speeding it
# up) or catch up a PR whose CI is already failing for non-BEHIND reasons
# (the failure needs human attention, not a branch update).
#
# "Fully green" = every check in `statusCheckRollup` has
# `conclusion ∈ {SUCCESS, SKIPPED, NEUTRAL}`. A null / empty conclusion is
# treated as pending (still running), which fails the gate. Any other
# resolved conclusion (FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED,
# STALE) also fails the gate.
#
# The empty-rollup case (no CI configured on the PR) is treated as green
# — there's no CI cycle to disrupt, and the BEHIND state still needs
# resolving. This matches how the outer monitor's STALLED_GREEN detector
# treats an empty rollup.
#
# Returns 0 (proceed) iff the rollup is empty or every entry is in the
# accepted-conclusion set; returns 1 (defer) otherwise. The `gh pr view`
# call is silenced on failure (network blip, transient API error) and the
# precheck defers to be safe rather than racing in on stale data.
ci_fully_green() {
  local rollup
  rollup=$(gh pr view "$pr" --json statusCheckRollup --jq '.statusCheckRollup' 2>/dev/null)
  if [[ -z "$rollup" || "$rollup" == "null" ]]; then
    # `gh` failed or returned no rollup -- defer to the next tick rather
    # than acting on missing data.
    return 1
  fi
  # Every entry must have an accepted conclusion. `(.conclusion // "")` so a
  # null/missing conclusion becomes "" (pending), which is not in the
  # accepted set and thus fails the gate.
  jq -e 'all(.[]?; (.conclusion // "") as $c
            | $c == "SUCCESS" or $c == "SKIPPED" or $c == "NEUTRAL")' \
    <<<"$rollup" >/dev/null 2>&1
}

if ! ci_fully_green; then
  # Silent no-op: wait for the next tick. The outer monitor will re-poll
  # the rollup and re-invoke us; once CI lands fully-green, the resolve
  # will proceed.
  exit 0
fi

# Run the catch-up in a subshell so the `cd` into the tempdir doesn't leak
# back to the caller. The dedupe file lives outside the subshell (passed by
# path), so writes survive subshell teardown.
(
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  cd "$tmpdir" || exit 0

  # Clone. `gh repo view` is inside the substitution -- if it fails the clone
  # will too, so capturing the clone failure subsumes both cases.
  clone_err=$(gh repo clone \
    "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>&1)" \
    repo -- --branch "$branch" --depth 50 2>&1 >/dev/null)
  clone_rc=$?
  if [[ $clone_rc -ne 0 ]]; then
    emit_degraded_once clone "$clone_err"
    exit 0
  fi

  cd repo || exit 0

  # Fetch the base branch.
  fetch_err=$(git fetch origin "$base" 2>&1 >/dev/null)
  fetch_rc=$?
  if [[ $fetch_rc -ne 0 ]]; then
    emit_degraded_once fetch "$fetch_err"
    exit 0
  fi

  # Merge the base branch into the PR branch.
  merge_err=$(git merge --no-edit "origin/$base" 2>&1 >/dev/null)
  merge_rc=$?
  if [[ $merge_rc -ne 0 ]]; then
    # A merge can fail two ways: an actual conflict (which we deliberately
    # leave for the outer loop's CONFLICT path to surface on the next tick),
    # or a hard merge error (e.g. `merge: refusing to merge unrelated
    # histories`, missing ref). Heuristic: if `git ls-files -u` shows
    # unmerged paths, this is a conflict -- abort and let the outer loop
    # handle it. Otherwise it's a hard failure -- emit MONITOR_DEGRADED.
    if git ls-files -u 2>/dev/null | grep -q .; then
      git merge --abort >/dev/null 2>&1 || true
    else
      emit_degraded_once merge "$merge_err"
    fi
    exit 0
  fi

  # Push. Capture stderr so push-specific failures (PAT scope, branch
  # protection rejection) keep emitting BEHIND_RESOLVE_FAILED -- this is the
  # pre-existing surfacing contract and intentionally distinct from
  # MONITOR_DEGRADED.
  push_err=$(git push origin "$branch" 2>&1 >/dev/null)
  push_rc=$?
  if [[ $push_rc -eq 0 ]]; then
    emit "BEHIND_RESOLVED $pr"
  else
    emit "BEHIND_RESOLVE_FAILED $pr $(collapse "$push_err")"
  fi
)
