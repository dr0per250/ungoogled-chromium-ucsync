# Instala Chromper en Windows 11 desde el ultimo release de este fork.
#
# Uso (PowerShell):
#   .\install_windows.ps1                    # descarga el ultimo zip y lo instala en %LOCALAPPDATA%
#   .\install_windows.ps1 -Zip C:\paquetes\ucsync-chromium-windows-x64.zip
#   .\install_windows.ps1 -Uninstall
param(
  [string]$Zip = '',
  [string]$Url = 'https://github.com/dr0per250/ungoogled-chromium-ucsync/releases/latest/download/chromper-windows-x64.zip',
  [string]$Prefix = "$env:LOCALAPPDATA\chromper",
  [string]$UserDataDir = "$env:LOCALAPPDATA\chromper-profile",
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
  if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
  $lnk = "$env:PUBLIC\Desktop\Chromper.lnk"
  if (Test-Path $lnk) { Remove-Item -Force $lnk }
  Write-Host "Borrado $Prefix (el perfil %LOCALAPPDATA%\chromper-profile se conserva)."
  return
}

$tmp = Join-Path $env:TEMP ("ucsync-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  if ($Zip) {
    Copy-Item $Zip (Join-Path $tmp 'pkg.zip')
  } elseif (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Host 'Descargando con gh (repo privado)'
    $tag = gh release view -R dr0per250/ungoogled-chromium-ucsync --json tagName -q .tagName
    Write-Host "Descargando chromper-windows-x64.zip del release $tag"
    gh release download $tag -R dr0per250/ungoogled-chromium-ucsync -p chromper-windows-x64.zip --dir $tmp --clobber
    Copy-Item (Join-Path $tmp 'chromper-windows-x64.zip') (Join-Path $tmp 'pkg.zip')
  } elseif ($env:GH_TOKEN) {
    Write-Host "Descargando con GH_TOKEN"
    Invoke-WebRequest -Uri $Url -Headers @{ Authorization = "Bearer $env:GH_TOKEN" } -OutFile (Join-Path $tmp 'pkg.zip')
  } else {
    # El repo es publico: basta una descarga normal.
    Write-Host "Descargando $Url"
    Invoke-WebRequest -Uri $Url -OutFile (Join-Path $tmp 'pkg.zip')
  }
  Expand-Archive -Path (Join-Path $tmp 'pkg.zip') -DestinationPath $tmp -Force
  $src = Join-Path $tmp 'chromper'
  if (-not (Test-Path (Join-Path $src 'chromper.exe')) -and -not (Test-Path (Join-Path $src 'chrome.exe'))) {
    throw 'El zip no trae chromper.exe'
  }
  if (-not (Test-Path (Join-Path $src 'chromper.exe'))) { Copy-Item (Join-Path $src 'chrome.exe') (Join-Path $src 'chromper.exe') }
  if (-not (Test-Path (Join-Path $src 'chrome.exe'))) { Copy-Item (Join-Path $src 'chromper.exe') (Join-Path $src 'chrome.exe') }
  foreach ($ext in 'ucsync','chromium-web-store') {
    if (-not (Test-Path (Join-Path $src $ext))) { Write-Warning "El zip no trae ${ext}: la extension integrada no aparecera." }
  }

  New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
  Copy-Item -Recurse -Force "$src\*" $Prefix
  Write-Host "Instalado en $Prefix"

  # Atajo de escritorio y en el menu de aplicaciones
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut("$env:PUBLIC\Desktop\Chromper.lnk")
  $lnk.TargetPath = Join-Path $Prefix 'chromper.exe'
  $lnk.Arguments = "--user-data-dir=`"$UserDataDir`""
  $lnk.IconLocation = (Join-Path $Prefix 'chromper.exe') + ',0'
  $lnk.Description = 'Chromper: Chromium sin Google con UC-Sync integrado'
  $lnk.Save()

  # En el PATH del usuario para poder lanzarlo desde la terminal
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not ($userPath -split ';' | Where-Object { $_ -eq $Prefix })) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Prefix), 'User')
    Write-Host "Anadido $Prefix al PATH del usuario (abre una terminal nueva)."
  }

  & (Join-Path $Prefix 'chromper.exe') --version
  Write-Host "Perfil: $UserDataDir"
  Write-Host 'Listo. Abrelo y ve a chrome://ucsync para conectar con tu servidor.'
  Write-Host 'Para traer marcadores e historial de Chrome: chrome://settings/importData.'
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
