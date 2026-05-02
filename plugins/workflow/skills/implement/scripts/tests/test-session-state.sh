#!/usr/bin/env bash

# Regression tests for `session-state.sh`. Originally focused on the
# `add-worktree` subcommand from #102; extended in #104 to cover the
# `find-overlap` and `find-stale` subcommands the orchestrator calls at
# intake (Phase 1.0 / 1.1) to detect a second `/workflow:implement`
# invocation racing the same issue or a state file abandoned by a dead
# session. The surrounding `add-worktree` invariants are still exercised:
# `init` seeds `worktrees: []` per issue, `update-issue worktree=<p>`
# does not disturb the plural array, and idempotent re-appends do not
# duplicate paths.
#
# Each test runs against an isolated state directory via the
# `WORKFLOW_IMPLEMENT_STATE_DIR` env override the script already
# respects, so tests do not touch the real `~/.claude/state/` tree.
#
# Run: bash plugins/workflow/skills/implement/scripts/tests/test-session-state.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../session-state.sh"

failed=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n      expected: %q\n      actual:   %q\n' \
      "$name" "$expected" "$actual"
    failed=1
  fi
}

assert_exit_code() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" -eq "$actual" ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n      expected exit code: %d\n      actual exit code:   %d\n' \
      "$name" "$expected" "$actual"
    failed=1
  fi
}

with_sandbox() {
  # Each test gets its own state dir. Trap-cleaned via the parent shell's EXIT.
  local tmp
  tmp=$(mktemp -d)
  printf '%s\n' "$tmp"
}

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

run_init() {
  local id="$1" repo="$2" issues="$3"
  bash "$script" init "$id" "$repo" '{}' "$issues" >/dev/null
}

# --- Test 1: init seeds worktrees: [] per issue. ----------------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-1 acme/repo '[281, 282]'
state=$(bash "$script" get wfi-test-1)
assert_eq "init seeds worktrees:[] for first issue" \
  "[]" "$(printf '%s' "$state" | jq -c '.issues["281"].worktrees')"
assert_eq "init seeds worktrees:[] for second issue" \
  "[]" "$(printf '%s' "$state" | jq -c '.issues["282"].worktrees')"

# --- Test 2: add-worktree appends a single path. ----------------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-2 acme/repo '[281]'
bash "$script" add-worktree wfi-test-2 281 /tmp/worktrees/agent-aaa
state=$(bash "$script" get wfi-test-2)
assert_eq "add-worktree appends path to issues[<n>].worktrees" \
  '["/tmp/worktrees/agent-aaa"]' \
  "$(printf '%s' "$state" | jq -c '.issues["281"].worktrees')"

# --- Test 3: add-worktree is idempotent on re-add. --------------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-3 acme/repo '[281]'
bash "$script" add-worktree wfi-test-3 281 /tmp/worktrees/agent-aaa
bash "$script" add-worktree wfi-test-3 281 /tmp/worktrees/agent-aaa
bash "$script" add-worktree wfi-test-3 281 /tmp/worktrees/agent-aaa
state=$(bash "$script" get wfi-test-3)
assert_eq "add-worktree is idempotent on re-add of same path" \
  '["/tmp/worktrees/agent-aaa"]' \
  "$(printf '%s' "$state" | jq -c '.issues["281"].worktrees')"

# --- Test 4: multiple distinct paths all land in the array. -----------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-4 acme/repo '[281]'
bash "$script" add-worktree wfi-test-4 281 /tmp/worktrees/agent-impl
bash "$script" add-worktree wfi-test-4 281 /tmp/worktrees/agent-conflict
bash "$script" add-worktree wfi-test-4 281 /tmp/worktrees/agent-review
state=$(bash "$script" get wfi-test-4)
assert_eq "add-worktree accumulates multiple distinct paths in order" \
  '["/tmp/worktrees/agent-impl","/tmp/worktrees/agent-conflict","/tmp/worktrees/agent-review"]' \
  "$(printf '%s' "$state" | jq -c '.issues["281"].worktrees')"

# --- Test 5: missing state file → exit 1. -----------------------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
set +e
bash "$script" add-worktree wfi-no-such-session 281 /tmp/worktrees/agent-aaa >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "add-worktree against missing state file exits 1" 1 "$rc"

