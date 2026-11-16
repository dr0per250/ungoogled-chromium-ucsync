#!/usr/bin/env python3
"""Instala las dependencias de Chromium que `gclient sync` se salta en un checkout de git.

Motivo: la mayoría de las dependencias de herramienta (clang, rust, gn, ninja, mold,
typescript, node, sysroots…) están condicionadas en `DEPS` a `non_git_source`, que gclient
pone a `False` en un checkout de git. Con eso el árbol compila "en theory" pero `ninja` se
cae con `missing and no known rule to make it`.

Este script lee `DEPS`, toma las entradas `cipd` y `gcs` que corresponden a Linux/x64 y las
instala con `cipd ensure` o descargándolas del bucket de GCS y extrayendo el tar.

Uso:
    python3 ucsync/install_deps.py --src /IA/chromium-build/src            # instala
    python3 ucsync/install_deps.py --src /IA/chromium-build/src --list     # sólo lista
    python3 ucsync/install_deps.py --src ... --filter typescript           # subset
"""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

SKIP_CONDITIONS = (
    "checkout_android",
    "checkout_ios",
    "checkout_mac",
    "checkout_win",
    "chrome_internal",
    "checkout_src_internal",
    "checkout_chromecast",
    "checkout_autoclip",
    "host_os == \"mac\"",
    "host_os == \"win\"",
    "checkout_arm",
    "checkout_mips",
    "checkout_ppc",
    "checkout_s390",
    "rbe",
)


def parse_deps(src):
    """Ejecuta DEPS con stubs y devuelve el dict `deps`."""
    text = pathlib.Path(src, "DEPS").read_text(encoding="utf-8")

    def Var(name):  # noqa: N802 - el nombre lo fija DEPS
        return f"{name}"

    def Str(value):  # noqa: N802
        return value

    def List(value):  # noqa: N802
        return list(value)

    ns = {"Var": Var, "Str": Str, "List": List, "Dict": dict}
    exec(compile(text, "DEPS", "exec"), ns)  # noqa: S102 - DEPS es un fichero de configuración
    return ns.get("deps", {}), ns.get("vars", {})


def resolve(value, variables):
    """`Var('x')` devuelve el nombre de la variable; aquí se sustituye por su valor."""
    if isinstance(value, str) and value in variables:
        return variables[value]
    return value


def usable(condition):
    condition = condition or ""
    return not any(skip in condition for skip in SKIP_CONDITIONS)


def extract_tar(path, dest):
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path) as tar:
        tar.extractall(dest, filter="data")


def download(url, dest):
    with urllib.request.urlopen(url, timeout=600) as response:  # noqa: S310 - url fija de GCS
        dest.write_bytes(response.read())


def cipd_entries(deps, variables):
    """{ruta_relativa_a_src: [líneas de ensure file]} para las dependencias cipd."""
    out = {}
    for key, entry in deps.items():
        if not isinstance(entry, dict) or entry.get("dep_type") != "cipd":
            continue
        if not usable(entry.get("condition", "")):
            continue
        path = key[len("src/"):] if key.startswith("src/") else key
        lines = []
        for pkg in entry.get("packages", []):
            name = resolve(pkg.get("package", ""), variables)
            version = resolve(pkg.get("version", ""), variables)
            if not name or not version:
                continue
            name = name.replace("${{platform}}", "linux-amd64").replace("${{arch}}", "amd64")
            lines.append(f"{name} {version}")
        if lines:
            out.setdefault(path, []).extend(lines)
    return out


def gcs_entries(deps, variables):
    out = {}
    for key, entry in deps.items():
        if not isinstance(entry, dict) or entry.get("dep_type") != "gcs":
            continue
        if not usable(entry.get("condition", "")):
            continue
        path = key[len("src/"):] if key.startswith("src/") else key
        objects = [o for o in entry.get("objects", []) if usable(o.get("condition", ""))]
        if objects:
            out.setdefault(path, []).extend([(entry["bucket"], o) for o in objects])
    return out


def install_cipd(src, entries, cipd_bin, tmp):
    failures = []
    for path, lines in sorted(entries.items()):
        root = pathlib.Path(src, path)
        if root.exists() and any(root.glob("*")) and not path.endswith("/host"):
            print(f"[deps] {path}: ya tiene contenido, se omite")
            continue
        root.mkdir(parents=True, exist_ok=True)
        ensure = pathlib.Path(tmp, f"{path.replace('/', '_')}.ensure")
        ensure.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = subprocess.run([str(cipd_bin), "ensure", "-root", str(root), "-ensure-file", str(ensure)],
                                capture_output=True, text=True, check=False)
        if result.returncode != 0:
            failures.append((path, (result.stdout + result.stderr).strip().splitlines()[-1:]))
            print(f"[deps] ✗ {path}")
        else:
            print(f"[deps] ✓ {path}  ({', '.join(lines)})")
    return failures


def install_gcs(src, entries, tmp):
    failures = []
    for path, objects in sorted(entries.items()):
        root = pathlib.Path(src, path)
        if root.exists() and any(root.glob("*")):
            print(f"[deps] {path}: ya tiene contenido, se omite")
            continue
        root.mkdir(parents=True, exist_ok=True)
        for bucket, obj in objects:
            url = f"https://storage.googleapis.com/{bucket}/{obj['object_name']}"
            blob = pathlib.Path(tmp, re.sub(r"[^A-Za-z0-9._-]", "_", obj["object_name"]) or "blob")
            try:
                download(url, blob)
                extract_tar(blob, root)
                print(f"[deps] ✓ {path} ← {bucket}/{obj['object_name']}")
            except Exception as err:  # noqa: BLE001 - se reporta por dependencias
                failures.append((path, str(err)))
                print(f"[deps] ✗ {path} ← {url}: {err}")
            finally:
                blob.unlink(missing_ok=True)
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", required=True, help="checkout de chromium/src")
    parser.add_argument("--list", action="store_true", help="sólo listar")
    parser.add_argument("--filter", default="", help="instala sólo las rutas que contienen este texto")
    parser.add_argument("--cipd", default=None, help="ruta del binario cipd")
    args = parser.parse_args()

    src = pathlib.Path(args.src).resolve()
    deps, variables = parse_deps(src)
    cipd_bin = pathlib.Path(args.cipd or shutil.which("cipd") or "/IA/chromium-build/depot_tools/cipd")

    cipd = cipd_entries(deps, variables)
    gcs = gcs_entries(deps, variables)
    if args.filter:
        cipd = {k: v for k, v in cipd.items() if args.filter in k}
        gcs = {k: v for k, v in gcs.items() if args.filter in k}

    print(f"[deps] cipd: {len(cipd)} rutas · gcs: {len(gcs)} rutas")
    if args.list:
        for path in sorted(cipd):
            print(f"  cipd {path}: {' | '.join(cipd[path])}")
        for path in sorted(gcs):
            names = ", ".join(f"{bucket}/{obj['object_name']}" for bucket, obj in gcs[path])
            print(f"  gcs  {path}: {names}")
        return 0

    with tempfile.TemporaryDirectory(prefix="ucsync-deps-") as tmpdir:
        tmp = pathlib.Path(tmpdir)
        failures = install_cipd(src, cipd, cipd_bin, tmp) + install_gcs(src, gcs, tmp)

    if failures:
        print(f"[deps] {len(failures)} dependencias sin instalar: {json.dumps([f[0] for f in failures])}",
              file=sys.stderr)
        return 1
    print("[deps] Todo instalado.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
