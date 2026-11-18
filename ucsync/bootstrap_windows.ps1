# Construye Chromper (Chromium + UC-Sync integrado) en Windows 11.
#
# Pasos (se pueden ejecutar por separado y son reanudables):
#   .\bootstrap_windows.ps1 -Step check     # diagnostico de la maquina
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
  [ValidateSet('check','install','paginacion','clone','build','package','publish','install-chromper','all')][string]$Step = 'check',
  [string]$Workspace = 'C:\chromper',
  [int]$Jobs = 0,
  [switch]$Fresh
  [string]$Fork = 'https://github.com/dr0per250/ungoogled-chromium-ucsync.git',
  [string]$ForkBranch = 'master',
  [string]$WindowsRepo = 'https://github.com/ungoogled-software/ungoogled-chromium-windows.git'
)
$ErrorActionPreference = 'Stop'

# winget y los instaladores no dejan siempre su PATH visible en la terminal abierta: se localizan
# las herramientas en sus carpetas estandar y se anaden al PATH de esta sesion (y al del usuario).
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
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  foreach ($d in $candidatos) {
    if (-not ($actual | Where-Object { $_ -ieq $d })) {
      $env:Path = $env:Path + ';' + $d
      Write-Host "  anadido al PATH: $d"
    }
    if ($userPath -and -not (($userPath -split ';') | Where-Object { $_ -ieq $d })) {
      [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $d), 'User')
    }
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

# El disco del workspace tiene que existir; si no, se listan los que hay para elegir otro.
function Comprobar-Workspace($ruta) {
  $letra = ([System.IO.Path]::GetPathRoot($ruta)).TrimEnd('\').TrimEnd(':')
  $drv = Get-PSDrive -Name $letra -ErrorAction SilentlyContinue
  if (-not $drv) {
    Write-Host "  el disco $letra no existe en esta maquina. Disponibles:"
    Get-PSDrive -PSProvider FileSystem | ForEach-Object {
      $gb = [math]::Round($_.Free / 1GB)
      Write-Host ("    {0}:  {1} GB libres" -f $_.Name, $gb)
    }
    throw "usa -Workspace C:\chromper (u otro disco de la lista)"
  }
  $libre = [math]::Round($drv.Free / 1GB)
  Write-Host "  workspace: $ruta (${letra}: $libre GB libres)"
  if ($libre -lt 90) { Write-Warning "para compilar hacen falta ~120 GB libres y quedan $libre GB" }
}
Comprobar-Workspace $Workspace

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
  Banner 'Diagnostico'
  & (Join-Path $PSScriptRoot 'diagnose_windows.ps1') -Workspace $Workspace
}