# --- Test 6: missing args. --------------------------------------------
# Missing required positional args use the same `${var:?msg}` shape as
# the rest of the script's subcommands, which exits 1 under `set -e`.
# An *empty* path is an explicit invalid-argument check and exits 2 so
# the caller can distinguish "you didn't pass anything" from "you passed
# something nonsensical."
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-6 acme/repo '[281]'
set +e
bash "$script" add-worktree wfi-test-6 >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "add-worktree with no issue#/path exits 1" 1 "$rc"

set +e
bash "$script" add-worktree wfi-test-6 281 "" >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "add-worktree with empty path exits 2" 2 "$rc"

# --- Test 7: update-issue worktree=<p> does not clobber the array. ----
# This is the migration invariant: the singular `worktree` field retains
# diagnostic value (which path was the implementing agent's), while the
# plural `worktrees` array is the source of truth Phase 6 cleanup reads.
# Touching one must not silently rewrite the other.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-7 acme/repo '[281]'
bash "$script" add-worktree wfi-test-7 281 /tmp/worktrees/agent-impl
bash "$script" add-worktree wfi-test-7 281 /tmp/worktrees/agent-conflict
bash "$script" update-issue wfi-test-7 281 in-progress \
  worktree=/tmp/worktrees/agent-impl branch=aidanns/foo
state=$(bash "$script" get wfi-test-7)
assert_eq "update-issue sets singular worktree field" \
  '"/tmp/worktrees/agent-impl"' \
  "$(printf '%s' "$state" | jq -c '.issues["281"].worktree')"
assert_eq "update-issue does not disturb plural worktrees array" \
  '["/tmp/worktrees/agent-impl","/tmp/worktrees/agent-conflict"]' \
  "$(printf '%s' "$state" | jq -c '.issues["281"].worktrees')"

# --- Test 8: add-worktree on a state file written before the field was
#             part of `init` defaults still works. ---------------------
# Simulates a `--resume` against a state file written by a prior
# orchestrator that didn't seed `worktrees: []`. The append path must
# materialise the array on the fly rather than crashing on `null + [...]`.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-8 acme/repo '[281]'
# Strip the worktrees field to simulate a pre-#102 state file.
state_file="$sandbox/wfi-test-8.json"
jq 'del(.issues["281"].worktrees)' "$state_file" > "${state_file}.new"
mv "${state_file}.new" "$state_file"
bash "$script" add-worktree wfi-test-8 281 /tmp/worktrees/agent-aaa
state=$(bash "$script" get wfi-test-8)
assert_eq "add-worktree materialises missing worktrees array" \
  '["/tmp/worktrees/agent-aaa"]' \
  "$(printf '%s' "$state" | jq -c '.issues["281"].worktrees')"

# --- Test 9: get surfaces the worktrees field verbatim. ---------------
# jq exposes any JSON field — confirm so callers don't reach for new
# read helpers when they can just `jq '.issues["<n>"].worktrees[]'`.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-test-9 acme/repo '[281]'
bash "$script" add-worktree wfi-test-9 281 /tmp/worktrees/agent-a
bash "$script" add-worktree wfi-test-9 281 /tmp/worktrees/agent-b
paths=$(bash "$script" get wfi-test-9 | jq -r '.issues["281"].worktrees[]' | tr '\n' ',' )
assert_eq "get + jq iterates the worktrees array" \
  "/tmp/worktrees/agent-a,/tmp/worktrees/agent-b," "$paths"

# --- find-overlap ----------------------------------------------------
# The intake-time scan a `/workflow:implement` invocation runs to detect
# another session already claiming an issue this one is about to claim.
# The active state set is `scheduled | in-progress | automerge_set`;
# `merged`, `blocked`, `paused`, `errored`, `externally_closed` are NOT
# active overlap (a parked issue can be picked up by a fresh run; an
# already-merged one is gone from the work pool entirely).

# --- Test 10: find-overlap on an empty state directory returns []. ----
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
got=$(bash "$script" find-overlap acme/repo '[1,2,3]' | jq -c '.')
assert_eq "find-overlap on empty state dir returns []" '[]' "$got"

# --- Test 11: find-overlap finds a single-issue overlap. --------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-overlap-a acme/repo '[456,457,458]'
got=$(bash "$script" find-overlap acme/repo '[458]' \
      | jq -c 'map({session_id, overlapping_issues})')
assert_eq "find-overlap surfaces session and the overlapping issue" \
  '[{"session_id":"wfi-overlap-a","overlapping_issues":[458]}]' \
  "$got"

