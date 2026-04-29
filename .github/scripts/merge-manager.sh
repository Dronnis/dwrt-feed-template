#!/bin/bash
# merge-manager.sh - Главный скрипт управления

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/repositories.yml"
PARALLEL_JOBS=8
TEMP_DIRS=()

# Загрузка утилит
source "${SCRIPT_DIR}/git-helpers.sh"

# Функция для парсинга YAML (простой вариант)
parse_yaml() {
   python3 -c "
import yaml, sys, json
with open('$1') as f:
    data = yaml.safe_load(f)
    print(json.dumps(data))
"
}

# Инициализация
init() {
    shopt -s extglob
    set +e
    
    # Очистка перед началом
    git rm -r --cache * >/dev/null 2>&1 &
    rm -rf $(find ./* -maxdepth 0 -type d ! -name ".github") >/dev/null 2>&1
    
    # Настройка git
    git config --global user.email "$(get_config_value settings.git_user_email)"
    git config --global user.name "$(get_config_value settings.git_user_name)"
    sudo timedatectl set-timezone "$(get_config_value settings.timezone)"
}

# Клонирование с обработкой ошибок
git_clone() {
    local url="$1"
    local dest="${2:-}"
    local depth="${3:-1}"
    
    echo "📦 Cloning: $url"
    
    if [ -n "$dest" ]; then
        git clone --depth "$depth" "$url" "$dest"
    else
        git clone --depth "$depth" "$url"
    fi
    
    if [ $? -ne 0 ]; then
        echo "❌ Error cloning: $url"
        exit 1
    fi
}

# Sparse clone
git_sparse_clone() {
    local branch="$1"
    local url="$2"
    shift 2
    local paths=("$@")
    
    local tmpdir="$(mktemp -d)"
    TEMP_DIRS+=("$tmpdir")
    
    if [ ${#branch} -lt 10 ]; then
        git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$url" "$tmpdir"
    else
        git clone --filter=blob:none --sparse "$url" "$tmpdir"
        cd "$tmpdir"
        git checkout "$branch"
    fi
    
    cd "$tmpdir"
    git sparse-checkout init --cone
    git sparse-checkout set "${paths[@]}"
    
    for path in "${paths[@]}"; do
        local basename=$(basename "$path")
        if [ -e "$path" ]; then
            cp -r "$path" "$OLDPWD/" 2>/dev/null || true
        fi
    done
    
    cd "$OLDPWD"
}

# Обработка mvdir
mvdir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        for item in "$dir"/*; do
            if [ -d "$item" ]; then
                mv "$item" "./"
            fi
        done
        rm -rf "$dir"
    fi
}

# Обработка группы репозиториев
process_group() {
    local base_url="$1"
    shift
    local repos=("$@")
    
    local pids=()
    for repo in "${repos[@]}"; do
        (
            local full_url="${base_url}/${repo}"
            git_clone "$full_url"
        ) &
        pids+=($!)
        
        # Контроль параллельности
        while [ $(jobs -r | wc -l) -ge $PARALLEL_JOBS ]; do
            sleep 0.1
        done
    done
    
    wait "${pids[@]}"
}

# Основная функция обработки репозиториев
process_repositories() {
    local config="$1"
    
    # Обработка обычных репозиториев
    for category in core proxy sirpdboy; do
        local repos=$(echo "$config" | jq -r ".repositories.${category}[]?.name // empty")
        if [ -n "$repos" ]; then
            for repo in $repos; do
                local url=$(echo "$config" | jq -r ".repositories.${category}[] | select(.name==\"$repo\") | .url")
                local action=$(echo "$config" | jq -r ".repositories.${category}[] | select(.name==\"$repo\") | .action // \"\"")
                
                git_clone "$url"
                
                if [ "$action" = "mvdir" ]; then
                    mvdir "$repo"
                fi
            done &
        fi
    done
    
    # Обработка групп
    for group in muink gspotx2f; do
        local base_url=$(echo "$config" | jq -r ".repositories.${group}.base_url")
        local repos=($(echo "$config" | jq -r ".repositories.${group}.repositories[].name"))
        
        if [ -n "$base_url" ] && [ ${#repos[@]} -gt 0 ]; then
            process_group "$base_url" "${repos[@]}" &
        fi
    done
    
    # Обработка sparse репозиториев
    local sparse_count=$(echo "$config" | jq '.repositories.sparse | length')
    for ((i=0; i<sparse_count; i++)); do
        local url=$(echo "$config" | jq -r ".repositories.sparse[$i].url")
        local branch=$(echo "$config" | jq -r ".repositories.sparse[$i].branch")
        local paths=($(echo "$config" | jq -r ".repositories.sparse[$i].sparse_paths[]"))
        
        git_sparse_clone "$branch" "$url" "${paths[@]}" &
    done
    
    wait
}

# Пост-обработка
post_process() {
    local config="$1"
    
    echo "🔧 Running post-processing..."
    
    # Удаление дубликатов
    local dup_count=$(echo "$config" | jq '.post_processing.delete_duplicates | length')
    for ((i=0; i<dup_count; i++)); do
        local source=$(echo "$config" | jq -r ".post_processing.delete_duplicates[$i].source")
        if [ -d "$source" ]; then
            local exclude=$(echo "$config" | jq -r ".post_processing.delete_duplicates[$i].exclude | join(\"|\")")
            if [ -n "$exclude" ] && [ "$exclude" != "null" ]; then
                mv -n ${source}/!($exclude) ./ 2>/dev/null || true
            else
                mv -n ${source}/* ./ 2>/dev/null || true
            fi
            rm -rf "$source"
        fi
    done
    
    # Sed замены
    local sed_count=$(echo "$config" | jq '.post_processing.sed_replacements | length')
    for ((i=0; i<sed_count; i++)); do
        local pattern=$(echo "$config" | jq -r ".post_processing.sed_replacements[$i].pattern")
        local replacement=$(echo "$config" | jq -r ".post_processing.sed_replacements[$i].replacement")
        local paths=$(echo "$config" | jq -r ".post_processing.sed_replacements[$i].paths | join(\" \")")
        
        find $paths -type f -exec sed -i "s/${pattern}/${replacement}/g" {} \; 2>/dev/null || true
    done
    
    # Удаление .git директорий
    rm -rf */.git
    
    # Копирование пользовательских патчей
    cp -rf .github/diy/packages/* ./ 2>/dev/null || true
    rm -rf */.github
}

# Очистка временных файлов
cleanup() {
    for dir in "${TEMP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}

# Main
main() {
    trap cleanup EXIT
    
    echo "🚀 Starting merge manager..."
    
    # Загрузка конфигурации
    local config_json=$(parse_yaml "$CONFIG_FILE")
    
    init
    process_repositories "$config_json"
    post_process "$config_json"
    
    # Применение патчей
    find ".github/diy/patches" -type f -name '*.patch' -print0 | sort -z | \
        xargs -I % -t -0 -n 1 sh -c "patch -d './' -p1 -E -f -F 1 --no-backup-if-mismatch -i '%'"
    
    echo "✅ Merge completed successfully!"
}

main "$@"