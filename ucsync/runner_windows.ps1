# Runner resistente para compilar Chromper en Windows (tarea programada /sc onstart como SYSTEM).
# Reanuda tras reinicios de Windows Update. Dos cosas que antes costaban horas:
#  - no avisaba: si un paso petaba, reintentaba 10 veces el mismo error. Ahora compara la firma del
#    fallo (genbuild.log.fallo -> firma.txt) y para tras dos fallos identicales, dejando ALERTA.txt.
#  - Start-Process -Wait se cuelga a veces en esta maquina: se llama a powershell con '&' en el
#    mismo proceso y se registra el codigo de salida.
param(
  [string]$Workspace = 'C:\chromper',
  [string]$Fork = '',
  [int]$Jobs = 12,
  [int]$Intentos = 10
)
$ErrorActionPreference = 'Continue'
$registro = $Workspace
$log = Join-Path $registro 'registro.txt'
$alerta = Join-Path $registro 'ALERTA.txt'
$firma = Join-Path $registro 'firma.txt'
if (-not $Fork) {
  # bajo la tarea programada se ejecuta como SYSTEM: $env:USERPROFILE es
  # C:\Windows\System32\config\systemprofile y no existe ahi -> powershell -File con una ruta
  # inexistente sale con codigo -196608 sin dejar nada en el registro. Se buscan las rutas reales.
  $candidatos = @((Join-Path $env:USERPROFILE 'chromper-fork\bootstrap_windows.ps1'))
  foreach ($u in @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
    $candidatos += (Join-Path $u.FullName 'chromper-fork\bootstrap_windows.ps1')
  }
  $candidatos += (Join-Path $Workspace 'bootstrap_windows.ps1')
  $elegida = @($candidatos | Where-Object { Test-Path $_ })
  if ($elegida.Count -eq 0) {
    Reg 'FALTA bootstrap_windows.ps1: clona el fork o pasa -Fork <ruta>'
    Set-Content -Path $alerta -Encoding ascii -Value ("[{0}] FALTA bootstrap_windows.ps1" -f (Get-Date -Format 'HH:mm'))
    exit 1
  }
  $Fork = $elegida[0]
}


$yo = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*runner_windows.ps1*' -or $_.CommandLine -like '*runner.ps1*' }).Count
if ($yo -gt 2) { exit 0 }

function Reg($t) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $t) }
function FirmaActual {
  # el log de ninja es el que trae el FAILED: real; el del paso solo lleva el arranque
  $ruta = Join-Path $registro 'genbuild.ninja.log.fallo'
  if (-not (Test-Path $ruta)) { $ruta = Join-Path $registro 'genbuild.log.fallo' }
  if (-not (Test-Path $ruta)) { return '' }
  $c = @(Select-String -Path $ruta -Pattern 'FAILED:|fatal error|error C[0-9]+|error: ' | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() })
  if ($c.Count -eq 0) { return '' }
  $s = $c -join ' ;; '
  if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
  return $s
}
function Paso($step, $jobs) {
  Reg "=== -Step $step ==="
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Fork -Step $step -Workspace $Workspace -Jobs $jobs
  Reg "-Step $step codigo $LASTEXITCODE"
  return $LASTEXITCODE
}

$src = Join-Path $Workspace 'windows\build\src'
$exe = Join-Path $src 'out\Default\chrome.exe'
if (-not (Test-Path (Join-Path $Workspace 'windows\build.py'))) { Paso 'clone' $Jobs | Out-Null }
if (-not (Test-Path (Join-Path $src 'out\Default\gn.exe'))) { Paso 'build' $Jobs | Out-Null }

$anterior = ''
for ($intento = 1; $intento -le $Intentos; $intento++) {
  if (Test-Path $exe) { break }
  # la alerta es de un intento: al empezar uno nuevo se borra para que el monitor no vea un fallo viejo
  Remove-Item $alerta -ErrorAction SilentlyContinue
  Reg "genbuild intento $intento"
  Paso 'genbuild' $Jobs | Out-Null
  $f = FirmaActual
  if ($f -ne '' -and $f -eq $anterior) {
    Reg ("FALLO REPETIDO (2 veces igual): {0}" -f $f)
    Set-Content -Path $alerta -Encoding ascii -Value ("[{0}] FALLO REPETIDO, no se reintentara: {1}" -f (Get-Date -Format 'HH:mm'), $f)
    exit 1
  }
  $anterior = $f
  Start-Sleep -Seconds 20
}
if (-not (Test-Path $exe)) {
  Reg 'FALTA chrome.exe tras los intentos: mira el registro'
  Set-Content -Path $alerta -Encoding ascii -Value ("[{0}] FALTA chrome.exe tras {1} intentos" -f (Get-Date -Format 'HH:mm'), $Intentos)
  exit 1
}
Remove-Item $alerta -ErrorAction SilentlyContinue
Reg 'CHROMPER_COMPILADO'
$zipRuta = Join-Path $Workspace 'pkg\chromper-windows-x64.zip'
if (Test-Path $zipRuta) {
  Reg "el zip ya existe ([math]::Round((Get-Item $zipRuta).Length/1MB)) MB: no se reempaqueta"
  Reg 'PAQUETE_HECHO'
  exit 0
}
$codPkg = Paso 'package' $Jobs
if ($codPkg -eq 0 -and (Test-Path (Join-Path $Workspace 'pkg\chromper-windows-x64.zip'))) {
  Reg 'PAQUETE_HECHO'
} else {
  Reg ("package fallo (codigo $codPkg): no hay pkg\chromper-windows-x64.zip")
  Set-Content -Path $alerta -Encoding ascii -Value ("[{0}] package codigo {1}: no hay zip" -f (Get-Date -Format 'HH:mm'), $codPkg)
  exit 1
}
