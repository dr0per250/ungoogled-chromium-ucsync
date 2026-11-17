#!/usr/bin/env python3
"""Comprueba que las choices de bandera que tocamos mantienen la invariante de `FeatureEntry`.

`FeatureEntry::IsValid()` exige que el **primer** item de una bandera `MULTI_VALUE` tenga el switch y
el valor vacíos. Si se pone un switch ahí, `chrome://flags` lo rechaza y `FlagsState::SanitizeList()`
aborta el navegador al arrancar ( DCHECK `entry.IsValid()` ), que es exactamente el fallo que dio un
`chromper` que no abría. Como el chequeo sólo salta en tiempo de ejecución, se comprueba aquí, sobre
el parche, sin compilar ni ejecutar nada.

Uso:
    python3 ucsync/check_flag_choices.py            # sobre patches/extra/ucsync/*.patch
    python3 ucsync/check_flag_choices.py <archivo>  # sobre un flag_choices.h
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATCH_DIR = ROOT / "patches" / "extra" / "ucsync"
CHOICE_ARRAY = re.compile(r"Choice\s+(k\w+)\s*\[\]\s*=\s*\{")
ENTRY = re.compile(r"\{\s*(\"[^\"]*\"|flags_ui::kGenericExperimentChoiceDefault)\s*,\s*(\"[^\"]*\")\s*,\s*(\"[^\"]*\")\s*\}")


def added_lines(text):
    """Líneas añadidas por el parche (con `+`, sin el marcador)."""
    for line in text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            yield line[1:]


def check_array(name, entries):
    """El primer item debe tener switch y valor vacíos."""
    if not entries:
        return f"{name}: la choices quedaron vacías"
    _, switch, value = entries[0]
    if switch != '""' or value != '""':
        return (f"{name}: el primer item debe tener switch y valor vacíos "
                f"(FeatureEntry::IsValid), y tiene switch={switch} valor={value}")
    return None


def scan(text, origin):
    problems = []
    array = None
    entries = []
    for line in text.splitlines():
        match = CHOICE_ARRAY.search(line)
        if match:
            if array:
                problem = check_array(array, entries)
                if problem:
                    problems.append(f"{origin}: {problem}")
            array = match.group(1)
            entries = []
            continue
        if array:
            if line.startswith("};"):
                problem = check_array(array, entries)
                if problem:
                    problems.append(f"{origin}: {problem}")
                array = None
                entries = []
                continue
            entry = ENTRY.search(line)
            if entry:
                entries.append(entry.groups())
    if array:  # array sin cierre en el texto analizado
        problem = check_array(array, entries)
        if problem:
            problems.append(f"{origin}: {problem}")
    return problems


def main():
    args = sys.argv[1:]
    if args:
        target = Path(args[0])
        problems = scan(target.read_text(encoding="utf-8", errors="replace"), target.name)
    else:
        problems = []
        for patch in sorted(PATCH_DIR.glob("*.patch")):
            text = "\n".join(added_lines(patch.read_text(encoding="utf-8", errors="replace")))
            if "Choice k" not in text and "kGenericExperimentChoiceDefault" not in text:
                continue
            problems += scan(text, patch.name)
    for problem in problems:
        print(f"[banderas] ✗ {problem}", file=sys.stderr)
    if problems:
        return 1
    print("[banderas] ✓ las choices mantienen la invariante de FeatureEntry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
