#!/usr/bin/env bash

# Regression tests for the Phase 5b BEHIND auto-resolve helper
# (`monitor-behind-resolve.sh`). Confirms each upstream step
# (`gh repo clone` / `git fetch` / `git merge`) emits a
# `MONITOR_DEGRADED <pr> <step> <reason>` event on failure, that the
# `<step>:<pr>` dedupe survives across invocations sharing the same
# dedupe file, and that the pre-existing `BEHIND_RESOLVED` /
# `BEHIND_RESOLVE_FAILED` push-specific paths are unchanged.
#
# The helper shells out to `gh` and `git`. Tests inject stubs via PATH:
# a per-test stub directory with executable `gh` and `git` scripts that
# read mode-flag files written by the test to decide whether to exit 0
# or fail with a canned message.
#
# Run: bash plugins/workflow/skills/implement/scripts/tests/test-monitor-behind-resolve.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../monitor-behind-resolve.sh"

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

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n      expected to contain: %q\n      actual:              %q\n' \
      "$name" "$needle" "$haystack"
    failed=1
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n      expected NOT to contain: %q\n      actual:                  %q\n' \
      "$name" "$needle" "$haystack"
    failed=1
  fi
}

# Each test gets a fresh sandbox: a stub bin dir on PATH, a state dir
# whose files the stubs read to decide their behaviour, and a dedupe
# file the helper writes to.
make_sandbox() {
  local sandbox; sandbox=$(mktemp -d)
  mkdir -p "$sandbox/bin" "$sandbox/state"

  # `gh` stub. Two subcommands matter:
  #   `gh repo view --json nameWithOwner -q .nameWithOwner` -> prints "owner/repo"
  #   `gh repo clone <repo> repo -- ...`                    -> reads state/clone_mode
  cat >"$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
state_dir="${STATE_DIR}"
case "$1 $2" in
  "pr view")
    # Used by the helper's CI-green precheck:
    #   gh pr view <pr> --json statusCheckRollup --jq '.statusCheckRollup'
    # The stub reads `state/checks_rollup` to decide what JSON to emit.
    # File contents map to canned rollups:
    #   `green`   -> all SUCCESS (proceed).
    #   `pending` -> one IN_PROGRESS entry (defer).
    #   `failure` -> one FAILURE entry (defer).
    #   `mixed`   -> mixed SUCCESS+SKIPPED+NEUTRAL (proceed).
    #   `empty`   -> empty array (proceed; no CI configured).
    #   missing/anything else -> default to `green` so existing tests
    #     that don't set this file see the helper's behaviour unchanged.
    mode="$(cat "${state_dir}/checks_rollup" 2>/dev/null || echo green)"
    case "$mode" in
      pending)
        printf '[{"name":"build","conclusion":null,"status":"IN_PROGRESS"}]\n'
        ;;
      failure)
        printf '[{"name":"build","conclusion":"FAILURE","status":"COMPLETED"}]\n'
        ;;
      mixed)
        printf '[{"name":"build","conclusion":"SUCCESS","status":"COMPLETED"},{"name":"lint","conclusion":"SKIPPED","status":"COMPLETED"},{"name":"sec","conclusion":"NEUTRAL","status":"COMPLETED"}]\n'
        ;;
      empty)
        printf '[]\n'
        ;;
      gh_fail)
        # Simulate a transient `gh` failure on the precheck path.
        printf 'gh pr view: api error\n' >&2
        exit 1
        ;;
      *)
        printf '[{"name":"build","conclusion":"SUCCESS","status":"COMPLETED"}]\n'
        ;;
    esac
    ;;
  "repo view")
    if [[ "$(cat "${state_dir}/view_mode" 2>/dev/null || echo ok)" == "fail" ]]; then
      printf 'gh repo view: rate-limited\n' >&2
      exit 1
    fi
    printf 'owner/repo\n'
    ;;
  "repo clone")
    if [[ "$(cat "${state_dir}/clone_mode" 2>/dev/null || echo ok)" == "fail" ]]; then
      printf 'gh repo clone: permission denied\n' >&2
      exit 1
    fi
    # The 3rd positional is the repo argument the helper interpolated from
    # `gh repo view`. If the view stub failed, the captured stderr ends up
    # here as a bogus repo name -- mirror real `gh repo clone` and reject
    # anything that does not look like `owner/repo`. This is what makes the
    # gh-repo-view-folded-into-clone contract actually observable in the
    # test fixture.
    repo_arg="$3"
    if [[ ! "$repo_arg" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      printf 'gh repo clone: invalid repository %q\n' "$repo_arg" >&2
      exit 1
    fi
    # Success: create a `repo` dir so the helper's `cd repo` succeeds.
    mkdir -p repo
    cd repo
    git init -q
    git config user.email test@example.com
    git config user.name test
    git commit --allow-empty -qm initial
    ;;
  *)
    printf 'gh stub: unhandled args: %s\n' "$*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$sandbox/bin/gh"

  # `git` stub. The helper invokes `git fetch`, `git merge`, `git ls-files`,
  # `git push`, `git init`, `git config`, `git commit`. We need real
  # behaviour from `git init` / `config` / `commit` (used by the `gh repo
  # clone` stub above), so we delegate to the real git binary for those
  # and only intercept the four commands the helper itself runs.
  real_git=$(command -v git)
  cat >"$sandbox/bin/git" <<STUB
#!/usr/bin/env bash
set -uo pipefail
state_dir="\${STATE_DIR}"
real_git="${real_git}"
case "\$1" in
  fetch)
    if [[ "\$(cat "\${state_dir}/fetch_mode" 2>/dev/null || echo ok)" == "fail" ]]; then
      printf 'fatal: could not read from remote\n' >&2
      exit 1
    fi
    exit 0
    ;;
  merge)
    if [[ "\$2" == "--abort" ]]; then
      # Record the abort call so tests can assert it was invoked.
      : >"\${state_dir}/merge_aborted"
      exit 0
    fi
    mode="\$(cat "\${state_dir}/merge_mode" 2>/dev/null || echo ok)"
    case "\$mode" in
      ok)       exit 0 ;;
      conflict)
        # Simulate an unmerged path so the helper's ls-files check
        # detects a real conflict and falls through to the outer loop.
        : >"\${state_dir}/has_conflict"
        printf 'CONFLICT (content): merge conflict in foo\n' >&2
        exit 1
        ;;
      hardfail)
        printf 'fatal: refusing to merge unrelated histories\n' >&2
        exit 128
        ;;
    esac
    ;;
  ls-files)
    if [[ "\$2" == "-u" && -f "\${state_dir}/has_conflict" ]]; then
      printf '100644 abc 1\tfoo\n'
    fi
    exit 0
    ;;
  push)
    if [[ "\$(cat "\${state_dir}/push_mode" 2>/dev/null || echo ok)" == "fail" ]]; then
      printf 'remote: refusing to allow PAT to create or update workflow\n' >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    exec "\$real_git" "\$@"
    ;;
