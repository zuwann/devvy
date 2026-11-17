# Inventory of all installed driver packages -> reports\drivers.csv
# For each package: who uses it (present / ghost devices), whether it is an old version, whether it ships with Windows,
# the advice from the knowledge base (knowledge.csv) including orphaned components (related app not installed),
# and - to recognize unknown packages - the hardware IDs of the devices using it, the .inf path and a description read from the .inf.
# Changes nothing. Action: KEEP / REMOVE / REMOVE+UNINSTALL (the last one also removes the driver from the devices using it).
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'inventory-drivers'
Write-ReadOnlyBanner

# Reads the first device description of a driver .inf (the text shown for the first hardware it supports)
function Get-InfDescription([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    try {
        if ((Get-Item $Path).Length -gt 2MB) { return '' }
        $text = Get-Content -Path $Path -Raw -ErrorAction Stop
        # [Strings] section: key = "value"
        $strings = @{}
        $sec = ''
        $models = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($text -split "`r?`n")) {
            $l = $line.Trim()
            if (-not $l -or $l.StartsWith(';')) { continue }
            if ($l -match '^\[(.+)\]$') { $sec = $Matches[1]; continue }
            if ($sec -ieq 'Strings') {
                if ($l -match '^([^=\s]+)\s*=\s*"?([^";]*)"?') { $strings[$Matches[1].ToLower()] = $Matches[2].Trim() }
            } elseif ($sec -ieq 'Manufacturer') {
                # "%Mfg% = ModelsSection, NTamd64"  -> models sections are ModelsSection and ModelsSection.NTamd64
                if ($l -match '=\s*([^,\s]+)(.*)$') {
                    $base = $Matches[1]
                    $models.Add($base)
                    foreach ($dec in ($Matches[2] -split ',')) { $dec = $dec.Trim(); if ($dec) { $models.Add($base + '.' + $dec) } }
                }
            }
        }
        if ($models.Count -eq 0) { return '' }
        $sec = ''
        foreach ($line in ($text -split "`r?`n")) {
            $l = $line.Trim()
            if (-not $l -or $l.StartsWith(';')) { continue }
            if ($l -match '^\[(.+)\]$') { $sec = $Matches[1]; continue }
            if ($models -contains $sec) {
                if ($l -match '^("[^"]+"|%[^%]+%)\s*=') {
                    $d = $Matches[1].Trim('"')
                    if ($d -match '^%([^%]+)%$') {
                        $k = $Matches[1].ToLower()
                        if ($strings.ContainsKey($k)) { $d = $strings[$k] } else { continue }
                    }
                    if ($d) { return $d }
                }
            }
        }
    } catch { }
    return ''
}

Write-Ok (T 'Reading the installed drivers (it can take 1-2 minutes)...')
$pkgs = @(Get-DriverPackages)
Write-Info ('  ' + (T 'Packages: {0}' $pkgs.Count))

Write-Ok (T 'Reading the devices and their drivers...')
$use = Get-DriverUsage
$useP = $use.Present
$useG = $use.Ghost

# Hardware IDs of the devices that use each package (built once; present devices first), key: inf name in lower case
$idMap = Get-DevicePropertyMap @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_DriverInfPath') $false
$presentIds = @{}
foreach ($pd in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)) { $presentIds[$pd.InstanceId] = 1 }
$hwByInf = @{}
foreach ($iid in $idMap.Keys) {
    $m = $idMap[$iid]
    $inf = "$($m['DEVPKEY_Device_DriverInfPath'])".ToLower()
    $hwl = @($m['DEVPKEY_Device_HardwareIds'] | Where-Object { $_ })
    if (-not $inf -or $hwl.Count -eq 0) { continue }
    if (-not $hwByInf.ContainsKey($inf)) { $hwByInf[$inf] = New-Object System.Collections.Generic.List[string] }
    $first = "$($hwl[0])"
    if ($presentIds.ContainsKey($iid)) { $hwByInf[$inf].Insert(0, $first) } else { $hwByInf[$inf].Add($first) }
}

