# Diagnostico de la maquina Windows para compilar Chromper. Solo lee, no cambia nada.
#
# Uso (PowerShell):
#   .\diagnose_windows.ps1
#   .\diagnose_windows.ps1 -Workspace D:\chromper
param([string]$Workspace = 'C:\chromper')
$ErrorActionPreference = 'SilentlyContinue'

# winget y los instaladores no dejan siempre su PATH visible en la terminal abierta: se localizan
# las herramientas en sus carpetas estandar y se anaden al PATH de esta sesion.
function Preparar-Path {
  $candidatos = @(
    "$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd",
    "$env:LOCALAPPDATA\Programs\Git\cmd", "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
    "$env:ProgramFiles\Python313", "$env:ProgramFiles\Python312", "$env:ProgramFiles\Python311",
    "$env:ProgramFiles\Python312\Scripts",
    "$env:LOCALAPPDATA\Programs\Python\Python313", "$env:LOCALAPPDATA\Programs\Python\Python312",
    "$env:ProgramFiles\7-Zip", "${env:ProgramFiles(x86)}\7-Zip",
    "$env:ProgramFiles\GitHub CLI"
  ) | Where-Object { $_ -and (Test-Path $_) }
  $actual = @($env:Path -split ';')
  foreach ($d in $candidatos) {
    if (-not ($actual | Where-Object { $_ -ieq $d })) { $env:Path = $env:Path + ';' + $d }
  }
}
function Buscar-Exe($exe, $raices) {
  # El alias de la Tienda (WindowsApps\python.exe) no ejecuta nada: se ignoran esas rutas.
  $c = Get-Command $exe -ErrorAction SilentlyContinue
  if ($c -and $c.Source -notlike '*WindowsApps*') { return $c.Source }
  foreach ($r in $raices) {
    if (-not $r -or -not (Test-Path $r)) { continue }
    $p = Get-ChildItem -Path (Join-Path $r $exe) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { return $p.FullName }
  }
  return $null
}
Preparar-Path

$ok = 0; $mal = 0
function Paso($txt) { Write-Host "   $txt"; ${script}:ok++ }
function Falta($txt) { Write-Host "   $txt"; ${script}:mal++ }
function Aviso($txt) { Write-Host "  ! $txt" }

Write-Host "== Sistema =="
$os = Get-CimInstance Win32_OperatingSystem
$arquitectura = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { '32 bits' }
Write-Host "  Windows $($os.Caption) build $([System.Environment]::OSVersion.Version.Build) - $arquitectura"
if ([System.Environment]::Is64BitOperatingSystem -and [System.Environment]::OSVersion.Version.Build -ge 19045) {
  Paso "Windows 10/11 x64 suficiente para compilar Chromium"
} else { Falta "Hace falta Windows 10 22H2 (build 19045) o superior, x64" }

$ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$libre = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
if ($ram -ge 16) { Paso "RAM ${ram} GB (libre ahora ${libre} GB)" } else { Falta "RAM ${ram} GB: con menos de 16 GB el enlazado de Chromium se queda corto" }
$nucleos = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
Write-Host "  Nucleos logicos: $nucleos (el build tarda horas; $([math]::Round(30000/$nucleos)) min es una buena senal)"

Write-Host "== Espacio en disco =="
$unidad = ([System.IO.Path]::GetPathRoot($Workspace)).TrimEnd('\')
$drv = Get-PSDrive -Name ($unidad.TrimEnd(':')) -ErrorAction SilentlyContinue
if (-not $drv) {
  Falta "el disco $unidad no existe; discos disponibles:"
  Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    $gb = [math]::Round($_.Free / 1GB)
    Write-Host ("      {0}:  {1} GB libres" -f $_.Name, $gb)
  }
  $libreGB = 0
} else {
  $libreGB = [math]::Round($drv.Free / 1GB)
}
if ($libreGB -ge 120) { Paso "$unidad libre ${libreGB} GB (fuente ~30 GB + cache ~10 GB + out ~35 GB)" }
elseif ($libreGB -ge 90) { Aviso "$unidad libre ${libreGB} GB: justo pero suele caber" }
else { Falta "$unidad libre ${libreGB} GB: hacen falta ~120 GB (usa -Workspace D:\chromper si hay otro disco)" }

