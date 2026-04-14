#!/bin/bash
set -euo pipefail

MAX_PARALLEL="${MAX_PARALLEL_PER_GROUP:-5}"
MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY_BASE:-2}"
CLONE_TIMEOUT="${CLONE_TIMEOUT_MIN:-5}"

> /tmp/clone_progress.log
declare -A grp_pids grp_count
declare -a grp_order

log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }

wait_for_slot() {
  local g="$1"
  while [[ ${grp_count[$g]:-0} -ge $MAX_PARALLEL ]]; do
    for pid in ${grp_pids[$g]:-}; do kill -0 "$pid" 2>/dev/null || continue; done 2>/dev/null
    sleep 1
  done
}

cleanup_group() {
  local g="$1" new_pids="" active=0
  for pid in ${grp_pids[$g]:-}; do
    if kill -0 "$pid" 2>/dev/null; then new_pids+=" $pid"; ((active++)); fi
  done
  grp_pids[$g]="${new_pids# }"; grp_count[$g]=$active
}

wait_for_group() {
  local g="$1"
  for pid in ${grp_pids[$g]:-}; do wait "$pid" 2>/dev/null || true; done
  grp_pids[$g]=""; grp_count[$g]=0
}

clone_with_retry() {
  local g="$1" p="$2" o="$3" r="$4" b="${5:-master}" t="${6:-}" sp="$7" pa="$8" pm="$9" ex="${10}" mr="${11:-$MAX_RETRIES}"
  local url="https://github.com/${o}/${r}.git" dir="${t:-${r}}" att=0 err=""
  
  while [[ $att -lt $mr ]]; do
    ((att++))
    local t0=$(date +%s) ec=0
    log "INFO" "[${att}/${mr}] ${o}/${r}"
    
    if [[ "$sp" == "true" ]]; then
      local td=$(mktemp -d)
      trap "rm -rf '$td'" RETURN
      timeout "${CLONE_TIMEOUT}m" git clone -b "$b" --depth=1 --filter=blob:none --sparse "$url" "$td" 2>/dev/null || ec=$?
      if [[ $ec -eq 0 ]]; then
        (cd "$td" && git sparse-checkout init --cone && git sparse-checkout set $pa) || ec=$?
      fi
      for pth in $pa; do 
        [[ -d "$td/$pth" ]] && mv -n "$td/$pth" ./ 2>/dev/null || true
      done
    else
      timeout "${CLONE_TIMEOUT}m" git clone --depth=1 --quiet "$url" "$dir" 2>/dev/null || ec=$?
      if [[ $ec -eq 0 ]]; then
        if [[ "$pm" == "true" && -d "$dir" ]]; then 
          find "$dir" -maxdepth 1 -mindepth 1 -type d -exec mv -n {} ./ \; 2>/dev/null
          rm -rf "$dir"
        elif [[ -n "$ex" && -d "$dir" ]]; then 
          for item in $ex; do 
            [[ -e "$dir/$item" ]] && mv -n "$dir/$item" ./ 2>/dev/null || true
          done
          rm -rf "$dir"
        fi
      fi
    fi
    
    local el=$(( $(date +%s) - t0 ))
    if [[ $ec -eq 0 ]]; then
      log "INFO" "✅ Done in ${el}s"
      echo "${g}|${p}|${o}/${r}|ok|${el}|" >> /tmp/clone_progress.log
      return 0
    fi
    err="Exit: $ec"
    log "WARN" "❌ $err"
    [[ $att -lt $mr ]] && sleep $((RETRY_DELAY * att))
  done
  
  log "ERROR" "💥 Failed after $mr attempts"
  echo "${g}|${p}|${o}/${r}|fail|${el}|${err}" >> /tmp/clone_progress.log
  return 1
}

enqueue() {
  local g="$1" src="$2"
  wait_for_slot "$g"
  (
    local priority=$(echo "$src" | jq -r '.priority // 99')
    local owner=$(echo "$src" | jq -r '.owner')
    local repo=$(echo "$src" | jq -r '.repo')
    local branch=$(echo "$src" | jq -r '.branch // "master"')
    local target=$(echo "$src" | jq -r '.target // empty')
    local sparse=$(echo "$src" | jq -r '.sparse // false')
    local paths=$(echo "$src" | jq -r '.paths // [] | join(" ")')
    local post_move=$(echo "$src" | jq -r '.post_move // false')
    local extract=$(echo "$src" | jq -r '.extract // [] | join(" ")')
    local max_retries=$(echo "$src" | jq -r ".max_retries // env.MAX_RETRIES // 2")
    
    clone_with_retry "$g" "$priority" "$owner" "$repo" "$branch" "$target" "$sparse" "$paths" "$post_move" "$extract" "$max_retries"
    exit $?
  ) &
  local pid=$!
  grp_count[$g]=$((${grp_count[$g]:-0} + 1))
  grp_pids[$g]="${grp_pids[$g]:-} $pid"
  log "INFO" "📋 $g: #${grp_count[$g]} (PID: $pid)"
}

main() {
  local json="$1"
  declare -A gmap
  declare -a glist
  declare -A gprio
  
  while IFS= read -r src; do
    local g=$(echo "$src" | jq -r '.group // "default"')
    gprio[$g]=$(echo "$src" | jq -r '.priority // 99')
    gmap[$g]+="$src"$'\n'
    if [[ -z "${glist[*]}" || ! " ${glist[*]} " =~ " $g " ]]; then
      glist+=("$g")
    fi
  done < <(echo "$json" | jq -c '.sources[]')
  
  # Sort groups by priority
  local sorted_groups=()
  IFS=$'\n' read -d '' -r -a sorted_groups < <(for g in "${glist[@]}"; do echo "${gprio[$g]} $g"; done | sort -n | awk '{print $2}' && printf '\0')
  glist=("${sorted_groups[@]}")
  
  log "INFO" "📦 Processing ${#glist[@]} groups"
  local total_ok=0 total_fail=0
  
  for g in "${glist[@]}"; do
    log "INFO" "🚀 Group: $g"
    while IFS= read -r src; do
      [[ -n "$src" ]] && enqueue "$g" "$src"
    done <<< "${gmap[$g]}"
    
    wait_for_group "$g"
    
    # Count results
    local group_ok=0 group_fail=0
    for f in /tmp/clone_result_*.tmp 2>/dev/null; do
      [[ -f "$f" ]] || continue
      if [[ "$(cat "$f")" == "0" ]]; then
        ((group_ok++))
      else
        ((group_fail++))
      fi
      rm -f "$f"
    done
    total_ok=$((total_ok + group_ok))
    total_fail=$((total_fail + group_fail))
    log "INFO" "✅ Group '$g' done: $group_ok ok, $group_fail fail"
  done
  
  echo "total_ok=$total_ok total_fail=$total_fail"
}

main "${1:-}"