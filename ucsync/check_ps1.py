#!/usr/bin/env python3
"""Comprueba que los .ps1 del fork los puede leer Windows PowerShell 5.1.

Falló en la práctica por tres cosas que este script detecta:
  * UTF-8 sin BOM → PowerShell 5.1 lo interpreta como ANSI y «máquina» se convierte en «mÃ¡quina»,
    lo que rompe cadenas y produce errores de parseo absurdos (token '&&', llaves sin cerrar).
  * `$variable:` dentro de una cadena → 5.1 lo lee como «variable de unidad» y da
    InvalidVariableReferenceWithDrive. Hay que escribir ${variable}:.
  * `&&` o comillas sin cerrar, y continuaciones con ` seguidas de espacio.

Uso: python3 ucsync/check_ps1.py [directorio-del-fork]
"""
import pathlib
import re
import sys

FORK = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
# Prefijos de variable que sí van seguidos de ':' en PowerShell (unidades y ámbitos reales).
VALIDOS = {
    'env', 'script', 'global', 'local', 'private', 'using', 'psitem', 'psscriptroot',
    'myinvocation', 'lastexitcode', 'psversiontable', 'pscmdlet', 'executioncontext',
    'powershell', 'host', 'output', 'error', 'warning', 'verbose', 'debug', 'input', 'args',
}


def revisar(ruta: pathlib.Path) -> list[str]:
    crudo = ruta.read_bytes()
    problemas: list[str] = []
    if not crudo.startswith(b'\xef\xbb\xbf'):
        problemas.append("sin BOM UTF-8: PowerShell 5.1 lo lee como ANSI y rompe el parseo")
    texto = crudo.decode("utf-8-sig", "replace")
    if any(ord(c) > 126 for c in texto):
        problemas.append("contiene caracteres no ASCII (acéntos, comillas tipográficas, glyphs)")
    for numero, linea in enumerate(texto.splitlines(), 1):
        for m in re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*):", linea):
            if m.group(1).lower() not in VALIDOS:
                problemas.append(f'línea {numero}: "${m.group(1)}:" → escribe ${{{m.group(1)}}}:')
        if "&&" in linea:
            problemas.append(f"línea {numero}: aparece '&&' (PowerShell 5.1 no lo entiende)")
        if linea.endswith("` ") or linea.endswith("`  "):
            problemas.append(f"línea {numero}: continuación con ` seguida de espacio")
        if linea.count('"') % 2:
            problemas.append(f"línea {numero}: comillas dobles sin cerrar")
    if texto.count("{") != texto.count("}"):
        problemas.append("llaves { y } desequilibradas")
    return problemas


def main() -> int:
    ficheros = sorted((FORK / "ucsync").glob("*.ps1"))
    if not ficheros:
        print("[ps1] no hay .ps1 en ucsync/", file=sys.stderr)
        return 1
    mal = 0
    for f in ficheros:
        problemas = revisar(f)
        if problemas:
            mal += 1
            print(f"  ✗ {f.name}: {'; '.join(problemas[:4])}")
        else:
            print(f"  ✓ {f.name}: legible por Windows PowerShell 5.1")
    if mal:
        print(f"[ps1] {mal} ficheros con problemas de PowerShell 5.1")
        return 1
    print("[ps1] todos los .ps1 pasan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
