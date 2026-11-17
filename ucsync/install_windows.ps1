# Instala el navegador UC-Sync en Windows 11 desde el último release de este fork.
#
# Uso (PowerShell):
#   .\install_windows.ps1                    # descarga el último zip y lo instala en %LOCALAPPDATA%
#   .\install_windows.ps1 -Zip C:\paquetes\ucsync-chromium-windows-x64.zip
#   .\install_windows.ps1 -Uninstall
param(
  [string]$Zip = '',
  [string]$Url = 'https://github.com/dr0per250/ungoogled-chromium-ucsync/releases/latest/download/ucsync-chromium-windows-x64.zip',
  [string]$Prefix = "$env:LOCALAPPDATA\ucsync-chromium",
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
  if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
  $lnk = "$env:PUBLIC\Desktop\UC-Sync.lnk"
  if (Test-Path $lnk) { Remove-Item -Force $lnk }
  Write-Host "Borrado $Prefix (el perfil %LOCALAPPDATA%\ucsync-chromium-profile se conserva)."
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
    Write-Host "Descargando ucsync-chromium-windows-x64.zip del release $tag"
    gh release download $tag -R dr0per250/ungoogled-chromium-ucsync -p ucsync-chromium-windows-x64.zip --dir $tmp --clobber
    Copy-Item (Join-Path $tmp 'ucsync-chromium-windows-x64.zip') (Join-Path $tmp 'pkg.zip')
  } elseif ($env:GH_TOKEN) {
    Write-Host "Descargando con GH_TOKEN"
    Invoke-WebRequest -Uri $Url -Headers @{ Authorization = "Bearer $env:GH_TOKEN" } -OutFile (Join-Path $tmp 'pkg.zip')
  } else {
    throw 'El repo del navegador es privado: autentica gh (`gh auth login`) o pasa -Zip C:\ruta\ucsync-chromium-windows-x64.zip'
  }
  Expand-Archive -Path (Join-Path $tmp 'pkg.zip') -DestinationPath $tmp -Force
  $src = Join-Path $tmp 'ucsync-chromium'
  if (-not (Test-Path (Join-Path $src 'chrome.exe'))) { throw 'El zip no trae chrome.exe' }

  New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
  Copy-Item -Recurse -Force "$src\*" $Prefix
  Write-Host "Instalado en $Prefix"

  # Atajo de escritorio y en el menú de aplicaciones
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut("$env:PUBLIC\Desktop\UC-Sync.lnk")
  $lnk.TargetPath = Join-Path $Prefix 'chrome.exe'
  $lnk.Arguments = "--user-data-dir=`"$env:LOCALAPPDATA\ucsync-chromium-profile`""
  $lnk.IconLocation = (Join-Path $Prefix 'chrome.exe') + ',0'
  $lnk.Description = 'Chromium sin Google con UC-Sync integrado'
  $lnk.Save()

  # En el PATH del usuario para poder lanzarlo desde la terminal
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not ($userPath -split ';' | Where-Object { $_ -eq $Prefix })) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Prefix), 'User')
    Write-Host "Añadido $Prefix al PATH del usuario (abre una terminal nueva)."
  }

  & (Join-Path $Prefix 'chrome.exe') --version
  Write-Host 'Listo. Ábrelo y ve a chrome://ucsync para conectar con tu servidor.'
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
