#!/bin/bash
# merge-manager.sh - Главный скрипт управления

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/repositories.yml"

echo "🔍 Looking for config at: $CONFIG_FILE"

# Проверка наличия конфига
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

# Функция для парсинга YAML
parse_yaml() {
   python3 -c "
import yaml, sys, json
try:
    with open('$1', 'r') as f:
        data = yaml.safe_load(f)
        if data is None:
            data = {}
        print(json.dumps(data))
except Exception as e:
    print('{}')
" 2>/dev/null || echo "{}"
}

# Инициализация - НЕ УДАЛЯЕМ .git
init() {
    shopt -s extglob
    set +e
    
    echo "🧹 Cleaning workspace (keeping .git)..."
    
    # Сохраняем .gitignore если есть
    if [ -f ".gitignore" ]; then
        cp .gitignore /tmp/.gitignore.backup
    fi
    
    # Удаляем все файлы и директории кроме .git и .github
    find . -maxdepth 1 -type f ! -name ".git" ! -name ".gitignore" -delete 2>/dev/null || true
    find . -maxdepth 1 -type d ! -name "." ! -name ".git" ! -name ".github" -exec rm -rf {} + 2>/dev/null || true
    
    # Восстанавливаем .gitignore
    if [ -f "/tmp/.gitignore.backup" ]; then
        mv /tmp/.gitignore.backup .gitignore
    fi
    
    # Настройка git
    git config --global user.email "github-actions[bot]@users.noreply.github.com"
    git config --global user.name "github-actions[bot]"
    
    echo "✅ Git configured"
    echo "📁 Current directory contents:"
    ls -la | head -10
}

# Клонирование репозитория
git_clone() {
    local url="$1"
    local dest="${2:-}"
    
    if [ -n "$dest" ]; then
        echo "📦 Cloning $url -> $dest"
        git clone --depth 1 "$url" "$dest" 2>&1 | head -3 || {
            echo "⚠️ Failed to clone $url"
            return 1
        }
    else
        local name=$(basename "$url" .git)
        echo "📦 Cloning $url"
        git clone --depth 1 "$url" 2>&1 | head -3 || {
            echo "⚠️ Failed to clone $url"
            return 1
        }
    fi
    return 0
}

# Перемещение содержимого директории
mvdir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "📁 Moving contents of $dir"
        for item in "$dir"/*; do
            if [ -e "$item" ]; then
                mv "$item" "./" 2>/dev/null || true
            fi
        done
        rm -rf "$dir"
    fi
}

# Обработка репозиториев
process_repositories() {
    local config_json="$1"
    
    echo "📥 Processing repositories..."
    
    local categories=$(echo "$config_json" | jq -r '.repositories | keys[]' 2>/dev/null | head -20)
    
    if [ -z "$categories" ] || [ "$categories" = "null" ]; then
        echo "⚠️ No categories found in config"
        return
    fi
    
    for category in $categories; do
        echo "📂 Category: $category"
        
        local count=$(echo "$config_json" | jq ".repositories.\"$category\" | length" 2>/dev/null)
        
        if [ -n "$count" ] && [ "$count" != "null" ] && [ "$count" -gt 0 ]; then
            for ((i=0; i<count; i++)); do
                local name=$(echo "$config_json" | jq -r ".repositories.\"$category\"[$i].name // empty" 2>/dev/null)
                local url=$(echo "$config_json" | jq -r ".repositories.\"$category\"[$i].url // empty" 2>/dev/null)
                local action=$(echo "$config_json" | jq -r ".repositories.\"$category\"[$i].action // empty" 2>/dev/null)
                local target_dir=$(echo "$config_json" | jq -r ".repositories.\"$category\"[$i].target_dir // empty" 2>/dev/null)
                
                if [ -z "$url" ] || [ "$url" = "null" ]; then
                    continue
                fi
                
                local clone_dir="${target_dir:-$name}"
                if [ -n "$clone_dir" ] && [ "$clone_dir" != "null" ]; then
                    if git_clone "$url" "$clone_dir"; then
                        if [ "$action" = "mvdir" ] && [ -d "$clone_dir" ]; then
                            mvdir "$clone_dir"
                        fi
                    fi
                fi
            done
        fi
    done
    
    echo "✅ Repository processing completed"
}

# Пост-обработка - БЕЗ УДАЛЕНИЯ КОРНЕВОГО .git
post_process() {
    local config_json="$1"
    
    echo "🔧 Running post-processing..."
    
    # Удаляем .git ТОЛЬКО внутри скачанных пакетов (глубина 1-2)
    echo "🗑️ Removing .git from subdirectories only..."
    find . -maxdepth 2 -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
    
    # Копируем пользовательские пакеты если есть
    if [ -d ".github/diy/packages" ]; then
        echo "📦 Copying DIY packages"
        cp -rf .github/diy/packages/* ./ 2>/dev/null || true
    fi
    
    # Применяем патчи если есть
    if [ -d ".github/diy/patches" ]; then
        echo "🔧 Applying patches"
        find ".github/diy/patches" -type f -name '*.patch' -exec sh -c "patch -d './' -p1 -E -f --no-backup-if-mismatch -i '{}'" \; 2>/dev/null || true
    fi
    
    echo "✅ Post-processing completed"
}

# Main
main() {
    echo "🚀 Starting merge manager..."
    echo "📁 Config file: $CONFIG_FILE"
    echo "📁 Current directory: $(pwd)"
    
    # Проверяем, что мы в git репозитории
    if [ ! -d ".git" ]; then
        echo "❌ ERROR: Not in a git repository!"
        echo "📁 Current directory contents:"
        ls -la
        exit 1
    fi
    
    # Загрузка конфигурации
    local config_json=$(parse_yaml "$CONFIG_FILE")
    
    if [ -z "$config_json" ] || [ "$config_json" = "{}" ]; then
        echo "❌ ERROR: Failed to parse config"
        exit 1
    fi
    
    # Проверка наличия jq
    if ! command -v jq &> /dev/null; then
        echo "📦 Installing jq..."
        sudo apt-get update -qq && sudo apt-get install -y jq -qq
    fi
    
    # Проверка наличия python3-yaml
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo "📦 Installing PyYAML..."
        pip3 install pyyaml --quiet --break-system-packages 2>/dev/null || pip3 install pyyaml --quiet
    fi
    
    init
    process_repositories "$config_json"
    post_process "$config_json"
    
    # Показываем статус изменений
    echo ""
    echo "📊 Final git status:"
    git status --short | head -20
    
    local changes=$(git status --porcelain | wc -l)
    if [ "$changes" -gt 0 ]; then
        echo "✅ $changes files changed"
    else
        echo "ℹ️ No changes detected"
    fi
    
    echo "🎉 Merge completed successfully!"
}

# Запуск
main "$@"