# Diagnóstico de la máquina Windows para compilar Chromper. Sólo lee, no cambia nada.
#
# Uso (PowerShell):
#   .\diagnose_windows.ps1
#   .\diagnose_windows.ps1 -Workspace D:\chromper
param([string]$Workspace = 'C:\chromper')
$ErrorActionPreference = 'SilentlyContinue'

$ok = 0; $mal = 0
function Paso($txt) { Write-Host "  ✓ $txt"; $script:ok++ }
function Falta($txt) { Write-Host "  ✗ $txt"; $script:mal++ }
function Aviso($txt) { Write-Host "  ! $txt" }

Write-Host "== Sistema =="
$os = Get-CimInstance Win32_OperatingSystem
$arquitectura = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { '32 bits' }
Write-Host "  Windows $($os.Caption) build $([System.Environment]::OSVersion.Version.Build) · $arquitectura"
if ([System.Environment]::Is64BitOperatingSystem -and [System.Environment]::OSVersion.Version.Build -ge 19045) {
  Paso "Windows 10/11 x64 suficiente para compilar Chromium"
} else { Falta "Hace falta Windows 10 22H2 (build 19045) o superior, x64" }

$ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$libre = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
if ($ram -ge 16) { Paso "RAM ${ram} GB (libre ahora ${libre} GB)" } else { Falta "RAM ${ram} GB: con menos de 16 GB el enlazado de Chromium se queda corto" }
$nucleos = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
Write-Host "  Núcleos lógicos: $nucleos (el build tarda horas; $([math]::Round(30000/$nucleos)) min es una buena señal)"

Write-Host "== Espacio en disco =="
$unidad = ([System.IO.Path]::GetPathRoot($Workspace)).TrimEnd('\')
$drv = Get-PSDrive -Name ($unidad.TrimEnd(':'))
$libreGB = [math]::Round($drv.Free / 1GB)
if ($libreGB -ge 120) { Paso "$unidad libre ${libreGB} GB (fuente ~30 GB + caché ~10 GB + out ~35 GB)" }
elseif ($libreGB -ge 90) { Aviso "$unidad libre ${libreGB} GB: justo pero suele caber" }
else { Falta "$unidad libre ${libreGB} GB: hacen falta ~120 GB (usa -Workspace D:\chromper si hay otro disco)" }

Write-Host "== Herramientas =="
function Comandos($nombre, $exe) {
  $c = Get-Command $exe
  if ($c) { Paso "$nombre → $(& $exe --version 2>&1 | Select-Object -First 1)" } else { Falta "falta $nombre ($exe)" }
}
Comandos 'Git' 'git'
$py = Get-Command python
if ($py) {
  $v = & python -c "import sys;print('.'.join(map(str,sys.version_info[:3])))" 2>&1
  if ([version]$v -ge [version]'3.11') { Paso "Python $v" } else { Falta "Python $v: hace falta 3.11 o más nuevo" }
  & python -c "import httplib2" 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Paso 'módulo httplib2 instalado' } else { Falta 'módulo httplib2 (pip install httplib2==0.22.0)' }
  & python -c "import clang.cindex" 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Paso 'módulo clang (libclang) instalado' } else { Falta 'módulo clang (pip install clang==21.1.7)' }
} else { Falta 'Python (winget install -e --id Python.Python.3.12)' }
$7z = @(Get-ChildItem "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe" | Select-Object -First 1)
if ($7z) { Paso "7-Zip → $($7z[0].FullName)" } else { Falta '7-Zip (winget install -e --id 7zip.7zip)' }
$winget = Get-Command winget
if ($winget) { Paso 'winget disponible (sirve para instalar lo que falte)' } else { Aviso 'sin winget: habrá que instalar a mano desde https://learn.microsoft.com' }

Write-Host "== Visual Studio =="
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  $ruta = & $vswhere -products * -prerelease -latest -property installationPath 2>&1
  if ($ruta) {
    Paso "Visual Studio en $ruta"
    $vcvars = Join-Path $ruta 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path $vcvars) { Paso 'vcvars64.bat (compilador C++ de MSVC)' } else { Falta 'falta la carga de trabajo «C++ for Windows Desktop»' }
    $sdk = Get-ChildItem (Join-Path $ruta 'VC\Tools\MSVC') -Directory | Select-Object -First 1
    if ($sdk) { Paso "MSVC $($sdk.Name)" } else { Falta 'no hay toolchain MSVC instalada' }
  } else { Falta 'vswhere no encuentra ninguna instalación de Visual Studio' }
} else { Falta 'vswhere.exe: no hay Visual Studio ni Build Tools' }
$kits = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue | ForEach-Object Name
if ($kits) { Paso "Windows SDK: $($kits -join ', ')" } else { Falta 'Windows SDK (se instala con las Build Tools)' }

Write-Host "== Rutas largas =="
$lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) { Paso 'LongPathsEnabled=1 (los scripts de construcción necesitan rutas > 260 caracteres)' }
else { Falta "LongPathsEnabled=$lp → se activa con (PowerShell como administrador):" ; Write-Host '      Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1' }

$esAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($esAdmin) { Paso 'PowerShell como administrador' } else { Aviso 'sin admin: para instalar dependencias y activar rutas largas vuelve a abrir PowerShell como administrador' }

$gh = Get-Command gh
if ($gh) { Paso "gh → $(& gh --version | Select-Object -First 1)" } else { Aviso 'sin gh: la subida del zip al release se puede hacer desde otra máquina' }

Write-Host ''
if ($mal -gt 0) {
  Write-Host "[diagnóstico] $mal cosas en falta. Con winget se instalan de una vez:"
  Write-Host '  .\bootstrap_windows.ps1 -Step install'
  Write-Host '(ejecútalo en PowerShell como administrador)'
} else {
  Write-Host "[diagnóstico] todo listo ($ok comprobaciones). Para empezar:"
  Write-Host "  .\bootstrap_windows.ps1 -Step clone -Workspace $Workspace"
}
Write-Host ''
Write-Host "Resumen para pegar en el chat:  Windows=$($os.Caption) build=$([System.Environment]::OSVersion.Version.Build) RAM=${ram}GB núcleos=$nucleos disco=$unidad libre=${libreGB}GB admin=$esAdmin longpaths=$lp faltan=$mal"