# ---------------------------------------------------------------- install
function Paso-Install {
  Banner 'Instalando dependencias'
  $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) { throw 'Ejecuta este paso en PowerShell como administrador (winget y rutas largas).' }

  Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1
  Write-Host '  rutas largas activadas (LongPathsEnabled=1)'

  function Winget-sano {
    try { & winget --version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } catch { $false }
  }
  function Descargar-e-instalar($url, $archivo, $argList) {
    $destino = Join-Path $env:TEMP $archivo
    Write-Host "  descargando $archivo"
    Write-Host "    $url"
    Invoke-WebRequest -Uri $url -OutFile $destino -UseBasicParsing
    $p = Start-Process $destino -ArgumentList $argList -Wait -PassThru
    Write-Host "    codigo de salida $($p.ExitCode)"
  }
  # winget suele venir roto en maquinas recien formateadas (0x8a15000f). Se intenta con winget y, si
  # falla, se descarga el instalador oficial: este paso no depende de que winget funcione.
  function Instalar($id, $esperado, $url, $archivo, $argList) {
    if (Test-Path $esperado) { Write-Host "  ya esta instalado: $esperado"; return }
    if (Winget-sano) {
      try { winget install -e --id $id 2>$null | Select-Object -Last 2 } catch { }
      if ($LASTEXITCODE -eq 0 -and (Test-Path $esperado)) { return }
      Write-Host "  winget no pudo con $id ($(& winget --version 2>&1 | Select-Object -First 1)): se usa el instalador oficial"
    }
    Descargar-e-instalar $url $archivo $argList
  }

  $gitUrl = $null
  try {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $gitUrl = ($rel.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1).browser_download_url
  } catch { Write-Warning 'no se pudo resolver la ultima version de Git for Windows' }
  if (-not $gitUrl) { $gitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' }

  Instalar 'Microsoft.VisualStudio.2022.BuildTools' "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" `
    'https://aka.ms/vs/17/release/vs_BuildTools.exe' 'vs_BuildTools.exe' `
    @('--quiet','--wait','--norestart','--add','Microsoft.VisualStudio.Workload.VCTools','--add','Microsoft.VisualStudio.Component.Windows11SDK.22621','--includeRecommended')
  Instalar 'Git.Git' "$env:ProgramFiles\Git\cmd\git.exe" $gitUrl 'Git-64-bit.exe' @('/VERYSILENT','/NORESTART')
  Instalar 'Python.Python.3.12' "$env:ProgramFiles\Python312\python.exe" `
    'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe' 'python-3.12.7-amd64.exe' `
    @('/quiet','InstallAllUsers=1','PrependPath=1','Include_test=0')
  Instalar '7zip.7zip' "$env:ProgramFiles\7-Zip\7z.exe" 'https://www.7-zip.org/a/7z2409-x64.exe' '7z-x64.exe' @('/S')

  $py = Buscar-Exe 'python.exe' @("$env:ProgramFiles\Python312", "$env:ProgramFiles\Python313", "$env:LOCALAPPDATA\Programs\Python\Python312", "$env:LOCALAPPDATA\Programs\Python\Python313")
  if (-not $py) {
    $lanzador = Buscar-Exe 'py.exe' @("$env:LOCALAPPDATA\Programs\Python\Launcher", 'C:\Windows')
    if ($lanzador) { $py = $lanzador }
  }
  if ($py) {
    Write-Host "  modulos de Python que usan los scripts de construccion ($py):"
    if ($py -like '*py.exe') { & $py -3 -m pip install --upgrade pip | Out-Null; & $py -3 -m pip install 'httplib2==0.22.0' 'clang==21.1.7' }
    else { & $py -m pip install --upgrade pip | Out-Null; & $py -m pip install 'httplib2==0.22.0' 'clang==21.1.7' }
  } else {
    Write-Warning 'Python instalado pero no localizado: busca C:\Program Files\Python312 o usa el lanzador py -3.'
  }

  Preparar-Path
  Write-Host '  git:  ' (Buscar-Exe 'git.exe' @("$env:ProgramFiles\Git\cmd"))
  Write-Host '  Listo. Si acabas de instalar algo, abre una terminal nueva antes de -Step clone.'
}

# ---------------------------------------------------------------- paginacion
function Paso-Paginacion {
  Banner 'Archivo de paginacion'
  # El enlazado de Chromium pide varios GB de golpe; con 16 GB de RAM hace falta paginacion holgada.
  # La asignacion se hace con Set-CimInstance (asignar la propiedad al objeto de Get-WmiObject falla).
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem
  if ($cs.AutomaticPagefileManagement) {
    Write-Host '  Windows ya administra el archivo de paginacion'
  } else {
    try {
      Set-CimInstance -InputObject $cs -Property @{ AutomaticPagefileManagement = $true }
      Write-Host '  activada la gestion automatica: hace falta reiniciar para que surta efecto'
    } catch {
      Write-Warning "no se pudo activar la gestion automatica ($($_.Exception.Message)). Fijalo a mano en: Sistema > Acerca de > Configuracion avanzada > Rendimiento (Configurar) > Avanzado > Archivo de paginacion (8192-32768 MB en C:)"
    }
  }
  $uso = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  if ($uso) {
    foreach ($u in $uso) { Write-Host ("  {0}: asignado {1} MB, en uso {2} MB" -f $u.Name, $u.AllocatedBaseSize, $u.CurrentUsage) }
    if ($uso[0].AllocatedBaseSize -lt 8192) { Write-Warning 'con menos de 8 GB asignados el enlazado puede fallar; reinicia despues de cambiarlo' }
  } else { Write-Warning 'no hay archivo de paginacion activo' }
}

