# Build-ArenaUi.ps1 - builds the live Arena UI pack from the player's OWN EFT: Arena install.
#
# Nothing of BSG's is downloaded or shared: AssetRipper reads the Arena install on this PC, our transpiler turns
# the menu prefabs into layout JSON, and the packer copies only the sprites, fonts and sounds those layouts use
# into <arena client>\BepInEx\plugins\maschine-ArenaMode\arena-ui (about 250 MB). Everything else (the tools,
# the ~10 GB of ripped files) lives in a scratch folder that is deleted at the end.
#
# Called by Install-SPTPack.ps1 -Arena when the pack is missing. Works under Windows PowerShell 5.1 and PowerShell 7.
param(
    [Parameter(Mandatory)][string]$SptRoot,      # the extraction SPT folder (EFT managed DLLs, SPT database)
    [Parameter(Mandatory)][string]$ArenaRoot,    # the arena client folder (output goes under its BepInEx)
    [Parameter(Mandatory)][string]$Work,         # scratch root; a subfolder is created and removed
    [string]$Arena = '',                         # EFT: Arena install; asked for when the default is not there
    [switch]$KeepScratch
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Net.Http

$tools = $PSScriptRoot
$out = Join-Path $ArenaRoot 'BepInEx\plugins\maschine-ArenaMode\arena-ui'
$scratch = Join-Path $Work 'arena-ui-build'
$AssetRipperUrl = 'https://github.com/AssetRipper/AssetRipper/releases/download/2.0.0/AssetRipper_win_x64.zip'
$PythonUrl = 'https://www.python.org/ftp/python/3.13.9/python-3.13.9-embed-amd64.zip'
$PyYamlApi = 'https://pypi.org/pypi/PyYAML/json'

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Fetch($url, $file) {
    if (Test-Path $file) { return }
    Write-Host "  downloading $([IO.Path]::GetFileName($file))"
    curl.exe -L --retry 5 --retry-delay 5 -sS -A 'Mozilla/5.0' -o $file $url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $file)) { throw "Download failed: $url" }
}
function LinkOrCopy($target, $link) {
    New-Item -ItemType Directory -Force (Split-Path $link -Parent) | Out-Null
    try { New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop | Out-Null }
    catch { Copy-Item -LiteralPath $target -Destination $link -Force }   # other volume: a copy, deleted with the scratch
}

# ---- where is EFT: Arena? --------------------------------------------------
if (-not $Arena) { $Arena = 'C:\Battlestate Games\Escape from Tarkov Arena' }
while (-not (Test-Path (Join-Path $Arena 'EscapeFromTarkovArena_Data\resources.assets'))) {
    Write-Host "EFT: Arena was not found at: $Arena" -ForegroundColor Yellow
    $Arena = Read-Host 'Type the folder where Escape from Tarkov: Arena is installed (the one with EscapeFromTarkovArena.exe)'
    if (-not $Arena) { throw 'EFT: Arena install path is required for the Arena UI pack.' }
}
$arenaData = Join-Path $Arena 'EscapeFromTarkovArena_Data'
$managed = Join-Path $SptRoot 'EscapeFromTarkov_Data\Managed'
$db = Join-Path $SptRoot 'SPT_Runtime\SPT_Data\database'
if (-not (Test-Path "$managed\UnityEngine.UI.dll")) { throw "EFT managed DLLs not found at $managed" }
if (-not (Test-Path "$db\templates\items.json")) { throw "SPT database not found at $db" }

# ---- room: the rip is large while it exists ----------------------------------
New-Item -ItemType Directory -Force $scratch | Out-Null
$free = (Get-PSDrive -Name ((Resolve-Path $scratch).Path.Substring(0, 1))).Free
if ($free -lt 14GB) { throw "The Arena UI build needs about 14 GB free on the drive of $scratch while it runs (free: $([math]::Round($free / 1GB)) GB). It all gets deleted afterwards." }
Write-Host "Arena: $Arena"
Write-Host "Scratch: $scratch (deleted when done)"

