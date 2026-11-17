#!/usr/bin/env bash
# Registra de qué commit de UC-Sync viene el código embebido del parche 0003.
#
# 0003 es una copia de `extension/` del repositorio UC-Sync. Sin este registro no hay forma de
# saber qué versión del navegador incluye qué versión de la extensión, ni si el fork está
# desincronizado. Se ejecuta justo después de `make_ucsync_patches.sh`.
#
# Uso: ./ucsync/record_extension_lock.sh <ruta-de-uc-sync>
set -euo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-/IA/uc-sync}"
PATCH="$FORK/patches/extra/ucsync/0003-ucsync-browser-extension.patch"
[[ -f "$PATCH" ]] || { echo "No existe $PATCH (ejecuta antes make_ucsync_patches.sh)"; exit 1; }

commit="$(git -C "$SRC" rev-parse HEAD)"
version="$(python3 -c "import json;print(json.load(open('$SRC/extension/manifest.json'))['version'])")"
sha="$(sha256sum "$PATCH" | cut -d' ' -f1)"

cat > "$FORK/ucsync/extension.lock.json" <<JSON
{
  "repo": "$(git -C "$SRC" remote get-url origin)",
  "ucsyncCommit": "$commit",
  "extensionVersion": "$version",
  "patch0003Sha256": "$sha",
  "forkCommit": "$(git -C "$FORK" rev-parse HEAD)",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo "[ucsync] lock escrito: extensión $version de $commit"
