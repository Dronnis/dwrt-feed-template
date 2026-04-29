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
  local branch="${3:-main}"  # Changed from master to main
  local target="${4:-}"
  local post_move="${5:-false}"
  
  local dir="${target:-$repo}"
  local url="https://github.com/${owner}/${repo}.git"
  
  # Check if directory already exists
  if [[ -d "$dir" ]] && [[ "$(ls -A "$dir" 2>/dev/null)" ]]; then
    log "WARN" "Directory $dir already exists, skipping $owner/$repo"
    return 0
  fi
  
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
      rmdir "$dir" 2>/dev/null || true
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
  
  # Get unique sources by owner/repo
  local sources=$(cat "$json_file" | jq -r '.sources[] | "\(.owner) \(.repo) \(.branch // "main") \(.target // "") \(.post_move // false)"' | sort -u)
  
  if [[ -z "$sources" ]]; then
    log "ERROR" "No sources found"
    exit 1
  fi
  
  # Count unique sources
  local total=$(echo "$sources" | wc -l)
  log "INFO" "Starting clone for $total unique repositories"
  
  local success=0
  local failed=0
  
  # Clone sequentially to avoid issues
  while IFS= read -r line; do
    if clone_repo $line; then
      ((success++))
    else
      ((failed++))
      if [[ $failed -gt 0 ]] && [[ $((success + failed)) -lt $total ]]; then
        log "WARN" "Continuing with next repository..."
      fi
    fi
  done <<< "$sources"
  
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