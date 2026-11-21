#!/usr/bin/env python3
"""Genera un parche propio contra la base de upstream ya aplicada (lo que espera patches/series).

Uso: make_one_patch.py <ruta/en/el/árbol> ... -> vuelca el diff en stdout
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ucsync"))
import patch_sections  # noqa: E402

VERSION = (ROOT / "chromium_version.txt").read_text(encoding="utf-8").strip()
CACHE = Path(os.environ.get("UCSYNC_FILE_CACHE", Path.home() / ".cache" / "ucsync-chromium-files"))
SRC = Path(os.environ.get("CHROMIUM_SRC", "/IA/chromium-build/src"))
SERIES = (ROOT / "patches" / "series").read_text(encoding="utf-8").splitlines()
upstream = [l.strip() for l in SERIES if l.strip() and not l.startswith("#")
            and not l.startswith("extra/ucsync/")]

paths = sys.argv[1:]
work = Path(tempfile.mkdtemp(prefix="base-"))
for path in paths:
    cached = CACHE / VERSION / path
    if not cached.exists():
        print(f"falta la caché {cached}", file=sys.stderr)
        sys.exit(1)
    dest = work / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(cached.read_bytes())

applied = 0
for entry in upstream:
    patch_path = ROOT / "patches" / entry
    if not patch_path.exists():
        continue
    text = patch_path.read_text(encoding="utf-8", errors="replace")
    for path in paths:
        section = patch_sections.section_for(text, path)
        if not section:
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".patch", delete=False) as handle:
            handle.write(section)
            sp = handle.name
        subprocess.run(["patch", "-p1", "--forward", "-s", "-f", "-i", sp],
                       cwd=work, capture_output=True, check=False)
        os.unlink(sp)
        applied += 1
print(f"[base] {applied} secciones de upstream aplicadas", file=sys.stderr)

for path in paths:
    base = work / path
    mod = SRC / path
    subprocess.run(["diff", "-u", f"--label=a/{path}", f"--label=b/{path}",
                    str(base), str(mod)], check=False)
