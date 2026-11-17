#!/usr/bin/env bash
# Empaqueta el navegador compilado y sube el binario al release de este fork.
#
# Necesita `gh` autenticado y el binario ya construido (`ucsync/build.sh --chrome`).
# El tag del release es `chromium-<versión>`, que es el que crea el bump automático.
#
# Uso:
#   ./ucsync/make_release.sh --src ~/ucbuild/src                  # Linux x64
#   ./ucsync/make_release.sh --src ~/ucbuild/src --only-tarball   # empaqueta sin subir
set -euo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
ONLY_TARBALL=0
OUT="${OUT:-$FORK/dist}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --only-tarball) ONLY_TARBALL=1; shift;;
    *) echo "opción desconocida: $1"; exit 1;;
  esac
done
[[ -n "$SRC" ]] || { echo "Falta --src <árbol de Chromium>"; exit 1; }
VERSION="$(cat "$FORK/chromium_version.txt")"
TAG="chromium-$VERSION"
REPO="$(git -C "$FORK" remote get-url origin | sed -E 's#(https://github.com/|git@github.com:)##; s#\.git$##')"

mkdir -p "$OUT"
"$FORK/ucsync/package_linux.sh" --src "$SRC" --out "$OUT" --version "$VERSION"
[[ "$ONLY_TARBALL" == "1" ]] && { echo "[release] Tarball en $OUT (sin subir)."; exit 0; }

command -v gh >/dev/null 2>&1 || { echo "Falta gh para subir"; exit 1; }
git -C "$FORK" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || \
  git -C "$FORK" -c user.name=dr0per250 -c user.email=dr0per250@users.noreply.github.com \
      tag -a "$TAG" -m "Chromium $VERSION con los parches de UC-Sync"
git -C "$FORK" push origin "$TAG" 2>/dev/null || true
gh release create "$TAG" -R "$REPO" --title "Chromium $VERSION con UC-Sync integrado (Linux x64)" \
  --notes "Build Linux x64 verificado: hora real en chrome://history, UI en chrome://ucsync y extensión integrada con ID fijo. Instálalo con una línea: \`ucsync/execute.sh\`." 2>/dev/null || true
gh release upload "$TAG" "$OUT/ucsync-chromium-linux-x64.tar.gz" "$OUT/ucsync-chromium-linux-x64-$VERSION.tar.gz" \
  -R "$REPO" --clobber
echo "[release] Subido a https://github.com/$REPO/releases/tag/$TAG"
