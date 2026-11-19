# Comprueba que los .ps1 se parsean con el analizador de Windows PowerShell (AST).
# check_ps1.py busca patterns concretos que petan en PS 5.1; esto ademas detecta cualquier error de
# sintaxis (llaves de mas, comillas sin cerrar, strings mal acabadas) antes de ejecutar nada.
# Uso en Windows:  powershell -ExecutionPolicy Bypass -File .\check_ps1_parse.ps1 .\
param([string]$Dir = '.')
$ErrorActionPreference = 'Stop'
$fallas = 0
foreach ($f in @(Get-ChildItem $Dir -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)) {
  $tokens = $null
  $errores = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errores) | Out-Null
  if ($errores.Count -gt 0) {
    foreach ($e in $errores) {
      Write-Host "  FALLO $($f.Name): linea $($e.Extent.StartLineNumber) - $($e.Message)"
    }
    $fallas++
  } else {
    Write-Host "  ok $($f.Name): parsea limpio"
  }
}
if ($fallas -gt 0) {
  Write-Host "[parse] $fallas ficheros con errores de sintaxis"
  exit 1
}
Write-Host '[parse] todos los .ps1 parsean limpio'
