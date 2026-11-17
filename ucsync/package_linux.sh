#!/usr/bin/env bash
# Empaqueta Chromper (Chromium sin Google con UC-Sync integrado) para Linux x64.
#
# Coge del `out/Default` sólo lo que necesita el navegador en tiempo de ejecución, recorta los
# idiomas y coloca la extensión integrada (`ucsync/`) junto al binario, que es donde
# `ucsync_built_in_extension.cc` la busca.
#
# Uso:
#   ./ucsync/package_linux.sh --src ~/ucbuild/src              # out/Default por defecto
#   ./ucsync/package_linux.sh --src ~/ucbuild/src --out ~/paquetes
#   LOCALES="es en-US" ./ucsync/package_linux.sh --src ~/ucbuild/src
set -euo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
OUT="$PWD"
VERSION="$(cat "$FORK/chromium_version.txt")"
# Nombres de pak reales: el español de España es `es.pak` (no existe es-ES.pak; es-ES, es-MX y
# es-AR se resuelven a es o es-419). en-US.pak es obligatorio como idioma base de reserva.
LOCALES="${LOCALES:-es es-419 en-US pt-BR fr de it gl ca eu ja zh-CN zh-TW ru}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    *) echo "opción desconocida: $1"; exit 1;;
  esac
done
[[ -n "$SRC" ]] || { echo "Falta --src <árbol de Chromium>"; exit 1; }
BUILD="$SRC/out/Default"
[[ -x "$BUILD/chrome" ]] || { echo "No hay binario en $BUILD (ejecuta ucsync/build.sh --chrome)"; exit 1; }

mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/chromper"
mkdir -p "$PKG"

echo "[package] Binario y helpers"
cp -a "$BUILD/chrome" "$PKG/chromper"
ln -sf chromper "$PKG/chrome"           # compatibilidad: el motor busca vecinos por su nombre
[[ -f "$BUILD/product_logo_48.png" ]] && cp -a "$BUILD/product_logo_48.png" "$PKG/"
for f in chrome_sandbox chrome_crashpad_handler; do
  [[ -f "$BUILD/$f" ]] && cp -a "$BUILD/$f" "$PKG/"
done

echo "[package] Recursos"
for f in resources.pak chrome_100_percent.pak chrome_200_percent.pak browser_resources.pak icudtl.dat v8_context_snapshot.bin \
         libEGL.so libGLESv2.so libvk_swiftshader.so vk_swiftshader_icd.json \
         libVkLayer_khronos_validation.so; do
  [[ -f "$BUILD/$f" ]] && cp -a "$BUILD/$f" "$PKG/"
done

echo "[package] Idiomas ($LOCALES)"
mkdir -p "$PKG/locales"
for loc in $LOCALES; do
  [[ -f "$BUILD/locales/$loc.pak" ]] && cp -a "$BUILD/locales/$loc.pak" "$PKG/locales/"
done
[[ -f "$PKG/locales/en-US.pak" ]] || { echo "Falta en-US.pak: el navegador no arranca sin idioma base"; exit 1; }

echo "[package] Extensión integrada"
if [[ -d "$SRC/chrome/browser/resources/ucsync" ]]; then
  cp -a "$SRC/chrome/browser/resources/ucsync" "$PKG/ucsync"
else
  echo "[package] Aviso: no hay recursos de UC-Sync en el árbol (falta el parche 0003)."
fi

cat > "$PKG/VERSION" <<TXT
chromium=$VERSION
fork=$(git -C "$FORK" rev-parse --short HEAD)
ucsyncExtension=$(python3 -c "import json;print(json.load(open('$PKG/ucsync/manifest.json'))['version'])" 2>/dev/null || echo n/d)
buildId=$(git -C "$FORK" rev-parse --short HEAD)-$(date -u +%Y%m%d%H%M)
TXT

# Nombre estable (lo usa el instalador con `releases/latest/download/…`) y nombre con versión.
STABLE="$OUT/chromper-linux-x64.tar.gz"
VERSIONED="$OUT/chromper-linux-x64-$VERSION.tar.gz"
tar czf "$STABLE" -C "$STAGE" chromper
cp "$STABLE" "$VERSIONED"
echo "[package] $STABLE ($(du -h "$STABLE" | cut -f1))"
echo "[package] $VERSIONED"
