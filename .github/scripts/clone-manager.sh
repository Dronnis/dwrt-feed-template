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
    # Очищаем мертвые процессы перед проверкой
    cleanup_group "$g"
    sleep 1
  done
}

cleanup_group() {
  local g="$1" new_pids="" active=0
  for pid in ${grp_pids[$g]:-}; do
    if kill -0 "$pid" 2>/dev/null; then 
      new_pids+=" $pid"
      ((active++))
    fi
  done
  grp_pids[$g]="${new_pids# }"
  grp_count[$g]=$active
}

wait_for_group() {
  local g="$1"
  local result_file="/tmp/clone_result_$$.tmp"
  
  for pid in ${grp_pids[$g]:-}; do 
    # Ждем конкретный процесс и сохраняем его exit code
    wait "$pid" 2>/dev/null
    local exit_code=$?
    echo "$exit_code" >> "$result_file"
  done
  
  grp_pids[$g]=""
  grp_count[$g]=0
  
  # Возвращаем файл с результатами для обработки
  echo "$result_file"
}

clone_with_retry() {
  local g="$1" p="$2" o="$3" r="$4" b="${5:-master}" t="${6:-}" sp="$7" pa="$8" pm="$9" ex="${10}" mr="${11:-$MAX_RETRIES}"
  local url="https://github.com/${o}/${r}.git"
  local dir="${t:-${r}}"
  local att=0 err=""
  
  while [[ $att -lt $mr ]]; do
    ((att++))
    local t0=$(date +%s) ec=0
    log "INFO" "[${att}/${mr}] ${o}/${r}"
    
    if [[ "$sp" == "true" ]]; then
      local td=$(mktemp -d)
      # Используем trap для очистки
      ( 
        trap "rm -rf '$td'" EXIT
        timeout "${CLONE_TIMEOUT}m" git clone -b "$b" --depth=1 --filter=blob:none --sparse "$url" "$td" 2>/dev/null || exit $?
        cd "$td" || exit 1
        git sparse-checkout init --cone || exit 1
        git sparse-checkout set $pa || exit 1
        for pth in $pa; do 
          if [[ -d "$pth" ]]; then
            mv -n "$pth" "$OLDPWD/" 2>/dev/null || true
          fi
        done
      )
      ec=$?
    else
      timeout "${CLONE_TIMEOUT}m" git clone --depth=1 --quiet "$url" "$dir" 2>/dev/null
      ec=$?
      if [[ $ec -eq 0 ]]; then
        if [[ "$pm" == "true" && -d "$dir" ]]; then 
          find "$dir" -maxdepth 1 -mindepth 1 -type d -exec mv -n {} ./ \; 2>/dev/null
          rm -rf "$dir"
        elif [[ -n "$ex" && -d "$dir" ]]; then 
          for item in $ex; do 
            if [[ -e "$dir/$item" ]]; then
              mv -n "$dir/$item" ./ 2>/dev/null || true
            fi
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
    log "WARN" "❌ $err (${el}s)"
    if [[ $att -lt $mr ]]; then
      sleep $((RETRY_DELAY * att))
    fi
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
    local found=0
    for existing in "${glist[@]}"; do
      if [[ "$existing" == "$g" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      glist+=("$g")
    fi
  done < <(echo "$json" | jq -c '.sources[]')
  
  # Sort groups by priority
  local temp_file=$(mktemp)
  for g in "${glist[@]}"; do
    echo "${gprio[$g]} $g" >> "$temp_file"
  done
  
  local sorted_groups=()
  while IFS= read -r line; do
    sorted_groups+=("${line#* }")
  done < <(sort -n "$temp_file")
  rm -f "$temp_file"
  
  if [[ ${#sorted_groups[@]} -gt 0 ]]; then
    glist=("${sorted_groups[@]}")
  fi
  
  log "INFO" "📦 Processing ${#glist[@]} groups"
  local total_ok=0 total_fail=0
  
  for g in "${glist[@]}"; do
    log "INFO" "🚀 Group: $g"
    
    # Запускаем все задачи группы
    while IFS= read -r src; do
      if [[ -n "$src" ]]; then
        enqueue "$g" "$src"
      fi
    done <<< "${gmap[$g]}"
    
    # Ждем завершения всех задач группы
    local result_file=$(wait_for_group "$g")
    
    # Подсчитываем результаты
    local group_ok=0 group_fail=0
    if [[ -f "$result_file" ]]; then
      while IFS= read -r code; do
        if [[ "$code" == "0" ]]; then
          ((group_ok++))
        else
          ((group_fail++))
        fi
      done < "$result_file"
      rm -f "$result_file"
    fi
    
    total_ok=$((total_ok + group_ok))
    total_fail=$((total_fail + group_fail))
    log "INFO" "✅ Group '$g' done: $group_ok ok, $group_fail fail"
  done
  
  echo "total_ok=$total_ok total_fail=$total_fail" >> /tmp/clone_summary.env
  
  # Выводим для захвата в GitHub Actions
  echo "total_ok=$total_ok"
  echo "total_fail=$total_fail"
}

main "${1:-}"