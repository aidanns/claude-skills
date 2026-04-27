#!/usr/bin/env bash

# Emit a one-line progress digest for a single in-flight issue, matching the
# format the workflow:implement skill's Phase 5 § Progress reporting documents:
#
#   #<N> <pr-url> — review: <state> — CI: <state> — merge: <state>
#
# The orchestrator's per-tick loop runs this once per in-flight issue and
# emits the stdout verbatim, replacing the prior practice of running the gh
# queries inline and formatting the line itself (~500-1K tokens per probe per
# in-flight issue).
#
# Edge cases (exit code is always 0; orchestrator distinguishes via stdout):
#   - No PR found yet           → "#<N> — implementing"
#   - PR state == MERGED        → "#<N> <pr-url> — merged"
#   - PR state == CLOSED        → "#<N> <pr-url> — closed (not merged)"
#   - statusCheckRollup empty   → CI: not started
#   - mergeable == UNKNOWN      → merge: computing
#
# Usage: digest-line.sh <owner/repo> <issue#>

set -euo pipefail

repo="${1:?repo required, e.g. aidanns/agent-auth}"
issue="${2:?issue number required}"

# --- Find the PR -----------------------------------------------------------
#
# `--state all` matches PRs in any state so a PR that merged between ticks
# still appears with `state: MERGED` instead of dropping out of the result
# set — otherwise the empty-result branch is ambiguous between "no PR
# opened yet" and "PR merged".
pr=$(gh pr list --repo "$repo" --state all \
  --search "Closes #${issue} in:body" \
  --json number,url,state,statusCheckRollup,mergeable,mergeStateStatus \
  --limit 1)

if [[ "$(jq 'length' <<<"$pr")" -eq 0 ]]; then
  printf '#%s — implementing\n' "$issue"
  exit 0
fi

pr_url=$(jq -r '.[0].url' <<<"$pr")
pr_state=$(jq -r '.[0].state' <<<"$pr")
pr_number=$(jq -r '.[0].number' <<<"$pr")

case "$pr_state" in
  MERGED)
    printf '#%s %s — merged\n' "$issue" "$pr_url"
    exit 0
    ;;
  CLOSED)
    printf '#%s %s — closed (not merged)\n' "$issue" "$pr_url"
    exit 0
    ;;
esac

# --- Review status ---------------------------------------------------------
#
# Count `Claude Reviewer:` comments — inline (per-line review comments) and
# issue-level (PR-level comments). The review subagent posts either inline
# findings or a single `Claude Reviewer: LGTM` PR-level comment; the
# implementing agent uses `Claude:`, so the prefix discriminates.
inline_count=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
  --jq '[.[] | select(.body | startswith("Claude Reviewer: "))] | length' \
  2>/dev/null || echo 0)
issue_count=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
  --jq '[.[] | select(.body | startswith("Claude Reviewer: "))] | length' \
  2>/dev/null || echo 0)
lgtm_count=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
  --jq '[.[] | select(.body | startswith("Claude Reviewer: LGTM"))] | length' \
  2>/dev/null || echo 0)

if (( inline_count >= 1 )); then
  review_state="done (${inline_count} findings)"
elif (( inline_count == 0 )) && (( lgtm_count == 1 )) && (( issue_count == 1 )); then
  review_state="done (LGTM)"
else
  review_state="pending"
fi

# --- CI state --------------------------------------------------------------
#
# Aggregate `statusCheckRollup`. Walk the table top-to-bottom and pick the
# first matching row.
rollup=$(jq -c '.[0].statusCheckRollup // []' <<<"$pr")
total=$(jq 'length' <<<"$rollup")

if (( total == 0 )); then
  ci_state="not started"
else
  failing=$(jq '[.[] | select(.conclusion == "FAILURE")] | length' <<<"$rollup")
  in_progress=$(jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED")] | length' <<<"$rollup")
  succeeded=$(jq '[.[] | select(.conclusion == "SUCCESS")] | length' <<<"$rollup")

  if (( failing > 0 )); then
    ci_state="red (${failing} failing)"
  elif (( in_progress > 0 )); then
    done_count=$(( total - in_progress ))
    ci_state="pending (${done_count}/${total})"
  elif (( succeeded == total )); then
    ci_state="green"
  else
    # Mixed terminal states (NEUTRAL / SKIPPED / CANCELLED etc.) with no
    # FAILURE and nothing in flight — treat as green so the digest doesn't
    # stall on benign non-success terminals.
    ci_state="green"
  fi
fi

# --- Merge state -----------------------------------------------------------
mergeable=$(jq -r '.[0].mergeable' <<<"$pr")
merge_status=$(jq -r '.[0].mergeStateStatus' <<<"$pr")

if [[ "$mergeable" == "CONFLICTING" || "$merge_status" == "DIRTY" ]]; then
  merge_state="conflict"
elif [[ "$merge_status" == "BEHIND" ]]; then
  merge_state="behind"
elif [[ "$mergeable" == "MERGEABLE" ]]; then
  merge_state="clean"
else
  # Covers `mergeable == "UNKNOWN"` and any other non-decisive combination —
  # GitHub hasn't finished computing mergeability yet; will resolve next tick.
  merge_state="computing"
fi

printf '#%s %s — review: %s — CI: %s — merge: %s\n' \
  "$issue" "$pr_url" "$review_state" "$ci_state" "$merge_state"
