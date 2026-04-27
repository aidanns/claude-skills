#!/usr/bin/env bash

# Read / write the per-session orchestrator state file for /workflow:implement.
#
# State lives at $HOME/.claude/state/workflow-implement/<id>.json. Each file
# captures the orchestrator-level context that a fresh /workflow:implement
# invocation would otherwise re-derive from scratch: selector args, resolved
# issue list with terminal state per issue, dep graph, per-issue dispatch
# context (worktree path, branch, PR number), and a tail of progress digests.
#
# Subcommands:
#   init   <id> <repo> <selector-json> <issues-json> [<deps-json>]
#       Create a fresh state file. <issues-json> is an array of issue numbers;
#       each is initialised with state="scheduled" and empty dispatch context.
#       <deps-json> defaults to {} (no declared edges).
#
#   get   <id>
#       Print the state file to stdout, or exit 1 with a clear error if the
#       file is missing.
#
#   path  <id>
#       Print the absolute path to the state file (whether or not it exists).
#       Useful for the orchestrator's bail-out check on --resume.
#
#   update-issue <id> <issue#> <new-state> [<key=value> ...]
#       Update the per-issue terminal state and any dispatch-context fields
#       (branch, worktree, pr_number, pr_url, blocked_question, paused_reason,
#       errored_reason). Keys outside that allow-list are rejected so the
#       schema stays disciplined.
#
#   append-digest <id> <digest-line>
#       Append <digest-line> to the progress-digest tail. The tail is capped
#       at the most recent 50 entries to keep the file bounded.
#
#   list
#       List every state file in the directory: ID, repo, selector summary,
#       last-modified ISO-8601 timestamp, in-flight issue count.
#
#   delete <id>
#       Remove the state file. No-op if it doesn't exist (the all-terminal
#       garbage-collection path in Phase 8 calls this; idempotency keeps
#       repeated calls cheap).
#
# Exit codes:
#   0 — success (or "list" returned no files).
#   1 — missing state file on get / update-issue / append-digest.
#   2 — invalid arguments.
#
# All JSON manipulation goes through `jq`; the script does not parse JSON in
# bash. Keep that property — the moment we start string-munging JSON the
# schema discipline starts slipping.

set -euo pipefail

state_dir="${WORKFLOW_IMPLEMENT_STATE_DIR:-$HOME/.claude/state/workflow-implement}"

usage() {
  cat <<'EOF' >&2
Usage:
  session-state.sh init   <id> <repo> <selector-json> <issues-json> [<deps-json>]
  session-state.sh get    <id>
  session-state.sh path   <id>
  session-state.sh update-issue <id> <issue#> <new-state> [<key=value> ...]
  session-state.sh append-digest <id> <digest-line>
  session-state.sh list
  session-state.sh delete <id>
EOF
  exit 2
}

state_path() {
  local id="$1"
  printf '%s/%s.json\n' "$state_dir" "$id"
}

require_file() {
  local p="$1"
  if [[ ! -f "$p" ]]; then
    printf 'session-state: state file not found: %s\n' "$p" >&2
    exit 1
  fi
}

cmd_init() {
  local id="${1:?id required}" repo="${2:?repo required}"
  local selector_json="${3:?selector-json required}"
  local issues_json="${4:?issues-json required}"
  local deps_json="${5:-{\}}"

  mkdir -p "$state_dir"
  local path
  path=$(state_path "$id")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build the per-issue map from the input array.
  jq -n \
    --arg id "$id" \
    --arg repo "$repo" \
    --arg now "$now" \
    --argjson selector "$selector_json" \
    --argjson issues "$issues_json" \
    --argjson deps "$deps_json" \
    '{
       session_id: $id,
       repo: $repo,
       created_at: $now,
       updated_at: $now,
       selector: $selector,
       deps: $deps,
       issues: ($issues
                | map({
                    number: .,
                    state: "scheduled",
                    branch: null,
                    worktree: null,
                    pr_number: null,
                    pr_url: null,
                    blocked_question: null,
                    paused_reason: null,
                    errored_reason: null
                  })
                | map({(.number | tostring): .})
                | add // {}),
       digest_tail: []
     }' >"$path"

  printf '%s\n' "$path"
}

cmd_get() {
  local id="${1:?id required}"
  local path
  path=$(state_path "$id")
  require_file "$path"
  cat "$path"
}

cmd_path() {
  local id="${1:?id required}"
  state_path "$id"
}

cmd_update_issue() {
  local id="${1:?id required}" issue="${2:?issue# required}" new_state="${3:?new state required}"
  shift 3

  local path
  path=$(state_path "$id")
  require_file "$path"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build a JSON patch from the remaining key=value args. The allow-list keeps
  # the schema disciplined — adding a new dispatch-context field is a
  # deliberate two-line change here, not an accident of an arbitrary key
  # appearing in a state file.
  local patch_json='{}'
  local kv key value
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    case "$key" in
      branch|worktree|pr_number|pr_url|blocked_question|paused_reason|errored_reason) ;;
      *)
        printf 'session-state: rejected key %q (allowed: branch worktree pr_number pr_url blocked_question paused_reason errored_reason)\n' "$key" >&2
        exit 2
        ;;
    esac
    patch_json=$(jq -n \
      --argjson base "$patch_json" \
      --arg k "$key" \
      --arg v "$value" \
      '$base + {($k): $v}')
  done

  local tmp
  tmp=$(mktemp)
  jq \
    --arg issue "$issue" \
    --arg new_state "$new_state" \
    --arg now "$now" \
    --argjson patch "$patch_json" \
    '.updated_at = $now
     | .issues[$issue] = ((.issues[$issue] // {number: ($issue | tonumber)})
                           + {state: $new_state}
                           + $patch)' \
    "$path" >"$tmp"
  mv "$tmp" "$path"
}

cmd_append_digest() {
  local id="${1:?id required}" line="${2:?digest line required}"
  local path
  path=$(state_path "$id")
  require_file "$path"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local tmp
  tmp=$(mktemp)
  jq \
    --arg now "$now" \
    --arg line "$line" \
    '.updated_at = $now
     | .digest_tail = ((.digest_tail // []) + [{ts: $now, line: $line}] | .[-50:])' \
    "$path" >"$tmp"
  mv "$tmp" "$path"
}

cmd_list() {
  if [[ ! -d "$state_dir" ]]; then
    return 0
  fi
  local f mtime
  for f in "$state_dir"/*.json; do
    [[ -f "$f" ]] || continue
    mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || stat -c '%y' "$f" | cut -d. -f1)
    # Single jq invocation per file. "in-flight" = anything not
    # fully-resolved (i.e. not merged / errored).
    jq -r --arg mtime "$mtime" '
      [.session_id,
       .repo,
       $mtime,
       (.selector | to_entries | map("\(.key)=\(.value)") | join(" ")),
       "in-flight=" + (([.issues[] | select(.state != "merged" and .state != "errored")] | length) | tostring)
      ] | @tsv
    ' "$f"
  done
}

cmd_delete() {
  local id="${1:?id required}"
  local path
  path=$(state_path "$id")
  rm -f "$path"
}

main() {
  local sub="${1:-}"
  [[ -z "$sub" ]] && usage
  shift
  case "$sub" in
    init)           cmd_init "$@" ;;
    get)            cmd_get "$@" ;;
    path)           cmd_path "$@" ;;
    update-issue)   cmd_update_issue "$@" ;;
    append-digest)  cmd_append_digest "$@" ;;
    list)           cmd_list "$@" ;;
    delete)         cmd_delete "$@" ;;
    -h|--help|help) usage ;;
    *)              usage ;;
  esac
}

main "$@"
