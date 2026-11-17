# Packaging

- **Scoop**: `python tools/make-scoop.py vX.Y.Z` writes `packaging/scoop/devvy.json` (needs the release already published). Put it in a bucket repo or install it by URL.
- **winget**: not prepared on purpose. winget installs `.exe`/`.msi`/`.msix` or zips with a portable `.exe`; Devvy is a batch file plus PowerShell scripts, which winget cannot register. Revisit if a signed launcher `.exe` is ever added.
