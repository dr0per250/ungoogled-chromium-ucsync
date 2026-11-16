#!/usr/bin/env bash
# Trae los cambios de ungoogled-chromium y comprueba que el parche de UC-Sync sigue aplicando.
#
# Este repo es una copia del repositorio público de ungoogled-chromium con dos
# parches propios sobre el código de Chromium. Cuando upstream actualiza la
# versión de Chromium, el parche puede dejar de aplicar: este script hace la
# comprobación ANTES de subir nada.
#
# Uso:
#   ./ucsync/sync.sh              # fetch + merge + verificación + push
#   ./ucsync/sync.sh --no-push    # deja el merge hecho sin empujar
#   UPSTREAM=https://... ./ucsync/sync.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${UPSTREAM:-https://github.com/ungoogled-software/ungoogled-chromium.git}"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
PUSH=1
[[ "${1:-}" == "--no-push" ]] && PUSH=0

git -C "$ROOT" remote get-url upstream >/dev/null 2>&1 || git -C "$ROOT" remote add upstream "$UPSTREAM"
git -C "$ROOT" fetch upstream --tags --prune

before="$(git -C "$ROOT" rev-parse HEAD)"
if ! git -C "$ROOT" merge --no-edit upstream/master; then
  echo "[ucsync] Conflicto al fusionar upstream/master. Resuelve los ficheros propios (patches/series, revision.txt) y vuelve a ejecutar."
  exit 1
fi

if [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$before" ]]; then
  echo "[ucsync] Sin cambios nuevos de upstream."
fi

echo "[ucsync] Versión de Chromium ahora fijada: $(cat "$ROOT/chromium_version.txt")"
python3 "$ROOT/devutils/check_patch_files.py" -p "$ROOT/patches"
python3 "$ROOT/ucsync/verify_patch.py"

if [[ "$PUSH" == "1" ]]; then
  git -C "$ROOT" push origin "$BRANCH"
  echo "[ucsync] Subido $BRANCH."
else
  echo "[ucsync] Merge hecho y verificado; no se ha empujado (--no-push)."
fi
