#!/bin/bash
init_metrics() {
  echo "workflow_start_ts=$(date +%s)" > /tmp/metrics.env
  echo "workflow_start_human=$(date '+%Y-%m-%d %H:%M:%S')" >> /tmp/metrics.env
}

start_timer() { echo "${1}_start=$(date +%s%N)" >> /tmp/metrics.env; }
end_timer() {
  local stage="$1" end_ns=$(date +%s%N)
  local start_ns=$(grep "^${stage}_start=" /tmp/metrics.env | cut -d= -f2)
  if [[ -n "$start_ns" ]]; then
    local delta_ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "${stage}_duration_ms=${delta_ms}" >> /tmp/metrics.env
  fi
}

print_summary() {
  [[ -f /tmp/metrics.env ]] || return 0
  source /tmp/metrics.env
  local total=$(( $(date +%s) - workflow_start_ts ))
  echo -e "\n📊 Workflow finished in ${total}s"
  for s in clone_repos apply_patches modify_packages git_commit; do
    grep -q "${s}_duration_ms=" /tmp/metrics.env 2>/dev/null && printf "   • %s: %sms\n" "$s" "$(grep "${s}_duration_ms=" /tmp/metrics.env | cut -d= -f2)"
  done
}

export_to_github() {
  [[ -n "$GITHUB_STEP_SUMMARY" && -f /tmp/metrics.env ]] || return 0
  source /tmp/metrics.env
  {
    echo "## ⏱️ Performance Metrics"
    echo "| Stage | Duration (ms) |"
    echo "|-------|--------------|"
    for s in clone_repos apply_patches modify_packages git_commit; do
      grep -q "${s}_duration_ms=" /tmp/metrics.env 2>/dev/null && printf "| %s | %s |\n" "$s" "$(grep "${s}_duration_ms=" /tmp/metrics.env | cut -d= -f2)"
    done
    echo "| **TOTAL** | **$(( $(date +%s) - workflow_start_ts )) s** |"
  } >> "$GITHUB_STEP_SUMMARY"
}