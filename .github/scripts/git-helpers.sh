#!/bin/bash
# git-helpers.sh - Простые git утилиты

# Проверка существования директории
ensure_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
    fi
}

# Быстрое клонирование с ретраем
git_clone_retry() {
    local url="$1"
    local dest="$2"
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if git_clone "$url" "$dest"; then
            return 0
        fi
        retry=$((retry + 1))
        echo "Retry $retry/$max_retries for $url"
        sleep 2
    done
    
    return 1
}