#!/usr/bin/env bash
# Regenera los parches que convierten UC-Sync en parte del navegador.
#
#   0003-ucsync-browser-extension.patch   → los ficheros de la extensión embebida, en
#                                           `chrome/browser/resources/ucsync/` (texto puro: los
#                                           PNG del manifiesto se quitan, el logo pasa a SVG).
#   0004-ucsync-browser-registration.patch → registro en el arranque + `chrome://ucsync`.
#
# 0003 se genera desde el código de UC-Sync (`--extension`), 0004 desde el árbol de Chromium
# ya modificado (`--src`), comparando contra el fichero original del tag.
#
# Uso: ./ucsync/make_ucsync_patches.sh [--src <árbol chromium>] [--extension <carpeta extensión>]
set -euo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=/IA/chromium-build/src
EXT=/IA/uc-sync/extension
ONLY=""            # vacío: 0003 y 0004; "0003": sólo la extensión (CI no tiene el árbol de Chromium)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --extension) EXT="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    *) echo "opción desconocida: $1"; exit 1;;
  esac
done
[[ -d "$EXT" ]] || { echo "No existe $EXT"; exit 1; }
[[ -d "$SRC/.git" || -f "$SRC/.git" ]] || { echo "$SRC no es un checkout de git"; exit 1; }

PATCH_DIR="$FORK/patches/extra/ucsync"
mkdir -p "$PATCH_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 0003: los ficheros de la extensión, en texto -------------------------------------------
STAGE="$WORK/stage/chrome/browser/resources/ucsync"
mkdir -p "$STAGE"
rsync -a --exclude 'test' --exclude 'node_modules' --exclude 'package.json' --exclude 'icons' "$EXT/" "$STAGE/"

python3 - "$STAGE" <<'PY'
import json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
manifest = json.loads((stage / 'manifest.json').read_text())
manifest.pop('icons', None)                      # sin PNG: el botón usa el icono por defecto
if 'action' in manifest:
    manifest['action'].pop('default_icon', None)
(stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

logo = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" role="img" aria-label="UC-Sync">
  <rect width="48" height="48" rx="10" fill="#1f6feb"/>
  <path d="M24 12a12 12 0 0 1 11 8.5l-4.6 1.6A7.2 7.2 0 0 0 24 17.2 7.2 7.2 0 0 0 17.6 24l3.6 3.6-8.4 2.4 2.4-8.4 3.2 3.2A7.2 7.2 0 0 1 24 12z" fill="#fff"/>
  <path d="M24 36a12 12 0 0 1-11-8.5l4.6-1.6A7.2 7.2 0 0 0 24 30.8 7.2 7.2 0 0 0 30.4 24l-3.6-3.6 8.4-2.4-2.4 8.4-3.2-3.2A7.2 7.2 0 0 1 24 36z" fill="#cfe3ff"/>
</svg>
'''
(stage / 'logo.svg').write_text(logo)
for name in ('options.html', 'popup.html'):
    page = stage / name
    if not page.exists():
        continue
    html = page.read_text().replace('<img src="icons/48.png" alt="">', '<img src="logo.svg" alt="">')
    html = html.replace('<img src="icons/16.png" alt="">', '<img src="logo.svg" alt="">')
    html = html.replace('icons/16.png', 'logo.svg').replace('icons/48.png', 'logo.svg')
    page.write_text(html)
print('[ucsync] manifiesto sin PNG y logo.svg añadido')
PY

git -C "$WORK/stage" init -q
git -C "$WORK/stage" commit -q --allow-empty -m base
git -C "$WORK/stage" add -A
git -C "$WORK/stage" diff --cached > "$PATCH_DIR/0003-ucsync-browser-extension.patch"
echo "[ucsync] 0003: $(grep -c '^diff --git' "$PATCH_DIR/0003-ucsync-browser-extension.patch") ficheros"

# --- 0004: registro en el navegador ----------------------------------------------------------
# 0004 se genera desde el árbol de Chromium ya modificado: sin árbol (CI) se omite.
if [[ -n "$ONLY" && "$ONLY" != "0004" ]]; then
  : > "$PATCH_DIR/0004-ucsync-browser-registration.patch.keep"
  rm -f "$PATCH_DIR/0004-ucsync-browser-registration.patch.keep"
  echo "[ucsync] --only $ONLY: se deja 0004 intacto (no hay árbol de Chromium)"
fi
if [[ -z "$ONLY" || "$ONLY" == "0004" ]]; then
MODIFIED=(
  chrome/browser/extensions/BUILD.gn
  chrome/browser/extensions/chrome_content_browser_client_extensions_part.cc
  chrome/browser/extensions/extension_management.cc
  chrome/browser/extensions/extension_service.cc
  chrome/browser/ui/webui/BUILD.gn
  chrome/browser/ui/webui/chrome_web_ui_configs.cc
  chrome/common/webui_url_constants.cc
  chrome/common/webui_url_constants.h
  extensions/browser/api/messaging/message_service_bindings.cc
  extensions/browser/extension_util.cc
  extensions/browser/extension_util.h
  extensions/browser/extension_web_contents_observer.cc
  extensions/common/constants.h
  extensions/common/extension_urls.cc
  extensions/common/extension_urls.h
  extensions/renderer/script_context_set.cc
)
NEW=(
  chrome/browser/ucsync/BUILD.gn
  chrome/browser/ucsync/ucsync_constants.h
  chrome/browser/extensions/ucsync_built_in_extension.h
  chrome/browser/extensions/ucsync_built_in_extension.cc
  chrome/browser/ui/webui/ucsync/BUILD.gn
  chrome/browser/ui/webui/ucsync/ucsync_ui.h
  chrome/browser/ui/webui/ucsync/ucsync_ui.cc
)
OUT="$WORK/0004.patch"
: > "$OUT"
# La base del diff es el fichero tal y como queda DESPUÉS de los parches de upstream: comparando
# contra el tag en crudo el parche arrastraría cambios que ya aportan otros parches.
for path in "${MODIFIED[@]}"; do
  BASE="$WORK/base"
  rm -rf "$BASE"
  mkdir -p "$(dirname "$BASE/$path")"
  git -C "$SRC" show "HEAD:$path" > "$BASE/$path"
  # Se extrae de cada parche de upstream sólo la sección de este fichero y se aplica en el orden
  # de la serie: así la base coincide con el árbol real sobre el que se escribe el parche.
  for other in $(grep -v '^extra/ucsync/' patches/series); do
    if python3 "$FORK/ucsync/patch_sections.py" "patches/$other" "$path" --out "$WORK/section.patch"; then
      patch -p1 -s -f --forward -i "$WORK/section.patch" -d "$BASE" >/dev/null 2>&1 || true
    fi
  done
  diff -u --label "a/$path" --label "b/$path" "$BASE/$path" "$SRC/$path" >> "$OUT" || true
done
for path in "${NEW[@]}"; do
  [[ -f "$SRC/$path" ]] || { echo "Falta $SRC/$path (¿se perdió la modificación?)"; exit 1; }
  # Sin etiqueta para el lado "a": el parche queda con `--- /dev/null`, y verify_patch.py
  # entiende que el fichero es nuevo (no existe en el tag de upstream).
  diff -u --label /dev/null --label "b/$path" /dev/null "$SRC/$path" >> "$OUT" || true
done
cp "$OUT" "$PATCH_DIR/0004-ucsync-browser-registration.patch"
echo "[ucsync] 0004: $(grep -c '^+++ ' "$PATCH_DIR/0004-ucsync-browser-registration.patch") ficheros"
fi

# --- serie ----------------------------------------------------------------------------------
SERIES="$FORK/patches/series"
for entry in extra/ucsync/0003-ucsync-browser-extension.patch extra/ucsync/0004-ucsync-browser-registration.patch; do
  grep -qxF "$entry" "$SERIES" || echo "$entry" >> "$SERIES"
done
echo "[ucsync] serie:"
grep -n "ucsync" "$SERIES"
