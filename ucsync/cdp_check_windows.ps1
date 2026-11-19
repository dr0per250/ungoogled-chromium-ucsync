# Comprobacion de runtime del Chromper de Windows sobre CDP (sin node ni gh en la maquina).
#
#   .\cdp_check_windows.ps1            # usa el puerto 9222
#   .\cdp_check_windows.ps1 -Port 9333
#
# Levanta el Chromper instalado en modo headless con un perfil de prueba (no toca el perfil real) y
# comprueba: chrome://ucsync, chrome.history.addUrls con marca de tiempo real, el ID estable de la
# extension embebida y que el buscador por defecto es Google. Sale con codigo 0 si todo pasa.
param(
  [int]$Port = 9222,
  [string]$Exe = (Join-Path $env:LOCALAPPDATA 'chromper\chromper.exe'),
  [string]$Perfil = 'C:\chromper\perfil_test',
  [string]$UcSyncId = 'lidfhdhmbifmhikiaklbiehnhnkhoghe'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $Exe)) { throw "no existe $Exe (ejecuta -Step install-chromper)" }
Get-Process chromper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process $Exe -ArgumentList '--headless=new', "--remote-debugging-port=$Port", "--user-data-dir=$Perfil", '--no-first-run', '--no-default-browser-check', '--disable-gpu' -WindowStyle Hidden

$targets = $null
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Seconds 2
  try { $targets = @(Invoke-WebRequest "http://127.0.0.1:$Port/json" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json; break } catch { }
}
if (-not $targets) { throw "no hay CDP en 127.0.0.1:$Port" }

function Nuevo-Target($url) {
  $t = Invoke-WebRequest "http://127.0.0.1:$Port/json/new?$url" -Method Put -UseBasicParsing -TimeoutSec 10 | ConvertFrom-Json
  Start-Sleep -Seconds 3
  return $t
}
function Nuevo-WebSocket($url) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ct = [System.Threading.CancellationToken]::None
  $ws.ConnectAsync([Uri]$url, $ct).Wait()
  return $ws
}
function Enviar($ws, $payload) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 8))
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
  $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
}
function Esperar($ws, $id) {
  $buf = New-Object byte[] 65536
  for ($i = 0; $i -lt 400; $i++) {
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buf)
    $t = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
    if (-not $t.Wait(5000)) { throw 'timeout leyendo CDP' }
    if ($t.Result.MessageType -eq 'Close') { throw 'CDP cerrado' }
    $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $t.Result.Count)
    if ($txt.Contains('"id":' + $id)) { return ($txt | ConvertFrom-Json) }
  }
  throw 'no llego la respuesta al id ' + $id
}
function Evaluar($ws, $refId, $expr) {
  $script = '(async () => { ' + $expr + ' })()'
  Enviar $ws @{ id = $refId; method = 'Runtime.evaluate'; params = @{ expression = $script; awaitPromise = $true; returnByValue = $true } }
  $r = Esperar $ws $refId
  if ($r.result.exceptionDetails) { return 'EXCEPCION: ' + ($r.result.exceptionDetails.exception.message) }
  return $r.result.result.value
}

$ok = 0
$fallos = @()
function Comprobar($nombre, $cond, $detalle) {
  if ($cond) { $script:ok++; Write-Host ("  OK   {0}  ({1})" -f $nombre, $detalle) }
  else { $script:fallos += "$nombre :: $detalle"; Write-Host ("  FALTA {0}  ({1})" -f $nombre, $detalle) }
}

# 1) chrome://ucsync
$t = Nuevo-Target 'chrome://ucsync'
$ws = Nuevo-WebSocket $t.webSocketDebuggerUrl
Enviar $ws @{ id = 1; method = 'Runtime.enable' } | Out-Null
$titulo = Evaluar $ws 2 'return document.title + " | " + (document.body ? document.body.innerText.slice(0, 120) : "sin cuerpo")'
Comprobar 'chrome://ucsync' ($titulo -match 'UC-Sync|Chromper') ($titulo -replace "`r|`n", ' ')
$ws.Dispose()

