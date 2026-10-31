# Install-SPTPack.ps1  (v2: self-syncing)
# Keeps a friend's SPT install matched to the host's mod pack, then optionally launches SPT.
#   INSTALL.bat -> sync only.     PLAY.bat -> sync, then start SPT.Launcher.
#
# How it stays in sync without new zips:
#   pack.json has "packUrl". If set, the latest manifest.json + overrides are downloaded from
#   there before syncing. Mods added by the host get installed, mods the host removed get
#   deleted (only files this script itself placed), changed config overrides get re-applied.
#   Personal F12 settings survive unless the host ships a changed copy of that config file.

param(
    [string]$SptRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Launch,
    [string]$Only = ''          # test hook: comma-separated name fragments
)

$ErrorActionPreference = 'Stop'
$pack  = $PSScriptRoot
$work  = Join-Path $pack '_work'
$dl    = Join-Path $work 'dl'
$state = Join-Path $work 'installed.json'

function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; Read-Host 'Press Enter to exit' | Out-Null; exit 1 }
function Hash($f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash }

# ---- sanity checks -------------------------------------------------------
if (-not (Test-Path (Join-Path $SptRoot 'EscapeFromTarkov.exe')))  { Fail "No EscapeFromTarkov.exe in $SptRoot. Put FriendPack inside your SPT folder." }
if (-not (Test-Path (Join-Path $SptRoot 'BepInEx\plugins\spt')))    { Fail "BepInEx\plugins\spt missing. Run SPT once before installing mods." }
if (Get-Process -Name 'EscapeFromTarkov','SPT.Launcher' -ErrorAction SilentlyContinue) { Fail 'Close the game and launcher first.' }
New-Item -ItemType Directory -Force $dl | Out-Null

# ---- pull latest pack definition from the host (optional) ----------------
$packCfg = @{ packUrl = '' }
if (Test-Path "$pack\pack.json") { $packCfg = Get-Content "$pack\pack.json" -Raw | ConvertFrom-Json }
if ($packCfg.packUrl) {
    Write-Host "Checking host for pack updates..." -ForegroundColor Cyan
    $zip = Join-Path $work 'pack-latest.zip'
    curl.exe -sSL --retry 3 -o $zip $packCfg.packUrl
    if ($LASTEXITCODE -eq 0) {
        $tmp = Join-Path $work 'pack-latest'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem $tmp -Recurse -Filter 'manifest.json' | Select-Object -First 1
        if ($src) {
            Copy-Item $src.FullName "$pack\manifest.json" -Force
            $ov = Join-Path $src.DirectoryName 'overrides'
            if (Test-Path $ov) { if (Test-Path "$pack\overrides") { Remove-Item "$pack\overrides" -Recurse -Force }; Copy-Item $ov "$pack\overrides" -Recurse }
            $md = Join-Path $src.DirectoryName 'INSTALL.md'; if (Test-Path $md) { Copy-Item $md "$pack\INSTALL.md" -Force }
            Write-Host '  pack definition updated from host'
        }
    } else { Write-Host '  host unreachable, using the local pack definition' -ForegroundColor Yellow }
}

$manifest = Get-Content (Join-Path $pack 'manifest.json') -Raw | ConvertFrom-Json
$ver = (Get-Item (Join-Path $SptRoot 'EscapeFromTarkov.exe')).VersionInfo.FileVersion
if ($ver -ne $manifest.eftFileVersion) { Fail "Client is $ver, pack needs $($manifest.eftFileVersion) (SPT $($manifest.sptVersion))." }
Write-Host "SPT root: $SptRoot  (client $ver)" -ForegroundColor Cyan

# ---- state: which files each mod url placed ------------------------------
$installed = @{}
if (Test-Path $state) { (Get-Content $state -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $installed[$_.Name] = $_.Value } }
function SaveState { $installed | ConvertTo-Json -Depth 5 | Set-Content $state -Encoding utf8 }

# ---- 7-Zip console for .7z files (zips use built-in Expand-Archive) -----
$sz = Join-Path $work '7zr.exe'
if (-not (Test-Path $sz)) { Write-Host 'Fetching 7zr.exe from 7-zip.org'; curl.exe -sSL --retry 3 -o $sz 'https://www.7-zip.org/a/7zr.exe' }

