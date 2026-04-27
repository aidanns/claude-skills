#!/usr/bin/env bash

# Emit a focused 20-40 line summary of a failed CI run for the workflow:implement
# skill's CI-failure recovery paths (Phase 5b CI-failure-fix mini-agent and the
# dispatch prompt's § 6.3 "Address CI failures").
#
# Replaces the prior practice of running `gh run view <run-id> --log-failed`
# directly and slicing the raw log by hand. GitHub Actions logs interleave every
# step's output plus environment dumps and setup spam; ad-hoc `tail`/`head`/grep
# slicing either misses the actual error or buries it in noise. Per-failure
# investigation cost was ~3-5K tokens of unrelated log content; this script
# narrows that to ~30 lines with the actual error guaranteed to be in scope.
#
# Output shape (stdout):
#   === failing step: <name> ===
#
#   === error markers ===
#   <up to 10 deduplicated lines matching error/FAIL/Traceback/assertion/::error::>
#
#   === final 10 lines ===
#   <last 10 lines of the failing step's log>
#
# Defensive against gh/API quirks: any sub-call that fails (run not found,
# no failing step recorded, log unattached on a green-but-failed run) yields
# an empty section rather than an error exit. Empty output is acceptable —
# the calling agent should recognise it and fall back to `gh run view <run-id>`
# without `--log-failed`, or treat the failure as ENVIRONMENTAL.
#
# Usage: triage-ci-failure.sh <owner/repo> <run-id>

set -euo pipefail

repo="${1:?repo required, e.g. aidanns/claude-skills}"
run_id="${2:?run id required}"

# --- Failing step name ------------------------------------------------------
#
# `gh run view --json jobs` returns every job and its steps with conclusions.
# Pick the first step whose conclusion is "failure" — this is what `--log-failed`
# is keyed on, so the slicing below stays consistent with what the agent sees.
# Fall back to "(unknown)" if no failing step is recorded (green-but-failed
# runs, API quirks, races where the run is still finalising).
step=$(gh run view "$run_id" --repo "$repo" --json jobs \
  --jq '[.jobs[]? | .steps[]? | select(.conclusion == "failure")] | first | .name // "(unknown)"' \
  2>/dev/null || echo "(unknown)")

printf '=== failing step: %s ===\n\n' "$step"

# --- Failure log ------------------------------------------------------------
#
# `--log-failed` returns only the failing job/step output (still verbose, but
# scoped). Suppress errors so a missing-log run still produces a sensible stub.
log=$(gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null || true)

# --- Error markers ----------------------------------------------------------
#
# Case-insensitive grep for lines that announce errors, test failures,
# tracebacks, or assertion failures. Dedupe with `sort -u` so a repeated stack
# trace doesn't crowd out other signals, then cap at 10 to keep total output
# in the 20-40 line target.
#
# `FAIL\b` requires a word boundary so we don't match "FAILED" inside benign
# step names ("Run failed-test-detector", etc.) — only the literal marker.
echo "=== error markers ==="
if [[ -n "$log" ]]; then
  grep -iE 'error:|::error::|^FAILED|Traceback|assertion|FAIL\b' <<<"$log" \
    | sort -u | head -10 || true
fi
echo

# --- Final 10 lines of the failing step -------------------------------------
#
# The last 10 lines of `--log-failed` are usually the actual failure point
# (test runner summary, compiler error, exit-code report). Keeping this even
# when error-marker grep returns hits gives the agent the trailing context
# without a second log fetch.
echo "=== final 10 lines ==="
if [[ -n "$log" ]]; then
  tail -10 <<<"$log"
fi
