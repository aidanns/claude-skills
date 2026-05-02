#!/usr/bin/env bash

# Emit a deterministic "Current PR conventions (observed)" block for the
# workflow:implement skill's Phase 1.5. The orchestrator runs this once per
# run and embeds the stdout verbatim into every dispatched agent's prompt,
# replacing the prior practice of reading raw PR-body JSON and inferring by
# eye (which cost ~5-10K tokens and could drift between dispatches).
#
# Usage: phase15-conventions.sh <owner/repo>

set -euo pipefail

# --- Pure-text workflow predicates ------------------------------------------
#
# These two helpers are separated from the network-touching main flow so the
# regression test (`tests/test-phase15-conventions.sh`) can exercise them
# directly against fixture files. Keep them stdin-driven so the test can pipe
# in a fixture without a tempfile dance.

# Does this workflow listen for `pull_request: types: [..., labeled, ...]`?
#
# Handles both YAML list shapes that GitHub Actions accepts:
#   - inline flow:  types: [labeled]   /   types: [opened, labeled]
#   - block list:   types:
#                     - labeled
#
# The previous heuristic only recognised the block form because it anchored
# on a leading `-` at line start. `merge-bot.yml`-shaped workflows that use
# the inline flow form (`types: [labeled]`) silently fell through and were
# excluded from the merge-mechanism candidate set, even though they were the
# very files that should have triggered the label-bot branch.
phase15_workflow_listens_to_labeled() {
  local content="$1"
  # Inline flow list: `types: [..., labeled, ...]`. The character class lets
  # us match across whitespace inside the brackets without having to handle
  # multi-line flow lists (GitHub Actions workflows in the wild keep the
  # flow form on a single line).
  if grep -qE 'types:[[:space:]]*\[[^]]*\blabeled\b[^]]*\]' <<<"$content"; then
    return 0
  fi
  # Block list: a `- labeled` entry on its own line.
  if grep -qE '^[[:space:]]*-[[:space:]]+labeled[[:space:]]*$' <<<"$content"; then
    return 0
  fi
  return 1
}

# Extract the first label name guarded by an `if:` in this workflow.
#
# Recognises the two shapes the merge-bot patterns use:
#   if: github.event.label.name == 'automerge'
#   if: contains(github.event.pull_request.labels.*.name, 'automerge')
#
# Both shapes work when buried inside a multi-line `if:` block joined by
# `||` clauses (e.g. `merge-bot.yml`'s primary trigger gate) — the regex
# is whitespace-tolerant and content-anchored, not line-anchored.
phase15_extract_label_guard() {
  local content="$1"
  grep -oE "(label\.name[[:space:]]*==[[:space:]]*'[^']+'|labels\.\\*\\.name,[[:space:]]*'[^']+')" \
    <<<"$content" | grep -oE "'[^']+'" | head -1 | tr -d "'" || true
}

# Does this workflow contain a project-side BEHIND-handling step? Two
# detection signals (either is sufficient):
#
#   1. A `PUT /pulls/{n}/update-branch` API call — the canonical way a
#      merge-bot catches up a stale PR head before merging. Recognised by
#      a literal `update-branch` substring; the path is consistent across
#      `gh api`, `curl`, and Octokit invocations.
#   2. A `mergeStateStatus`/`mergeable_state` reference where the workflow
#      branches on the value being `BEHIND`/`behind`. Catches workflows
#      that probe the state explicitly before invoking `update-branch` or
#      that route to a different remediation. We require both halves
#      (`mergeStateStatus`/`mergeable_state` *and* `BEHIND`/`behind`) on
#      the same workflow so an unrelated `mergeable_state == 'clean'`
#      check or a stray `behind` token elsewhere doesn't false-positive.
#
# Returns 0 iff the workflow handles BEHIND, 1 otherwise. Whitespace and
# casing variants are tolerated where they appear in the wild; the
# substring-anchored signals are deliberately broad because under-detection
# (skipping a project-side handler and racing it from the monitor) is the
# expensive failure mode this trailer is meant to prevent.
phase15_workflow_handles_behind() {
  local content="$1"
  if grep -q 'update-branch' <<<"$content"; then
    return 0
  fi
  if grep -qE 'mergeStateStatus|mergeable_state' <<<"$content" \
     && grep -qE '\b(BEHIND|behind)\b' <<<"$content"; then
    return 0
  fi
  return 1
}

