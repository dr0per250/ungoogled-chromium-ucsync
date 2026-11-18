# Construye Chromper (Chromium + UC-Sync integrado) en Windows 11.
#
# Pasos (se pueden ejecutar por separado y son reanudables):
#   .\bootstrap_windows.ps1 -Step check     # diagnóstico de la máquina
#   .\bootstrap_windows.ps1 -Step install   # instala lo que falte con winget (como administrador)
#   .\bootstrap_windows.ps1 -Step clone     # clona ungoogled-chromium-windows y lo apunta a nuestro fork
#   .\bootstrap_windows.ps1 -Step build     # descarga Chromium, parchea y compila (horas)
#   .\bootstrap_windows.ps1 -Step package   # genera chromper-windows-x64.zip
#   .\bootstrap_windows.ps1 -Step publish   # sube el zip al release (necesita `gh auth login`)
#   .\bootstrap_windows.ps1 -Step install-chromper   # instala el zip en %LOCALAPPDATA%\chromper
#
# Uso normal (PowerShell como administrador, disco con ~120 GB libres):
#   $env:CHROMPER_BRANCH='master'
#   .\bootstrap_windows.ps1 -Step all -Workspace D:\chromper
#
# El registro de todo queda en <Workspace>\registro.txt (Start-Transcript), que es lo que hay que
# pegar si algo falla.
param(
  [ValidateSet('check','install','clone','build','package','publish','install-chromper','all')][string]$Step = 'check',
  [string]$Workspace = 'C:\chromper',
  [int]$Jobs = 0,
  [string]$Fork = 'https://github.com/dr0per250/ungoogled-chromium-ucsync.git',
  [string]$ForkBranch = 'master',
  [string]$WindowsRepo = 'https://github.com/ungoogled-software/ungoogled-chromium-windows.git'
)
$ErrorActionPreference = 'Stop'

$windows = Join-Path $Workspace 'windows'
$registro = Join-Path $Workspace 'registro.txt'
New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
try { Start-Transcript -Path $registro -Append | Out-Null } catch { }

function Banner($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

$version = $null
function LeerVersion {
  $f = Join-Path $windows 'ungoogled-chromium\chromium_version.txt'
  if (Test-Path $f) { (Get-Content $f).Trim() } else { $null }
}

# ---------------------------------------------------------------- check
function Paso-Check {
  Banner 'Diagnóstico'
  & (Join-Path $PSScriptRoot 'diagnose_windows.ps1') -Workspace $Workspace
}

# ---------------------------------------------------------------- install
function Paso-Install {
  Banner 'Instalando dependencias'
  $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) { throw 'Ejecuta este paso en PowerShell como administrador (winget y rutas largas).' }

  Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1
  Write-Host '  rutas largas activadas (LongPathsEnabled=1)'

  function Instalar($id, $override = '') {
    $ya = winget list -e --id $id 2>&1 | Select-String -SimpleMatch $id
    if ($ya) { Write-Host "  ya está instalado: $id"; return }
    if ($override) { winget install -e --id $id --override $override }
    else { winget install -e --id $id }
  }

  Instalar 'Microsoft.VisualStudio.2022.BuildTools' '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended'
  Instalar 'Git.Git'
  Instalar 'Python.Python.3.12'
  Instalar '7zip.7zip'

  Write-Host '  módulos de Python que usan los scripts de construcción:'
  python -m pip install --upgrade pip | Out-Null
  python -m pip install 'httplib2==0.22.0' 'clang==21.1.7'

  Write-Host '  Reinicia el terminal para que git/python/7z queden en el PATH, y vuelve con -Step clone.'
}

# ---------------------------------------------------------------- clone
function Paso-Clone {
  Banner 'Clonando el constructor de Windows y apuntándolo a Chromper'
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Falta git: ejecuta -Step install o instala Git for Windows.' }
  if (-not (Test-Path (Join-Path $windows '.git'))) {
    git clone --recurse-submodules $WindowsRepo $windows
  } else {
    Write-Host '  el repositorio ya está clonado, actualizando'
    git -C $windows fetch --all --tags --prune | Out-Null
  }

  $sub = Join-Path $windows 'ungoogled-chromium'
  if (-not (Test-Path (Join-Path $sub '.git'))) {
    git -C $windows submodule update --init --recursive
  }
  Write-Host "  el submódulo ungoogled-chromium se apunta a $Fork ($ForkBranch)"
  git -C $sub fetch --depth 1 $Fork $ForkBranch
  git -C $sub checkout -q -B chromper FETCH_HEAD

  $serie = Join-Path $sub 'patches\series'
  $nuestros = @(Select-String -Path $serie -Pattern 'extra/ucsync/').Count
  if ($nuestros -lt 7) { throw "la serie sólo trae $nuestros parches de ucsync (esperados ≥ 7): ¿el fork apunta a la rama correcta?" }
  Write-Host "  serie con $nuestros parches propios ✓ y Chromium fijado en $(LeerVersion)"

  $paquete = Join-Path $sub 'ucsync\package_windows.ps1'
  if (-not (Test-Path $paquete)) { throw 'no está ucsync/package_windows.ps1 en el fork' }
  Write-Host '  empaquetador de Chromper disponible ✓'
}

