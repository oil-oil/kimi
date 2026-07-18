#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_kimi.sh <task> [options]
  ask_kimi.sh -t <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -t, --task <text>            Alias for positional task
  (stdin)                      Pipe task text via stdin if no arg/flag is given

Context (optional, repeatable):
  -f, --file <path>            Priority file or media path
      --add-dir <path>         Additional directory Kimi may access
      --skills-dir <path>      Replace Kimi's auto-discovered Skill directories

Multi-turn:
      --session <id>           Resume a previous Kimi session

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <alias>          Kimi model alias override
  -o, --output <path>          Markdown output path
  -h, --help                   Show this help

Output (on success):
  session_id=<id>              Use with --session for a follow-up
  output_path=<file>           Absolute path to the Markdown result
  elapsed=<seconds>s

Notes:
  Kimi prompt mode is non-interactive and may edit files or run commands.
  This wrapper has no read-only mode because `kimi -p` cannot enforce one.
USAGE
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_value() {
  local option="$1" value="${2:-}"
  [[ -n "$value" ]] || fail "Missing value for $option"
}

trim_whitespace() {
  awk 'BEGIN { RS=""; ORS="" } { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print }' <<<"$1"
}

to_absolute() {
  local base="$1" target="$2" parent
  if [[ "$target" != /* ]]; then
    target="$base/$target"
  fi
  if [[ -e "$target" ]]; then
    parent="$(cd "$(dirname "$target")" && pwd)"
    printf '%s/%s\n' "$parent" "$(basename "$target")"
  else
    printf '%s\n' "$target"
  fi
}

resolve_hint() {
  local base="$1" raw="$2" cleaned
  cleaned="$(trim_whitespace "$raw")"
  [[ -n "$cleaned" ]] || return 0
  if [[ "$cleaned" =~ ^(.+)#L[0-9]+$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" =~ ^(.+):[0-9]+(-[0-9]+)?$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  to_absolute "$base" "$cleaned"
}

append_file_hints() {
  local raw="$1" item trimmed
  IFS=',' read -r -a split_hints <<<"$raw"
  for item in "${split_hints[@]}"; do
    trimmed="$(trim_whitespace "$item")"
    [[ -n "$trimmed" ]] && file_hints+=("$trimmed")
  done
}

redact_stderr() {
  sed -E \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=:-]+/\1[REDACTED]/g' \
    -e 's/(sk-[A-Za-z0-9_-]{6})[A-Za-z0-9_-]+/\1...[REDACTED]/g' \
    -e 's/((api_key|api-key|access_token|refresh_token|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g'
}

content_text_filter='def content_text:
  if (.content | type) == "string" then .content
  elif (.content | type) == "array" then
    [.content[] |
      if type == "string" then .
      elif type == "object" and .type == "text" then (.text // "")
      else empty end
    ] | join("")
  else "" end;'

print_progress() {
  local line="$1" tool_names preview
  tool_names="$(printf '%s' "$line" | jq -r '
    select(.role == "assistant")
    | .tool_calls[]?
    | (.function.name // .name // "tool")
  ' 2>/dev/null || true)"
  if [[ -n "$tool_names" ]]; then
    while IFS= read -r tool_name; do
      [[ -n "$tool_name" ]] && echo "[kimi] tool: $tool_name" >&2
    done <<<"$tool_names"
    return
  fi

  preview="$(printf '%s' "$line" | jq -r "$content_text_filter
    select(.role == \"assistant\") | content_text
  " 2>/dev/null | awk 'NF { print; exit }' | cut -c1-140 || true)"
  [[ -n "$preview" ]] && echo "[kimi] $preview" >&2
}

workspace="$PWD"
task_text=""
model=""
session_id=""
output_path=""
file_hints=()
add_dirs=()
skills_dirs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      require_value "$1" "${2:-}"; workspace="$2"; shift 2 ;;
    -t|--task)
      require_value "$1" "${2:-}"; task_text="$2"; shift 2 ;;
    -f|--file|--focus)
      require_value "$1" "${2:-}"; append_file_hints "$2"; shift 2 ;;
    --add-dir)
      require_value "$1" "${2:-}"; add_dirs+=("$2"); shift 2 ;;
    --skills-dir)
      require_value "$1" "${2:-}"; skills_dirs+=("$2"); shift 2 ;;
    --model)
      require_value "$1" "${2:-}"; model="$2"; shift 2 ;;
    --session)
      require_value "$1" "${2:-}"; session_id="$2"; shift 2 ;;
    -o|--output)
      require_value "$1" "${2:-}"; output_path="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -z "$task_text" ]]; then
        task_text="$1"; shift
      else
        echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1
      fi ;;
  esac
done

require_cmd kimi
require_cmd jq

[[ -d "$workspace" ]] || fail "Workspace does not exist: $workspace"
workspace="$(cd "$workspace" && pwd)"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi
task_text="$(trim_whitespace "$task_text")"
[[ -n "$task_text" ]] || fail "Request text is empty. Pass a positional task, --task, or stdin."

resolved_add_dirs=()
if (( ${#add_dirs[@]} > 0 )); then
  for raw_dir in "${add_dirs[@]}"; do
    resolved_dir="$(to_absolute "$workspace" "$raw_dir")"
    [[ -d "$resolved_dir" ]] || fail "Additional directory does not exist: $resolved_dir"
    resolved_add_dirs+=("$resolved_dir")
  done
fi

resolved_skills_dirs=()
if (( ${#skills_dirs[@]} > 0 )); then
  for raw_dir in "${skills_dirs[@]}"; do
    resolved_dir="$(to_absolute "$workspace" "$raw_dir")"
    [[ -d "$resolved_dir" ]] || fail "Skills directory does not exist: $resolved_dir"
    resolved_skills_dirs+=("$resolved_dir")
  done
fi

file_block=""
if (( ${#file_hints[@]} > 0 )); then
  file_block=$'\nPriority files or media (inspect these first):'
  for hint in "${file_hints[@]}"; do
    resolved_hint="$(resolve_hint "$workspace" "$hint")"
    [[ -n "$resolved_hint" ]] || continue
    existence="missing"
    [[ -e "$resolved_hint" ]] && existence="exists"
    file_block+=$'\n- '"$resolved_hint ($existence)"
  done
fi

prompt="$task_text$file_block"

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  output_path="$skill_dir/.runtime/${timestamp}-$$.md"
elif [[ "$output_path" != /* ]]; then
  output_path="$workspace/$output_path"
fi
mkdir -p "$(dirname "$output_path")"
output_parent="$(cd "$(dirname "$output_path")" && pwd)"
output_path="$output_parent/$(basename "$output_path")"

cmd=(kimi)
[[ -n "$session_id" ]] && cmd+=(-S "$session_id")
[[ -n "$model" ]] && cmd+=(-m "$model")
if (( ${#resolved_skills_dirs[@]} > 0 )); then
  for resolved_dir in "${resolved_skills_dirs[@]}"; do
    cmd+=(--skills-dir "$resolved_dir")
  done
fi
if (( ${#resolved_add_dirs[@]} > 0 )); then
  for resolved_dir in "${resolved_add_dirs[@]}"; do
    cmd+=(--add-dir "$resolved_dir")
  done
fi
cmd+=(-p "$prompt" --output-format stream-json)

json_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$json_file" "$stderr_file"' EXIT

run_kimi() {
  (cd "$workspace" && "${cmd[@]}")
}

start_seconds=$SECONDS
kimi_status=0
set +e
run_kimi 2>"$stderr_file" | while IFS= read -r line; do
  line="${line//$'\r'/}"
  [[ -n "$line" ]] || continue
  if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$line" >>"$json_file"
    print_progress "$line"
  else
    echo "[kimi] Ignored non-JSON output from stream-json mode" >&2
  fi
done
kimi_status=${PIPESTATUS[0]}
set -e
elapsed=$((SECONDS - start_seconds))

if (( kimi_status != 0 )); then
  case "$kimi_status" in
    3) failure_reason="Kimi goal blocked" ;;
    6) failure_reason="Kimi goal paused" ;;
    *) failure_reason="Kimi command failed" ;;
  esac
  echo "[ERROR] $failure_reason (exit $kimi_status)" >&2
  if [[ -s "$stderr_file" ]]; then
    tail -n 40 "$stderr_file" | redact_stderr >&2
  fi
  exit "$kimi_status"
fi

[[ -s "$json_file" ]] || fail "Kimi returned no JSONL messages. Check kimi doctor and local configuration."

captured_session_id="$(jq -rs '
  [.[] | select(.role == "meta" and .type == "session.resume_hint") | .session_id // empty]
  | last // ""
' <"$json_file" 2>/dev/null)"
[[ -n "$captured_session_id" ]] || captured_session_id="$session_id"

summary_text="$(jq -rs "$content_text_filter
  [.[] | select(.role == \"assistant\") | content_text | select(length > 0)]
  | last // \"\"
" <"$json_file" 2>/dev/null)"
[[ -n "$summary_text" ]] || summary_text="(Kimi completed without a final assistant message.)"

tool_summary="$(jq -rs '
  [.[] | select(.role == "assistant") | .tool_calls[]? | (.function.name // .name // "tool")]
  | group_by(.)
  | map("- `" + .[0] + "` ×" + (length | tostring))
  | .[]
' <"$json_file" 2>/dev/null)"
tool_count="$(jq -rs '[.[] | select(.role == "assistant") | .tool_calls[]?] | length' <"$json_file" 2>/dev/null)"

{
  printf '## Summary\n\n%s\n\n' "$summary_text"
  [[ -n "$tool_summary" ]] && printf '## Tools used\n\n%s\n\n' "$tool_summary"
  printf -- '---\nelapsed %ss · %s tools\n' "$elapsed" "${tool_count:-0}"
} >"$output_path"

[[ -n "$captured_session_id" ]] && echo "session_id=$captured_session_id"
echo "output_path=$output_path"
echo "elapsed=${elapsed}s"