# ---------------------------------------------------------------- clone
function Paso-Clone {
  Banner 'Clonando el constructor de Windows y apuntandolo a Chromper'
  $git = Buscar-Exe 'git.exe' @("$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")
  if (-not $git) { throw 'No se encuentra git.exe (winget install -e --id Git.Git y abre una terminal nueva). Instalado pero sin PATH: anade C:\Program Files\Git\cmd.' }
  Write-Host "  git: $git"
  if (-not (Test-Path (Join-Path $windows '.git'))) {
    git clone --recurse-submodules $WindowsRepo $windows
  } else {
    Write-Host '  el repositorio ya esta clonado, actualizando'
    git -C $windows fetch --all --tags --prune | Out-Null
  }

  $sub = Join-Path $windows 'ungoogled-chromium'
  if (-not (Test-Path (Join-Path $sub '.git'))) {
    git -C $windows submodule update --init --recursive
  }
  Write-Host "  el submodulo ungoogled-chromium se apunta a $Fork ($ForkBranch)"
  git -C $sub fetch --depth 1 $Fork $ForkBranch
  git -C $sub checkout -q -B chromper FETCH_HEAD

  $serie = Join-Path $sub 'patches\series'
  $nuestros = @(Select-String -Path $serie -Pattern 'extra/ucsync/').Count
  if ($nuestros -lt 7) { throw "la serie solo trae $nuestros parches de ucsync (esperados  7): el fork apunta a la rama correcta?" }
  Write-Host "  serie con $nuestros parches propios  y Chromium fijado en $(LeerVersion)"

  $paquete = Join-Path $sub 'ucsync\package_windows.ps1'
  if (-not (Test-Path $paquete)) { throw 'no esta ucsync/package_windows.ps1 en el fork' }
  Write-Host '  empaquetador de Chromper disponible '
}

