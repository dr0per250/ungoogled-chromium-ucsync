#!/usr/bin/env python3
"""Comprueba que los parches de UC-Sync siguen aplicando sobre la versión de Chromium fijada.

El fork mantiene dos parches propios sobre el código de Chromium
(`patches/extra/ucsync/*.patch`). Cada actualización de upstream cambia
`chromium_version.txt`, y con ella el código que tocamos. Este script responde,
sin compilar nada y sin un checkout de Chromium:

  ¿siguen aplicando nuestros parches sobre la versión de Chromium actual?

Descarga de chromium.googlesource.com los ficheros que cada parche toca, en el
tag indicado por `chromium_version.txt`, y los aplica con `patch -p1` en un
directorio temporal. Sale con código 0 si todo aplica y 1 si alguno se rechaza,
que es cuando hay que readaptar el parche.

Uso:
    python3 ucsync/verify_patch.py            # versión fijada en chromium_version.txt
    python3 ucsync/verify_patch.py 157.0.8103.78
    python3 ucsync/verify_patch.py --list     # sólo qué ficheros tocan los parches
"""

import argparse
import base64
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UCSYNC_PATCHES = ROOT / "patches" / "extra" / "ucsync"
VERSION_FILE = ROOT / "chromium_version.txt"
SERIES_FILE = ROOT / "patches" / "series"
UCSYNC_PREFIX = "extra/ucsync/"
SHOW_URL = "https://chromium.googlesource.com/chromium/src/+show/refs/tags/{version}/{path}?format=TEXT"

PATCH_HEADER = re.compile(r"^\+\+\+ b/(\S+)$")


def series_patches():
    """Parches propios en el orden de `patches/series` (y detecta los que faltan allí)."""
    ordered = []
    for line in SERIES_FILE.read_text(encoding="utf-8").splitlines():
        entry = line.strip()
        if entry and not entry.startswith("#") and entry.startswith(UCSYNC_PREFIX):
            ordered.append(entry)
    on_disk = sorted(p.relative_to(ROOT / "patches").as_posix() for p in UCSYNC_PATCHES.glob("*.patch"))
    missing = [p for p in on_disk if p not in ordered]
    if missing:
        print(f"[ucsync] FALTAN en patches/series: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)
    return ordered


def touched_files(patch_path):
    files = []
    for line in patch_path.read_text(encoding="utf-8").splitlines():
        match = PATCH_HEADER.match(line)
        if match and match.group(1) != "/dev/null":
            files.append(match.group(1))
    return files


def fetch(version, path, dest):
    url = SHOW_URL.format(version=version, path=path)
    result = subprocess.run(["curl", "-sL", "--retry", "2", "--max-time", "90", url],
                            capture_output=True, check=False)
    if result.returncode != 0 or not result.stdout:
        return f"no se pudo descargar {path} ({url})"
    try:
        raw = base64.b64decode(result.stdout)
    except Exception as err:  # noqa: BLE001 - el mensaje ya dice bastante
        return f"respuesta inesperada para {path}: {err}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(raw)
    return None


def apply_patch(src_root, patch_path):
    result = subprocess.run(["patch", "-p1", "--forward", "--fuzz=0", "--dry-run", "-i", str(patch_path)],
                            cwd=src_root, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return (result.stdout + result.stderr).strip()
    real = subprocess.run(["patch", "-p1", "--forward", "--fuzz=0", "-i", str(patch_path)],
                          cwd=src_root, capture_output=True, text=True, check=False)
    if real.returncode != 0:
        return (real.stdout + real.stderr).strip()
    if "FAILED" in real.stdout or "rejected" in real.stdout.lower():
        return real.stdout.strip()
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="versión de Chromium (por defecto chromium_version.txt)")
    parser.add_argument("--list", action="store_true", help="sólo listar los ficheros que tocan los parches")
    args = parser.parse_args()

    version = args.version or VERSION_FILE.read_text(encoding="utf-8").strip()
    patches = [ROOT / "patches" / entry for entry in series_patches()]

    if args.list:
        for patch_path in patches:
            print(f"{patch_path.relative_to(ROOT)}:")
            for path in touched_files(patch_path):
                print(f"    {path}")
        return 0

    print(f"[ucsync] Versión de Chromium: {version}")
    failures = 0
    with tempfile.TemporaryDirectory(prefix="ucsync-verify-") as tmp:
        src = Path(tmp) / "src"
        src.mkdir()
        all_files = sorted({path for patch_path in patches for path in touched_files(patch_path)})
        for path in all_files:
            error = fetch(version, path, src / path)
            if error:
                print(f"[ucsync] {error}", file=sys.stderr)
                return 1
        print(f"[ucsync] {len(all_files)} ficheros descargados: {', '.join(all_files)}")

        for patch_path in patches:
            failure = apply_patch(src, patch_path)
            if failure:
                failures += 1
                print(f"[ucsync] ✗ {patch_path.name} NO aplica sobre {version}")
                print("  " + failure.replace("\n", "\n  "))
            else:
                print(f"[ucsync] ✓ {patch_path.name} aplica sobre {version}")

    if failures:
        print(
            "\n[ucsync] Hay que readaptar el parche:\n"
            "  1. `python3 ucsync/verify_patch.py --list` para ver los ficheros tocados.\n"
            "  2. Descarga la versión nueva de esos ficheros (ver SHOW_URL en este script) y\n"
            "     rehaz el cambio sobre ellos; `ucsync/rebuild_patches.sh` regenera los .patch.\n"
            "  3. Vuelve a ejecutar este script antes de subir el cambio.\n",
            file=sys.stderr,
        )
        return 1
    print("[ucsync] El parche propio sigue aplicando limpio.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