# --- Test 12: find-overlap finds multi-issue overlap. -----------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-overlap-multi acme/repo '[456,457,458]'
got=$(bash "$script" find-overlap acme/repo '[456,458,500]' \
      | jq -c 'map({session_id, overlapping_issues})')
assert_eq "find-overlap returns every overlapping issue, in input order" \
  '[{"session_id":"wfi-overlap-multi","overlapping_issues":[456,458]}]' \
  "$got"

# --- Test 13: find-overlap returns an empty array on no overlap. ------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-no-overlap acme/repo '[100,101]'
got=$(bash "$script" find-overlap acme/repo '[200,201]' | jq -c '.')
assert_eq "find-overlap returns [] when issues do not intersect" '[]' "$got"

# --- Test 14: find-overlap filters by repo. ---------------------------
# A session claiming the same issue *number* in a different repo is not
# overlap — the issue numbers are scoped to the repo.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-other-repo other/repo '[458]'
got=$(bash "$script" find-overlap acme/repo '[458]' | jq -c '.')
assert_eq "find-overlap scopes overlap to the requested repo" '[]' "$got"

# --- Test 15: find-overlap honours --except <session-id>. -------------
# The orchestrator scans after Phase 3 has written its own state file;
# without --except it would see itself in the overlap output.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-self acme/repo '[458]'
run_init wfi-other acme/repo '[458]'
got=$(bash "$script" find-overlap acme/repo '[458]' --except wfi-self \
      | jq -c '[.[] | .session_id]')
assert_eq "find-overlap --except skips the named session" \
  '["wfi-other"]' "$got"

# --- Test 16: find-overlap excludes terminal / parked states. ---------
# Active set = scheduled | in-progress | automerge_set. The other
# possibilities (merged | blocked | paused | errored | externally_closed)
# are either gone from the work pool or recoverable-by-the-other-session
# without holding an active dispatch.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-mixed-states term/repo '[1,2,3,4,5,6,7,8]'
bash "$script" update-issue wfi-mixed-states 1 scheduled        >/dev/null
bash "$script" update-issue wfi-mixed-states 2 in-progress      >/dev/null
bash "$script" update-issue wfi-mixed-states 3 automerge_set    >/dev/null
bash "$script" update-issue wfi-mixed-states 4 merged           >/dev/null
bash "$script" update-issue wfi-mixed-states 5 blocked          >/dev/null
bash "$script" update-issue wfi-mixed-states 6 paused           >/dev/null
bash "$script" update-issue wfi-mixed-states 7 errored          >/dev/null
bash "$script" update-issue wfi-mixed-states 8 externally_closed >/dev/null
got=$(bash "$script" find-overlap term/repo '[1,2,3,4,5,6,7,8]' \
      | jq -c '.[] | .overlapping_issues')
assert_eq "find-overlap only counts scheduled/in-progress/automerge_set" \
  '[1,2,3]' "$got"

# --- Test 17: find-overlap rejects malformed issues-json. -------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
set +e
bash "$script" find-overlap acme/repo 'not-json' >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "find-overlap rejects non-JSON input with exit 2" 2 "$rc"

set +e
bash "$script" find-overlap acme/repo '["a","b"]' >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "find-overlap rejects non-numeric array with exit 2" 2 "$rc"

# --- Test 18: find-overlap survives a corrupted neighbour state file. -
# The intake-time scan must not be blocked by an unrelated corrupted
# file — `--session list` is the surface that flags corruption to the
# user, not this scan. A fresh run should still see the overlap from
# every parseable peer.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-good acme/repo '[458]'
printf '{ broken' > "$sandbox/wfi-bad.json"
got=$(bash "$script" find-overlap acme/repo '[458]' \
      | jq -c '[.[] | .session_id]')
assert_eq "find-overlap skips corrupted state files without failing" \
  '["wfi-good"]' "$got"

# --- find-stale ------------------------------------------------------
# Stale = every active issue (state ∈ scheduled | in-progress |
# automerge_set) is CLOSED on GitHub per the supplied gh-state mapping.
# The mapping is supplied by the orchestrator (it owns the network
# calls) so this script stays offline-by-default and unit-testable.

# --- Test 19: find-stale on empty state directory returns []. --------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
got=$(echo '{}' | bash "$script" find-stale - | jq -c '.')
assert_eq "find-stale on empty state dir returns []" '[]' "$got"