# ---------------------------------------------------------------- build
function Paso-Build {
  Banner 'Descargando Chromium, parcheando y compilando'
  if (-not (Test-Path (Join-Path $windows 'build.py'))) { throw 'falta el repositorio: ejecuta -Step clone' }

  # depot_tools llama a `python3`, y el alias de la Tienda (%LOCALAPPDATA%\Microsoft\WindowsApps) lo
  # tapaba con un ejecutable que no hace nada (gclient.bat devolvia 9009). Se quitan WindowsApps del
  # PATH de esta sesion, se pone Python real primero y se deja un python3.exe junto a python.exe.
  $env:Path = (@($env:Path -split ';' | Where-Object { $_ -and $_ -notlike '*WindowsApps*' }) -join ';')
  $pyRuta = Buscar-Exe 'python.exe' @("$env:ProgramFiles\Python312", "$env:ProgramFiles\Python313", "$env:LOCALAPPDATA\Programs\Python\Python312")
  if ($pyRuta) {
    $pyDir = Split-Path -Parent $pyRuta
    $env:Path = "$pyDir;$pyDir\Scripts;$env:Path"
    if (-not (Test-Path (Join-Path $pyDir 'python3.exe'))) {
      Copy-Item $pyRuta (Join-Path $pyDir 'python3.exe')
      Write-Host "  creado python3.exe en $pyDir (lo necesita depot_tools)"
    }
  }

  if ($Fresh) {
    Write-Host '  -Fresh: se borra build\src para repetir la preparacion desde cero'
    Remove-Item -Recurse -Force (Join-Path $windows 'build\src') -ErrorAction SilentlyContinue
  }
  $src = Join-Path $windows 'build\src'
  if ((Test-Path (Join-Path $src 'BUILD.gn')) -and -not (Test-Path (Join-Path $src 'third_party\ninja\ninja.exe'))) {
    Write-Warning 'la preparacion anterior quedo a medias (falta third_party\ninja): repite con -Step build -Fresh'
    throw 'build\src esta incompleto: usa -Step build -Fresh'
  }
  $nucleos = [int](Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
  $ramGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB)
  if ($Jobs -le 0) {
    # Cada clang come ~0.6 GB y el enlazado pide varios GB de golpe: con poca RAM se bajan los hilos.
    $Jobs = [math]::Min($nucleos, [math]::Max(4, [math]::Floor($ramGB * 0.9)))
    Write-Host "  $nucleos nucleos, $ramGB GB de RAM -> $Jobs hilos (puedes forzar con -Jobs)"
  }
  $pagina = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  if ($pagina) {
    Write-Host ("  archivo de paginacion: {0}  asignado {1} MB (maximo {2} MB)" -f $pagina.Name, $pagina.CurrentUsage, $pagina.AllocatedBaseSize)
  }
  if ($ramGB -lt 16 -and (-not $pagina -or $pagina.AllocatedBaseSize -lt 24576)) {
    Write-Warning "con $ramGB GB de RAM y una paginacion de $([math]::Round($pagina.AllocatedBaseSize/1024)) GB el enlazado de Chromium se queda corto"
    Write-Host '   Solucion (Windows administra el archivo de paginacion, y reinicia):'
    Write-Host '     (Get-WmiObject Win32_ComputerSystem).AutomaticPagefileManagement = $true'
    Write-Host '   o a mano: Sistema > Acerca de > Configuracion avanzada > Rendimiento (Configurar) > Avanzado > Archivo de paginacion > TAMANIO personalizado 8192-32768 MB en C:'
  }
  $py = Buscar-Exe 'python.exe' @("$env:ProgramFiles\Python313", "$env:ProgramFiles\Python312", "$env:LOCALAPPDATA\Programs\Python\Python312")
  if (-not $py) {
    $pyLauncher = Buscar-Exe 'py.exe' @("$env:LOCALAPPDATA\Programs\Python\Launcher", "C:\Windows")
    if (-not $pyLauncher) { throw 'No se encuentra python: ejecuta -Step install (winget install -e --id Python.Python.3.12) y abre una terminal nueva.' }
    $py = $pyLauncher + ' -3'
  }
  Write-Host "  python: $py"
  Write-Host "  $Jobs hilos. Para que el equipo no se duerma a mitad: powercfg /change standby-timeout-ac 0"
  Write-Host '  Este paso descarga ~10 GB de dependencias y compila durante horas; el registro va a '
  Write-Host "  $registro"
  Push-Location $windows
  try {
    # build.py llama a vcvars64 por su cuenta y usa DEPOT_TOOLS_WIN_TOOLCHAIN=0 (compila con el
    # Visual Studio instalado en esta maquina, no con el toolchain de Google).
    if ($py -like '*py.exe*') { & py -3 build.py -j $Jobs } else { & $py build.py -j $Jobs }
    if ($LASTEXITCODE -ne 0) { throw "build.py termino con codigo $LASTEXITCODE (mira $registro)" }
  } finally { Pop-Location }
  $exe = Join-Path $windows 'build\src\out\Default\chrome.exe'
  if (-not (Test-Path $exe)) { $exe = Join-Path $windows 'build\src\out\Release\chrome.exe' }
  if (-not (Test-Path $exe)) { throw 'no aparecio chrome.exe en out\Default ni out\Release' }
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
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'falta gh (instala GitHub CLI y ejecuta gh auth login)' }
  $ver = LeerVersion
  if (-not $ver) { throw 'no se lee chromium_version.txt: ejecuta -Step clone' }
  $zip = Join-Path $Workspace 'pkg\chromper-windows-x64.zip'
  if (-not (Test-Path $zip)) { throw "no existe ${zip}: ejecuta -Step package" }
  gh release upload "chromium-$ver" $zip -R dr0per250/ungoogled-chromium-ucsync --clobber
  $json = (gh release view "chromium-$ver" -R dr0per250/ungoogled-chromium-ucsync --json assets | Out-String)
  try {
    ($json | ConvertFrom-Json).assets | ForEach-Object {
      Write-Host ("  {0}  {1} MB" -f $_.name, [math]::Round($_.size / 1MB))
    }
  } catch { Write-Host $json }
}

# ---------------------------------------------------------------- install-chromper
function Paso-Instalar {
  Banner 'Instalando Chromper en esta maquina'
  $zip = Join-Path $Workspace 'pkg\chromper-windows-x64.zip'
  if (-not (Test-Path $zip)) { throw "no existe ${zip}: ejecuta -Step package" }
  & (Join-Path $windows 'ungoogled-chromium\ucsync\install_windows.ps1') -Zip $zip
}

switch ($Step) {
  'check' { Paso-Check }
  'install' { Paso-Install }
  'paginacion' { Paso-Paginacion }
  'clone' { Paso-Clone }
  'build' { Paso-Build }
  'package' { Paso-Package }
  'publish' { Paso-Publish }
  'install-chromper' { Paso-Instalar }
  'all' { Paso-Check; Paso-Clone; Paso-Build; Paso-Package }
}
try { Stop-Transcript | Out-Null } catch { }