# When sourced (e.g. by the regression test), expose only the helpers. Skip
# argument parsing and all `gh api` calls so the test runs offline.
if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
  return 0
fi

repo="${1:?repo required, e.g. aidanns/claude-skills}"

# --- Sample: most recent merged PRs -----------------------------------------
#
# 5 is the count Phase 1.5 prose specifies. Bigger samples dilute the signal
# when conventions change.
prs=$(gh pr list --repo "$repo" --state merged --limit 5 \
  --json number,title,body,labels,files)
sample_size=$(jq 'length' <<<"$prs")

# --- Native auto-merge availability ----------------------------------------
#
# Probe `allow_auto_merge` (REST) / `autoMergeAllowed` (GraphQL) once at
# script-time. When it's `false`, the `gh pr merge --auto --squash` default
# would fail with the GraphQL error `Auto merge is not allowed for this
# repository (enablePullRequestAutoMerge)`, so the merge-mechanism decision
# below routes to immediate `gh pr merge --squash` instead. Default to
# `false` on probe failure (treated the same as a repo with automerge
# disabled — safer than emitting an `--auto` flag the merge handoff can't
# honour).
auto_merge_allowed=$(gh api "repos/${repo}" \
  --jq '.allow_auto_merge' 2>/dev/null || echo false)
[[ "$auto_merge_allowed" == "true" ]] || auto_merge_allowed=false

