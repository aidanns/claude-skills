#!/usr/bin/env bash

# Regression tests for the Phase 1.5 merge-mechanism detector in
# `phase15-conventions.sh`. Sources the script (the script's main flow is
# guarded so sourcing exposes only the pure-text helpers) and exercises the
# workflow-listens-for-`labeled` and label-guard-extraction predicates
# against the fixtures in `fixtures/`. No network calls.
#
# Run: bash plugins/workflow/skills/implement/scripts/tests/test-phase15-conventions.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${here}/fixtures"

# shellcheck source=../phase15-conventions.sh
source "${here}/../phase15-conventions.sh"

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

assert_listens() {
  local name="$1" fixture="$2" expected="$3"
  local content; content="$(cat "${fixtures}/${fixture}")"
  if phase15_workflow_listens_to_labeled "$content"; then
    actual=true
  else
    actual=false
  fi
  assert_eq "$name" "$expected" "$actual"
}

assert_guard() {
  local name="$1" fixture="$2" expected="$3"
  local content; content="$(cat "${fixtures}/${fixture}")"
  local actual; actual="$(phase15_extract_label_guard "$content")"
  assert_eq "$name" "$expected" "$actual"
}

# Issue #101: inline-flow `types: [labeled]` plus a multi-line `if:` block
# whose label-name guard is buried inside an `||` clause. The pre-fix
# detector missed both halves of this pattern and so emitted the wrong
# `Merge mechanism:` trailer.
assert_listens "inline-flow types: [labeled] is recognised" \
  "merge-bot-inline-flow.yml" true
assert_guard   "label.name guard inside multi-line if: is extracted" \
  "merge-bot-inline-flow.yml" "automerge"

# Block-list `types:` with `- labeled` plus a `labels.*.name, 'X'` guard.
# Both shapes appear in the wild; both must be detected.
assert_listens "block-list - labeled entry is recognised" \
  "merge-bot-block-list.yml" true
assert_guard   "labels.*.name contains() guard is extracted" \
  "merge-bot-block-list.yml" "automerge"

# Negative: workflow listens for `labeled` but does not gate on a specific
# label. Must not yield a candidate label.
assert_listens "labeled trigger without label guard is still detected as labeled" \
  "labeled-no-guard.yml" true
assert_guard   "no label guard yields empty extraction" \
  "labeled-no-guard.yml" ""

# Negative: workflow does not subscribe to `pull_request: labeled` at all.
assert_listens "non-pull_request workflow is rejected" \
  "no-pull-request-trigger.yml" false

if (( failed != 0 )); then
  printf '\nFAIL: one or more assertions failed.\n' >&2
  exit 1
fi

printf '\nAll phase15-conventions assertions passed.\n'
