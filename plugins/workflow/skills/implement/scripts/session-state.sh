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
#       (branch, worktree, pr_number, pr_url, agent_id, blocked_question,
#       paused_reason, errored_reason, body_snapshot, labels_snapshot). Keys
#       outside that allow-list are rejected so the schema stays disciplined.
#       <new-state> must be one of: scheduled, in-progress, automerge_set,
#       merged, blocked, paused, errored, externally_closed. (externally_closed
#       is the terminal outcome the parked-issue poll uses when an issue is
#       closed externally while in `blocked` — it qualifies for Phase 8
#       garbage collection alongside merged/errored.)
#
#   add-worktree <id> <issue#> <path>
#       Append <path> to issues[<issue#>].worktrees if not already present.
#       Idempotent — re-adding a path the array already contains is a no-op.
#       The orchestrator calls this immediately after parsing each
#       isolation:worktree-dispatched agent's terminal notification, so Phase 6
#       housekeeping can iterate every worktree spawned during the PR's
#       lifecycle (implementing agent + any conflict-resolution / CI-failure
#       /review-comment / address-review mini-agents) without leaking them.
#       The singular `worktree` field set via `update-issue` is retained for
#       diagnostic value (it identifies which path was the implementing
#       agent's); cleanup reads the plural `worktrees` array.
#
#   append-digest <id> <digest-line>
#       Append <digest-line> to the progress-digest tail. The tail is capped
#       at the most recent 50 entries to keep the file bounded.
#
#   list
#       List every state file in the directory: ID, repo, selector summary,
#       last-modified ISO-8601 timestamp, in-flight issue count. Files that
#       fail to parse as JSON are surfaced with a `(corrupted — see § Session
#       state recovery)` annotation instead of being silently skipped, so the
#       user sees there is a problem and can follow the manual recovery
#       sequence in SKILL.md.
#
#   find-overlap <repo> <issues-json> [--except <session-id>]...
#       Scan every state file under the state directory, filter to sessions
#       whose `repo` field matches <repo>, and intersect each session's
#       active issue numbers (state ∈ scheduled | in-progress |
#       automerge_set) against the input <issues-json> array. Emit a JSON
#       array of overlapping tuples on stdout — one element per session
#       with overlap, of shape `{session_id, repo, updated_at,
#       overlapping_issues:[<n>...]}`. Sessions with no overlap are omitted.
#       `--except <session-id>` (repeatable) skips named sessions; the
#       orchestrator passes its own session ID and every session ID
#       returned by `find-stale` so dead sessions don't surface as
#       concurrency conflicts (AC #4 of #104). Exits 0 with `[]` when no
#       overlap is found — the orchestrator distinguishes "scan ran
#       cleanly, no overlap" from "scan failed" by parsing the JSON, not
#       by exit code.
#
#       The active-state set deliberately excludes `merged`, `blocked`,
#       `paused`, `errored`, and `externally_closed`: a session that is
#       parked on a clarification (`blocked`) or paused on a usage cap
#       (`paused`) is still alive in the user's mental model, but neither
#       holds an *active dispatch* on the issue — a fresh run claiming the
#       same issue can pick it up safely (the resumed session would notice
#       on its next loop tick that the label changed). Concretely: the
#       overlap that matters is "two implementing agents racing the same
#       PR", not "the same issue lives in two state files."
#
#   find-stale [<repo>] <gh-state-json>
#       Determine which sessions are stale — every active issue (state ∈
#       scheduled | in-progress | automerge_set) has GitHub-state CLOSED
#       per the supplied <gh-state-json> mapping (`{"<issue#>": "OPEN" |
#       "CLOSED"}`). The mapping is read from a path argument or `-` for
#       stdin; the orchestrator owns the `gh issue view` calls that
#       populate it (this script stays offline-by-default — no network).
#       Optional <repo> filters the scan to that `<owner>/<repo>` only.
#       Emits a JSON array of `{session_id, repo, updated_at,
#       active_issues:[<n>...]}` tuples on stdout — one element per stale
#       session. Sessions with at least one OPEN active issue, or with no
#       active issues at all (every issue terminal — Phase 8 GC will
#       handle them), are omitted. Exits 0 with `[]` when no stale
#       sessions are found.
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
  session-state.sh add-worktree <id> <issue#> <path>
  session-state.sh append-digest <id> <digest-line>
  session-state.sh list
  session-state.sh find-overlap <repo> <issues-json> [--except <session-id>]...
  session-state.sh find-stale [<repo>] <gh-state-json-path-or-->
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
                    worktrees: [],
                    pr_number: null,
                    pr_url: null,
                    agent_id: null,
                    blocked_question: null,
                    paused_reason: null,
                    errored_reason: null,
                    body_snapshot: null,
                    labels_snapshot: null
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

  case "$new_state" in
    scheduled|in-progress|automerge_set|merged|blocked|paused|errored|externally_closed) ;;
    *)
      printf 'session-state: rejected state %q (allowed: scheduled in-progress automerge_set merged blocked paused errored externally_closed)\n' "$new_state" >&2
      exit 2
      ;;
  esac

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
      branch|worktree|pr_number|pr_url|agent_id|blocked_question|paused_reason|errored_reason|body_snapshot|labels_snapshot) ;;
      *)
        printf 'session-state: rejected key %q (allowed: branch worktree pr_number pr_url agent_id blocked_question paused_reason errored_reason body_snapshot labels_snapshot)\n' "$key" >&2
        exit 2
        ;;
    esac
    # Empty value clears the field to JSON `null` (preserving the schema
    # invariant established by `init` defaults: a "cleared" field is `null`,
    # not the empty string). Non-empty values are written as JSON strings.
    if [[ -z "$value" ]]; then
      patch_json=$(jq -n \
        --argjson base "$patch_json" \
        --arg k "$key" \
        '$base + {($k): null}')
    else
      patch_json=$(jq -n \
        --argjson base "$patch_json" \
        --arg k "$key" \
        --arg v "$value" \
        '$base + {($k): $v}')
    fi
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