# Duplicate versions (same .inf, same provider and class) among third-party packages
$third = @($pkgs | Where-Object { $_.Driver -like 'oem*.inf' })
$verTag = @{}
$groups = $third | Group-Object { '{0}|{1}|{2}' -f (Split-Path $_.OriginalFileName -Leaf), $_.ProviderName, $_.ClassName }
foreach ($g in $groups) {
    if ($g.Count -lt 2) {
        foreach ($p in $g.Group) { $verTag[$p.Driver] = 'Single' }
        continue
    }
    $s = @($g.Group | Sort-Object @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { ConvertTo-Ver $_.Version }; Descending = $true })
    $verTag[$s[0].Driver] = 'Newest'
    foreach ($p in ($s | Select-Object -Skip 1)) { $verTag[$p.Driver] = 'OldVersion' }
}

$rows = foreach ($p in $pkgs) {
    $leaf = Split-Path $p.OriginalFileName -Leaf
    $isOem = ($p.Driver -like 'oem*.inf')
    $key = "$($p.Driver)".ToLower()
    $nP = [int]$useP[$key]
    $nG = [int]$useG[$key]

    $excluded = Test-Excluded ('{0} {1}' -f $p.ProviderName, $leaf) $p.ClassName

    $tag = 'Inbox'
    $origin = 'Inbox'
    if ($isOem) { $tag = $verTag[$p.Driver]; $origin = 'Third-party' }

    $adv = $null
    if ($isOem -and -not $excluded) { $adv = Get-Advice ('{0} {1} {2}' -f $leaf, $p.ProviderName, $p.ClassName) }
    $kbId = ''; $what = ''; $risk = ''; $advText = ''; $decide = ''
    if ($adv) {
        $kbId = $adv.Id; $what = $adv.Name; $risk = $adv.Risk; $advText = Get-AdviceText $adv
        if ($adv.Depends -eq 'YES') { $decide = 'YES' }
    }

    if ($isOem -and -not $excluded -and -not $adv) { $advText = Get-ClassAdvice "$($p.ClassName)" $nP $nG }
    if (-not $isOem) { $action = 'KEEP'; $why = TE 'Driver included with Windows' }
    elseif ($excluded) { $action = 'KEEP'; $why = TE 'Excluded by you in the settings (pattern: {0})' (Get-ExclusionMatch ('{0} {1}' -f $p.ProviderName, $leaf)) }
    elseif ($nP -gt 0) { $action = 'KEEP'; $why = TE 'In use by {0} connected device(s)' $nP }
    elseif ($adv -and $adv.Auto -eq 'ORPHAN' -and $adv.IsOrphan) { $action = 'REMOVE+UNINSTALL'; $why = TE 'Orphaned component: {0} (app not installed)' $adv.Name }
    elseif ($adv -and $adv.Auto -eq 'UNUSED') { $action = 'REMOVE+UNINSTALL'; $why = TE 'Not in use: {0}' $adv.Name }
    elseif ($tag -eq 'OldVersion') { $action = 'REMOVE'; $why = TE 'Older version of the same package' }
    elseif ($nG -gt 0) { $action = 'REMOVE'; $why = TE 'Used only by devices that are not connected' }
    elseif ($p.ClassName -eq 'Extension') { $action = 'KEEP'; $why = TE 'Extension driver: it extends another driver (0 users is normal)' }
    else { $action = 'KEEP'; $why = TE 'Third-party driver not in use: to be evaluated' }

    if ($excluded) { $cat = T 'Excluded by you' }
    elseif ($adv) { $cat = $adv.Name }
    elseif (-not $isOem) { $cat = T 'Windows (included)' }
    else { $cat = T 'Other third-party' }

    # To recognize the package: hardware IDs of the devices that use it, the file and a description read from it
    $hwIds = ''
    if ($hwByInf.ContainsKey($key)) { $hwIds = (@($hwByInf[$key] | Select-Object -Unique | Select-Object -First 3) -join ' | ') }
    $infPath = ''
    if ($isOem -and $p.OriginalFileName) { $infPath = "$($p.OriginalFileName)" }
    $infDesc = ''
    if ($isOem -and -not $excluded) { $infDesc = Get-InfDescription $infPath }

    [pscustomobject][ordered]@{
        Action         = $action
        Origin         = $origin
        Category       = $cat
        Driver         = "$($p.Driver)"
        InfName        = $leaf
        Provider       = "$($p.ProviderName)"
        Class          = "$($p.ClassName)"
        Version        = "$($p.Version)"
        Date           = Format-Date $p.Date
        UsedByPresent  = $nP
        UsedByGhost    = $nG
        Versions       = $tag
        KbId           = $kbId
        Risk           = $risk
        Decide         = $decide
        Advice         = $advText
        Reason         = $why
        HardwareIds    = $hwIds
        InfPath        = $infPath
        InfDescription = $infDesc
    }
}

