#!/usr/bin/env python3
import yaml, json, sys, os

def main():
    config_path = os.environ.get('CONFIG_PATH', '.github/configs/package-sources.yml')
    if not os.path.exists(config_path):
        print(f"❌ Config not found: {config_path}", file=sys.stderr)
        sys.exit(1)

    with open(config_path) as f:
        cfg = yaml.safe_load(f)

    sources = []
    protection = cfg.get('protection', {})

    for group in cfg.get('groups', []):
        gname = group.get('name', 'default')
        prio = group.get('priority', 99)
        for src in group.get('sources', []):
            s = src.copy()
            s['group'] = gname
            s['priority'] = prio
            s.setdefault('max_retries', protection.get('max_retries', 2))
            s.setdefault('timeout_minutes', protection.get('timeout_minutes', 5))
            sources.append(s)

    for src in cfg.get('default_sources', []):
        s = src.copy()
        s['group'] = 'default'
        s['priority'] = 99
        s.setdefault('max_retries', protection.get('max_retries', 2))
        s.setdefault('timeout_minutes', protection.get('timeout_minutes', 5))
        sources.append(s)

    sources.sort(key=lambda x: (x['priority'], f"{x['owner']}/{x['repo']}"))
    print(json.dumps({'sources': sources, 'protection': protection}))

if __name__ == '__main__':
    main()