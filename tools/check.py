#!/usr/bin/env python3
"""Repository checks (run in CI and before every release). Exit code 1 when something is wrong.
- every .ps1 is pure ASCII (PowerShell 5.1 reads files without BOM as ANSI)
- locales/it.json is valid and has no two keys equal ignoring case (Windows PowerShell 5.1 ConvertFrom-Json rejects them)
- the JavaScript of scripts/web/app.html parses (needs node, skipped when missing)
- CSV files of the knowledge base have the expected header
- the version in app.html, README.md and CLAUDE.md agree
"""
import csv, collections, json, pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
sc = root / 'scripts'
bad = []

for f in sorted(root.rglob('*.ps1')):
    data = f.read_bytes()
    if any(b > 127 for b in data):
        bad.append(f'{f.relative_to(root)}: non-ASCII characters (use ASCII only in .ps1)')

try:
    d = json.loads((sc / 'locales' / 'it.json').read_text(encoding='utf-8-sig'))
    c = collections.Counter(k.lower() for k in d)
    for k, n in c.items():
        if n > 1:
            bad.append(f'it.json: keys that differ only by case: {k!r}')
except Exception as e:
    bad.append(f'it.json: {e}')

for lf in sorted((sc / 'locales').glob('*.json')):
    if lf.name == 'it.json':
        continue
    try:
        o = json.loads(lf.read_text(encoding='utf-8-sig'))
        cc = collections.Counter(k.lower() for k in o)
        for k, n in cc.items():
            if n > 1:
                bad.append(f'{lf.name}: keys that differ only by case: {k!r}')
        for k, v in o.items():
            if sorted(re.findall(r'\{\d+\}', k)) != sorted(re.findall(r'\{\d+\}', str(v))):
                bad.append(f'{lf.name}: placeholders differ: {k[:60]!r}')
        miss = [k for k in d if k not in o]
        if miss:
            print(f'NOTE: {lf.name} lacks {len(miss)} key(s) present in it.json (shown in English)')
    except Exception as e:
        bad.append(f'{lf.name}: {e}')

html = (sc / 'web' / 'app.html').read_text(encoding='utf-8')
m = re.search(r'<script>(.*)</script>', html, re.S)
if shutil.which('node') and m:
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as t:
        t.write('new Function(require("fs").readFileSync(' + json.dumps(t.name) + ',"utf8"));')
    p = pathlib.Path(t.name)
    js = p.with_suffix('.body.js'); js.write_text(m.group(1), encoding='utf-8')
    p.write_text('new Function(require("fs").readFileSync(' + json.dumps(str(js)) + ',"utf8"));', encoding='utf-8')
    r = subprocess.run(['node', str(p)], capture_output=True, text=True)
    if r.returncode:
        bad.append('app.html: JavaScript error: ' + r.stderr.strip().splitlines()[-1])

heads = {'knowledge.csv': 'Id;Match', 'locales/knowledge.it.csv': 'Id;Name', 'locales/knowledge.es.csv': 'Id;Name', 'locales/knowledge.de.csv': 'Id;Name', 'locales/knowledge.fr.csv': 'Id;Name', 'support-links.csv': 'Match;Name;Url', 'support-models.csv': 'Sku;Url', 'board-links.csv': 'Match;Name;Url'}
for name, h in heads.items():
    p = sc / name
    if not p.exists():
        bad.append(f'{name}: missing'); continue
    first = p.read_text(encoding='utf-8-sig').splitlines()[0]
    for col in h.split(';'):
        if col not in first:
            bad.append(f'{name}: missing column {col}')
    for i, row in enumerate(csv.reader(p.read_text(encoding='utf-8-sig').splitlines(), delimiter=';'), 1):
        pass

v = re.search(r'Devvy <small class="mut">([^<]+)</small>', html)
ver = v.group(1) if v else ''
num = ver.split()[0] if ver else ''
for name, pat in (('README.md', r'\((\d+\.\d+\.\d+)\)'), ('CLAUDE.md', r'Version (\d+\.\d+\.\d+) \(beta\)')):
    if not (root / name).exists(): continue   # CLAUDE.md is local only (not on GitHub)
    t = (root / name).read_text(encoding='utf-8')
    mm = re.search(pat, t)
    if not mm or mm.group(1) != num:
        bad.append(f'{name}: version {mm.group(1) if mm else "not found"} differs from app.html {num}')

# files.json (update list) must match the files
import importlib.util, json as _json
_sp = importlib.util.spec_from_file_location('mm', str(root / 'tools/make-manifest.py')); _mm = importlib.util.module_from_spec(_sp); _sp.loader.exec_module(_mm)
try:
    _cur = _json.loads((root / 'files.json').read_text(encoding='utf-8'))
    if _cur != _mm.build():
        bad.append('files.json is out of date: run python tools/make-manifest.py')
except Exception as e:
    bad.append('files.json missing or invalid: run python tools/make-manifest.py (' + str(e) + ')')

if bad:
    print('\n'.join('ERROR ' + b for b in bad)); sys.exit(1)
print('OK: all checks passed (version ' + ver + ')')
