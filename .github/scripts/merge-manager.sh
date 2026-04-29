#!/bin/bash
# merge-manager.sh - Главный скрипт управления

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/repositories.yml"

# Функция для парсинга YAML (простой вариант)
parse_yaml() {
   python3 -c "
import yaml, sys, json
with open('$1') as f:
    data = yaml.safe_load(f)
    print(json.dumps(data))
"
}

# Получение значения из конфига
get_config_value() {
    local key="$1"
    python3 -c "
import yaml, sys, json
with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f)
    keys = '$key'.split('.')
    value = data
    for k in keys:
        value = value.get(k, {})
    print(value if not isinstance(value, dict) else '')
" 2>/dev/null || echo ""
}

# Инициализация
init() {
    shopt -s extglob
    set +e
    
    echo "🧹 Cleaning workspace..."
    git rm -r --cache * >/dev/null 2>&1
    rm -rf $(find ./* -maxdepth 0 -type d ! -name ".github") >/dev/null 2>&1
    
    # Настройка git
    local git_email=$(get_config_value "settings.git_user_email")
    local git_name=$(get_config_value "settings.git_user_name")
    local timezone=$(get_config_value "settings.timezone")
    
    git config --global user.email "${git_email:-github-actions[bot]@users.noreply.github.com}"
    git config --global user.name "${git_name:-github-actions[bot]}"
    
    if [ -n "$timezone" ] && [ "$timezone" != "null" ]; then
        sudo timedatectl set-timezone "$timezone" 2>/dev/null || true
    fi
    
    echo "✅ Git configured"
}

# Клонирование с обработкой ошибок
git_clone() {
    local url="$1"
    local dest="${2:-}"
    
    if [ -n "$dest" ]; then
        echo "📦 Cloning $url -> $dest"
        git clone --depth 1 "$url" "$dest"
    else
        echo "📦 Cloning $url"
        git clone --depth 1 "$url"
    fi
    
    if [ $? -ne 0 ]; then
        echo "❌ Error cloning: $url"
        return 1
    fi
    return 0
}

# Функция mvdir
mvdir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "📁 Moving contents of $dir"
        for item in "$dir"/*; do
            if [ -d "$item" ]; then
                mv "$item" "./" 2>/dev/null || true
            fi
        done
        rm -rf "$dir"
    fi
}

# Обработка обычных репозиториев из JSON
process_repos() {
    local repos_json="$1"
    local count=$(echo "$repos_json" | jq 'length')
    
    for ((i=0; i<count; i++)); do
        local name=$(echo "$repos_json" | jq -r ".[$i].name // empty")
        local url=$(echo "$repos_json" | jq -r ".[$i].url // empty")
        local action=$(echo "$repos_json" | jq -r ".[$i].action // empty")
        local target_dir=$(echo "$repos_json" | jq -r ".[$i].target_dir // empty")
        
        if [ -z "$url" ] || [ "$url" = "null" ]; then
            continue
        fi
        
        if [ -n "$target_dir" ] && [ "$target_dir" != "null" ]; then
            git_clone "$url" "$target_dir"
            if [ "$action" = "mvdir" ]; then
                mvdir "$target_dir"
            fi
        else
            git_clone "$url"
        fi
        
        # Обработка специальных действий
        if [ -n "$action" ] && [ "$action" != "null" ]; then
            case "$action" in
                "mvdir")
                    mvdir "$name"
                    ;;
                "special")
                    echo "⚡ Special action for $name"
                    ;;
            esac
        fi
    done
}

# Основная функция обработки
process_repositories() {
    local config_json="$1"
    
    echo "📥 Processing repositories..."
    
    # Получаем список категорий
    local categories=$(echo "$config_json" | jq -r '.repositories | keys[]' 2>/dev/null | grep -v "sparse" | grep -v "muink" | grep -v "gspotx2f")
    
    for category in $categories; do
        echo "📂 Category: $category"
        local repos_json=$(echo "$config_json" | jq -c ".repositories.\"$category\"")
        
        # Проверяем, что это массив
        if echo "$repos_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
            process_repos "$repos_json" &
        fi
    done
    
    wait
    echo "✅ All repositories cloned"
}

# Обработка групп репозиториев (muink, gspotx2f)
process_groups() {
    local config_json="$1"
    
    for group in muink gspotx2f; do
        local base_url=$(echo "$config_json" | jq -r ".repositories.\"$group\".base_url // empty")
        if [ -n "$base_url" ] && [ "$base_url" != "null" ]; then
            echo "📦 Processing group: $group"
            local repos_json=$(echo "$config_json" | jq -c ".repositories.\"$group\".repositories[]")
            local count=$(echo "$repos_json" | jq -s 'length')
            
            for ((i=0; i<count; i++)); do
                local repo_name=$(echo "$repos_json" | jq -r ".[$i].name // empty")
                if [ -n "$repo_name" ]; then
                    local full_url="${base_url}/${repo_name}"
                    git_clone "$full_url" &
                    
                    # Ограничиваем параллельность
                    while [ $(jobs -r | wc -l) -ge 4 ]; do
                        sleep 0.5
                    done
                fi
            done
            wait
        fi
    done
}

# Обработка sparse репозиториев
process_sparse() {
    local config_json="$1"
    local sparse_count=$(echo "$config_json" | jq '.repositories.sparse | length')
    
    echo "📦 Processing sparse repositories..."
    
    for ((i=0; i<sparse_count; i++)); do
        local name=$(echo "$config_json" | jq -r ".repositories.sparse[$i].name // empty")
        local url=$(echo "$config_json" | jq -r ".repositories.sparse[$i].url // empty")
        local branch=$(echo "$config_json" | jq -r ".repositories.sparse[$i].branch // \"master\"")
        local paths_json=$(echo "$config_json" | jq -c ".repositories.sparse[$i].sparse_paths // []")
        
        if [ -z "$url" ] || [ "$url" = "null" ]; then
            continue
        fi
        
        echo "🌿 Sparse clone: $name"
        
        local tmpdir=$(mktemp -d)
        
        if [ ${#branch} -lt 10 ]; then
            git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$url" "$tmpdir" 2>/dev/null || true
        else
            git clone --filter=blob:none --sparse "$url" "$tmpdir" 2>/dev/null || true
            cd "$tmpdir"
            git checkout "$branch" 2>/dev/null || true
            cd - >/dev/null
        fi
        
        cd "$tmpdir"
        git sparse-checkout init --cone 2>/dev/null || true
        
        local paths_count=$(echo "$paths_json" | jq 'length')
        for ((j=0; j<paths_count; j++)); do
            local path=$(echo "$paths_json" | jq -r ".[$j]")
            if [ -n "$path" ] && [ "$path" != "null" ]; then
                git sparse-checkout set "$path" 2>/dev/null || true
                
                # Копируем найденные файлы
                if [ -d "$path" ]; then
                    cp -r "$path" "$OLDPWD/" 2>/dev/null || true
                fi
            fi
        done
        
        cd - >/dev/null
        rm -rf "$tmpdir"
    done
    
    echo "✅ Sparse repositories processed"
}

# Пост-обработка
post_process() {
    local config_json="$1"
    
    echo "🔧 Running post-processing..."
    
    # Удаление дубликатов из config
    local dup_count=$(echo "$config_json" | jq '.post_processing.delete_duplicates | length')
    for ((i=0; i<dup_count; i++)); do
        local source=$(echo "$config_json" | jq -r ".post_processing.delete_duplicates[$i].source // empty")
        if [ -n "$source" ] && [ "$source" != "null" ] && [ -d "$source" ]; then
            echo "🗑️ Removing duplicates from $source"
            mv $source/* ./ 2>/dev/null || true
            rm -rf "$source"
        fi
    done
    
    # Удаление .git директорий
    echo "🗑️ Removing .git directories"
    rm -rf */.git 2>/dev/null || true
    
    # Копирование пользовательских пакетов
    if [ -d ".github/diy/packages" ]; then
        echo "📦 Copying DIY packages"
        cp -rf .github/diy/packages/* ./ 2>/dev/null || true
    fi
    
    # Очистка
    rm -rf */.github 2>/dev/null || true
    
    # Применение патчей
    if [ -d ".github/diy/patches" ]; then
        echo "🔧 Applying patches"
        find ".github/diy/patches" -type f -name '*.patch' -print0 | sort -z | while IFS= read -r -d '' patch; do
            echo "  Applying: $(basename "$patch")"
            patch -d './' -p1 -E -f -F 1 --no-backup-if-mismatch -i "$patch" 2>/dev/null || true
        done
    fi
    
    # Выполнение дополнительных sed замен
    local sed_count=$(echo "$config_json" | jq '.post_processing.sed_replacements | length')
    for ((i=0; i<sed_count; i++)); do
        local pattern=$(echo "$config_json" | jq -r ".post_processing.sed_replacements[$i].pattern // empty")
        local replacement=$(echo "$config_json" | jq -r ".post_processing.sed_replacements[$i].replacement // empty")
        
        if [ -n "$pattern" ] && [ "$pattern" != "null" ] && [ -n "$replacement" ]; then
            echo "🔧 Running sed replacement"
            find . -type f -name "Makefile" -exec sed -i "s/${pattern}/${replacement}/g" {} \; 2>/dev/null || true
        fi
    done
    
    echo "✅ Post-processing completed"
}

# Обновление версий пакетов
update_versions() {
    echo "🔄 Updating package versions..."
    
    for makefile in $(find . -name "Makefile" -not -path "*/luci-*" 2>/dev/null | head -20); do
        # Простое обновление PKG_RELEASE
        if grep -q "PKG_RELEASE" "$makefile" 2>/dev/null; then
            local pkg_dir=$(dirname "$makefile")
            local rev_count=$(git rev-list --count HEAD "$pkg_dir" 2>/dev/null || echo "1")
            sed -i "s/PKG_RELEASE:=.*/PKG_RELEASE:=$rev_count/" "$makefile" 2>/dev/null || true
        fi
    done
    
    echo "✅ Version update completed"
}

# Main
main() {
    echo "🚀 Starting merge manager..."
    
    # Проверка наличия конфига
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Загрузка конфигурации
    local config_json=$(parse_yaml "$CONFIG_FILE")
    
    if [ -z "$config_json" ] || [ "$config_json" = "null" ]; then
        echo "❌ Failed to parse config"
        exit 1
    fi
    
    init
    process_repositories "$config_json"
    process_groups "$config_json"
    process_sparse "$config_json"
    post_process "$config_json"
    update_versions
    
    echo "✅ Merge completed successfully!"
}

# Запуск
main "$@"