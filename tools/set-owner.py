#!/usr/bin/env python3
"""Sets the GitHub account in the places that still have the OWNER placeholder (issues page, knowledge-update address, update repository, get.ps1).
Then run tools/make-manifest.py again (common.ps1 changed).
Usage:  python tools/set-owner.py <github-account> [repository-name]
"""
import pathlib, sys

if len(sys.argv) < 2:
    sys.exit(__doc__)
owner = sys.argv[1]
repo = sys.argv[2] if len(sys.argv) > 2 else 'devvy'
root = pathlib.Path(__file__).resolve().parent.parent
edits = {
    'scripts/common.ps1': [('github.com/OWNER/devvy', f'github.com/{owner}/{repo}'), ('raw.githubusercontent.com/OWNER/devvy', f'raw.githubusercontent.com/{owner}/{repo}'), ("'OWNER/devvy'", f"'{owner}/{repo}'")],
    'get.ps1': [("'REPLACE-OWNER/devvy'", f"'{owner}/{repo}'"), ('https://REPLACE-WITH-YOUR-ADDRESS/get.ps1', f'https://raw.githubusercontent.com/{owner}/{repo}/main/get.ps1')],
}
for name, pairs in edits.items():
    p = root / name
    t = p.read_text(encoding='utf-8')
    for a, b in pairs:
        if a in t:
            t = t.replace(a, b); print('replaced in', name, ':', a)
    p.write_text(t, encoding='utf-8', newline='')