$sorted = $rows | Sort-Object Action, Origin, Category, Provider, InfName
$path = Save-ReportCsv $sorted 'drivers'
Write-Host ''
Write-Ok ((T 'Report:') + ' ' + $path)
Write-Info (T 'Summary (Action, Origin):')
$rows | Group-Object Action, Origin | Sort-Object Name | ForEach-Object { Write-Host ('  {0}: {1}' -f (ConvertTo-SummaryName $_.Name), $_.Count) }

# Third-party packages without an entry in the knowledge base -> unknown.csv
# Same format as knowledge-user.csv: fill in Name/What/IfNeeded/IfNotNeeded/Risk and paste the rows there.
# It has no device names or personal data: only the .inf file, vendor, class, version, counts, hardware IDs and description.
$unk = @($rows | Where-Object { $_.Origin -eq 'Third-party' -and -not $_.KbId -and $_.Category -ne (T 'Excluded by you') })
if ($unk.Count -gt 0) {
    $tpl = foreach ($u in ($unk | Sort-Object Provider, InfName)) {
        $nm = $u.Provider + ' - ' + $u.InfName
        if ($u.InfDescription) { $nm = $u.Provider + ' - ' + $u.InfDescription }
        [pscustomobject][ordered]@{
            Id             = ($u.InfName -replace '\.inf$', '').ToLower()
            Match          = [regex]::Escape($u.InfName)
            Exclude        = ''
            Name           = $nm
            What           = ''
            IfNeeded       = ''
            IfNotNeeded    = ''
            AppRegex       = ''
            Risk           = 'Medium'
            Depends        = 'YES'
            Auto           = ''
            InfName        = $u.InfName
            Provider       = $u.Provider
            Class          = $u.Class
            Version        = $u.Version
            Date           = $u.Date
            UsedByPresent  = $u.UsedByPresent
            UsedByGhost    = $u.UsedByGhost
            HardwareIds    = $u.HardwareIds
            InfPath        = $u.InfPath
            InfDescription = $u.InfDescription
        }
    }
    $pu = Save-ReportCsv $tpl 'unknown'
    Write-Host ''
    Write-Warn (T 'Components WITHOUT advice in the knowledge base: {0}' $unk.Count)
    Write-Host ('  ' + (T 'List:') + ' ' + $pu)
    Write-Host ('  ' + (T 'The HardwareIds, InfPath and InfDescription columns help to recognize them.'))
}

$old = @($rows | Where-Object { $_.Versions -eq 'OldVersion' })
if ($old.Count -gt 0) {
    Write-Host ''
    Write-Host (T 'Found {0} old driver versions: use the Run tab to remove them.' $old.Count)
}
Write-Todo @(
    (T 'Open the Drivers tab: REMOVE or REMOVE+UNINSTALL means the package will be deleted, KEEP means it stays.'),
    (T 'For the components that depend on how you use the PC (VPN, virtual machines, phone drivers...) read the advice column.'),
    (T 'When you are ready go to the Run tab: first the preview, then the changes.')
)
Stop-Log
