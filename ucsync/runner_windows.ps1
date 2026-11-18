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
if (-not $Fork) { $Fork = (Join-Path $env:USERPROFILE 'chromper-fork\bootstrap_windows.ps1') }

$yo = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*runner_windows.ps1*' -or $_.CommandLine -like '*runner.ps1*' }).Count
if ($yo -gt 2) { exit 0 }

function Reg($t) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $t) }
function FirmaActual {
  if (-not (Test-Path (Join-Path $registro 'genbuild.log.fallo'))) { return '' }
  $c = @(Select-String -Path (Join-Path $registro 'genbuild.log.fallo') -Pattern 'FAILED:|fatal error|error C[0-9]+|error: ' | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() })
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
Paso 'package' $Jobs | Out-Null
Reg 'PAQUETE_HECHO'