$mods = @($manifest.mods)
if ($Only) { $frags = $Only.Split(','); $mods = @($mods | Where-Object { $n = $_.name; $frags | Where-Object { $n -like "*$($_.Trim())*" } }) }
$wanted = @($mods | ForEach-Object { $_.url })

# ---- remove mods the host dropped ----------------------------------------
foreach ($url in @($installed.Keys)) {
    if ($url -eq '__overrides__' -or $wanted -contains $url) { continue }
    Write-Host "Removing (no longer in pack): $([IO.Path]::GetFileName($url))" -ForegroundColor Yellow
    foreach ($rel in $installed[$url]) { $f = Join-Path $SptRoot $rel; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    foreach ($rel in ($installed[$url] | Sort-Object -Descending)) { $d = Split-Path (Join-Path $SptRoot $rel) -Parent; while ($d -and $d -ne $SptRoot -and (Test-Path $d) -and -not (Get-ChildItem $d -Force | Select-Object -First 1)) { Remove-Item $d -Force; $d = Split-Path $d -Parent } }
    $installed.Remove($url); SaveState
}

# ---- install new mods ----------------------------------------------------
$i = 0
foreach ($m in $mods) {
    $i++
    if ($installed.ContainsKey($m.url)) { continue }
    $file = Join-Path $dl ([IO.Path]::GetFileName($m.url))
    Write-Host "[$i/$($mods.Count)] $($m.name)" -ForegroundColor Green
    if (-not (Test-Path $file)) {
        curl.exe -L --retry 5 --retry-delay 5 -# -o $file $m.url
        if ($LASTEXITCODE -ne 0) { Fail "Download failed: $($m.url)" }
    }
    $x = Join-Path $work ('x\' + [IO.Path]::GetFileNameWithoutExtension($file))
    if (Test-Path $x) { Remove-Item $x -Recurse -Force }
    if ($file -like '*.zip') { Expand-Archive -LiteralPath $file -DestinationPath $x -Force }
    else { & $sz x $file "-o$x" -y | Out-Null; if ($LASTEXITCODE -ne 0) { Fail "Extract failed: $file" } }
    # SPT_Runtime is copied too: the client reads mod bundles from user\mods\<mod>\bundles
    # locally instead of downloading 8+ GB from the host on first launch. No server runs here.
    $placed = @()
    foreach ($sub in 'BepInEx','EscapeFromTarkov_Data','SPT_Runtime') {
        if (Test-Path "$x\$sub") {
            Get-ChildItem "$x\$sub" -Recurse -File | ForEach-Object { $placed += $_.FullName.Substring($x.Length + 1) }
            robocopy "$x\$sub" "$SptRoot\$sub" /E /NFL /NDL /NJH /NJS /NP | Out-Null
        }
    }
    $installed[$m.url] = $placed; SaveState
    Remove-Item $x -Recurse -Force
}

# ---- host config overrides: apply only files the host changed ------------
if (Test-Path "$pack\overrides") {
    if (-not $installed.ContainsKey('__overrides__')) { $installed['__overrides__'] = @{} }
    $applied = $installed['__overrides__']; if ($applied -isnot [hashtable]) { $h = @{}; $applied.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }; $applied = $h }
    Get-ChildItem "$pack\overrides" -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring("$pack\overrides".Length + 1); $hash = Hash $_.FullName
        if ($applied[$rel] -ne $hash) {
            $dest = Join-Path $SptRoot $rel; New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
            Copy-Item $_.FullName $dest -Force; $applied[$rel] = $hash; Write-Host "  config applied: $rel"
        }
    }
    $installed['__overrides__'] = $applied; SaveState
}

Write-Host "`nUp to date." -ForegroundColor Cyan
if ($Launch) {
    Start-Process (Join-Path $SptRoot 'SPT_Runtime\SPT.Launcher.exe') -WorkingDirectory (Join-Path $SptRoot 'SPT_Runtime')
} else {
    Write-Host 'Open SPT.Launcher -> your host server -> play. Do NOT run SPT.Server yourself.'
    Read-Host 'Press Enter to exit' | Out-Null
}