# ---- tools: AssetRipper 2.0.0 and a portable Python with PyYAML --------------
Step 'Fetching the tools'
$ripperZip = Join-Path $scratch 'AssetRipper_win_x64.zip'; $ripperDir = Join-Path $scratch 'AssetRipper'
Fetch $AssetRipperUrl $ripperZip
if (-not (Test-Path "$ripperDir\AssetRipper.GUI.Free.exe")) { Expand-Archive -LiteralPath $ripperZip -DestinationPath $ripperDir -Force }
$ripper = Join-Path $ripperDir 'AssetRipper.GUI.Free.exe'
if (-not (Test-Path $ripper)) { throw 'AssetRipper.GUI.Free.exe missing after unpack.' }
$pyZip = Join-Path $scratch 'python-embed.zip'; $pyDir = Join-Path $scratch 'python'
Fetch $PythonUrl $pyZip
if (-not (Test-Path "$pyDir\python.exe")) { Expand-Archive -LiteralPath $pyZip -DestinationPath $pyDir -Force }
$python = Join-Path $pyDir 'python.exe'
if (-not (Test-Path "$pyDir\yaml\__init__.py")) {
    $api = (Invoke-WebRequest $PyYamlApi -UseBasicParsing).Content | ConvertFrom-Json
    $wheel = $api.urls | Where-Object { $_.filename -like '*cp313*win_amd64*.whl' } | Select-Object -First 1
    if (-not $wheel) { throw 'No PyYAML wheel for Python 3.13 / Windows x64 on PyPI.' }
    $whl = Join-Path $scratch 'pyyaml.zip'
    Fetch $wheel.url $whl
    $whlDir = Join-Path $scratch 'pyyaml'
    Expand-Archive -LiteralPath $whl -DestinationPath $whlDir -Force
    foreach ($d in 'yaml', '_yaml') { if (Test-Path "$whlDir\$d") { Copy-Item "$whlDir\$d" "$pyDir\$d" -Recurse -Force } }
}
# Windows PowerShell 5.1 strips inner quotes from native arguments: the check script goes through a file.
$check = Join-Path $scratch 'check.py'
Set-Content -Path $check -Value 'import yaml, json, sys; print("python ok, pyyaml", yaml.__version__)' -Encoding ascii
& $python $check
if ($LASTEXITCODE -ne 0) { throw 'The portable Python could not import PyYAML.' }

# ---- the stub game: Arena's data files presented as a Mono game with EFT's own managed DLLs ------------------
# Arena is IL2CPP with encrypted metadata, so AssetRipper cannot read its scripts. The UI layouts only need the
# shared Unity/BSG UI assemblies, which the EFT client carries; TextMeshPro gets our layout shim.
Step 'Preparing the Arena data for AssetRipper'
$stub = Join-Path $scratch 'stub'
if (Test-Path $stub) { Remove-Item -Recurse -Force $stub }
New-Item -ItemType Directory -Force "$stub\EscapeFromTarkovArena_Data\Managed" | Out-Null
$stubFiles = @('EscapeFromTarkovArena.exe', 'UnityPlayer.dll', 'baselib.dll') +
    (@('app.info', 'boot.config', 'ScriptingAssemblies.json', 'RuntimeInitializeOnLoads.json', 'globalgamemanagers', 'globalgamemanagers.assets',
       'resources.assets', 'resources.assets.resS', 'resources.resource', 'sharedassets0.assets', 'level0', 'level1',
       'sharedassets1.assets', 'sharedassets1.assets.resS', 'sharedassets1.resource') | ForEach-Object { "EscapeFromTarkovArena_Data\$_" })
foreach ($f in $stubFiles) { $src = Join-Path $Arena $f; if (Test-Path $src) { LinkOrCopy $src (Join-Path $stub $f) } }
foreach ($dll in Get-ChildItem $managed -Filter *.dll) { LinkOrCopy $dll.FullName "$stub\EscapeFromTarkovArena_Data\Managed\$($dll.Name)" }
$shim = Join-Path $tools 'Unity.TextMeshPro.dll'
if (-not (Test-Path $shim)) { throw "TextMeshPro layout shim missing from the pack: $shim" }
Remove-Item -Force "$stub\EscapeFromTarkovArena_Data\Managed\Unity.TextMeshPro.dll" -ErrorAction SilentlyContinue
Copy-Item $shim "$stub\EscapeFromTarkovArena_Data\Managed\Unity.TextMeshPro.dll" -Force

# AssetRipper settings: PNG images, YAML prefabs; StreamingAssetsMode 0 keeps the 6,000 map bundles out.
@{ Import = @{ StreamingAssetsMode = 0 }; Processing = @{ EnableStaticMeshSeparation = $false }; Export = @{ SaveSettingsToDisk = $true } } |
    ConvertTo-Json -Depth 4 | Set-Content -Encoding ascii (Join-Path $ripperDir 'AssetRipper.Settings.json')

# ---- AssetRipper, headless over its local HTTP API ----------------------------------------------------------
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromHours(3)
function Post($base, $path, $body) {
    $content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')
    $resp = $http.PostAsync("$base$path", $content).GetAwaiter().GetResult()
    $null = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}
