#!/bin/bash
set -euo pipefail

MAX_PARALLEL="${MAX_PARALLEL_PER_GROUP:-2}"
MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY_BASE:-2}"
CLONE_TIMEOUT="${CLONE_TIMEOUT_MIN:-3}"

log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }

clone_repo() {
  local owner="$1"
  local repo="$2"
  local branch="${3:-master}"
  local target="${4:-}"
  local post_move="${5:-false}"
  
  local dir="${target:-$repo}"
  local url="https://github.com/${owner}/${repo}.git"
  
  log "INFO" "Cloning $owner/$repo (branch: $branch)"
  
  set +e
  timeout "${CLONE_TIMEOUT}m" git clone --depth=1 --branch "$branch" "$url" "$dir" 2>&1
  local ec=$?
  set -e
  
  if [[ $ec -eq 0 ]]; then
    log "INFO" "✅ Successfully cloned $owner/$repo"
    if [[ "$post_move" == "true" && -d "$dir" ]]; then
      log "INFO" "Moving contents of $dir to current directory"
      find "$dir" -maxdepth 1 -mindepth 1 -exec mv -n {} ./ \; 2>/dev/null || true
      rm -rf "$dir" 2>/dev/null || true
    fi
    return 0
  else
    log "ERROR" "❌ Failed to clone $owner/$repo (exit code: $ec)"
    return 1
  fi
}

main() {
  local json_file="$1"
  
  if [[ ! -f "$json_file" ]]; then
    log "ERROR" "JSON file not found: $json_file"
    exit 1
  fi
  
  log "INFO" "Reading sources from $json_file"
  
  # Parse JSON and extract critical group
  local sources=$(cat "$json_file" | jq -r '.sources[] | select(.group == "critical") | "\(.owner) \(.repo) \(.branch // "master") \(.target // "") \(.post_move // false)"')
  
  if [[ -z "$sources" ]]; then
    log "ERROR" "No critical sources found"
    exit 1
  fi
  
  log "INFO" "Starting clone for critical group"
  
  local success=0
  local failed=0
  local pids=()
  
  # Start clones in parallel (max 2 at a time)
  while IFS= read -r line; do
    # Wait if we have 2 running processes
    while [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; do
      for i in "${!pids[@]}"; do
        if ! kill -0 "${pids[$i]}" 2>/dev/null; then
          wait "${pids[$i]}" 2>/dev/null
          unset 'pids[$i]'
        fi
      done
      pids=("${pids[@]}")
      sleep 1
    done
    
    # Start new clone
    (
      clone_repo $line
    ) &
    pids+=($!)
    log "INFO" "Started PID: ${pids[-1]}"
    
  done <<< "$sources"
  
  # Wait for all remaining clones
  log "INFO" "Waiting for all clones to complete..."
  for pid in "${pids[@]}"; do
    if wait "$pid" 2>/dev/null; then
      ((success++))
    else
      ((failed++))
    fi
  done
  
  log "INFO" "Clone completed: $success successful, $failed failed"
  
  if [[ $failed -gt 0 ]]; then
    exit 1
  fi
}

# Write JSON to temp file if argument is JSON string
if [[ "$1" == *"{"* ]]; then
  echo "$1" > /tmp/sources.json
  main "/tmp/sources.json"
else
  main "$1"
fi