if (( sample_size == 0 )); then
  if [[ "$auto_merge_allowed" == "true" ]]; then
    default_merge='gh pr merge --auto --squash'
  else
    default_merge='gh pr merge --squash'
  fi
  # Probe BEHIND handling even on empty-sample repos so the trailer is
  # always present in the emitted block (downstream consumers can rely on
  # the trailer existing rather than having to handle two output shapes).
  empty_sample_behind="no"
  empty_sample_workflows=$(gh api "repos/${repo}/contents/.github/workflows" \
    --jq '.[]?.name' 2>/dev/null || true)
  if [[ -n "$empty_sample_workflows" ]]; then
    while IFS= read -r wf; do
      [[ -z "$wf" ]] && continue
      [[ "$wf" =~ \.ya?ml$ ]] || continue
      wf_content=$(gh api "repos/${repo}/contents/.github/workflows/${wf}" \
        --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
      [[ -z "$wf_content" ]] && continue
      if phase15_workflow_handles_behind "$wf_content"; then
        empty_sample_behind="yes"
        break
      fi
    done <<<"$empty_sample_workflows"
  fi
  cat <<EOF
Current PR conventions (observed): no merged PRs in this repo yet — fall back to project docs (\`CLAUDE.md\`, \`CONTRIBUTING.md\`) for conventions.
Project BEHIND handling: ${empty_sample_behind}
Merge mechanism: ${default_merge}
EOF
  exit 0
fi

# --- Title-prefix histogram -------------------------------------------------
#
# Capture the leading token before the first `:` (with optional `(scope)`),
# e.g. `feat:`, `fix(api):`, `feature:`, `chore:`. Pick the most-frequent
# prefix family (the part before any scope) as the canonical style. If
# nothing matches, fall back to "no consistent prefix observed".
prefix_family=$(jq -r '
  [.[] | .title | capture("^(?<p>[a-zA-Z]+)(\\([^)]+\\))?:").p // empty]
  | if length == 0 then "" else
      group_by(.) | map({k: .[0], n: length}) | sort_by(-.n) | .[0].k
    end
' <<<"$prs")

# Sample titles for the prefix family so the orchestrator can show the
# dispatched agent concrete examples (incl. scopes that recur).
sample_titles=$(jq -r --arg fam "$prefix_family" '
  [.[] | select(.title | test("^" + $fam + "(\\([^)]+\\))?:")) | .title]
  | .[0:3] | .[] | "  - " + .
' <<<"$prs")

# --- Title length limit -----------------------------------------------------
#
# Default to 72 unless we can find a commit-message-lint config in the repo
# that specifies a different subject-max-length. Probe a small set of common
# locations; if absent, keep the default.
title_max=72
lint_paths=(
  ".github/workflows/commit-lint.yml"
  ".github/workflows/commitlint.yml"
  ".github/commitlint.config.js"
  "commitlint.config.js"
  "commitlint.config.cjs"
  ".commitlintrc.json"
  ".commitlintrc.yml"
)
for path in "${lint_paths[@]}"; do
  content=$(gh api "repos/${repo}/contents/${path}" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null || true)
  if [[ -n "$content" ]]; then
    # Look for a `subject-max-length` rule; commitlint syntax is
    # `'subject-max-length': [<level>, <applic>, <N>]` or a YAML equivalent.
    detected=$(grep -oE "subject-max-length[^0-9]+[0-9]+" <<<"$content" \
      | grep -oE '[0-9]+' | tail -1 || true)
    if [[ -n "$detected" ]]; then
      title_max="$detected"
      break
    fi
  fi
done

# --- ==COMMIT_MSG== block presence ------------------------------------------
#
# Count how many recent PRs wrap their body in the block. all -> required,
# any -> optional, none -> not used.
block_count=$(jq '[.[] | (.body // "" | contains("==COMMIT_MSG=="))] | map(select(.)) | length' <<<"$prs")

if (( block_count == sample_size )); then
  body_block_line='==COMMIT_MSG== block: required (every recent merged PR wraps the commit message in this block)'
elif (( block_count > 0 )); then
  body_block_line='==COMMIT_MSG== block: optional (some recent merged PRs use it; match if your PR style needs it)'
else
  body_block_line='==COMMIT_MSG== block: not used (no recent merged PR wraps the body in this block)'
fi

# --- Label histogram --------------------------------------------------------
#
# Surface labels that appear on the majority of recent merged PRs — those
# are the ones the dispatched agent likely needs to apply at merge time.
label_hist=$(jq -r --argjson n "$sample_size" '
  [.[].labels[]?.name]
  | group_by(.)
  | map({label: .[0], count: length})
  | sort_by(-.count)
  | .[]
  | "  - \(.label): \(.count)/\($n)"
' <<<"$prs")

if [[ -z "$label_hist" ]]; then
  label_hist="  - (no labels observed on recent merged PRs)"
fi

# --- Manual changelog entries -----------------------------------------------
#
# Detect the `changelog/@unreleased/pr-<N>-*.yml` convention by counting
# recent PRs that touched such a file. If most do, the dispatched agent
# must hand-author one (or apply a `no changelog` label).
changelog_prs=$(jq '[.[] | select((.files // []) | map(.path) | any(test("^changelog/@unreleased/pr-[0-9]+-")))] | length' <<<"$prs")

if (( changelog_prs >= (sample_size + 1) / 2 )); then
  changelog_line="Manual changelog entries: required (\`changelog/@unreleased/pr-<N>-<slug>.yml\` — ${changelog_prs}/${sample_size} recent PRs touched one). Use a \`no changelog\` label only for non-user-visible changes."
elif (( changelog_prs > 0 )); then
  changelog_line="Manual changelog entries: occasional (\`changelog/@unreleased/pr-<N>-<slug>.yml\` — ${changelog_prs}/${sample_size} recent PRs touched one)."
else
  changelog_line="Manual changelog entries: not observed."
fi

# --- Merge mechanism --------------------------------------------------------
#
# Three-branch decision:
#   1. Two-signal label-triggered merge-bot heuristic (preserved verbatim
#      from the prior Phase 1.5 prose):
#        a. Workflow probe: does any workflow listen to `pull_request:
#           types: [labeled]` with a label-name guard?
#        b. PR-label cross-check: does that label appear on essentially
#           every recent merged PR?
#      If both signals agree, the project uses a label-triggered merge-bot.
#   2. Else if `autoMergeAllowed == true` (probed above): native auto-merge.
#   3. Else: immediate squash-merge — `gh pr merge --squash` (no `--auto`).
#      Selected when GitHub auto-merge is disabled at the repo level
#      (`autoMergeAllowed: false`); without this branch the orchestrator's
#      merge handoff would fail with the GraphQL error
#      `Auto merge is not allowed for this repository
#      (enablePullRequestAutoMerge)`.
if [[ "$auto_merge_allowed" == "true" ]]; then
  merge_mechanism='gh pr merge --auto --squash'
else
  merge_mechanism='gh pr merge --squash'
fi

workflows=$(gh api "repos/${repo}/contents/.github/workflows" \
  --jq '.[]?.name' 2>/dev/null || true)

candidate_label=""
project_handles_behind="no"
if [[ -n "$workflows" ]]; then
  while IFS= read -r wf; do
    [[ -z "$wf" ]] && continue
    [[ "$wf" =~ \.ya?ml$ ]] || continue
    wf_content=$(gh api "repos/${repo}/contents/.github/workflows/${wf}" \
      --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ -z "$wf_content" ]] && continue

    # Project BEHIND-handling probe: scans every workflow (independent of
    # the label-bot probe below) so a project that uses immediate-squash
    # merge but still has a separate update-branch workflow is detected.
    # Once we've found one match, skip the further-grep cost on remaining
    # workflows.
    if [[ "$project_handles_behind" == "no" ]] \
       && phase15_workflow_handles_behind "$wf_content"; then
      project_handles_behind="yes"
    fi

    phase15_workflow_listens_to_labeled "$wf_content" || continue

    label=$(phase15_extract_label_guard "$wf_content")
    if [[ -n "$label" && -z "$candidate_label" ]]; then
      candidate_label="$label"
      # Don't `break` — keep iterating so the BEHIND probe gets a chance
      # to fire on workflows we'd otherwise have skipped. The early-out
      # on `project_handles_behind` above bounds the extra cost.
    fi
  done <<<"$workflows"
fi

if [[ -n "$candidate_label" ]]; then
  # Cross-check: does the label appear on most recent merged PRs?
  label_pr_count=$(jq --arg L "$candidate_label" \
    '[.[] | select((.labels // []) | map(.name) | index($L))] | length' \
    <<<"$prs")
  if (( label_pr_count >= (sample_size + 1) / 2 )); then
    merge_mechanism="apply ${candidate_label} label (merge-bot picks it up)"
  fi
fi

# --- Emit the block ---------------------------------------------------------
#
# Format matches what the dispatch prompt embeds today: a short header line
# followed by a bulleted list, terminated by the `Merge mechanism:` line
# that sub-step 6.4 of the dispatch template parses.

prefix_display="${prefix_family:-(no consistent prefix observed)}"
[[ -n "$prefix_family" ]] && prefix_display="\`${prefix_family}:\` (or \`${prefix_family}(<scope>):\`)"

cat <<EOF
Current PR conventions (observed from the ${sample_size} most recent merged PRs on ${repo} — \`CLAUDE.md\` may not yet reflect these):
- Title prefix style: ${prefix_display}
EOF

if [[ -n "$sample_titles" ]]; then
  echo "  Recent examples:"
  printf '%s\n' "$sample_titles" | sed 's/^  /    /'
fi

cat <<EOF
- Title length limit: <=${title_max} characters.
- ${body_block_line}
- Labels seen at merge time:
${label_hist}
- ${changelog_line}
Project BEHIND handling: ${project_handles_behind}
Merge mechanism: ${merge_mechanism}
EOF