# 2) la extension embebida, con su ID estable, y chrome.history.addUrls con fecha real
$t = Nuevo-Target ("chrome-extension://" + $UcSyncId + "/options.html")
$ws = Nuevo-WebSocket $t.webSocketDebuggerUrl
Enviar $ws @{ id = 1; method = 'Runtime.enable' } | Out-Null
$hayApi = Evaluar $ws 2 'return typeof chrome.history !== "undefined" && typeof chrome.history.addUrls === "function"'
Comprobar 'chrome.history.addUrls disponible' ($hayApi -eq $true) ("tipo: " + $hayApi)
$ayer = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - (86400000 * 3)
# addUrls recibe UN OBJETO con la propiedad 'urls' (chrome.history.addUrls({urls: [...]})); si se le
# pasa el array suelto da 'No matching signature'.
$expr = @'
const url = 'https://ucsync-check.invalid/' + Date.now();
await chrome.history.addUrls({ urls: [{ url: url, title: 'comprobacion ucsync', visitTime: AYER }] });
const lista = await chrome.history.search({ text: '', maxResults: 100, startTime: 0 });
const item = lista.find(i => i.url.startsWith('https://ucsync-check.invalid/'));
return JSON.stringify({ url: item ? item.url : 'sin url', visitTime: item ? item.visitTime : 0, esperado: AYER, diferencia: item ? Math.abs(item.visitTime - AYER) : -1, source: item ? item.source : 'n/d' });
'@ -replace 'AYER', $ayer
$cruda = Evaluar $ws 3 $expr
try { $j = $cruda | ConvertFrom-Json } catch { $j = $null }
Comprobar 'addUrls conserva la visita de hace 3 dias' ($j -and $j.diferencia -ge 0 -and $j.diferencia -lt 2000) ("visitTime=" + $j.visitTime + " esperado=" + $j.esperado + " diff=" + $j.diferencia + "ms source=" + $j.source)
$fuente = Evaluar $ws 4 'const l = await chrome.history.search({ text: "ucsync-check", maxResults: 5, startTime: 0 }); return l[0] ? l[0].source : "n/d"'
Comprobar 'la visita queda como SOURCE_EXTENSION' ($fuente -match 'Extension|chrome') ("source=" + $fuente)
$ws.Dispose()

# 3) buscador por defecto: Google de verdad (no el dominio de ungoogled). Se pregunta al WebUI de
# ajustes, que es lo que ve el usuario; en headless --no-first-run las Preferences quedan vacias,
# asi que esa via solo sirve como respaldo.
$t = Nuevo-Target 'chrome://settings/search'
$ws = Nuevo-WebSocket $t.webSocketDebuggerUrl
Enviar $ws @{ id = 1; method = 'Runtime.enable' } | Out-Null
$busc = Evaluar $ws 2 @'
if (typeof chrome.searchEnginesPrivate === 'undefined') { return 'API no disponible' }
const l = await chrome.searchEnginesPrivate.getSearchEngines();
const d = l.find(e => e.isDefault) || l[0];
return JSON.stringify({ nombre: d.name, keyword: d.keyword, url: d.url, total: l.length });
'@
try { $b = $busc | ConvertFrom-Json } catch { $b = $null }
$ws.Dispose()
Get-Process chromper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$url = ''
if ($b -and $b.url) { $url = $b.url } else {
  $pref = Join-Path $Perfil 'Default\Preferences'
  if (Test-Path $pref) {
    $d = (Get-Content $pref -Raw | ConvertFrom-Json)
    $tpl = $d.default_search_provider_data.template_url_data
    if ($tpl) { $url = $tpl.url }
  }
}
if (-not $url) { $url = 'sin datos (headless sin first-run)' }
Comprobar 'buscador por defecto usa google.com' ($url -match 'google\.com/search') ($b.nombre + ' ' + $b.keyword + ' ' + $url)
Comprobar 'no queda el dominio sustituto de ungoogled' (-not ($url -match '9oo91e|nosearch')) ($url)

Write-Host ''
Write-Host ("[cdp] {0} comprobaciones ok, {1} fallos" -f $ok, $fallos.Count)
if ($fallos.Count -gt 0) { $fallos | ForEach-Object { Write-Host "  ! $_" }; exit 1 }
exit 0
