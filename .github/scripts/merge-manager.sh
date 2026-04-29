#!/bin/bash
# merge-manager.sh - Главный скрипт управления

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/repositories.yml"

echo "🔍 Looking for config at: $CONFIG_FILE"

# Проверка наличия конфига
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "📁 Creating default config..."
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    
    cat > "$CONFIG_FILE" << 'EOF'
settings:
  timezone: "Asia/Shanghai"
  git_user_email: "github-actions[bot]@users.noreply.github.com"
  git_user_name: "github-actions[bot]"

repositories:
  kiddin9:
    - name: luci-app-dnsfilter
      url: https://github.com/kiddin9/luci-app-dnsfilter
    - name: luci-theme-edge
      url: https://github.com/kiddin9/luci-theme-edge

post_processing:
  delete_duplicates: []
  sed_replacements: []
EOF
    echo "✅ Created default config"
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

# Получение значения из конфига
get_config_value() {
    local key="$1"
    python3 -c "
import yaml, sys, json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = yaml.safe_load(f)
        if data is None:
            data = {}
        keys = '$key'.split('.')
        value = data
        for k in keys:
            value = value.get(k, {})
        if isinstance(value, dict):
            print('')
        else:
            print(value if value else '')
except:
    print('')
" 2>/dev/null
}

# Инициализация - НЕ удаляем существующие файлы полностью
init() {
    shopt -s extglob
    set +e
    
    echo "🧹 Cleaning workspace (keeping .git)..."
    
    # Удаляем только файлы, но не .git
    git rm -r --cached * >/dev/null 2>&1 || true
    
    # Удаляем все директории кроме .git и .github
    find . -maxdepth 1 -type d ! -name "." ! -name ".git" ! -name ".github" -exec rm -rf {} + 2>/dev/null || true
    
    # Удаляем файлы в корне кроме .gitignore
    find . -maxdepth 1 -type f ! -name ".gitignore" ! -name ".git" -delete 2>/dev/null || true
    
    # Настройка git
    local git_email=$(get_config_value "settings.git_user_email")
    local git_name=$(get_config_value "settings.git_user_name")
    
    if [ -n "$git_email" ] && [ "$git_email" != "null" ]; then
        git config --global user.email "$git_email"
    fi
    
    if [ -n "$git_name" ] && [ "$git_name" != "null" ]; then
        git config --global user.name "$git_name"
    fi
    
    echo "✅ Git configured"
}

# Клонирование репозитория
git_clone() {
    local url="$1"
    local dest="${2:-}"
    
    # Пропускаем если директория уже существует
    if [ -n "$dest" ] && [ -d "$dest" ]; then
        echo "⚠️ Directory $dest already exists, skipping..."
        return 0
    fi
    
    if [ -n "$dest" ]; then
        echo "📦 Cloning $url -> $dest"
        git clone --depth 1 "$url" "$dest" 2>&1 | head -3 || {
            echo "⚠️ Failed to clone $url"
            return 1
        }
    else
        local name=$(basename "$url" .git)
        if [ -d "$name" ]; then
            echo "⚠️ Directory $name already exists, skipping..."
            return 0
        fi
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
                else
                    if git_clone "$url"; then
                        if [ "$action" = "mvdir" ] && [ -d "$name" ]; then
                            mvdir "$name"
                        fi
                    fi
                fi
            done
        fi
    done
    
    echo "✅ Repository processing completed"
}

# Пост-обработка
post_process() {
    local config_json="$1"
    
    echo "🔧 Running post-processing..."
    
    # Удаляем .git директории ТОЛЬКО внутри пакетов (не корневой)
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

# Обновление версий
update_versions() {
    echo "🔄 Updating package versions..."
    
    local pkg_count=$(find . -name "Makefile" 2>/dev/null | wc -l)
    echo "📊 Found $pkg_count packages"
    
    # Обновляем PKG_RELEASE для каждого пакета
    for makefile in $(find . -name "Makefile" 2>/dev/null | head -50); do
        if grep -q "PKG_RELEASE" "$makefile" 2>/dev/null; then
            local pkg_dir=$(dirname "$makefile")
            # Используем количество коммитов в этом пакете
            local rev_count=$(git rev-list --count HEAD -- "$pkg_dir" 2>/dev/null || echo "1")
            sed -i "s/PKG_RELEASE:=.*/PKG_RELEASE:=$rev_count/" "$makefile" 2>/dev/null || true
        fi
    done
    
    echo "✅ Version update completed"
}

# Main
main() {
    echo "🚀 Starting merge manager..."
    echo "📁 Config file: $CONFIG_FILE"
    echo "📁 Current directory: $(pwd)"
    
    # Проверяем, что мы в git репозитории
    if [ ! -d ".git" ]; then
        echo "❌ Not in a git repository! Current dir: $(pwd)"
        echo "📁 Contents: $(ls -la)"
        exit 1
    fi
    
    # Загрузка конфигурации
    local config_json=$(parse_yaml "$CONFIG_FILE")
    
    if [ -z "$config_json" ] || [ "$config_json" = "{}" ]; then
        echo "⚠️ Config is empty, using defaults"
        config_json='{"settings":{},"repositories":{},"post_processing":{}}'
    fi
    
    # Проверка наличия jq
    if ! command -v jq &> /dev/null; then
        echo "⚠️ jq not found, installing..."
        sudo apt-get update -qq && sudo apt-get install -y jq -qq
    fi
    
    # Проверка наличия python3-yaml
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo "⚠️ PyYAML not found, installing..."
        pip3 install pyyaml --quiet --break-system-packages 2>/dev/null || pip3 install pyyaml --quiet
    fi
    
    init
    process_repositories "$config_json"
    post_process "$config_json"
    update_versions
    
    # Показываем статус изменений
    echo ""
    echo "📊 Git status after changes:"
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