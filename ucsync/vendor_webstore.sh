#!/usr/bin/env bash
# Vendoriza la extensión «chromium-web-store» (NeverDecaf) dentro del árbol de Chromium, igual
# que se hace con UC-Sync: sólo ficheros de texto, sin PNG.
#
# El registro en el navegador (parche 0006) la carga desde `<exe>/chromium-web-store`, y el
# empaquetado copia este directorio en el tarball/zip. Los PNG se sustituyen por un SVG con el
# icono incrustado en base64, porque un parche de texto no puede llevar binarios.
#
# Uso: ./ucsync/vendor_webstore.sh --src <árbol chromium/src> --repo <clon de chromium-web-store>
set -euo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    *) echo "argumento desconocido: $1"; exit 1;;
  esac
done
[[ -f "$SRC/chrome/browser/resources" ]] || [[ -d "$SRC/chrome/browser" ]] || { echo "no es un árbol de Chromium: $SRC"; exit 1; }
[[ -f "$REPO/src/manifest.json" ]] || { echo "no hay src/manifest.json en $REPO (clon de chromium-web-store)"; exit 1; }

DEST="$SRC/chrome/browser/resources/chromium-web-store"
mkdir -p "$DEST"
rsync -a --delete --exclude '.git' --exclude 'assets/icon' "$REPO/src/" "$DEST/"

python3 - "$REPO" "$DEST" <<'PY'
import base64, json, pathlib, sys

repo, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# Un solo icono: el PNG de 128 incrustado en un SVG (el navegador rasteriza SVG para los iconos).
png = repo / 'src' / 'assets' / 'icon' / 'icon_128.png'
svg_dir = dest / 'assets' / 'icon'
svg_dir.mkdir(parents=True, exist_ok=True)
b64 = base64.b64encode(png.read_bytes()).decode()
(svg_dir / 'icon.svg').write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
    f'<image width="128" height="128" href="data:image/png;base64,{b64}"/></svg>\n')

manifest = json.loads((dest / 'manifest.json').read_text())
icon = 'assets/icon/icon.svg'
manifest['icons'] = {size: icon for size in ('16', '24', '32', '48', '64', '128')}
if 'action' in manifest and 'default_icon' in manifest['action']:
    manifest['action']['default_icon'] = icon
(dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

print(f"[webstore] {manifest['version']} vendida en {dest}")
print('[webstore] icono:', icon, '(SVG con el PNG en base64)')
PY

# Lock: de dónde viene el código vendido, para poder detectar desincronización con upstream.
tag="$(git -C "$REPO" describe --tags --always 2>/dev/null || echo sin-tag)"
sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo sin-commit)"
version="$(python3 -c "import json;print(json.load(open('$DEST/manifest.json'))['version'])")"
cat > "$FORK/ucsync/webstore.lock.json" <<JSON
{
  "repo": "https://github.com/NeverDecaf/chromium-web-store",
  "tag": "$tag",
  "commit": "$sha",
  "extensionVersion": "$version",
  "extensionId": "ocaahdebbfolfmndjeplogmgcagdmblk",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo "[webstore] lock escrito: $version ($tag)"
