#!/usr/bin/env python3
"""Writes files.json in the root: every file that belongs to the program, with its SHA-256.
The in-program update compares this list of the installed copy with the one of the new release.
Run it before every release (tools/check.py verifies that it is current). Usage:  python tools/make-manifest.py
"""
import hashlib, json, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent
SKIP_DIRS = {'data', '.git', '__pycache__', 'node_modules'}
SHIPPED_DIRS = {'scripts'}
SHIPPED_FILES = {'devvy.bat', 'README.md', 'COMMANDS.md', 'LICENSE', 'DISCLAIMER.txt'}  # same list as the release zip (.github/workflows/release.yml)
SKIP_NAMES = {'files.json', 'CLAUDE.md'}
SKIP_SUFFIX = ('.zip', '.sha256', '-user.csv')

def files():
    out = []
    for p in sorted(root.rglob('*')):
        rel = p.relative_to(root)
        top = rel.parts[0]
        if top not in SHIPPED_DIRS and rel.as_posix() not in SHIPPED_FILES:
            continue
        if not p.is_file() or any(x in SKIP_DIRS for x in rel.parts) or p.name in SKIP_NAMES or p.name.endswith(SKIP_SUFFIX):
            continue
        out.append(p)
    return out

def build():
    html = (root / 'scripts/web/app.html').read_text(encoding='utf-8')
    ver = re.search(r'<h1>Devvy <small class="mut">([^<]+)</small>', html).group(1).strip()
    items = [{'path': p.relative_to(root).as_posix(), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'size': p.stat().st_size} for p in files()]
    return {'version': ver, 'deferred': ['devvy.bat'], 'files': items}

if __name__ == '__main__':
    m = build()
    (root / 'files.json').write_text(json.dumps(m, indent=1) + '\n', encoding='utf-8', newline='\n')
    print('files.json:', len(m['files']), 'files, version', m['version'])
