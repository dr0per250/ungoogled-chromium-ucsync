#!/usr/bin/env bash
# Crea el espacio de trabajo de parches con los ficheros prístinos de la versión fijada.
#
# Si ya hay .patch en patches/extra/ucsync/, se descargan los ficheros que esos
# parches tocan y se deja un commit prístino listo para volver a editarlos.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/ucsync/work}"
VERSION="$(cat "$ROOT/chromium_version.txt")"

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
git init -q .

mapfile -t files < <(python3 "$ROOT/ucsync/verify_patch.py" --list | grep -E '^\s{4}' | tr -d ' ')
if [[ ${#files[@]} -eq 0 ]]; then
  files=(
    chrome/browser/extensions/api/history/history_api.cc
    chrome/browser/extensions/api/history/history_api.h
    chrome/browser/extensions/api/history/history_apitest.cc
    chrome/common/extensions/api/history.json
    extensions/browser/extension_function_histogram_value.h
  )
fi

for path in "${files[@]}"; do
  mkdir -p "$(dirname "$path")"
  curl -sL --retry 2 --max-time 90 \
    "https://chromium.googlesource.com/chromium/src/+show/refs/tags/$VERSION/$path?format=TEXT" \
    | base64 -d > "$path"
  echo "Descargado $path"
done

git add -A
git -c user.name=ucsync -c user.email=ucsync@localhost commit -qm "Chromium $VERSION (ficheros que toca el parche de UC-Sync)"
echo "Espacio de trabajo en $WORK (versión $VERSION). Edita, commitea un commit por parche y ejecuta ucsync/rebuild_patches.sh"