esac
STUB
  chmod +x "$sandbox/bin/git"

  printf '%s\n' "$sandbox"
}

run_helper() {
  local sandbox="$1" pr="$2" branch="$3" base="$4" dedupe_file="$5"
  STATE_DIR="$sandbox/state" PATH="$sandbox/bin:$PATH" \
    bash "$helper" "$pr" "$branch" "$base" "$dedupe_file"
}

# --- Test 1: clone failure emits MONITOR_DEGRADED clone, deduped on second call.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'fail\n' >"$sandbox/state/clone_mode"
out1=$(run_helper "$sandbox" 451 feature/x main "$dedupe" 2>&1)
out2=$(run_helper "$sandbox" 451 feature/x main "$dedupe" 2>&1)

assert_contains \
  "clone failure emits MONITOR_DEGRADED clone with reason" \
  "MONITOR_DEGRADED 451 clone" "$out1"
assert_contains \
  "clone failure reason includes the captured stderr" \
  "permission denied" "$out1"
assert_eq \
  "second invocation with same dedupe file emits nothing (dedupe holds)" \
  "" "$out2"
assert_eq \
  "dedupe file records clone:451 marker" \
  "clone:451" "$(cat "$dedupe")"
rm -rf "$sandbox"

# --- Test 2: clone failure for pr 451 does NOT suppress clone failure for pr 452
# (dedupe is per `<step>:<pr>`, not per step alone).
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'fail\n' >"$sandbox/state/clone_mode"
out1=$(run_helper "$sandbox" 451 feature/x main "$dedupe" 2>&1)
out2=$(run_helper "$sandbox" 452 feature/y main "$dedupe" 2>&1)

