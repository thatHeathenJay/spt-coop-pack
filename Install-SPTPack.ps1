# Install-SPTPack.ps1  (v3: self-syncing, extraction + optional arena)
# Keeps a friend's SPT install matched to the host's mod pack, then optionally launches it.
#   INSTALL.bat / PLAY.bat             -> the extraction client (this SPT folder)
#   INSTALL-ARENA.bat / PLAY-ARENA.bat -> the arena client, a sibling folder "<SPT folder>-Arena"
#                                         built from this install (game data shared by junction)
#
# How it stays in sync without new zips:
#   pack.json has "packUrl". If set, the latest manifests + overrides are downloaded from there
#   before syncing. Mods added by the host get installed, mods the host removed get deleted (only
#   files this script itself placed), changed config overrides get re-applied. Personal F12
#   settings survive unless the host ships a changed copy of that config file.

param(
    [string]$SptRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Launch,
    [switch]$Arena,
    [string]$Only = ''          # test hook: comma-separated name fragments
)

$ErrorActionPreference = 'Stop'
$pack  = $PSScriptRoot
$work  = Join-Path $pack '_work'
$dl    = Join-Path $work 'dl'
$MainRoot = $SptRoot
if ($Arena) { $SptRoot = "$MainRoot-Arena"; $manifestName = 'manifest-arena.json'; $state = Join-Path $work 'installed-arena.json'; $overridesDir = "$pack\overrides-arena" }
else        { $manifestName = 'manifest.json';       $state = Join-Path $work 'installed.json';       $overridesDir = "$pack\overrides" }

function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; Read-Host 'Press Enter to exit' | Out-Null; exit 1 }
function Hash($f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash }
function Junction($link, $target) { if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Directory -Force (Split-Path $link -Parent) | Out-Null; cmd /c mklink /J "$link" "$target" | Out-Null } }

# ---- sanity checks -------------------------------------------------------
if (-not (Test-Path (Join-Path $MainRoot 'EscapeFromTarkov.exe')))  { Fail "No EscapeFromTarkov.exe in $MainRoot. Put FriendPack inside your SPT folder." }
if (-not (Test-Path (Join-Path $MainRoot 'BepInEx\plugins\spt')))    { Fail "BepInEx\plugins\spt missing. Run SPT once before installing mods." }
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
            foreach ($f in 'manifest.json','manifest-arena.json','INSTALL.md') { $p = Join-Path $src.DirectoryName $f; if (Test-Path $p) { Copy-Item $p "$pack\$f" -Force } }
            foreach ($o in 'overrides','overrides-arena') { $ov = Join-Path $src.DirectoryName $o; if (Test-Path $ov) { if (Test-Path "$pack\$o") { Remove-Item "$pack\$o" -Recurse -Force }; Copy-Item $ov "$pack\$o" -Recurse } }
            Write-Host '  pack definition updated from host'
        }
    } else { Write-Host '  host unreachable, using the local pack definition' -ForegroundColor Yellow }
}

if (-not (Test-Path (Join-Path $pack $manifestName))) { Fail "$manifestName not found in the pack." }
$manifest = Get-Content (Join-Path $pack $manifestName) -Raw | ConvertFrom-Json
$ver = (Get-Item (Join-Path $MainRoot 'EscapeFromTarkov.exe')).VersionInfo.FileVersion
if ($ver -ne $manifest.eftFileVersion) { Fail "Client is $ver, pack needs $($manifest.eftFileVersion) (SPT $($manifest.sptVersion))." }
Write-Host "$(if ($Arena) {'Arena'} else {'SPT'}) root: $SptRoot  (client $ver)" -ForegroundColor Cyan

