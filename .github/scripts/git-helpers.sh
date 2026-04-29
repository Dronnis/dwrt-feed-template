#!/bin/bash
# git-helpers.sh - Git утилиты

get_config_value() {
    local key="$1"
    python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f)
    keys = '$key'.split('.')
    value = data
    for k in keys:
        value = value.get(k, {})
    print(value if not isinstance(value, dict) else '')
"
}

# Автообновление версий из GitHub
update_package_versions() {
    local pkg_dir="$1"
    
    for makefile in $(find "$pkg_dir" -name "Makefile" -not -path "*/luci-*"); do
        local repo=$(grep "^PKG_SOURCE_URL" "$makefile" | grep github | sed 's/.*github\.com\/\([^/]*\/[^/]*\).*/\1/')
        
        if [ -n "$repo" ]; then
            local owner=$(echo "$repo" | cut -d/ -f1)
            local name=$(echo "$repo" | cut -d/ -f2)
            
            # Получение последнего коммита
            local latest_commit=$(curl -s "https://api.github.com/repos/$owner/$name/commits/master" | jq -r '.sha')
            
            if [ -n "$latest_commit" ]; then
                sed -i "s/PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$latest_commit/" "$makefile"
            fi
        fi
    done
}