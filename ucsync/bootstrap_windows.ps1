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
  [ValidateSet('check','install','paginacion','clone','build','genbuild','package','publish','install-chromper','all')][string]$Step = 'check',
  [string]$Workspace = 'C:\chromper',
  [int]$Jobs = 0,
  [switch]$Fresh,
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

# Version del Windows SDK realmente instalada (con Include y Lib para x64), la mas alta disponible.
function Elegir-SDK($kits) {
  if (-not $kits) { return $null }
  $candidatas = Get-ChildItem (Join-Path $kits 'Include') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $kits "Lib\$($_.Name)\um\x64") } |
    Sort-Object { [version]$_.Name } -Descending
  if ($candidatas) { return $candidatas[0].Name }
  return $null
}

# Chromium busca VS 2022 en C:\Program Files\Microsoft Visual Studio\2022\*, pero las Build Tools
# quedan en C:\Program Files (x86)\..., y vs_toolchain.py aborta con "No supported Visual Studio can
# be found". Se le pasa la ruta real con vs2022_install, la version con GYP_MSVS_VERSION y el SDK con
# WINDOWSSDKDIR. Devuelve la ruta de vcvars64.bat.
function Preparar-VS {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vswhere)) { $vswhere = "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe" }
  $ruta = $null
  if (Test-Path $vswhere) {
    $ruta = & $vswhere -products * -prerelease -latest -property installationPath 2>&1 | Select-Object -First 1
  }
  if (-not $ruta) { $ruta = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools" }
  $env:vs2022_install = $ruta
  $env:GYP_MSVS_VERSION = '2022'
  $kits = @("${env:ProgramFiles(x86)}\Windows Kits\10", "$env:ProgramFiles\Windows Kits\10") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($kits) { $env:WINDOWSSDKDIR = $kits }
  $script:rutaVS = $ruta
  Write-Host "  vs2022_install = $ruta"
  if ($kits) { Write-Host "  WINDOWSSDKDIR = $kits" }
  return (Buscar-Exe 'vcvars64.bat' @("$ruta\VC\Auxiliary\Build"))
}

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
  # Las Build Tools se instalan en "Program Files (x86)" casi siempre, y el SDK queda en otra raiz: se
  # comprueban varias rutas candidatas en vez de una sola (si no, este paso reinstalaria en balde).
  function Esta-instalado($candidatas) {
    foreach ($c in @($candidatas)) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
  }
  function Instalar($id, $esperado, $url, $archivo, $argList) {
    $donde = Esta-instalado $esperado
    if ($donde) { Write-Host "  ya esta instalado: $donde"; return }
    if (Winget-sano) {
      try { winget install -e --id $id 2>$null | Select-Object -Last 2 } catch { }
      $donde = Esta-instalado $esperado
      if ($LASTEXITCODE -eq 0 -and $donde) { Write-Host "  instalado con winget: $donde"; return }
      Write-Host "  winget no pudo con $id ($(& winget --version 2>&1 | Select-Object -First 1)): se usa el instalador oficial"
    }
    Descargar-e-instalar $url $archivo $argList
    $donde = Esta-instalado $esperado
    if ($donde) { Write-Host "  instalado: $donde" } else { Write-Warning "sigue sin estar: $id" }
  }

  $gitUrl = $null
  try {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $gitUrl = ($rel.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1).browser_download_url
  } catch { Write-Warning 'no se pudo resolver la ultima version de Git for Windows' }
  if (-not $gitUrl) { $gitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' }

  Instalar 'Microsoft.VisualStudio.2022.BuildTools' @("$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat") `
    'https://aka.ms/vs/17/release/vs_BuildTools.exe' 'vs_BuildTools.exe' `
    @('--quiet','--wait','--norestart','--add','Microsoft.VisualStudio.Workload.VCTools','--add','Microsoft.VisualStudio.Component.Windows11SDK.22621','--add','Microsoft.VisualStudio.Component.VC.DiagnosticTools','--add','Microsoft.VisualStudio.Component.VC.ATL','--add','Microsoft.VisualStudio.Component.VC.ATLSRC','--includeRecommended')
  Instalar 'Git.Git' @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe") $gitUrl 'Git-64-bit.exe' @('/VERYSILENT','/NORESTART')
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
  Banner 'Archivo de paginacion (el enlazado de Chromium pide varios GB de golpe)'
  $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) { throw 'Ejecuta este paso como administrador (tocan HKLM).' }
  # Win32_ComputerSystem ya no expone AutomaticPagefileManagement en Windows 11 y Get-WmiObject
  # -EnableAllProperties no existe en todas las versiones de PowerShell: se escribe el valor
  # MultiString PagingFiles, que es lo que lee el gestor de sesion al arrancar (fija tamano y con
  # eso desactiva la autogestion). Hace falta reiniciar.
  $ruta = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
  $min = 16384
  $max = 32768
  $actual = (Get-ItemProperty -Path $ruta -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles
  Write-Host ('  actual: ' + $(if ($actual) { $actual -join ' | ' } else { '(autogestionado: sin entrada fija)' }))
  Set-ItemProperty -Path $ruta -Name PagingFiles -Value @("C:\pagefile.sys $min $max") -Type MultiString
  $nuevo = (Get-ItemProperty -Path $ruta -Name PagingFiles).PagingFiles
  Write-Host ('  dejado: ' + ($nuevo -join ' | ') + " (min $min MB, max $max MB)")
  $uso = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
  foreach ($u in $uso) { Write-Host ('  ahora mismo: {0} asignado {1} MB, en uso {2} MB' -f $u.Name, $u.AllocatedBaseSize, $u.CurrentUsage) }
  if (-not $uso -or $uso[0].AllocatedBaseSize -lt $min) { Write-Host '  REINICIA la maquina para que se aplique el tamano nuevo' }
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

# Chromium fija el SDK con el que compila en SDK_VERSION (en Chromium 157 es 10.0.28000.0). Si en
# esta maquina ese SDK no esta instalado, setup_toolchain.py re-invoca vcvarsall pidiendo un SDK
# inexistente y aborta. Se reescribe SDK_VERSION al SDK completo que hay en disco.
function Corregir-SDKVersion($arbol, $ver) {
  foreach ($f in @((Join-Path $arbol 'build\toolchain\win\setup_toolchain.py'), (Join-Path $arbol 'build\vs_toolchain.py'))) {
    if (-not (Test-Path $f)) { continue }
    $contenido = Get-Content $f -Raw
    if ($contenido -match "SDK_VERSION = '([^']+)'") {
      $actual = $Matches[1]
      if ($actual -ne $ver) {
        $contenido = $contenido -replace "SDK_VERSION = '[^']+'", "SDK_VERSION = '$ver'"
        Set-Content -Path $f -Value $contenido -Encoding ascii -NoNewline
        Write-Host "  SDK_VERSION: $actual -> $ver en $(Split-Path -Leaf $f)"
      } else {
        Write-Host "  SDK_VERSION ya es $ver en $(Split-Path -Leaf $f)"
      }
    }
  }
}

# Chromium copia dbghelp.dll (y dbgcore/symsrv, opcionales) desde Windows Kits\10\Debuggers\<cpu>.
# Ese directorio solo existe si se instalo "Debugging Tools for Windows" en el SDK. Si falta, se
# rellena con los DLL que ya trae Windows (System32/SysWOW64), que son los mismos que usa el sistema.
function Preparar-Debuggers($kits) {
  if (-not $kits) { return }
  $dirs = @('x64', 'x86')
  $origen = @{ 'x64' = "$env:SystemRoot\System32"; 'x86' = "$env:SystemRoot\SysWOW64" }
  foreach ($cpu in $dirs) {
    $destino = Join-Path $kits "Debuggers\$cpu"
    if (Test-Path (Join-Path $destino 'dbghelp.dll')) { continue }
    New-Item -ItemType Directory -Path $destino -Force | Out-Null
    foreach ($dll in 'dbghelp.dll', 'dbgcore.dll', 'symsrv.dll') {
      $p = Join-Path $origen[$cpu] $dll
      if (Test-Path $p) { Copy-Item $p $destino -Force }
    }
    if (Test-Path (Join-Path $destino 'dbghelp.dll')) {
      $desde = $origen[$cpu]
      Write-Host "  dbghelp.dll copiado de $desde a $destino (via oficial: instala 'Debugging Tools for Windows' en el SDK)"
    } else {
      Write-Warning "no hay dbghelp.dll en $origen[$cpu]: instala el SDK con "Debugging Tools for Windows""
    }
  }
}

# build.py copia el toolchain de Rust desde third_party/rust-toolchain-x64 (y x86/arm) a
# third_party/rust-toolchain y escribe INSTALLED_VERSION. Si la preparacion se interrumpio antes, a
# ninja le falta bindgen.exe. Esto hace lo mismo para poder reanudar.
function Preparar-Rust($arbol) {
  $dst = Join-Path $arbol 'third_party\rust-toolchain'
  if (Test-Path (Join-Path $dst 'bin\bindgen.exe')) { Write-Host '  rust-toolchain ya esta completo'; return }
  New-Item -ItemType Directory -Path (Join-Path $dst 'bin') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dst 'lib') -Force | Out-Null
  $es64 = [Environment]::Is64BitOperatingSystem
  # 1) Si los paquetes de Rust estan extraidos, copiar su contenido (bin/lib) al destino.
  foreach ($nombre in 'rust-toolchain-x64', 'rust-toolchain-x86', 'rust-toolchain-arm') {
    $ori = Join-Path $arbol "third_party\$nombre"
    if (-not (Test-Path $ori)) { continue }
    foreach ($sub in 'bin', 'lib') {
      if ($sub -eq 'bin' -and ($es64 -ne ($nombre -eq 'rust-toolchain-x64'))) { continue }
      foreach ($item in @(Get-ChildItem -Path (Join-Path $ori "*$sub\*") -ErrorAction SilentlyContinue)) {
        $destino = Join-Path $dst "$sub\$($item.Name)"
        if ($item.PSIsContainer) { Copy-Item -Recurse -Force $item.FullName $destino -ErrorAction SilentlyContinue }
        else { Copy-Item -Force $item.FullName $destino -ErrorAction SilentlyContinue }
      }
    }
  }
  foreach ($item in @(Get-ChildItem -Path (Join-Path $arbol 'third_party\rust-toolchain-x64-dev\*\lib\*') -ErrorAction SilentlyContinue)) {
    Copy-Item -Recurse -Force $item.FullName (Join-Path $dst "lib\$($item.Name)") -ErrorAction SilentlyContinue
  }
  # 2) Si los directorios estan vacios porque los tar.gz no se extrajeron, extraerlos con 7-Zip
  #    desde la cache de descargas del constructor de Windows.
  $cache = Join-Path $windows 'build\download_cache'
  if ((Test-Path $cache) -and -not (Get-ChildItem (Join-Path $arbol 'third_party\rust-toolchain-x64\*') -ErrorAction SilentlyContinue)) {
    $siete = Buscar-Exe '7z.exe' @("$env:ProgramFiles\7-Zip", "${env:ProgramFiles(x86)}\7-Zip")
    if ($siete) {
      foreach ($par in @(@('rust-nightly-x86_64-pc-windows-msvc', 'rust-toolchain-x64'),
                         @('rust-nightly-i686-pc-windows-msvc', 'rust-toolchain-x86'),
                         @('rust-nightly-aarch64-pc-windows-msvc', 'rust-toolchain-arm'),
                         @('rustc-dev-nightly-x86_64-pc-windows-msvc', 'rust-toolchain-x64-dev'))) {
        $p = Get-ChildItem (Join-Path $cache "$($par[0])*") -Filter '*.tar.gz' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $p) { continue }
        $destino = Join-Path $arbol "third_party\$($par[1])"
        New-Item -ItemType Directory -Path $destino -Force | Out-Null
        Write-Host "  extrayendo $($p.Name) con 7-Zip en $destino"
        & $siete x -y "-o$destino" $p.FullName | Select-Object -Last 1
      }
    }
    # De nuevo la copia, ahora con el contenido extraido.
    foreach ($nombre in 'rust-toolchain-x64', 'rust-toolchain-x86', 'rust-toolchain-arm') {
      $ori = Join-Path $arbol "third_party\$nombre"
      foreach ($item in @(Get-ChildItem -Path (Join-Path $ori "*bin\*") -ErrorAction SilentlyContinue)) {
        Copy-Item -Force $item.FullName (Join-Path $dst "bin\$($item.Name)") -ErrorAction SilentlyContinue
      }
      foreach ($item in @(Get-ChildItem -Path (Join-Path $ori "*lib\*") -ErrorAction SilentlyContinue)) {
        Copy-Item -Recurse -Force $item.FullName (Join-Path $dst "lib\$($item.Name)") -ErrorAction SilentlyContinue
      }
    }
  }
  # 3) ltimo recurso: localizar bindgen.exe en cualquier parte del arbol de Rust y colocarlo.
  if (-not (Test-Path (Join-Path $dst 'bin\bindgen.exe'))) {
    $encontrado = Get-ChildItem (Join-Path $arbol 'third_party') -Recurse -Filter 'bindgen.exe' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($encontrado) {
      Copy-Item -Force $encontrado.FullName (Join-Path $dst 'bin\bindgen.exe')
      Write-Host "  bindgen.exe copiado de $($encontrado.FullName)"
    }
  }
  $rustc = Join-Path $arbol 'third_party\rust-toolchain-x64\rustc\bin\rustc.exe'
  if (Test-Path $rustc) { & $rustc --version | Set-Content -Path (Join-Path $dst 'INSTALLED_VERSION') -Encoding ascii }
  if (Test-Path (Join-Path $dst 'bin\bindgen.exe')) { Write-Host '  rust-toolchain preparado (bindgen.exe presente)' }
  else { Write-Host '  bindgen.exe no viene hecho: se compilara con tools\rust\build_bindgen.py antes de ninja' }
}

