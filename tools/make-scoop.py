#!/usr/bin/env python3
"""Writes packaging/scoop/devvy.json for a published release.
Usage: python tools/make-scoop.py <version-tag>   e.g. v0.10.72
The SHA-256 is read from the release file devvy-<tag>.zip.sha256 (downloaded from GitHub) - the repo must be public and the release built.
Publish the result in a Scoop bucket (a repo named e.g. zuwann/scoop-devvy, file bucket/devvy.json) or install it directly:
  scoop install https://raw.githubusercontent.com/zuwann/devvy/main/packaging/scoop/devvy.json"""
import json, re, sys, urllib.request
OWNER, REPO = 'zuwann', 'devvy'
def main():
    if len(sys.argv) != 2 or not re.fullmatch(r'v\d+\.\d+\.\d+', sys.argv[1]):
        sys.exit(__doc__)
    tag = sys.argv[1]; ver = tag[1:]
    base = f'https://github.com/{OWNER}/{REPO}/releases/download/{tag}/devvy-{tag}.zip'
    with urllib.request.urlopen(base + '.sha256', timeout=30) as r:
        sha = r.read().decode().split()[0].strip().lower()
    if not re.fullmatch(r'[0-9a-f]{64}', sha):
        sys.exit('Unexpected content of the .sha256 file')
    m = {
        '$schema': 'https://raw.githubusercontent.com/ScoopInstaller/Scoop/master/schema.json',
        'version': ver,
        'description': 'Signed drivers from the Microsoft catalog, verified before install. Open source driver cleaner and updater for Windows .',
        'homepage': f'https://github.com/{OWNER}/{REPO}',
        'license': 'MIT',
        'url': base,
        'hash': sha,
        'extract_dir': 'devvy',
        'bin': 'devvy.bat',
        'shortcuts': [['devvy.bat', 'Devvy']],
        'persist': 'data',
        'notes': 'Devvy asks for administrator rights when it starts. It can also update itself from the program: after that, "scoop update" may report the files as changed.',
        'checkver': {'url': f'https://api.github.com/repos/{OWNER}/{REPO}/releases', 'jsonpath': '$[0].tag_name', 'regex': 'v([\\d.]+)'},
        'autoupdate': {'url': f'https://github.com/{OWNER}/{REPO}/releases/download/v$version/devvy-v$version.zip',
                       'hash': {'url': '$url.sha256'}},
    }
    open('packaging/scoop/devvy.json', 'w', encoding='utf-8', newline='\n').write(json.dumps(m, indent=2) + '\n')
    print('packaging/scoop/devvy.json written for', ver)
main()