assert_contains "first PR clone failure surfaces" \
  "MONITOR_DEGRADED 451 clone" "$out1"
assert_contains "second PR clone failure also surfaces (different pr#)" \
  "MONITOR_DEGRADED 452 clone" "$out2"
rm -rf "$sandbox"

# --- Test 3: fetch failure emits MONITOR_DEGRADED fetch.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'fail\n' >"$sandbox/state/fetch_mode"
out=$(run_helper "$sandbox" 700 feature/z main "$dedupe" 2>&1)

assert_contains "fetch failure emits MONITOR_DEGRADED fetch" \
  "MONITOR_DEGRADED 700 fetch" "$out"
assert_contains "fetch failure reason includes captured stderr" \
  "could not read from remote" "$out"
rm -rf "$sandbox"

# --- Test 4: hard merge error (unrelated histories) emits MONITOR_DEGRADED merge.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'hardfail\n' >"$sandbox/state/merge_mode"
out=$(run_helper "$sandbox" 800 feature/q main "$dedupe" 2>&1)

assert_contains "hard merge error emits MONITOR_DEGRADED merge" \
  "MONITOR_DEGRADED 800 merge" "$out"
assert_contains "merge failure reason includes captured stderr" \
  "unrelated histories" "$out"
rm -rf "$sandbox"

# --- Test 5: a real merge conflict does NOT emit MONITOR_DEGRADED -- it falls
# through to the outer loop's CONFLICT path on the next tick. This is the
# key contract distinguishing "auto-resolve degraded" from "auto-resolve
# decided not to escalate this tick".
#
# Also pin two adjacent contracts that a future regression could quietly
# break: (1) `git merge --abort` is invoked so the working tree is clean
# for the next tick, and (2) the dedupe file stays empty so a transient
# conflict does not consume the `merge:<pr>` slot and silently swallow a
# later hard-merge-error event for the same PR.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'conflict\n' >"$sandbox/state/merge_mode"
out=$(run_helper "$sandbox" 801 feature/q main "$dedupe" 2>&1)

assert_not_contains "merge-conflict tick does NOT emit MONITOR_DEGRADED" \
  "MONITOR_DEGRADED" "$out"
assert_not_contains "merge-conflict tick does NOT emit BEHIND_RESOLVED either" \
  "BEHIND_RESOLVED" "$out"
if [[ -f "$sandbox/state/merge_aborted" ]]; then
  abort_called=true
else
  abort_called=false
fi
assert_eq "merge-conflict tick calls git merge --abort" \
  "true" "$abort_called"
assert_eq "merge-conflict tick leaves dedupe file untouched" \
  "" "$(cat "$dedupe")"
rm -rf "$sandbox"

# --- Test 6: success path emits BEHIND_RESOLVED, no MONITOR_DEGRADED.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
out=$(run_helper "$sandbox" 900 feature/r main "$dedupe" 2>&1)

assert_contains "success path emits BEHIND_RESOLVED" \
  "BEHIND_RESOLVED 900" "$out"
assert_not_contains "success path emits no MONITOR_DEGRADED" \
  "MONITOR_DEGRADED" "$out"
rm -rf "$sandbox"

# --- Test 7: push failure path is unchanged -- emits BEHIND_RESOLVE_FAILED,
# not MONITOR_DEGRADED. This guards the acceptance criterion that
# BEHIND_RESOLVED / BEHIND_RESOLVE_FAILED remain push-specific.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'fail\n' >"$sandbox/state/push_mode"
out=$(run_helper "$sandbox" 901 feature/r main "$dedupe" 2>&1)

assert_contains "push failure emits BEHIND_RESOLVE_FAILED" \
  "BEHIND_RESOLVE_FAILED 901" "$out"
assert_contains "BEHIND_RESOLVE_FAILED reason includes captured stderr" \
  "workflow" "$out"
assert_not_contains "push failure does NOT emit MONITOR_DEGRADED" \
  "MONITOR_DEGRADED" "$out"
rm -rf "$sandbox"

