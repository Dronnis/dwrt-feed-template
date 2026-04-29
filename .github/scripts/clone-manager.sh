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
  local branch="${3:-main}"
  local target="${4:-}"
  local post_move="${5:-false}"
  
  # Use repo name as directory if target is empty or "null"
  local dir="$repo"
  if [[ -n "$target" && "$target" != "null" ]]; then
    dir="$target"
  fi
  
  local url="https://github.com/${owner}/${repo}.git"
  
  # Check if directory already exists and not empty
  if [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    log "WARN" "Directory $dir already exists, skipping $owner/$repo"
    return 0
  fi
  
  log "INFO" "Cloning $owner/$repo to $dir (branch: $branch)"
  
  set +e
  timeout "${CLONE_TIMEOUT}m" git clone --depth=1 --branch "$branch" "$url" "$dir" 2>&1
  local ec=$?
  set -e
  
  if [[ $ec -eq 0 ]]; then
    log "INFO" "✅ Successfully cloned $owner/$repo"
    if [[ "$post_move" == "true" && -d "$dir" ]]; then
      log "INFO" "Moving contents of $dir to current directory"
      # Move all contents including hidden files
      shopt -s dotglob
      for item in "$dir"/*; do
        if [[ -e "$item" ]]; then
          mv -n "$item" ./ 2>/dev/null || true
        fi
      done
      shopt -u dotglob
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
  
  # Get unique sources, handle empty/null values properly
  local sources=$(cat "$json_file" | jq -r '.sources[] | 
    {
      owner: .owner, 
      repo: .repo, 
      branch: (.branch // "main"), 
      target: (.target // ""), 
      post_move: (.post_move // false)
    } | "\(.owner) \(.repo) \(.branch) \(.target) \(.post_move)"')
  
  if [[ -z "$sources" ]]; then
    log "ERROR" "No sources found"
    exit 1
  fi
  
  local total=$(echo "$sources" | wc -l)
  log "INFO" "Starting clone for $total unique repositories"
  
  local success=0
  local failed=0
  
  while IFS= read -r line; do
    # Skip empty lines
    [[ -z "$line" ]] && continue
    
    if clone_repo $line; then
      ((success++))
    else
      ((failed++))
      log "WARN" "Failed, continuing with next repository..."
    fi
  done <<< "$sources"
  
  log "INFO" "Clone completed: $success successful, $failed failed"
  
  if [[ $failed -gt 0 ]]; then
    exit 1
  fi
}

# Handle JSON string as argument
if [[ "$1" == *"{"* ]]; then
  echo "$1" > /tmp/sources.json
  main "/tmp/sources.json"
else
  main "$1"
fi