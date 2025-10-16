#!/bin/sh
# POSIX shell harness to run a single experiment defined by experiments/N/input.json
# Usage: bash scripts/run_experiments.sh experiments/1/input.json

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/helpers.sh"

require_cmd jq
require_cmd curl

# Validate env
[ -n "${KIE_API_KEY:-}" ] || die "KIE_API_KEY is required (export before running)."
[ -n "${KIE_BASE_URL:-}" ] || die "KIE_BASE_URL is required (export before running)."

INPUT_JSON=${1:-}
[ -n "$INPUT_JSON" ] || die "Path to experiment input.json is required."
[ -f "$INPUT_JSON" ] || die "Input file not found: $INPUT_JSON"

# Read config
endpoint=$(jq -er '.endpoint' "$INPUT_JSON") || die "Missing .endpoint in input JSON"
method=$(jq -er '.method' "$INPUT_JSON") || die "Missing .method in input JSON"
statusEndpoint=$(jq -er '.statusEndpoint' "$INPUT_JSON") || die "Missing .statusEndpoint in input JSON"
taskIdPath=$(jq -er '.taskIdJsonPath' "$INPUT_JSON") || die "Missing .taskIdJsonPath in input JSON"
statusPath=$(jq -er '.statusJsonPath' "$INPUT_JSON") || die "Missing .statusJsonPath in input JSON"
successFlagPath=$(jq -er '.successFlagJsonPath' "$INPUT_JSON") || die "Missing .successFlagJsonPath in input JSON"
resultUrlsPath=$(jq -er '.resultUrlsJsonPath' "$INPUT_JSON") || die "Missing .resultUrlsJsonPath in input JSON"
pollIntervalSec=$(jq -er '.pollIntervalSec' "$INPUT_JSON") || die "Missing .pollIntervalSec in input JSON"
maxPolls=$(jq -er '.maxPolls' "$INPUT_JSON") || die "Missing .maxPolls in input JSON"

# Optional payload
payload=$(jq -c '.payload // {}' "$INPUT_JSON")

base_dir=$(dirname "$INPUT_JSON")
outputs_dir="$base_dir/outputs"
mkdir -p "$outputs_dir"
http_log="$base_dir/http.log"

full_url="${KIE_BASE_URL%/}${endpoint}"
status_url_template="${KIE_BASE_URL%/}${statusEndpoint}"

# If this is experiment 5 and payload has a placeholder taskId, try to inject from experiments/1/task_id.txt before submit
case "$base_dir" in
  */experiments/5)
    placeholder="__REPLACE_WITH_EXPERIMENT_1_TASK_ID__"
    current_task_id=$(printf '%s' "$payload" | jq -er '.taskId // empty' 2>/dev/null || true)
    if [ "$current_task_id" = "$placeholder" ] && [ -f "$(dirname "$base_dir")/1/task_id.txt" ]; then
      tid=$(cat "$(dirname "$base_dir")/1/task_id.txt" | tr -d '\n')
      if [ -n "$tid" ]; then
        payload=$(printf '%s' "$payload" | jq -c --arg t "$tid" '.taskId=$t')
        log "Injected taskId from experiments/1/task_id.txt into payload for experiment 5."
      fi
    fi
    ;;
esac

log "Submitting experiment: $INPUT_JSON"
log "Endpoint: $full_url"
if [ "${VERBOSE:-}" = "1" ]; then
  # Redact auth header in console; write detailed headers to file via helpers
  : >"$http_log" || true
  export HTTP_LOG_PATH="$http_log"
fi

case "$method" in
  POST|post)
response_json=$(http_post "$full_url" "$payload") || die "Initial request failed"
    ;;
  *)
    die "Unsupported method: $method (only POST is supported)"
    ;;
esac

# Save initial response for troubleshooting
printf '%s' "$response_json" > "$base_dir/initial_response.json"

# Extract taskId
taskId=$(printf '%s' "$response_json" | json_get "$taskIdPath") || {
  log "Task ID extraction failed using path: $taskIdPath"
  exit 2
}
log "taskId: $taskId"

# Persist taskId if under experiments/1
case "$base_dir" in
  */experiments/1)
    printf '%s' "$taskId" > "$base_dir/task_id.txt" || true
    ;;
esac

# If this is experiment 5 and payload has a placeholder taskId, try to inject from experiments/1/task_id.txt
case "$base_dir" in
  */experiments/5)
    placeholder="__REPLACE_WITH_EXPERIMENT_1_TASK_ID__"
    current_task_id=$(printf '%s' "$payload" | jq -er '.taskId // empty' 2>/dev/null || true)
    if [ "$current_task_id" = "$placeholder" ] && [ -f "$(dirname "$base_dir")/1/task_id.txt" ]; then
      tid=$(cat "$(dirname "$base_dir")/1/task_id.txt" | tr -d '\n')
      if [ -n "$tid" ]; then
        payload=$(printf '%s' "$payload" | jq -c --arg t "$tid" '.taskId=$t')
        log "Injected taskId from experiments/1/task_id.txt into payload for experiment 5."
      fi
    fi
    ;;
esac

# Polling loop
poll=0
status_json=""
while [ $poll -lt "$maxPolls" ]; do
  poll=$((poll + 1))
  # Build status URL; allow {taskId} placeholder in statusEndpoint
  status_url=$(printf '%s' "$status_url_template" | sed "s/{taskId}/$taskId/g")

  log "Polling ($poll/$maxPolls): $status_url"
  status_json=$(http_get "$status_url") || {
    log "Status request failed (attempt $poll)"
    sleep "$pollIntervalSec"
    continue
  }

  # Save rolling status
  printf '%s' "$status_json" > "$base_dir/status.json"

  status_val=$(printf '%s' "$status_json" | json_get "$statusPath" 2>/dev/null || true)
  success_flag=$(printf '%s' "$status_json" | json_get "$successFlagPath" 2>/dev/null || true)

  if [ "$success_flag" = "1" ] || [ "$success_flag" = "true" ] || [ "$status_val" = "success" ] || [ "$status_val" = "completed" ]; then
    log "Task succeeded. Downloading results."
    # Collect result URLs
    if urls=$(printf '%s' "$status_json" | jq -er "$resultUrlsPath" 2>/dev/null); then
      idx=0
      printf '%s\n' "$urls" | while IFS= read -r url; do
        dest="$outputs_dir/$idx.png"
        log "Downloading $url -> $dest"
        if download_file "$url" "$dest"; then
          :
        else
          log "Failed to download $url"
        fi
        idx=$((idx + 1))
      done
    else
      log "No result URLs found using path: $resultUrlsPath"
    fi
    log "Done. Status JSON saved to $base_dir/status.json"
    exit 0
  fi

  # Detect failure
  if [ "$status_val" = "failed" ] || [ "$status_val" = "error" ]; then
    log "Task failed per status field: $status_val"
    exit 3
  fi

  sleep "$pollIntervalSec"
done

log "Polling timed out after $maxPolls checks. Last status saved at $base_dir/status.json"
exit 4