# --- Test 8: `gh repo view` failure surfaces as MONITOR_DEGRADED clone.
# Pins the design decision documented in the PR body: `gh repo view` is
# folded into the `clone` step because the view call is an argument
# substitution to clone -- if view fails the clone arg is corrupt and the
# clone fails, capturing both. `clone_mode=ok` here so the clone-stub-side
# explicit-fail path is NOT what surfaces the failure -- it has to come
# from the view-corrupted repo arg flowing into the clone.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'fail\n' >"$sandbox/state/view_mode"
out=$(run_helper "$sandbox" 951 feature/v main "$dedupe" 2>&1)

assert_contains "gh repo view failure surfaces as MONITOR_DEGRADED clone" \
  "MONITOR_DEGRADED 951 clone" "$out"
assert_contains "view-via-clone failure reason carries the clone-side stderr" \
  "invalid repository" "$out"
rm -rf "$sandbox"

# --- Test 9 (issue #100): CI-pending precheck defers the resolve.
# When `statusCheckRollup` shows any check still running (null/missing
# conclusion), the helper must exit silently — no MONITOR_DEGRADED, no
# BEHIND_RESOLVED, no BEHIND_RESOLVE_FAILED. This guards the merge-bot
# `recheck` ordering: don't push a merge commit that restarts an
# in-flight CI cycle.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'pending\n' >"$sandbox/state/checks_rollup"
out=$(run_helper "$sandbox" 1001 feature/p main "$dedupe" 2>&1)

assert_eq "CI-pending precheck emits no event (silent next-tick deferral)" \
  "" "$out"
assert_eq "CI-pending precheck leaves dedupe file untouched" \
  "" "$(cat "$dedupe")"
rm -rf "$sandbox"

# --- Test 10 (issue #100): CI-failed precheck also defers the resolve.
# A non-green resolved conclusion (FAILURE / CANCELLED / TIMED_OUT) means
# the PR has problems unrelated to BEHIND that need human attention; do
# not push a merge commit on top of failing CI.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'failure\n' >"$sandbox/state/checks_rollup"
out=$(run_helper "$sandbox" 1002 feature/f main "$dedupe" 2>&1)

assert_eq "CI-failed precheck emits no event (silent next-tick deferral)" \
  "" "$out"
rm -rf "$sandbox"

# --- Test 11 (issue #100): SUCCESS+SKIPPED+NEUTRAL is treated as fully
# green — the precheck must not be a strict-SUCCESS-only check, since
# real CI rollups commonly include skipped/neutral entries (e.g. a
# matrix job that only runs on certain paths).
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'mixed\n' >"$sandbox/state/checks_rollup"
out=$(run_helper "$sandbox" 1003 feature/m main "$dedupe" 2>&1)

assert_contains "SUCCESS+SKIPPED+NEUTRAL rollup proceeds to BEHIND_RESOLVED" \
  "BEHIND_RESOLVED 1003" "$out"
rm -rf "$sandbox"

# --- Test 12 (issue #100): empty rollup (no CI configured on the PR)
# proceeds — there's no in-flight cycle to disrupt and BEHIND still
# needs resolving. Matches how the outer monitor's STALLED_GREEN
# detector treats an empty rollup.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'empty\n' >"$sandbox/state/checks_rollup"
out=$(run_helper "$sandbox" 1004 feature/e main "$dedupe" 2>&1)

assert_contains "empty rollup proceeds to BEHIND_RESOLVED" \
  "BEHIND_RESOLVED 1004" "$out"
rm -rf "$sandbox"

# --- Test 13 (issue #100): a transient `gh pr view` failure on the
# precheck path defers rather than racing in on missing data. The
# helper must treat gh-failure-during-precheck the same as
# CI-not-fully-green and exit silently.
sandbox=$(make_sandbox)
dedupe="$sandbox/dedupe"; : >"$dedupe"
printf 'gh_fail\n' >"$sandbox/state/checks_rollup"
out=$(run_helper "$sandbox" 1005 feature/g main "$dedupe" 2>&1)

assert_eq "transient gh failure on precheck defers silently" \
  "" "$out"
rm -rf "$sandbox"

if (( failed != 0 )); then
  printf '\nFAIL: one or more assertions failed.\n' >&2
  exit 1
fi

printf '\nAll monitor-behind-resolve assertions passed.\n'
