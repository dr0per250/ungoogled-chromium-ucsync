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


def trozos_de_cadena(linea: str):
    """Genera (texto, dentro_de_cadena) recorriendo la línea; basta para detectar Expansiones."""
    dentro = False
    actual = []
    i = 0
    while i < len(linea):
        c = linea[i]
        if c == '"' and (i == 0 or linea[i - 1] != '`'):
            if actual:
                yield ''.join(actual), dentro
                actual = []
            dentro = not dentro
        elif c == "'" and (i == 0 or linea[i - 1] != '`'):
            if actual:
                yield ''.join(actual), dentro
                actual = []
            dentro = not dentro
        else:
            actual.append(c)
        i += 1
    if actual:
        yield ''.join(actual), dentro


def revisar(ruta: pathlib.Path) -> list[str]:
    crudo = ruta.read_bytes()
    problemas: list[str] = []
    if not crudo.startswith(b'\xef\xbb\xbf'):
        problemas.append("sin BOM UTF-8: PowerShell 5.1 lo lee como ANSI y rompe el parseo")
    texto = crudo.decode("utf-8-sig", "replace")
    if any(ord(c) > 126 for c in texto):
        problemas.append("contiene caracteres no ASCII (acéntos, comillas tipográficas, glyphs)")
    for numero, linea in enumerate(texto.splitlines(), 1):
        for tramo, dentro in trozos_de_cadena(linea):
            if dentro:
                # Dentro de una cadena "$var:" se lee como «variable de unidad»: hay que escribir ${var}.
                for m in re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*):", tramo):
                    if m.group(1).lower() not in VALIDOS:
                        problemas.append(f'línea {numero}: "$ {m.group(1)}:" en una cadena → escribe ${{{m.group(1)}}}:')
            # `${scope}:nombre` no es una referencia válida: el ámbito va dentro de las llaves.
            if re.search(r"\$\{(script|global|local|private|env|using)\}:\w", tramo):
                problemas.append(f'línea {numero}: "${{scope}}:nombre" no válido → usa $scope:nombre o ${{scope:nombre}}')
        if "&&" in linea:
            problemas.append(f"línea {numero}: aparece '&&' (PowerShell 5.1 no lo entiende)")
        if linea.endswith("` ") or linea.endswith("`  "):
            problemas.append(f"línea {numero}: continuación con ` seguida de espacio")
        if linea.count('"') % 2:
            problemas.append(f"línea {numero}: comillas dobles sin cerrar")
    if texto.count("{") != texto.count("}"):
        problemas.append("llaves { y } desequilibradas")
    # En la lista de parámetros falta coma entre declaraciones: PowerShell da errores en cascada.
    lineas = texto.splitlines()
    for i, l in enumerate(lineas):
        if l.strip().startswith("param(") and l.count("(") > l.count(")"):
            j = i
            while j < len(lineas) and not lineas[j].strip().startswith(")"):
                terminacion = lineas[j].rstrip()
                siguiente = lineas[j + 1].strip() if j + 1 < len(lineas) else ')'
                if terminacion and siguiente != ')' and not terminacion.endswith(',') and not terminacion.endswith('`') and not terminacion.endswith('param('):
                    problemas.append(f"línea {j + 1}: en la lista de parámetros falta la coma final")
                j += 1
            if j >= len(lineas):
                problemas.append("lista de parámetros sin cerrar")
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