function StartRipper($port, $log) {
    $proc = Start-Process -FilePath $ripper -ArgumentList @('--headless', "--port=$port") -PassThru -WindowStyle Minimized -RedirectStandardOutput "$log.out.txt" -RedirectStandardError "$log.err.txt"
    $base = "http://127.0.0.1:$port"
    $deadline = (Get-Date).AddSeconds(120)
    do {
        Start-Sleep -Milliseconds 500
        try { $null = $http.GetAsync("$base/").GetAwaiter().GetResult(); $up = $true } catch { $up = $false }
    } until ($up -or $proc.HasExited -or (Get-Date) -gt $deadline)
    if (-not $up) { Get-Content "$log.out.txt", "$log.err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 30; throw 'AssetRipper did not start.' }
    return @{ Proc = $proc; Base = $base }
}

Step 'Ripping the Arena UI (menus, sprites, fonts). This is the slow part: 10 to 30 minutes.'
$rip = Join-Path $scratch 'rip'
if (Test-Path $rip) { Remove-Item -Recurse -Force $rip }
New-Item -ItemType Directory -Force $rip | Out-Null
$r = StartRipper 5577 (Join-Path $scratch 'assetripper-ui')
try {
    Post $r.Base '/LoadFolder' ('Path=' + [uri]::EscapeDataString($stub))
    Write-Host '  loaded; exporting...'
    Post $r.Base '/Export/UnityProject' ('Path=' + [uri]::EscapeDataString($rip))
} finally { if (-not $r.Proc.HasExited) { Stop-Process -Id $r.Proc.Id -Force } }
$assets = Join-Path $rip 'ExportedProject\Assets'
if (-not (Test-Path "$assets\GameObject")) { throw "The rip produced no prefabs under $assets" }

Step 'Ripping the Arena sound banks (announcer, crowd, effects)'
$bundleRoot = Join-Path $arenaData 'StreamingAssets\Windows'
$bundles = @(
    'assets/arena/resources/arenaaudio/arenasoundeffectswrapper.bundle',
    'assets/content/audio/arena/soundeffects/arenasoundeffectstagbankmanager.bundle',
    'assets/content/audio/arena/blastgang/blastgangsoundsso.bundle',
    'assets/content/audio/phrases/arena/arenaspeakertagbankmanagereng.bundle',
    'assets/content/audio/phrases/arena_effects.bundle',
    'assets/content/audio/phrases/speaker_voice.bundle',
    'assets/content/audio/phrases/speaker_voice2.bundle',
    'assets/content/audio/phrases/fan_speaker_voice.bundle',
    'assets/content/audio/startmission/introanim/introanimsoundlibrary.bundle')
$stage = Join-Path $scratch 'bundles-stage'; $bundleOut = Join-Path $scratch 'bundles'
foreach ($d in $stage, $bundleOut) { if (Test-Path $d) { Remove-Item -Recurse -Force $d }; New-Item -ItemType Directory -Force $d | Out-Null }
foreach ($rel in $bundles) { $src = Join-Path $bundleRoot ($rel -replace '/', '\'); if (Test-Path $src) { LinkOrCopy $src (Join-Path $stage ([IO.Path]::GetFileName($src))) } else { Write-Host "  (missing bundle $rel)" -ForegroundColor Yellow } }
$r = StartRipper 5578 (Join-Path $scratch 'assetripper-bundles')
try {
    foreach ($file in Get-ChildItem $stage -File) {
        Write-Host "  $($file.Name)"
        Post $r.Base '/LoadFile' ('Path=' + [uri]::EscapeDataString($file.FullName))
        $target = Join-Path $bundleOut ([IO.Path]::GetFileNameWithoutExtension($file.Name))
        New-Item -ItemType Directory -Force $target | Out-Null
        Post $r.Base '/Export/UnityProject' ('Path=' + [uri]::EscapeDataString($target))
        Post $r.Base '/Reset' ''
    }
} finally { if (-not $r.Proc.HasExited) { Stop-Process -Id $r.Proc.Id -Force } }

# ---- layouts and the pack ------------------------------------------------------------------------------------
Step 'Transpiling the menu prefabs'
$layouts = Join-Path $scratch 'layouts'
if (Test-Path $layouts) { Remove-Item -Recurse -Force $layouts }
# Exactly the prefabs the packer wants (its LAYOUTS list), not every "Arena*" prefab: the shared parts (Header,
# Footer, PresetViewCard, MatchInfoPanel ...) carry no prefix.
$packer = Get-Content (Join-Path $tools 'pack-arena-ui.py') -Raw
if ($packer -notmatch '(?s)LAYOUTS = \[(.*?)\]') { throw 'pack-arena-ui.py has no LAYOUTS list.' }
$wanted = [regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
& $python (Join-Path $tools 'arena-ui-export.py') $assets $layouts @wanted
if ($LASTEXITCODE -ne 0) { throw 'The layout transpiler failed.' }

Step 'Packing the UI'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
& $python (Join-Path $tools 'pack-arena-ui.py') $layouts $assets $out --db $db --bundles $bundleOut
if ($LASTEXITCODE -ne 0) { throw 'The UI packer failed.' }
$count = (Get-ChildItem (Join-Path $out 'layouts') -Filter *.json -ErrorAction SilentlyContinue).Count
if ($count -lt 30) { throw "The pack came out short ($count layouts); the rip is incomplete." }
$size = [math]::Round(((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)
Write-Host "Arena UI pack ready: $count layouts, $size MB at $out" -ForegroundColor Green

# ---- cleanup: only the pack stays ---------------------------------------------------------------------------
$http.Dispose()
if (-not $KeepScratch) {
    Step 'Removing the scratch files'
    Remove-Item -Recurse -Force $scratch
}