Write-Host "== Herramientas =="
function Probar-Exe($nombre, $exe, $raices, $ayuda) {
  $ruta = Buscar-Exe $exe $raices
  if (-not $ruta) { Falta "${nombre}: no se encuentra $exe. $ayuda"; return $null }
  $v = & $ruta --version 2>&1 | Select-Object -First 1
  Paso "$nombre  $ruta  ($v)"
  return $ruta
}
$gitRuta = Probar-Exe 'Git' 'git.exe' @("$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd") 'winget install -e --id Git.Git, o anade C:\Program Files\Git\cmd al PATH'
$pyexe = Buscar-Exe 'python.exe' @("$env:ProgramFiles\Python313", "$env:ProgramFiles\Python312", "$env:ProgramFiles\Python311", "$env:LOCALAPPDATA\Programs\Python\Python312", "$env:LOCALAPPDATA\Programs\Python\Python313")
if (-not $pyexe) { $pyexe = Buscar-Exe 'py.exe' @("$env:LOCALAPPDATA\Programs\Python\Launcher", 'C:\Windows') }
if ($pyexe) {
  if ($pyexe -like '*WindowsApps*') { Aviso 'python resuelto es el alias de la Tienda (no ejecuta nada): instala Python con winget y desactiva las alias en App execution aliases' }
  if ($pyexe -like '*py.exe') { $v = & $pyexe -3 -c "import sys;print('.'.join(map(str,sys.version_info[:3])))" 2>&1 } else { $v = & $pyexe -c "import sys;print('.'.join(map(str,sys.version_info[:3])))" 2>&1 }
  Paso "Python  $pyexe ($v)"
  foreach ($mod in @(@('httplib2','httplib2==0.22.0'), @('clang.cindex','clang==21.1.7'))) {
    if ($pyexe -like '*py.exe') { & $pyexe -3 -m pip show ($mod[1] -split '==')[0] 2>&1 | Out-Null } else { & $pyexe -m pip show ($mod[1] -split '==')[0] 2>&1 | Out-Null }
    if ($LASTEXITCODE -eq 0) { Paso "modulo $($mod[0]) instalado" } else { Falta "modulo $($mod[0]) (pip install $($mod[1]))" }
  }
} else { Falta 'Python (winget install -e --id Python.Python.3.12)' }
$7z = @(Get-ChildItem "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe" | Select-Object -First 1)
if ($7z) { Paso "7-Zip  $($7z[0].FullName)" } else { Falta '7-Zip (winget install -e --id 7zip.7zip)' }
$winget = Get-Command winget
if ($winget) { Paso 'winget disponible (sirve para instalar lo que falte)' } else { Aviso 'sin winget: habra que instalar a mano desde https://learn.microsoft.com' }

Write-Host "== Visual Studio =="
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  $ruta = & $vswhere -products * -prerelease -latest -property installationPath 2>&1
  if ($ruta) {
    Paso "Visual Studio en $ruta"
    $vcvars = Join-Path $ruta 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path $vcvars) { Paso 'vcvars64.bat (compilador C++ de MSVC)' } else { Falta 'falta la carga de trabajo "C++ for Windows Desktop"' }
    $sdk = Get-ChildItem (Join-Path $ruta 'VC\Tools\MSVC') -Directory | Select-Object -First 1
    if ($sdk) { Paso "MSVC $($sdk.Name)" } else { Falta 'no hay toolchain MSVC instalada' }
  } else { Falta 'vswhere no encuentra ninguna instalacion de Visual Studio' }
} else { Falta 'vswhere.exe: no hay Visual Studio ni Build Tools' }
$kits = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue | ForEach-Object Name
if ($kits) { Paso "Windows SDK: $($kits -join ', ')" } else { Falta 'Windows SDK (se instala con las Build Tools)' }

Write-Host "== Rutas largas =="
$lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) { Paso 'LongPathsEnabled=1 (los scripts de construccion necesitan rutas > 260 caracteres)' }
else { Falta "LongPathsEnabled=$lp  se activa con (PowerShell como administrador):" ; Write-Host '      Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1' }

$esAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($esAdmin) { Paso 'PowerShell como administrador' } else { Aviso 'sin admin: para instalar dependencias y activar rutas largas vuelve a abrir PowerShell como administrador' }

$gh = Get-Command gh
if ($gh) { Paso "gh  $(& gh --version | Select-Object -First 1)" } else { Aviso 'sin gh: la subida del zip al release se puede hacer desde otra maquina' }

Write-Host ''
if ($mal -gt 0) {
  Write-Host "[diagnostico] $mal cosas en falta. Con winget se instalan de una vez:"
  Write-Host '  .\bootstrap_windows.ps1 -Step install'
  Write-Host '(ejecutalo en PowerShell como administrador)'
} else {
  Write-Host "[diagnostico] todo listo ($ok comprobaciones). Para empezar:"
  Write-Host "  .\bootstrap_windows.ps1 -Step clone -Workspace $Workspace"
}
Write-Host ''
Write-Host "Resumen para pegar en el chat:  Windows=$($os.Caption) build=$([System.Environment]::OSVersion.Version.Build) RAM=${ram}GB nucleos=$nucleos disco=$unidad libre=${libreGB}GB admin=$esAdmin longpaths=$lp faltan=$mal"
