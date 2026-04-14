#!/bin/bash
set -euo pipefail
LOG="/tmp/clone_progress.log"
SUM="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
TG_T="${TG_TOKEN:-}" TG_C="${TG_CHAT_ID:-}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

[[ ! -f "$LOG" || ! -s "$LOG" ]] && exit 0

declare -A g_tot g_ok g_fail g_prio g_sum g_cnt
tot_ok=0 tot_fail=0
> /tmp/failed_details.md

while IFS='|' read -r g p r st du err; do
  [[ -z "$g" ]] && continue
  g_tot[$g]=$((${g_tot[$g]:-0} + 1))
  g_prio[$g]="$p"; g_sum[$g]=$((${g_sum[$g]:-0} + du)); g_cnt[$g]=$((${g_cnt[$g]:-0} + 1))
  if [[ "$st" == "ok" ]]; then g_ok[$g]=$((${g_ok[$g]:-0} + 1)); ((tot_ok++))
  else g_fail[$g]=$((${g_fail[$g]:-0} + 1)); ((tot_fail++)); echo "  ❌ $r: ${err%%$'\n'}" >> /tmp/failed_details.md; fi
done < "$LOG"

{
  echo "## 📦 OpenWrt Packages Clone Report"
  echo "**Progress:** ✅ \`${tot_ok}\` | ❌ \`${tot_fail}\`"
  echo ""
  echo "| 📦 Group | ⭐ Priority | 📊 Total | ✅ OK | ❌ Fail | ⏱️ Avg | Status |"
  echo "|----------|-------------|---------|-------|---------|-------|--------|"
  for g in $(echo "${!g_tot[@]}" | tr ' ' '\n' | sort); do
    ok=${g_ok[$g]:-0}; fl=${g_fail[$g]:-0}; tot=${g_tot[$g]}; pr="${g_prio[$g]}"
    av=$(( ${g_cnt[$g]} > 0 ? ${g_sum[$g]} / ${g_cnt[$g]} : 0 ))
    st="✅ Done"; [[ $fl -gt 0 && $ok -gt 0 ]] && st="⚠️ Partial"; [[ $ok -eq 0 ]] && st="❌ Failed"
    echo "| \`${g}\` | \`${pr}\` | ${tot} | ${ok} | ${fl} | ${av}s | ${st} |"
  done
  echo ""
  [[ -s /tmp/failed_details.md ]] && echo "<details><summary>🔍 Failed ($tot_fail)</summary><pre>$(cat /tmp/failed_details.md)</pre></details>"
} > "$SUM"

if [[ -n "$TG_T" && -n "$TG_C" ]]; then
  msg="📦 <b>OpenWrt Sync</b>\n✅ <code>${tot_ok}</code> | ❌ <code>${tot_fail}</code>\n"
  [[ $tot_fail -gt 0 ]] && msg+="⚠️ Ошибки в группах. <a href='${RUN_URL}'>Details</a>" || msg+="🎉 Все успешно! <a href='${RUN_URL}'>Summary</a>"
  curl -s -X POST "https://api.telegram.org/bot${TG_T}/sendMessage" -d "chat_id=${TG_C}" -d "text=${msg}" -d "parse_mode=HTML" >/dev/null 2>&1 || true
fi
echo "✅ Report generated"