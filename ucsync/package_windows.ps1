# Empaqueta el navegador UC-Sync compilado en Windows (x64) en un zip listo para instalar.
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
  [string]$Locales = "es-ES es-MX en-US pt-BR fr de it gl ca ja zh-CN ru"
)
$ErrorActionPreference = 'Stop'
$fork = Split-Path -Parent $PSScriptRoot
$build = Join-Path $Src 'out\Release'
if (-not (Test-Path (Join-Path $build 'chrome.exe'))) {
  throw "No hay chrome.exe en $build (ejecuta gn gen + ninja -C out\Release chrome)"
}
$version = (Get-Content (Join-Path $fork 'chromium_version.txt')).Trim()

$stage = Join-Path $env:TEMP ("ucsync-win-" + [guid]::NewGuid().ToString('N'))
$pkg = Join-Path $stage 'ucsync-chromium'
New-Item -ItemType Directory -Path $pkg | Out-Null

$files = 'chrome.exe','resources.pak','chrome_100_percent.pak','chrome_200_percent.pak',
         'icudtl.dat','v8_context_snapshot.bin','libEGL.dll','libGLESv2.dll',
         'chrome_crashpad_handler.exe'
foreach ($f in $files) {
  $p = Join-Path $build $f
  if (Test-Path $p) { Copy-Item $p $pkg }
}
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

$embedded = Join-Path $Src 'chrome\browser\resources\ucsync'
if (Test-Path $embedded) {
  Copy-Item -Recurse $embedded (Join-Path $pkg 'ucsync')
} else {
  Write-Warning 'No hay recursos de UC-Sync en el árbol (falta el parche 0003).'
}

$extVersion = 'n/d'
$manifest = Join-Path $pkg 'ucsync\manifest.json'
if (Test-Path $manifest) { $extVersion = (Get-Content $manifest -Raw | ConvertFrom-Json).version }
Set-Content -Path (Join-Path $pkg 'VERSION') -Value "chromium=$version", "ucsyncExtension=$extVersion", "builtAt=$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm'))"

New-Item -ItemType Directory -Path $Out | Out-Null
$stable = Join-Path $Out 'ucsync-chromium-windows-x64.zip'
$versioned = Join-Path $Out "ucsync-chromium-windows-x64-$version.zip"
Compress-Archive -Path $pkg -DestinationPath $stable -CompressionLevel Optimal
Copy-Item $stable $versioned
Remove-Item -Recurse -Force $stage
Write-Host "[$stable] $([math]::Round((Get-Item $stable).Length/1MB,1)) MB"
Write-Host "[$versioned]"