# ---- arena: build the second client from this install (idempotent) ------
if ($Arena) {
    Write-Host 'Preparing the arena client folder from your SPT install...' -ForegroundColor Cyan
    $b = $manifest.baseFromMain
    foreach ($d in 'BepInEx\plugins','BepInEx\patchers','BepInEx\config','BepInEx\core','SPT_Runtime\user\mods','SPT_Runtime\user\launcher','Logs') { New-Item -ItemType Directory -Force (Join-Path $SptRoot $d) | Out-Null }
    Junction "$SptRoot\EscapeFromTarkov_Data" "$MainRoot\EscapeFromTarkov_Data"
    foreach ($f in 'EscapeFromTarkov.exe','UnityPlayer.dll','winhttp.dll','doorstop_config.ini','.doorstop_version') { if (Test-Path "$MainRoot\$f") { Copy-Item "$MainRoot\$f" "$SptRoot\$f" -Force } }
    foreach ($d in 'MonoBleedingEdge','NLog','BepInEx\core') { robocopy "$MainRoot\$d" "$SptRoot\$d" /E /NFL /NDL /NJH /NJS /NP | Out-Null }
    if (Test-Path "$MainRoot\BepInEx\BepInEx.cfg") { Copy-Item "$MainRoot\BepInEx\BepInEx.cfg" "$SptRoot\BepInEx\" -Force }
    foreach ($p in $b.plugins)  { $s = "$MainRoot\BepInEx\plugins\$p";  if (Test-Path $s) { if ((Get-Item $s).PSIsContainer) { robocopy $s "$SptRoot\BepInEx\plugins\$p" /E /NFL /NDL /NJH /NJS /NP | Out-Null } else { Copy-Item $s "$SptRoot\BepInEx\plugins\" -Force } } else { Write-Host "  (main install lacks $p, skipped)" -ForegroundColor Yellow } }
    foreach ($p in $b.patchers) { $s = "$MainRoot\BepInEx\patchers\$p"; if (Test-Path $s) { if ((Get-Item $s).PSIsContainer) { robocopy $s "$SptRoot\BepInEx\patchers\$p" /E /NFL /NDL /NJH /NJS /NP | Out-Null } else { Copy-Item $s "$SptRoot\BepInEx\patchers\" -Force } } }
    foreach ($c in $b.configs)  { $s = "$MainRoot\BepInEx\config\$c";   if ((Test-Path $s) -and -not (Test-Path "$SptRoot\BepInEx\config\$c")) { Copy-Item $s "$SptRoot\BepInEx\config\" -Force } }
    foreach ($m in $b.bundleMods) { if (Test-Path "$MainRoot\SPT_Runtime\user\mods\$m") { Junction "$SptRoot\SPT_Runtime\user\mods\$m" "$MainRoot\SPT_Runtime\user\mods\$m" } }
    # own launcher: same launcher binaries, GamePath -> arena folder, same server list
    Get-ChildItem "$MainRoot\SPT_Runtime" -File | Where-Object { $_.Name -notmatch '^SPT\.Server' } | Copy-Item -Destination "$SptRoot\SPT_Runtime" -Force
    foreach ($d in 'Launcher','dotnet','SPT_Data','user\sptSettings') { if (Test-Path "$MainRoot\SPT_Runtime\$d") { Junction "$SptRoot\SPT_Runtime\$d" "$MainRoot\SPT_Runtime\$d" } }
    $lsPath = "$SptRoot\SPT_Runtime\user\launcher\LauncherSettings.json"
    if (-not (Test-Path $lsPath)) {
        $ls = Get-Content "$MainRoot\SPT_Runtime\user\launcher\LauncherSettings.json" -Raw | ConvertFrom-Json
        $ls.GamePath = $SptRoot; $ls.EnableGamePath = $true
        $ls | ConvertTo-Json -Depth 6 | Set-Content $lsPath -Encoding utf8
    }
    Write-Host '  arena base ready'
}

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
    $file = Join-Path $dl ([IO.Path]::GetFileName(($m.url -split '\?')[0]))
    if ($m.url -match 'pixeldrain') { $file = Join-Path $dl ("$($m.name -replace '[^A-Za-z0-9.]','_').zip") }
    Write-Host "[$i/$($mods.Count)] $($m.name)" -ForegroundColor Green
    if (-not (Test-Path $file)) {
        curl.exe -L --retry 5 --retry-delay 5 -# -A 'Mozilla/5.0' -o $file $m.url
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
if (Test-Path $overridesDir) {
    if (-not $installed.ContainsKey('__overrides__')) { $installed['__overrides__'] = @{} }
    $applied = $installed['__overrides__']; if ($applied -isnot [hashtable]) { $h = @{}; $applied.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }; $applied = $h }
    Get-ChildItem $overridesDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($overridesDir.Length + 1); $hash = Hash $_.FullName
        if ($applied[$rel] -ne $hash) {
            $dest = Join-Path $SptRoot $rel; New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
            Copy-Item $_.FullName $dest -Force; $applied[$rel] = $hash; Write-Host "  config applied: $rel"
        }
    }
    $installed['__overrides__'] = $applied; SaveState
}

# ---- arena: the live Arena UI pack, when the host provides one --------------
if ($Arena) {
    $uiUrl = $manifest.arenaUi.url
    $uiDir = Join-Path $SptRoot 'BepInEx\plugins\maschine-ArenaMode\arena-ui'
    if ($uiUrl) {
        if ($installed['__arenaUi__'] -ne $uiUrl) {
            Write-Host 'Arena UI pack' -ForegroundColor Green
            $file = Join-Path $dl 'arena-ui.zip'
            if (-not (Test-Path $file)) { curl.exe -L --retry 5 --retry-delay 5 -# -A 'Mozilla/5.0' -o $file $uiUrl; if ($LASTEXITCODE -ne 0) { Fail "Download failed: $uiUrl" } }
            if (Test-Path $uiDir) { Remove-Item $uiDir -Recurse -Force }
            Expand-Archive -LiteralPath $file -DestinationPath (Split-Path $uiDir -Parent) -Force
            if (-not (Test-Path (Join-Path $uiDir 'layouts'))) { Fail 'The Arena UI pack did not unpack to an arena-ui folder with layouts.' }
            $installed['__arenaUi__'] = $uiUrl; SaveState
        }
    } elseif (-not (Test-Path $uiDir)) {
        Write-Host 'No Arena UI pack in the manifest: the stock Arena Mode HUD and menus are used.' -ForegroundColor Yellow
    }
}

Write-Host "`nUp to date." -ForegroundColor Cyan
if ($Launch) {
    Start-Process (Join-Path $SptRoot 'SPT_Runtime\SPT.Launcher.exe') -WorkingDirectory (Join-Path $SptRoot 'SPT_Runtime')
} else {
    Write-Host "Open $(if ($Arena) {'PLAY-ARENA.bat'} else {'PLAY.bat'}) to play. Do NOT run SPT.Server yourself; the host runs it."
    Read-Host 'Press Enter to exit' | Out-Null
}