# ---------------------------------------------------------------- build
function Paso-Build {
  Banner 'Descargando Chromium, parcheando y compilando'
  if (-not (Test-Path (Join-Path $windows 'build.py'))) { throw 'falta el repositorio: ejecuta -Step clone' }
  if ($Jobs -le 0) { $Jobs = [int](Get-CimInstance Win32_Processor).NumberOfLogicalProcessors }
  Write-Host "  $Jobs hilos. Para que el equipo no se duerma a mitad: powercfg /change standby-timeout-ac 0"
  Write-Host '  Este paso descarga ~10 GB de dependencias y compila durante horas; el registro va a '
  Write-Host "  $registro"
  Push-Location $windows
  try {
    # build.py llama a vcvars64 por su cuenta y usa DEPOT_TOOLS_WIN_TOOLCHAIN=0 (compila con el
    # Visual Studio instalado en esta máquina, no con el toolchain de Google).
    python build.py -j $Jobs
    if ($LASTEXITCODE -ne 0) { throw "build.py terminó con código $LASTEXITCODE (mira $registro)" }
  } finally { Pop-Location }
  $exe = Join-Path $windows 'build\src\out\Default\chrome.exe'
  if (-not (Test-Path $exe)) { $exe = Join-Path $windows 'build\src\out\Release\chrome.exe' }
  if (-not (Test-Path $exe)) { throw 'no apareció chrome.exe en out\Default ni out\Release' }
  Write-Host "  navegador compilado: $exe"
  & $exe --version 2>&1 | Select-Object -First 1
}

# ---------------------------------------------------------------- package
function Paso-Package {
  Banner 'Empaquetando'
  $src = Join-Path $windows 'build\src'
  $paquete = Join-Path $windows 'ungoogled-chromium\ucsync\package_windows.ps1'
  $salida = Join-Path $Workspace 'pkg'
  New-Item -ItemType Directory -Path $salida -Force | Out-Null
  & $paquete -Src $src -Out $salida
  Get-ChildItem (Join-Path $salida 'chromper-windows-x64*.zip') | ForEach-Object {
    Write-Host ("  {0}  {1} MB" -f $_.Name, [math]::Round($_.Length / 1MB))
  }
}

# ---------------------------------------------------------------- publish
function Paso-Publish {
  Banner 'Subiendo el zip al release'
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'falta gh (winget install -e --id GitHub.cli && gh auth login)' }
  $ver = LeerVersion
  if (-not $ver) { throw 'no se lee chromium_version.txt: ejecuta -Step clone' }
  $zip = Join-Path $Workspace 'pkg\chromper-windows-x64.zip'
  if (-not (Test-Path $zip)) { throw "no existe $zip: ejecuta -Step package" }
  gh release upload "chromium-$ver" $zip -R dr0per250/ungoogled-chromium-ucsync --clobber
  gh release view "chromium-$ver" -R dr0per250/ungoogled-chromium-ucsync --json assets --jq '.assets[] | "\(.name) \(.size)"'
}

# ---------------------------------------------------------------- install-chromper
function Paso-Instalar {
  Banner 'Instalando Chromper en esta máquina'
  $zip = Join-Path $Workspace 'pkg\chromper-windows-x64.zip'
  if (-not (Test-Path $zip)) { throw "no existe $zip: ejecuta -Step package" }
  & (Join-Path $windows 'ungoogled-chromium\ucsync\install_windows.ps1') -Zip $zip
}

switch ($Step) {
  'check' { Paso-Check }
  'install' { Paso-Install }
  'clone' { Paso-Clone }
  'build' { Paso-Build }
  'package' { Paso-Package }
  'publish' { Paso-Publish }
  'install-chromper' { Paso-Instalar }
  'all' { Paso-Check; Paso-Clone; Paso-Build; Paso-Package }
}
try { Stop-Transcript | Out-Null } catch { }
