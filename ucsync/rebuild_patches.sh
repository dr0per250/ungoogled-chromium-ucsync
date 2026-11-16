#!/usr/bin/env bash
# Regenera los .patch de UC-Sync desde el espacio de trabajo de parches.
#
# El espacio de trabajo (`ucsync/work/`, no versionado) es un repositorio git
# con los ficheros de Chromium que tocamos, tal como están en la versión fijada
# en `chromium_version.txt`:
#
#   * commit 0  → ficheros prístinos de la versión fijada
#   * commit 1..N → un commit por parche, en el orden de `patches/series`
#
# Uso:
#   ucsync/make_workspace.sh          # crea ucsync/work con el commit prístino
#   # edita ficheros en ucsync/work y haz un commit por parche
#   ucsync/rebuild_patches.sh         # vuelca los diffs a patches/extra/ucsync/
#   python3 ucsync/verify_patch.py    # comprueba que siguen aplicando
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/ucsync/work}"
OUT="$ROOT/patches/extra/ucsync"

[[ -d "$WORK/.git" ]] || { echo "No hay espacio de trabajo en $WORK (usa ucsync/make_workspace.sh)"; exit 1; }

mapfile -t commits < <(git -C "$WORK" log --reverse --format=%H | tail -n +2)
if [[ ${#commits[@]} -eq 0 ]]; then
  echo "El espacio de trabajo sólo tiene el commit prístino: no hay parches que volcar."
  exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.patch
i=0
prev="$(git -C "$WORK" log --reverse --format=%H | head -1)"
for commit in "${commits[@]}"; do
  i=$((i + 1))
  subject="$(git -C "$WORK" log -1 --format=%s "$commit")"
  name="$(printf '%04d-%s.patch' "$i" "$(echo "$subject" | tr -cs '[:alnum:]' '-' | tr '[:upper:]' '[:lower:]' | sed 's/-$//')")"
  git -C "$WORK" diff "$prev" "$commit" > "$OUT/$name"
  echo "Generado $OUT/$name ($(wc -l < "$OUT/$name") líneas) desde «$subject»"
  prev="$commit"
done

echo "Actualiza patches/series con los nombres generados y ejecuta: python3 ucsync/verify_patch.py"
