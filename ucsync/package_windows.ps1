# Empaqueta Chromper (Chromium sin Google con UC-Sync integrado) para Windows x64.
#
# Se ejecuta DESPUÉS de `ninja -C out\Release chrome`: coge del directorio de salida sólo lo que
# el navegador necesita en tiempo de ejecución, recorta idiomas y coloca la extensión integrada
# (`ucsync\`) junto a chrome.exe, que es donde el loader la busca (`base::DIR_EXE`).
#
# Uso (PowerShell):
#   .\package_windows.ps1 -Src C:\ucbuild\src -Out C:\paquetes
param(
  [Parameter(Mandatory=$true)][string]$Src,
  [string]$Out = "$PWD",
  [string]$BuildDir = '',
  [string]$Locales = "es es-419 en-US pt-BR fr de it gl ca eu ja zh-CN zh-TW ru"
)
$ErrorActionPreference = 'Stop'
$fork = Split-Path -Parent $PSScriptRoot
if ($BuildDir) {
  $build = $BuildDir
} else {
  # build.py de Windows deja la salida en out\Default; otros flujos usan out\Release.
  $build = @('out\Default','out\Release') | ForEach-Object { Join-Path $Src $_ } |
    Where-Object { Test-Path (Join-Path $_ 'chrome.exe') } | Select-Object -First 1
}
if (-not $build -or -not (Test-Path (Join-Path $build 'chrome.exe'))) {
  throw "No hay chrome.exe en $Src\out\Default ni $Src\out\Release (ejecuta primero el build: python build.py)"
}
$version = (Get-Content (Join-Path $fork 'chromium_version.txt')).Trim()

$stage = Join-Path $env:TEMP ("ucsync-win-" + [guid]::NewGuid().ToString('N'))
$pkg = Join-Path $stage 'chromper'
New-Item -ItemType Directory -Path $pkg | Out-Null

$files = 'chrome.exe','chrome_proxy.exe','chrome_crashpad_handler.exe','product_logo_48.png',
         'resources.pak','chrome_100_percent.pak','chrome_200_percent.pak','browser_resources.pak',
         'chrome_elf.dll','libEGL.dll','libGLESv2.dll','d3dcompiler_47.dll',
         'icudtl.dat','v8_context_snapshot.bin','vk_swiftshader_icd.json'
foreach ($f in $files) {
  $p = Join-Path $build $f
  if (Test-Path $p) { Copy-Item $p $pkg }
}
# Cualquier DLL/PAK/DAT que el build haya puesto junto al ejecutable (el conjunto cambia entre
# versiones de Chromium), salvo los binarios de test y las herramientas de gn/ninja.
Get-ChildItem $build -File | Where-Object {
  $_.Extension -in '.dll','.dat','.bin','.pak' -and $_.BaseName -notmatch '(_test$|^test_|^(gn|ninja)$)'
} | ForEach-Object { Copy-Item $_.FullName $pkg }
foreach ($f in 'libvk_swiftshader.dll','vk_swiftshader_icd.json') {
  $p = Join-Path $build $f
  if (Test-Path $p) { Copy-Item $p $pkg }
}

New-Item -ItemType Directory -Path (Join-Path $pkg 'locales') | Out-Null
foreach ($loc in $Locales -split ' ') {
  $p = Join-Path $build "locales\$loc.pak"
  if (Test-Path $p) { Copy-Item $p (Join-Path $pkg 'locales') }
}
if (-not (Test-Path (Join-Path $pkg 'locales\en-US.pak'))) { throw 'Falta en-US.pak: el navegador no arranca sin idioma base' }

function Colocar-extension($origen, $nombre) {
  if (-not (Test-Path $origen)) { throw "No hay recursos de $nombre en $origen (falta su parche)." }
  # El paquete va sólo con texto: si la UI pidiera icons/*.png saldría roto en chrome://extensions.
  $png = @(Get-ChildItem (Join-Path $origen '*.html') | ForEach-Object {
    Select-String -Path $_.FullName -Pattern 'icons/[a-z0-9_-]+\.png'
  }).Count
  if ($png -gt 0) { throw "$nombre referencia $png veces icons/*.png: usa logo.svg (este paquete no lleva PNG)." }
  Copy-Item -Recurse $origen (Join-Path $pkg $nombre)
}
$rec = Join-Path $Src 'chrome\browser\resources'
Colocar-extension (Join-Path $rec 'ucsync') 'ucsync'
Colocar-extension (Join-Path $rec 'chromium-web-store') 'chromium-web-store'

function Version-de($dir) {
  $m = Join-Path $dir 'manifest.json'
  if (Test-Path $m) { (Get-Content $m -Raw | ConvertFrom-Json).version } else { 'n/d' }
}
$extVersion = Version-de (Join-Path $pkg 'ucsync')
$wsVersion = Version-de (Join-Path $pkg 'chromium-web-store')
Set-Content -Path (Join-Path $pkg 'VERSION') -Value "chromium=$version", "ucsyncExtension=$extVersion", "webstoreExtension=$wsVersion", "builtAt=$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm'))"
# El ejecutable se llama chromper.exe; install_windows.ps1 deja también chrome.exe en la instalación
# por si algún componente busca al motor por su nombre original.
if (Test-Path (Join-Path $pkg 'chrome.exe')) { Rename-Item (Join-Path $pkg 'chrome.exe') 'chromper.exe' }
if (-not (Test-Path (Join-Path $pkg 'chromper.exe'))) { throw 'No hay chromper.exe en el paquete.' }

New-Item -ItemType Directory -Path $Out | Out-Null
$stable = Join-Path $Out 'chromper-windows-x64.zip'
$versioned = Join-Path $Out "chromper-windows-x64-$version.zip"
Compress-Archive -Path $pkg -DestinationPath $stable -CompressionLevel Optimal
Copy-Item $stable $versioned
Remove-Item -Recurse -Force $stage
Write-Host "[$stable] $([math]::Round((Get-Item $stable).Length/1MB,1)) MB"
Write-Host "[$versioned]"
