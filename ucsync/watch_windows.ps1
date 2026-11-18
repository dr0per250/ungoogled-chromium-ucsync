# Consola LOCAL del estado de la compilacion, para ejecutarla en la propia maquina Windows
# (no hace falta SSH). En el otro equipo usa tools/watch_windows.sh.
#
# Uso (PowerShell, sin administrador):
#   cd $env:USERPROFILE\chromper-fork
#   powershell -ExecutionPolicy Bypass -File .\watch_windows.ps1
#   powershell -ExecutionPolicy Bypass -File .\watch_windows.ps1 -Intervalo 30 -Workspace C:\chromper
param(
  [int]$Intervalo = 10,
  [string]$Workspace = 'C:\chromper'
)
$ErrorActionPreference = 'SilentlyContinue'

function Estado($ws) {
  $src = Join-Path $ws 'windows\build\src'
  $log = Join-Path $ws 'registro.txt'
  $t = Get-Content $log -Raw -ErrorAction SilentlyContinue
  if (-not $t) { $t = '' }
  $os = Get-CimInstance Win32_OperatingSystem
  $libre = [math]::Round((Get-PSDrive C).Free/1GB)
  $ramLibre = [math]::Round($os.FreePhysicalMemory/1MB, 1)
  $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  $pfTxt = 'sin pagefile activo'
  if ($pf) { $pfTxt = '{0} MB asignados' -f $pf.AllocatedBaseSize }

  $fase = 'sin empezar'
  if (Test-Path (Join-Path $src 'out\Default\chrome.exe')) { $fase = 'navegador compilado' }
  elseif ($t -match 'cc_bindings_from_rs') { $fase = 'Crubit: cc_bindings_from_rs (justo antes de ninja)' }
  elseif ($t -match 'build_bindgen\.py|bindgen-host-build') { $fase = 'Rust: compilando bindgen (justo antes de ninja)' }
  elseif ($t -match 'ninja\.exe -C out') { $fase = 'ninja: compilando Chromium' }
  elseif ($t -match 'gn\.exe gen') { $fase = 'gn gen' }
  elseif (Test-Path (Join-Path $src 'BUILD.gn')) { $fase = 'parcheando y preparando el arbol' }
  elseif (Test-Path (Join-Path $ws 'windows\build.py')) { $fase = 'descargando Chromium (gclient sync)' }
  elseif ($t -match 'Instalando dependencias') { $fase = 'instalando dependencias' }

  $progreso = '(sin acciones de ninja todavia)'
  $m = [regex]::Matches($t, '\[(\d+)/(\d+)\]')
  if ($m.Count -gt 0) {
    $u = $m[$m.Count - 1]
    $n = [int]$u.Groups[1].Value
    $tot = [int]$u.Groups[2].Value
    if ($tot -gt 0) {
      $pct = [math]::Round(100 * $n / $tot, 1)
      $llenos = [int]($pct / 2)
      if ($llenos -lt 0) { $llenos = 0 }
      if ($llenos -gt 50) { $llenos = 50 }
      $progreso = '{0}/{1}  {2}%  [{3}{4}]' -f $n, $tot, $pct, ('#' * $llenos), ('.' * (50 - $llenos))
    }
  }

  $filtros = "Name='powershell.exe'"
  $runner = @(Get-CimInstance Win32_Process -Filter $filtros | Where-Object { $_.CommandLine -like '*runner.ps1*' }).Count
  $procs = @(Get-Process python,ninja,git,clang,llc,rustc -ErrorAction SilentlyContinue).Count
  $uptime = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes)

  $excluir = '^\*+$|^(Inicio|Hora|Nombre|Usuario|Aplicaci|Id\.|PSVersion|PSEdition|PSCompatible|BuildVersion|Serialization|Session|Transcript|M..quina|Configuraci)'
  $lineas = @($t -split "`n" | Where-Object { $_ -match '\S' -and $_ -notmatch $excluir })
  $ultima = ($lineas | Select-Object -Last 3) -join ' ;; '
  $errs = @([regex]::Matches($t, '(?m)^(Exception|ERROR|FAILED|error:).*') | ForEach-Object { $_.Value } | Select-Object -Last 2) -join ' ;; '

  $zip = Join-Path $ws 'pkg\chromper-windows-x64.zip'
  $zipTxt = 'todavia no'
  if (Test-Path $zip) { $zipTxt = '{0} MB' -f [math]::Round((Get-Item $zip).Length/1MB) }
  $exe = Join-Path $src 'out\Default\chrome.exe'
  $exeTxt = 'no'
  if (Test-Path $exe) { $exeTxt = (Get-Item $exe).LastWriteTime.ToString('dd/MM HH:mm') }

  ("fase      | {0}" -f $fase)
  ("progreso  | {0}" -f $progreso)
  ("disco     | C: {0} GB libres, RAM libre {1} GB, pagefile {2}" -f $libre, $ramLibre, $pfTxt)
  ("actividad | runner={0} procesos={1} uptime={2} min" -f $runner, $procs, $uptime)
  ("chrome.exe| {0}" -f $exeTxt)
  ("zip       | {0}" -f $zipTxt)
  ("marcadores| clone:{0} compilado:{1} paquete:{2}" -f ($t -match 'Resumen de la construccion'), ($t -match 'CHROMPER_COMPILADO'), ($t -match 'PAQUETE_HECHO'))
  ("ultimo    | {0}" -f $ultima)
  if ($errs) { ("errores   | {0}" -f $errs) }
}

while ($true) {
  Clear-Host
  Write-Host ("=== Chromper en {0} - {1} ===" -f $env:COMPUTERNAME, (Get-Date -Format 'HH:mm:ss'))
  Estado $Workspace | ForEach-Object { Write-Host $_ }
  Write-Host ''
  Write-Host 'registro: C:\chromper\registro.txt   paquete: C:\chromper\pkg\chromper-windows-x64.zip'
  Write-Host 'Ctrl-C para salir - -Intervalo 30 para refrescar mas lento'
  Start-Sleep -Seconds $Intervalo
}