# Watchdog: un paso que deja de escribir en el registro durante N minutos esta congelado (el git.bat
# de depot_tools se quedo 2h24m esperando sin hacer nada). Se mata el arbol de procesos y se dice
# exactamente que hijo estaba colgado, en vez de quedarse mirando.
function Descendientes($ids) {
  $lista = @()
  foreach ($id in @($ids)) {
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -ErrorAction SilentlyContinue)) {
      $lista += $c
      $lista += Descendientes @($c.ProcessId)
    }
  }
  return $lista
}

# Ejecuta un .bat con vigilancia. En esta maquina Start-Process -Wait se cuelga al terminar el hijo y
# $p.ExitCode queda vacio, asi que (a) el log del paso va a un fichero propio, (b) el bat escribe su
# codigo en <log>.codigo y (c) se copia al registro lo que va saliendo, para la consola y para saber
# si el paso se ha estampado: un paso colgado deja de escribir.
function Ejecutar-Con-Vigilancia($bat, $logPaso, $registro, $minSinAvance, $maxMinutos) {
  $cod = "$logPaso.codigo"
  $err = "$logPaso.err"
  Remove-Item $logPaso, $err, $cod -ErrorAction SilentlyContinue
  $p = Start-Process cmd.exe -ArgumentList "/c `"$bat`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput $logPaso -RedirectStandardError $err
  $inicio = Get-Date
  $ultimo = Get-Date
  $ultimaCpu = 0.0
  $ultimoResumen = Get-Date
  while (-not $p.HasExited) {
    Start-Sleep -Seconds 20
    # el CPU tambien es avance: con la salida redirigida a fichero el buffer puede tardar en vaciarse
    $cpu = 0.0
    foreach ($h in @(Descendientes @($p.Id))) { $cpu += $h.UserProcessorTime.TotalSeconds }
    if ($cpu -gt $ultimaCpu) { $ultimo = Get-Date; $ultimaCpu = $cpu }
    if (((Get-Date) - $ultimoResumen).TotalMinutes -ge 1) {
      $ultimaResumen = Get-Date
      $cola = @(Get-Content $logPaso -Tail 1 -ErrorAction SilentlyContinue)
      $procs = @(Descendientes @($p.Id) | ForEach-Object { $_.Name } | Select-Object -Unique) -join ','
      Write-Host ('  avance: {0} | cpu acumulada {1} min | procesos: {2}' -f ($cola -join ''), [math]::Round($cpu / 60, 1), $procs)
    }
    if (Test-Path $logPaso) {
      # el registro lo tiene abierto Start-Transcript, asi que no se escribe dentro del bucle: se
      # muestra por consola (que va al transcript) al final del paso.
      $mt = (Get-Item $logPaso -ErrorAction SilentlyContinue).LastWriteTime
      if ($mt -gt $ultimo) { $ultimo = $mt }
    }
    foreach ($f in @($logPaso, $err)) {
      $mt = (Get-Item $f -ErrorAction SilentlyContinue).LastWriteTime
      if ($mt -gt $ultimo) { $ultimo = $mt }
    }
    $colgado = (Get-Date) - $ultimo
    if ($colgado.TotalMinutes -ge $minSinAvance) {
      $hijos = @(Descendientes @($p.Id))
      $desc = 'ningun hijo vivo'
      if ($hijos.Count -gt 0) { $desc = ($hijos | ForEach-Object { '{0} pid{1} :: {2}' -f $_.Name, $_.ProcessId, $_.CommandLine }) -join ' ;; ' }
      Write-Warning ('sin avance hace {0} min: se mata el proceso colgado' -f [math]::Round($colgado.TotalMinutes))
      foreach ($h in $hijos) { Stop-Process -Id $h.ProcessId -Force -ErrorAction SilentlyContinue }
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      throw "congelado $minSinAvance min sin escribir en $logPaso. Colgado: $desc"
    }
    if (((Get-Date) - $inicio).TotalMinutes -ge $maxMinutos) {
      foreach ($h in @(Descendientes @($p.Id))) { Stop-Process -Id $h.ProcessId -Force -ErrorAction SilentlyContinue }
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      throw "el paso supero $maxMinutos min y se interrumpio (mira $logPaso)"
    }
  }
  $codigo = (Get-Content $cod -Raw -ErrorAction SilentlyContinue).Trim()
  if (-not $codigo) { $codigo = 'desconocido' }
  Write-Host "  codigo del paso: $codigo (log en $logPaso)"
  if ($codigo -ne '0') {
    # se guarda el log del intento fallido: el siguiente intento pisa genbuild.log y sin esto no se
    # puede leer que fallo (cmd solo vacia el buffer al salir).
    Copy-Item $logPaso "$logPaso.fallo" -Force -ErrorAction SilentlyContinue
    Copy-Item $err "$logPaso.fallo.err" -Force -ErrorAction SilentlyContinue
    Get-Content "$logPaso.fallo" -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  | $_" }
    Get-Content "$logPaso.fallo.err" -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  ! $_" }
    # senal para el exterior: ALERTA.txt y firma.txt permiten que el runner pare tras dos fallos
    # iguales y que la consola/monitor remoto avise sin que nadie tenga que preguntar.
    $candidatos = @(Select-String -Path "$logPaso.fallo" -Pattern 'FAILED:|fatal error|error C[0-9]+|error: ' | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() })
    $firma = $candidatos -join ' ;; '
    if ($firma.Length -gt 300) { $firma = $firma.Substring(0, 300) }
    if ($firma -eq '') { $firma = ('codigo ' + $codigo + ' sin mensaje de error en ' + $logPaso) }
    # $registro es el fichero del transcript: el directorio es su padre (Join-Path sobre un fichero
    # daria C:\chromper\registro.txt\firma.txt, ruta que no existe).
    $carpeta = Split-Path $registro -Parent
    Set-Content -Path (Join-Path $carpeta 'firma.txt') -Encoding ascii -Value $firma
    Set-Content -Path (Join-Path $carpeta 'ALERTA.txt') -Encoding ascii -Value ("[{0}] paso {1} codigo {2} :: {3}" -f (Get-Date -Format 'HH:mm'), (Split-Path $logPaso -Leaf), $codigo, $firma)
    throw "el paso termino con codigo $codigo (mira $logPaso.fallo)"
  }
}

# Chromium 157 pide SDK 10.0.28000.0 y define NTDDI_VERSION=NTDDI_WIN11_BR. Con un SDK mas viejo (p.ej.
# 10.0.26100.0, el ultimo que ofrece el canal de Visual Studio 2022) ese simbolo no existe en
# sdkddkver.h, todas las comparaciones "NTDDI_VERSION >= ..." de los headers salen falsas y clang-cl
# peta con "unknown type name 'FILE_INFO_BY_HANDLE_CLASS'". Si el SDK del disco es anterior a 28000,
# se baja el nivel objetivo al NTDDI que si define ese SDK.
function Corregir-NTDDI($arbol, $ver) {
  if (-not $ver) { return }
  $partes = $ver.Split('.')
  if ($partes.Count -lt 3) { return }
  if ([int]$partes[2] -ge 28000) { Write-Host "  NTDDI: el SDK $ver tiene NTDDI_WIN11_BR, no se toca"; return }
  $gn = Join-Path $arbol 'build\config\win\BUILD.gn'
  if (-not (Test-Path $gn)) { return }
  $contenido = Get-Content $gn -Raw
  $ge = '"NTDDI_VERSION=NTDDI_WIN11_GE",'
  $alias = '    "NTDDI_WIN11_BR=NTDDI_WIN11_GE",'
  # base/win/windows_version.cc hace '#if !defined(NTDDI_WIN11_BR) #error Windows 10.0.28000.0 SDK or
  # higher required'. Con un SDK mas viejo: se baja NTDDI_VERSION a GE y se anade el alias
  # NTDDI_WIN11_BR=NTDDI_WIN11_GE (el #error pasa; las guardas '>= NTDDI_WIN11_BR' salen falsas).
  $contenido = $contenido -replace '"NTDDI_VERSION=NTDDI_WIN11_[A-Z]+",', $ge
  if ($contenido -notmatch [regex]::Escape($alias)) {
    $contenido = $contenido -replace [regex]::Escape($ge), ($ge + [Environment]::NewLine + $alias)
    Write-Host "  NTDDI: SDK $ver sin NTDDI_WIN11_BR -> NTDDI_VERSION=NTDDI_WIN11_GE + alias NTDDI_WIN11_BR en build\config\win\BUILD.gn"
  } else {
    Write-Host '  NTDDI: ya adaptado al SDK de esta maquina'
  }
  Set-Content -Path $gn -Value $contenido -Encoding ascii -NoNewline
}

function Paso-Genbuild {
  Banner 'gn gen + ninja (sin volver a clonar: sirve para reanudar donde fallo la preparacion)'
  $src = Join-Path $windows 'build\src'
  if (-not (Test-Path (Join-Path $src 'BUILD.gn'))) { throw 'no hay build\src: ejecuta -Step build' }
  $vcvars = Preparar-VS
  if (-not $vcvars) { throw 'no se encuentra vcvars64.bat (Visual Studio C++)' }

  # vcvars64 apunta al SDK mas reciente que cree instalado; si ese SDK esta a medias (hay entrada
  # pero no carpeta Include), setup_toolchain.py aborta con "Path ...\10.0.28000.0\um does not
  # exist". Se fijan INCLUDE/LIB al SDK que de verdad esta completo en el disco.
  $kits = $env:WINDOWSSDKDIR
  $sdkVer = Elegir-SDK $kits
  if (-not $sdkVer) { throw 'no hay ningun Windows SDK completo (falta Include\<ver>\um y Lib\<ver>\um\x64): instala uno desde el instalador de Visual Studio (Componentes individuales > Windows SDK).' }
  $msvcDir = Get-ChildItem (Join-Path $script:rutaVS 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
  if (-not $msvcDir) { throw 'no hay toolchain MSVC en la instalacion de Visual Studio' }
  $include = @("$($msvcDir.FullName)\include", "$kits\Include\$sdkVer\ucrt", "$kits\Include\$sdkVer\um", "$kits\Include\$sdkVer\shared", "$kits\Include\$sdkVer\winrt", "$kits\Include\$sdkVer\cppwinrt") -join ';'
  $lib = @("$($msvcDir.FullName)\lib\x64", "$kits\Lib\$sdkVer\um\x64", "$kits\Lib\$sdkVer\ucrt\x64") -join ';'
  Write-Host "  SDK usado: $sdkVer (MSVC $($msvcDir.Name))"
  Corregir-SDKVersion $src $sdkVer
  Corregir-NTDDI $src $sdkVer
  Preparar-Debuggers $kits
  Preparar-Rust $src
  $dia = Join-Path $script:rutaVS 'DIA SDK\bin\amd64\msdia140.dll'
  if (-not (Test-Path $dia)) {
    Write-Warning "falta el DIA SDK ($dia). En el instalador de Visual Studio: Modify > Componentes individuales > 'C++ Debugging Tools' (Microsoft.VisualStudio.Component.VC.DiagnosticTools)"
  }

  $out = Join-Path $src 'out\Default'
  if (-not (Test-Path (Join-Path $out 'args.gn'))) {
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    Copy-Item (Join-Path $windows 'flags.windows.gn') (Join-Path $out 'args.gn')
    Write-Host '  escrito out\Default\args.gn desde flags.windows.gn'
  }
  $bat = Join-Path $env:TEMP 'chromper_genbuild.bat'
  Set-Content -Path $bat -Encoding ascii -Value @(
    '@echo off'
    "call `"$vcvars`" >nul"
    "set INCLUDE=$include"
    "set LIB=$lib"
    "set WindowsSDKVersion=$sdkVer\"
    'set DEPOT_TOOLS_WIN_TOOLCHAIN=0'
    'set PATH=%CD%\uc_staging\depot_tools;%CD%\uc_staging\gn;%PATH%'
    # build_bindgen.py hace un `git clone`: si resuelve el git.bat de depot_tools se queda colgado
    # horas sin hacer nada, asi que dentro de este bat el git real del sistema va primero en el PATH
    # y nunca pregunta credenciales.
    'set GIT_TERMINAL_PROMPT=0'
    'set PATH=C:\Program Files\Git\cmd;%PATH%'
    'out\Default\gn.exe gen out\Default --fail-on-unused-args'
    'if errorlevel 1 goto fallo'
    # bindgen y Crubit no vienen hechos: build.py los compila aqui, despues de gn gen y antes de ninja
    'if not exist "third_party\rust-toolchain\bin\bindgen.exe" python tools\rust\build_bindgen.py --skip-test'
    'if errorlevel 1 goto fallo'
    'if not exist "third_party\rust-toolchain\crubit\bin" mkdir "third_party\rust-toolchain\crubit\bin"'
    'if not exist "third_party\rust-toolchain\crubit\bin\cc_bindings_from_rs.exe" ('
    'set RUSTC=%CD%\third_party\rust-toolchain\bin\rustc.exe'
    'set CARGO_HOME=%CD%\out\crubit\cargo_home'
    'set RUSTFLAGS=-Ctarget-feature=+crt-static'
    '"%CD%\third_party\rust-toolchain\bin\cargo.exe" build --release --locked -p cc_bindings_from_rs --bin cc_bindings_from_rs --manifest-path "third_party\rust-toolchain\crubit\lib\third_party\crubit\Cargo.toml" --target-dir "%CD%\out\crubit"'
    ')'
    'if not exist "third_party\rust-toolchain\crubit\bin\cc_bindings_from_rs.exe" copy /y "out\crubit\release\cc_bindings_from_rs.exe" "third_party\rust-toolchain\crubit\bin\" >nul'
    'if not exist "third_party\rust-toolchain\crubit\bin\cc_bindings_from_rs.exe" goto fallo'
    'copy /y "third_party\rust-toolchain\bin\*.dll" "third_party\rust-toolchain\crubit\bin\" >nul'
    # ninja se ejecuta dentro de powershell con Tee-Object: cmd bufferiza su salida y el log del paso
    # no se vacia hasta que ninja termina, asi que la consola no ve progreso (y el vigilador no puede
    # distinguir 'compilando' de 'congelado'). PowerShell si vacia linea a linea.
    ('powershell -NoProfile -Command "& ''ninja.exe'' -C out\Default chrome -j ' + $Jobs + ' 2>&1 | Tee-Object -FilePath ''' + (Join-Path $workspace 'genbuild.log') + ''' ; exit $LASTEXITCODE"')
    'set RC=%errorlevel%'
    'goto fin'
    ':fallo'
    'set RC=1'
    ':fin'
    'echo %RC% > "' + (Join-Path $workspace 'genbuild.log.codigo') + '"'
    'exit /b %RC%'
  )
  Push-Location $src
  try { Ejecutar-Con-Vigilancia $bat (Join-Path $workspace 'genbuild.log') $registro 12 600 } finally { Pop-Location }
  $exe = Join-Path $out 'chrome.exe'
  if (-not (Test-Path $exe)) { throw 'no aparecio out\Default\chrome.exe' }
  Write-Host "  navegador compilado: $exe"
  & $exe --version 2>&1 | Select-Object -First 1
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
  Preparar-VS | Out-Null
  $srcPrep = Join-Path $windows 'build\src'
  $sdkPrep = Elegir-SDK $env:WINDOWSSDKDIR
  if ((Test-Path $srcPrep) -and $sdkPrep) { Corregir-SDKVersion $srcPrep $sdkPrep }
  Write-Host '  si gn gen se queja de un SDK inexistente, usa -Step genbuild: fija INCLUDE/LIB y SDK_VERSION al SDK completo del disco'

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
    $cmdBuild = 'py -3 build.py -j ' + $Jobs
    if ($py -notlike '*py.exe*') { $cmdBuild = '"' + $py + '" build.py -j ' + $Jobs }
    $batBuild = Join-Path $env:TEMP 'chromper_build_py.bat'
    Set-Content -Path $batBuild -Encoding ascii -Value @(
      '@echo off',
      $cmdBuild,
      'set RC=%errorlevel%',
      'echo %RC% > "' + (Join-Path $workspace 'buildpy.log.codigo') + '"',
      'exit /b %RC%'
    )
    try { Ejecutar-Con-Vigilancia $batBuild (Join-Path $workspace 'buildpy.log') $registro 25 720 } catch {
      # build.py peta en su propio gn gen cuando el SDK fijado en el arbol no esta instalado
      # (Chromium 157 pide 10.0.28000.0 y la maquina tiene 26100). Si gn.exe existe, la preparacion
      # (descargas, poda, parches, dominio, rust) si termino: -Step genbuild reanuda fijando
      # SDK_VERSION, INCLUDE y LIB al SDK real del disco.
      if (Test-Path (Join-Path $windows 'build\src\out\Default\gn.exe')) {
        Write-Host "  build.py fallo en su gn gen (codigo $LASTEXITCODE), pero gn.exe existe: la preparacion termino."
        Write-Host '  continua con: -Step genbuild  (fija SDK_VERSION/INCLUDE/LIB y compila)'
        return
      }
      throw "build.py fallo (mira $registro)"
    }
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
  'genbuild' { Paso-Genbuild }
  'package' { Paso-Package }
  'publish' { Paso-Publish }
  'install-chromper' { Paso-Instalar }
  'all' { Paso-Check; Paso-Clone; Paso-Build; Paso-Package }
}
try { Stop-Transcript | Out-Null } catch { }