cmd_add_worktree() {
  local id="${1:?id required}" issue="${2:?issue# required}"
  # Use a default so an unset $3 (no positional) and an explicitly-empty
  # $3 take separate branches: missing-args mirrors the `${var:?}` exit-1
  # convention used elsewhere in this script, while an empty string is a
  # contract violation worth its own exit-2 ("you passed something
  # nonsensical, here's why") so the caller can distinguish.
  if (( $# < 3 )); then
    printf 'session-state: add-worktree path required\n' >&2
    exit 1
  fi
  local path="$3"
  if [[ -z "$path" ]]; then
    printf 'session-state: add-worktree path must be non-empty\n' >&2
    exit 2
  fi

  local file
  file=$(state_path "$id")
  require_file "$file"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Append idempotently. If the issue record is missing, materialise a
  # minimal one (same convention as update-issue's `// {number: ...}`
  # fallback) so a misordered call doesn't silently drop the path. If the
  # `worktrees` field is missing (state file written before this field was
  # added to `init`), initialise it as `[]` first.
  local tmp
  tmp=$(mktemp)
  jq \
    --arg issue "$issue" \
    --arg path "$path" \
    --arg now "$now" \
    '.updated_at = $now
     | .issues[$issue] = ((.issues[$issue] // {number: ($issue | tonumber)})
                           | .worktrees = ((.worktrees // []) as $wt
                                           | if ($wt | index($path)) then $wt
                                             else $wt + [$path] end))' \
    "$file" >"$tmp"
  mv "$tmp" "$file"
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
  local f mtime id
  for f in "$state_dir"/*.json; do
    [[ -f "$f" ]] || continue
    mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || stat -c '%y' "$f" | cut -d. -f1)
    # Surface unparseable state files instead of silently skipping. Without
    # this, a corruption (truncated mid-write, partial schema after a crash,
    # bad UTF-8) would simply not appear in `--session list` and the user
    # would have no signal that anything is wrong — they'd just see their
    # session go missing. Print a flagged row pointing at the recovery prose
    # in SKILL.md § Session state § Recovering a corrupted state file.
    if ! jq -e . "$f" >/dev/null 2>&1; then
      id=$(basename "$f" .json)
      printf '%s\t(corrupted — see § Session state recovery)\t%s\t\t\n' "$id" "$mtime"
      continue
    fi
    # Single jq invocation per file. "in-flight" = anything not
    # fully-resolved (i.e. not merged / errored / externally_closed).
    jq -r --arg mtime "$mtime" '
      [.session_id,
       .repo,
       $mtime,
       (.selector | to_entries | map("\(.key)=\(.value)") | join(" ")),
       "in-flight=" + (([.issues[] | select(.state != "merged" and .state != "errored" and .state != "externally_closed")] | length) | tostring)
      ] | @tsv
    ' "$f"
  done
}

# Read every parseable state file into a single JSON array on stdout.
# Unparseable files are silently skipped: `cmd_list` is the surface that
# flags corruption to the user, and we do not want a corrupted neighbour
# session to block a fresh intake's overlap or stale scan. Returns `[]`
# when the state directory does not exist.
read_all_sessions() {
  if [[ ! -d "$state_dir" ]]; then
    printf '[]\n'
    return 0
  fi
  local f parseable=()
  for f in "$state_dir"/*.json; do
    [[ -f "$f" ]] || continue
    if jq -e . "$f" >/dev/null 2>&1; then
      parseable+=("$f")
    fi
  done
  if (( ${#parseable[@]} == 0 )); then
    printf '[]\n'
    return 0
  fi
  jq -s -c . "${parseable[@]}"
}

cmd_find_overlap() {
  local repo="${1:?repo required}"
  local issues_json="${2:?issues-json required}"
  shift 2

  # Optional `--except <session-id>` (repeatable) lets the caller skip
  # specific peer sessions from the overlap result. Two distinct callers:
  #
  #   1. The caller's own state file. The orchestrator scanning after
  #      Phase 3 has written the new session's state would otherwise see
  #      itself in the output.
  #
  #   2. Stale sessions identified by `find-stale`. AC #4 of #104 is
  #      explicit that stale sessions are NOT counted as active overlap
  #      — they are surfaced separately and offered for cleanup. The
  #      orchestrator runs `find-stale` first, then passes each stale
  #      session ID as `--except <id>` so a dead state file does not
  #      generate a false-positive concurrency-conflict prompt.
  local except_json='[]'
  while (( $# > 0 )); do
    case "$1" in
      --except)
        local v="${2:?--except requires a session-id}"
        except_json=$(jq -nc \
          --argjson acc "$except_json" \
          --arg id "$v" \
          '$acc + [$id]')
        shift 2
        ;;
      *)
        printf 'session-state: find-overlap: unexpected argument %q\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  # Validate the issues-json input — bail with exit 2 on malformed input
  # rather than silently treating bad input as "no overlap" (which would
  # bypass the guard at intake exactly when it matters most).
  if ! jq -e 'type == "array" and all(.[]; type == "number")' >/dev/null 2>&1 <<<"$issues_json"; then
    printf 'session-state: find-overlap: <issues-json> must be a JSON array of numbers\n' >&2
    exit 2
  fi

  read_all_sessions | jq -c \
    --arg repo "$repo" \
    --argjson input "$issues_json" \
    --argjson except "$except_json" \
    '
    map(select(.repo == $repo and (.session_id | IN($except[]) | not)))
    | map(
        . as $sess
        | ($input
           | map(tostring)
           | map(select(
               ($sess.issues[.] // {}) as $rec
               | ($rec.state // "") | IN("scheduled", "in-progress", "automerge_set")
             ))
           | map(tonumber)
          ) as $overlap
        | select($overlap | length > 0)
        | {
            session_id: $sess.session_id,
            repo: $sess.repo,
            updated_at: $sess.updated_at,
            overlapping_issues: $overlap
          }
      )
    '
}

cmd_find_stale() {
  # Either `find-stale <repo> <gh-state-json>` or `find-stale <gh-state-json>`.
  # The repo argument is optional and acts as a filter; absent, every
  # session is considered. The gh-state-json argument is required — pass
  # `-` to read from stdin or a path to read from disk.
  if (( $# < 1 )); then
    printf 'session-state: find-stale: <gh-state-json> required\n' >&2
    exit 2
  fi

  local repo="" gh_state_src
  if (( $# == 1 )); then
    gh_state_src="$1"
  else
    repo="$1"
    gh_state_src="$2"
  fi

  local gh_state_json
  if [[ "$gh_state_src" == "-" ]]; then
    gh_state_json=$(cat)
  else
    if [[ ! -f "$gh_state_src" ]]; then
      printf 'session-state: find-stale: gh-state file not found: %s\n' "$gh_state_src" >&2
      exit 2
    fi
    gh_state_json=$(cat "$gh_state_src")
  fi

  if ! jq -e 'type == "object" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$gh_state_json"; then
    printf 'session-state: find-stale: <gh-state-json> must be a JSON object {"<n>": "OPEN"|"CLOSED"}\n' >&2
    exit 2
  fi

  read_all_sessions | jq -c \
    --arg repo "$repo" \
    --argjson gh "$gh_state_json" \
    '
    map(select($repo == "" or .repo == $repo))
    | map(
        . as $sess
        | ([$sess.issues[]
            | select(.state | IN("scheduled", "in-progress", "automerge_set"))
            | .number]
          ) as $active
        | select(($active | length) > 0)
        | select($active
                 | all(. as $n
                       | ($gh[$n | tostring] // "OPEN") == "CLOSED"))
        | {
            session_id: $sess.session_id,
            repo: $sess.repo,
            updated_at: $sess.updated_at,
            active_issues: $active
          }
      )
    '
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
    add-worktree)   cmd_add_worktree "$@" ;;
    append-digest)  cmd_append_digest "$@" ;;
    list)           cmd_list "$@" ;;
    find-overlap)   cmd_find_overlap "$@" ;;
    find-stale)     cmd_find_stale "$@" ;;
    delete)         cmd_delete "$@" ;;
    -h|--help|help) usage ;;
    *)              usage ;;
  esac
}

main "$@"
