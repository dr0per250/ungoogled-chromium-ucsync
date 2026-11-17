#!/usr/bin/env python3
"""Extrae de un parche la sección que toca un fichero concreto.

Los parches de ungoogled tocan decenas de ficheros; para reconstruir la base sobre la que se
escribieron los parches de UC-Sync (o para comprobarlos) hace falta aplicar, en orden de
`patches/series`, sólo los trozos que afectan a los ficheros que nos interesan.

Uso:
    python3 ucsync/patch_sections.py <parche> <ruta>            # imprime la sección
    python3 ucsync/patch_sections.py <parche> <ruta> --out f.patch
"""

import re
import sys
from pathlib import Path

GIT_HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
PLUS_HEADER = re.compile(r"^\+\+\+ b/(\S+)$")
MINUS_HEADER = re.compile(r"^--- (?:a/)?(\S+)$")


def sections(text):
    """Divide un parche en secciones por fichero, admitiendo formato git y `diff -u`."""
    out = []
    current = None
    for line in text.splitlines(keepends=True):
        if GIT_HEADER.match(line):
            if current:
                out.append(current)
            current = [line]
            continue
        if line.startswith("--- ") and (current is None or any(l.startswith("@@") for l in current)):
            if current:
                out.append(current)
            current = [line]
            continue
        if current is not None:
            current.append(line)
    if current:
        out.append(current)
    return out


def section_for(text, path):
    for section in sections(text):
        for line in section:
            match = PLUS_HEADER.match(line)
            if match and match.group(1) == path:
                return "".join(section)
    return ""


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    patch_path, path = Path(argv[1]), argv[2]
    out = section_for(patch_path.read_text(encoding="utf-8", errors="replace"), path)
    if not out:
        return 1
    if len(argv) > 3 and argv[3] == "--out":
        Path(argv[4]).write_text(out, encoding="utf-8")
        return 0
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