# --- Test 20: find-stale detects a session whose every active issue is
#              CLOSED on GitHub. -------------------------------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-stale acme/repo '[458]'
bash "$script" update-issue wfi-stale 458 in-progress >/dev/null
got=$(echo '{"458":"CLOSED"}' \
      | bash "$script" find-stale acme/repo - \
      | jq -c '[.[] | .session_id]')
assert_eq "find-stale flags a session whose only active issue is CLOSED" \
  '["wfi-stale"]' "$got"

# --- Test 21: find-stale ignores sessions with at least one OPEN
#              active issue. ----------------------------------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-not-stale acme/repo '[458,459]'
bash "$script" update-issue wfi-not-stale 458 in-progress >/dev/null
bash "$script" update-issue wfi-not-stale 459 scheduled   >/dev/null
got=$(echo '{"458":"CLOSED","459":"OPEN"}' \
      | bash "$script" find-stale acme/repo - \
      | jq -c '.')
assert_eq "find-stale ignores sessions with at least one OPEN active issue" \
  '[]' "$got"

# --- Test 22: find-stale ignores sessions with no active issues at all
#              (every issue terminal — Phase 8 GC will pick them up). -
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-all-merged acme/repo '[458]'
bash "$script" update-issue wfi-all-merged 458 merged >/dev/null
got=$(echo '{}' \
      | bash "$script" find-stale acme/repo - \
      | jq -c '.')
assert_eq "find-stale ignores sessions with no active issues" '[]' "$got"

# --- Test 23: find-stale defaults missing gh-state entries to OPEN. --
# An active issue not present in the mapping is conservatively treated
# as still-open; the orchestrator sometimes batch-fetches a subset of
# the relevant issues, and stale-marking on missing data would surface
# false positives.
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-conservative acme/repo '[458]'
bash "$script" update-issue wfi-conservative 458 in-progress >/dev/null
got=$(echo '{}' \
      | bash "$script" find-stale acme/repo - \
      | jq -c '.')
assert_eq "find-stale treats missing gh-state entries as OPEN (not stale)" \
  '[]' "$got"

# --- Test 24: find-stale repo filter restricts the scan. -------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-acme acme/repo '[458]'
bash "$script" update-issue wfi-acme 458 in-progress >/dev/null
run_init wfi-other other/repo '[100]'
bash "$script" update-issue wfi-other 100 in-progress >/dev/null
got=$(echo '{"458":"CLOSED","100":"CLOSED"}' \
      | bash "$script" find-stale acme/repo - \
      | jq -c '[.[] | .session_id]')
assert_eq "find-stale repo filter restricts the scan to the named repo" \
  '["wfi-acme"]' "$got"

# Without the filter, both sessions are surfaced.
got=$(echo '{"458":"CLOSED","100":"CLOSED"}' \
      | bash "$script" find-stale - \
      | jq -c '[.[] | .session_id] | sort')
assert_eq "find-stale without repo filter surfaces every stale session" \
  '["wfi-acme","wfi-other"]' "$got"

# --- Test 25: find-stale reads the gh-state from a file path. --------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
run_init wfi-from-file acme/repo '[458]'
bash "$script" update-issue wfi-from-file 458 in-progress >/dev/null
gh_state_path="$sandbox/gh-state.json"
printf '%s' '{"458":"CLOSED"}' > "$gh_state_path"
got=$(bash "$script" find-stale acme/repo "$gh_state_path" \
      | jq -c '[.[] | .session_id]')
assert_eq "find-stale reads gh-state from a file path" \
  '["wfi-from-file"]' "$got"

# --- Test 26: find-stale rejects a non-existent file path. -----------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
set +e
bash "$script" find-stale acme/repo /tmp/definitely-not-here-$$ \
  >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "find-stale exits 2 on missing gh-state file" 2 "$rc"

# --- Test 27: find-stale rejects malformed gh-state. -----------------
sandbox=$(with_sandbox); cleanup_dirs+=("$sandbox")
export WORKFLOW_IMPLEMENT_STATE_DIR="$sandbox"
set +e
echo '[]' | bash "$script" find-stale - >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "find-stale exits 2 on non-object gh-state" 2 "$rc"

if (( failed != 0 )); then
  printf '\nFAIL: one or more assertions failed.\n' >&2
  exit 1
fi

printf '\nAll session-state assertions passed.\n'
