#!/usr/bin/env bash
# Trae el binario esbuild que DevTools necesita.
#
# `third_party/devtools-frontend/src` es un repositorio anidado cuyo propio `DEPS`
# gclient no procesa, así que el binario de esbuild no aparece en el checkout y
# `ninja` falla con «third_party/devtools-frontend/src/third_party/esbuild/esbuild …
# missing and no known rule to make it». La versión la fija el `package.json` de
# DevTools; se descarga del paquete de plataforma de npm.
set -euo pipefail
SRC="${1:-/IA/chromium-build/src}"
DEVTOOLS="$SRC/third_party/devtools-frontend/src"
[[ -f "$DEVTOOLS/package.json" ]] || { echo "No hay package.json de DevTools en $DEVTOOLS"; exit 1; }
VERSION="$(python3 -c "import json,sys;print(json.load(open('$DEVTOOLS/package.json'))['devDependencies'].get('esbuild') or json.load(open('$DEVTOOLS/package.json'))['dependencies']['esbuild'])")"
DEST="$DEVTOOLS/third_party/esbuild"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[esbuild] Versión $VERSION desde el paquete @esbuild/linux-x64"
curl -sL --retry 2 --max-time 300 -o "$TMP/linux-x64.tgz" \
  "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-$VERSION.tgz"
tar -xzf "$TMP/linux-x64.tgz" -C "$TMP"
mkdir -p "$DEST"
install -m 0755 "$TMP/package/bin/esbuild" "$DEST/esbuild"
"$DEST/esbuild" --version
