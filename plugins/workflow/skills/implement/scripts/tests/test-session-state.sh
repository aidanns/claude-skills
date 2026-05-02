#!/usr/bin/env bash

# Regression tests for `session-state.sh`. Focused on the `add-worktree`
# subcommand introduced for issue #102 (every dispatched-agent worktree
# must be tracked so Phase 6 housekeeping can remove all of them, not
# just the implementing agent's). Also exercises the surrounding
# invariants the new field interacts with: `init` seeds `worktrees: []`
# per issue, `update-issue worktree=<p>` does not disturb the plural
# array, and idempotent re-appends do not duplicate paths.
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

if (( failed != 0 )); then
  printf '\nFAIL: one or more assertions failed.\n' >&2
  exit 1
fi

printf '\nAll session-state assertions passed.\n'
