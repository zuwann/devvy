#!/usr/bin/env python3
"""Builds the kb/ folder published on GitHub for the in-app knowledge update (28-update-knowledge.ps1).
Copies the data files from scripts/, writes kb/manifest.json with their SHA-256 and the version from scripts/kb-version.txt.
Bump scripts/kb-version.txt (yyyyMMddNN) every time one of these files changes, then run:  python tools/make-kb.py
"""
import hashlib, json, pathlib, shutil, datetime

root = pathlib.Path(__file__).resolve().parent.parent
sc, kb = root / 'scripts', root / 'kb'
kb.mkdir(exist_ok=True)
files = {'knowledge.csv': sc / 'knowledge.csv', 'knowledge.it.csv': sc / 'locales' / 'knowledge.it.csv', 'knowledge.es.csv': sc / 'locales' / 'knowledge.es.csv', 'knowledge.de.csv': sc / 'locales' / 'knowledge.de.csv', 'knowledge.fr.csv': sc / 'locales' / 'knowledge.fr.csv',
         'support-links.csv': sc / 'support-links.csv', 'support-models.csv': sc / 'support-models.csv'}
entries = []
for name, src in files.items():
    dst = kb / name
    shutil.copyfile(src, dst)
    entries.append({'name': name, 'sha256': hashlib.sha256(dst.read_bytes()).hexdigest()})
version = int((sc / 'kb-version.txt').read_text().strip())
(kb / 'manifest.json').write_text(json.dumps({'version': version, 'date': datetime.date.today().isoformat(), 'files': entries}, indent=1), encoding='utf-8')
print('kb/manifest.json written, version', version)
