# Devvy - small bootstrap (this is the only code that runs from the web)
# Usage in PowerShell:   irm https://raw.githubusercontent.com/zuwann/devvy/main/get.ps1 | iex
# What it does, in plain words:
#   1. downloads the release package of Devvy from GitHub (a .zip) and its SHA-256 hash file,
#   2. checks that the hash matches; if it does not, it stops and runs nothing,
#   3. unpacks it in %LOCALAPPDATA%\Devvy\<version> and starts it (Windows asks for administrator rights).
# It changes nothing else on the PC. Read it before running it: it is short on purpose.
$ErrorActionPreference = 'Stop'
$Repo    = 'zuwann/devvy'     # GitHub "owner/repository"
$Version = 'latest'                        # 'latest' or a tag such as 'v0.10.72'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    # 'latest' = newest published release of the list (the "/releases/latest" address ignores pre-releases, and every Devvy beta is one)
    $api = if ($Version -eq 'latest') { "https://api.github.com/repos/$Repo/releases?per_page=10" } else { "https://api.github.com/repos/$Repo/releases/tags/$Version" }
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Devvy-bootstrap' }
    if ($Version -eq 'latest') { $rel = @($rel | Where-Object { -not $_.draft })[0]; if (-not $rel) { throw 'No release has been published yet.' } }
    $zipAsset = @($rel.assets | Where-Object { $_.name -like 'devvy-*.zip' })[0]
    $hashAsset = @($rel.assets | Where-Object { $_.name -like 'devvy-*.zip.sha256' })[0]
    if (-not $zipAsset -or -not $hashAsset) { throw 'The release has no package or no hash file.' }

    $tmp = Join-Path $env:TEMP ('devvy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp $zipAsset.name
    Write-Host ('Downloading ' + $zipAsset.name + ' ...')
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -UseBasicParsing
    $expected = ((Invoke-WebRequest -Uri $hashAsset.browser_download_url -UseBasicParsing).Content -split '\s+')[0].Trim().ToLower()
    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw ('Hash mismatch: expected ' + $expected + ' but got ' + $actual + '. Nothing was run.') }
    Write-Host ('Hash OK (' + $actual.Substring(0, 12) + '...)')

    $dest = Join-Path $env:LOCALAPPDATA ('Devvy\' + $rel.tag_name)
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item -Recurse -Force $tmp
    $bat = Get-ChildItem -Path $dest -Recurse -Filter 'devvy.bat' | Select-Object -First 1
    if (-not $bat) { throw 'devvy.bat not found in the package.' }
    Write-Host ('Starting ' + $bat.FullName)
    Start-Process -FilePath $bat.FullName
}
catch {
    Write-Host ('Devvy could not start: ' + $_.Exception.Message) -ForegroundColor Red
}
