#!/usr/bin/env bash
# Actualiza el fork a la versión de Chromium que trae upstream y comprueba nuestros parches.
#
# Es la parte mecánica de la integración: fusionar `upstream/master`, validar que la serie
# sigue aplicando (incluidos los 4 parches de UC-Sync) y, si todo aplica, dejar el cambio
# hecho, etiquetado y empujado. Si algún parche rechaza, NO se sube nada: se revierte el merge
# y se abre un issue con los rechazos, que es lo que necesita un humano o un agente.
#
# Uso:
#   ./ucsync/bump.sh                 # funde upstream y valida; no escribe (informativo)
#   ./ucsync/bump.sh --apply         # lo mismo y, si aplica, merge + tag + push
#   ./ucsync/bump.sh --apply --issue # además abre un issue si algo rechaza (necesita gh)
#   ./ucsync/bump.sh --to 158.0.8413.4 --apply   # fija una versión concreta (adelantarse a upstream)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${UPSTREAM:-https://github.com/ungoogled-software/ungoogled-chromium.git}"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
APPLY=0
ISSUE=0
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1;;
    --issue) ISSUE=1;;
    --to) TARGET="$2"; shift 2;;
    *) echo "opción desconocida: $1"; exit 1;;
  esac
done

cd "$ROOT"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "${UPSTREAM:-https://github.com/ungoogled-software/ungoogled-chromium.git}"
git fetch upstream --tags --prune

BEFORE="$(git rev-parse HEAD)"
OLD_VERSION="$(cat chromium_version.txt)"

if [[ -n "$TARGET" ]]; then
  # Adelantarse a upstream: sólo válido si el tag existe en chromium/src.
  if ! git ls-remote --tags https://chromium.googlesource.com/chromium/src.git "refs/tags/$TARGET" \
      | grep -q "refs/tags/$TARGET"; then
    echo "[bump] El tag $TARGET no existe en chromium/src"; exit 1
  fi
  echo "$TARGET" > chromium_version.txt
  git add chromium_version.txt
  git -c user.name="${GIT_AUTHOR_NAME:-ucsync-bot}" -c user.email="${GIT_AUTHOR_EMAIL:-ucsync@localhost}" \
    commit -m "chromium_version.txt: $TARGET (adelantando a upstream)"
fi

if ! git merge --no-edit upstream/master; then
  echo "[bump] Conflicto fusionando upstream/master; nada subido."
  git merge --abort || true
  REPORT="/tmp/ucsync-bump-conflict.txt"
  git status --porcelain > "$REPORT" || true
  if [[ "$ISSUE" == "1" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create --title "UC-Sync: conflicto al fusionar upstream (Chromium $(cat chromium_version.txt))" \
      --label bug --body "Upstream trae cambios que chocan con el árbol del fork. Ficheros en conflicto en `$REPORT`." || true
  fi
  exit 2
fi

NEW_VERSION="$(cat chromium_version.txt)"
if [[ "$(git rev-parse HEAD)" == "$BEFORE" && "$NEW_VERSION" == "$OLD_VERSION" ]]; then
  echo "[bump] Nada nuevo de upstream (Chromium $NEW_VERSION)."
  exit 0
fi
echo "[bump] Chromium: $OLD_VERSION -> $NEW_VERSION"

python3 devutils/check_patch_files.py -p patches

FAIL_LOG="/tmp/ucsync-bump-rejects.txt"
: > "$FAIL_LOG"
if ! python3 ucsync/verify_patch.py "$NEW_VERSION" 2>&1 | tee "$FAIL_LOG"; then
  echo "[bump] Algún parche de UC-Sync no aplica en $NEW_VERSION: se revierte el merge y no se sube nada."
  git reset --hard "$BEFORE" >/dev/null
  if [[ "$ISSUE" == "1" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create --title "UC-Sync: los parches no aplican en Chromium $NEW_VERSION" \
      --label bug --body-file <(
        printf 'Upstream trajo Chromium **%s**. Nuestros parches de `patches/extra/ucsync/` rechazan:\n\n```\n' "$NEW_VERSION"
        tail -60 "$FAIL_LOG"
        printf '\n```\n\nReadaptar y volver a lanzar `ucsync/bump.sh --apply --issue`.\n'
      ) || echo "[bump] No se pudo abrir el issue (gh)"
  fi
  exit 1
fi

if [[ "$APPLY" == "1" ]]; then
  git push origin "$BRANCH"
  TAG="chromium-$NEW_VERSION"
  if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git tag -a "$TAG" -m "Chromium $NEW_VERSION con los parches de UC-Sync"
    git push origin "$TAG"
  fi
  echo "[bump] Subido $BRANCH y etiquetado $TAG."
else
  echo "[bump] Merge validado localmente (--apply para subir)."
fi
