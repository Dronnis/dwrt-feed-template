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

# Инициализация
init() {
    shopt -s extglob
    set +e
    
    echo "🧹 Cleaning workspace..."
    
    git rm -r --cache * >/dev/null 2>&1 || true
    find ./* -maxdepth 0 -type d ! -name ".github" -exec rm -rf {} + 2>/dev/null || true
    
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
    
    if [ -n "$dest" ]; then
        echo "📦 Cloning $url -> $dest"
        git clone --depth 1 "$url" "$dest" 2>&1 | head -3 || {
            echo "⚠️ Failed to clone $url"
            return 1
        }
    else
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
    
    # Получаем список категорий
    local categories=$(echo "$config_json" | jq -r '.repositories | keys[]' 2>/dev/null | grep -v "muink" | grep -v "gspotx2f" | head -20)
    
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
    
    # Удаляем .git директории
    echo "🔧 Cleaning up .git directories in packages (keeping root .git)"
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
    
    # Дополнительные sed замены из конфига
    local sed_count=$(echo "$config_json" | jq '.post_processing.sed_replacements | length' 2>/dev/null)
    if [ -n "$sed_count" ] && [ "$sed_count" != "null" ] && [ "$sed_count" -gt 0 ]; then
        echo "🔧 Running sed replacements"
        for ((i=0; i<sed_count; i++)); do
            local pattern=$(echo "$config_json" | jq -r ".post_processing.sed_replacements[$i].pattern // empty" 2>/dev/null)
            local replacement=$(echo "$config_json" | jq -r ".post_processing.sed_replacements[$i].replacement // empty" 2>/dev/null)
            
            if [ -n "$pattern" ] && [ "$pattern" != "null" ] && [ -n "$replacement" ] && [ "$replacement" != "null" ]; then
                find . -type f -name "Makefile" -exec sed -i "s|${pattern}|${replacement}|g" {} \; 2>/dev/null || true
            fi
        done
    fi
    
    echo "✅ Post-processing completed"
}

# Обновление версий
update_versions() {
    echo "🔄 Updating package versions..."
    
    local pkg_count=$(find . -name "Makefile" -not -path "*/luci-*" 2>/dev/null | wc -l)
    echo "📊 Found $pkg_count packages"
    
    # Обновляем PKG_RELEASE для каждого пакета
    for makefile in $(find . -name "Makefile" 2>/dev/null | head -50); do
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
    
    if [ ! -d ".git" ]; then
        echo "❌ Not in a git repository! Exiting."
        exit 1
    fi

    echo "📁 Config file: $CONFIG_FILE"
    
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

    if [ -n "$(git status --porcelain)" ]; then
        echo "✅ Changes detected, ready to commit"
    else
        echo "ℹ️ No changes - everything is up to date"
    fi
    
    echo "🎉 Merge completed successfully!"
}

# Запуск
main "$@"