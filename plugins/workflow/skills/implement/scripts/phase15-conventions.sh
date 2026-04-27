#!/usr/bin/env bash

# Emit a deterministic "Current PR conventions (observed)" block for the
# workflow:implement skill's Phase 1.5. The orchestrator runs this once per
# run and embeds the stdout verbatim into every dispatched agent's prompt,
# replacing the prior practice of reading raw PR-body JSON and inferring by
# eye (which cost ~5-10K tokens and could drift between dispatches).
#
# Usage: phase15-conventions.sh <owner/repo>

set -euo pipefail

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
  cat <<EOF
Current PR conventions (observed): no merged PRs in this repo yet — fall back to project docs (\`CLAUDE.md\`, \`CONTRIBUTING.md\`) for conventions.
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
if [[ -n "$workflows" ]]; then
  while IFS= read -r wf; do
    [[ -z "$wf" ]] && continue
    [[ "$wf" =~ \.ya?ml$ ]] || continue
    wf_content=$(gh api "repos/${repo}/contents/.github/workflows/${wf}" \
      --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ -z "$wf_content" ]] && continue

    # Listens to `pull_request: types: [..., labeled, ...]`?
    if ! grep -qE '^[[:space:]]*-?[[:space:]]*labeled([[:space:]]|$|,)' \
        <<<"$wf_content"; then
      continue
    fi

    # Extract a label name from the workflow's `if:` guard. Common shapes:
    #   if: github.event.label.name == 'automerge'
    #   if: contains(github.event.pull_request.labels.*.name, 'automerge')
    label=$(grep -oE "(label\.name[[:space:]]*==[[:space:]]*'[^']+'|labels\.\\*\\.name,[[:space:]]*'[^']+')" \
      <<<"$wf_content" | grep -oE "'[^']+'" | head -1 | tr -d "'" || true)
    if [[ -n "$label" ]]; then
      candidate_label="$label"
      break
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
Merge mechanism: ${merge_mechanism}
EOF
