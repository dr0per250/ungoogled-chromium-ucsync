#!/usr/bin/env bash
# Regenera `0007-chromper-default-search-engine.patch`: Google como buscador integrado.
#
# Dos piezas:
#   1. `third_party/search_engines_data/resources/definitions/prepopulated_engines.json`: undo
#      parcial de `core/ungoogled-chromium/replace-google-search-engine-with-nosearch.patch`, que
#      convierte el motor `google` en el marcador «No Search». Aquí se restaura el bloque original
#      de Google, así los perfiles nuevos arrancan con Google (los ajustes regionales ES/AR/… lo
#      ponen primero en su lista).
#   2. `components/search_engines/default_search_manager.cc`: limpia la preferencia del buscador
#      por defecto cuando apunta al marcador `nosearch`, para que los perfiles ya creados vuelvan a
#      Google una sola vez (si el usuario elige otro motor después, no se toca).
#
# La base del JSON no sale de `git show HEAD:` porque ese fichero viene del submódulo
# `external/search_engines_data` y no está en el tag de chromium/src: se guarda en
# `ucsync/baseline/` ya con el parche de ungoogled aplicado. `--refresh-baseline` la vuelve a
# construir cuando el submódulo cambie (necesita red).
#
# Uso: ./ucsync/make_search_patch.sh --src <chromium/src> [--refresh-baseline]
set -euo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
REFRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --refresh-baseline) REFRESH=1; shift;;
    *) echo "argumento desconocido: $1"; exit 1;;
  esac
done
[[ -d "$SRC" ]] || { echo "no existe el árbol: $SRC"; exit 1; }

JSON_PATH="third_party/search_engines_data/resources/definitions/prepopulated_engines.json"
BASE_FLAT="third_party_search_engines_data_resources_definitions_prepopulated_engines.json"
BASE="$FORK/ucsync/baseline/$BASE_FLAT"
MANAGER="components/search_engines/default_search_manager.cc"
OUT="$FORK/patches/extra/ucsync/0007-chromper-default-search-engine.patch"
NOSEARCH_PATCH="$FORK/patches/core/ungoogled-chromium/replace-google-search-engine-with-nosearch.patch"
# Commit del submódulo, leído del DEPS de chromium/src.
SUBMODULE_COMMIT="$(grep -A 2 "src/third_party/search_engines_data/resources'" "$SRC/DEPS" | grep -o '[0-9a-f]\{40\}' | head -1)"

if [[ "$REFRESH" == "1" ]]; then
  [[ -n "$SUBMODULE_COMMIT" ]] || { echo "no se encontró el commit del submódulo en $SRC/DEPS"; exit 1; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://chromium.googlesource.com/external/search_engines_data.git/+show/$SUBMODULE_COMMIT/definitions/prepopulated_engines.json?format=TEXT" \
    | base64 -d > "$TMP/pristine.json"
  mkdir -p "$TMP/base/$JSON_PATH" 2>/dev/null || true
  cp "$TMP/pristine.json" "$TMP/pristine_only.json"
  # Se aplica sólo la sección del parche que sustituye Google por «No Search».
  python3 "$FORK/ucsync/patch_sections.py" "$NOSEARCH_PATCH" "$JSON_PATH" --out "$TMP/seccion.patch"
  STAGE="$TMP/stage"; mkdir -p "$STAGE/$(dirname "$JSON_PATH")"
  cp "$TMP/pristine_only.json" "$STAGE/$JSON_PATH"
  ( cd "$STAGE" && patch -p1 -s -f --forward -i "$TMP/seccion.patch" )
  cp "$STAGE/$JSON_PATH" "$BASE"
  echo "[buscador] base actualizada desde $SUBMODULE_COMMIT ($(wc -c < "$BASE") bytes)"
fi

[[ -f "$BASE" ]] || { echo "falta la base $BASE (ejecuta --refresh-baseline)"; exit 1; }
[[ -f "$SRC/$JSON_PATH" ]] || { echo "no existe $SRC/$JSON_PATH"; exit 1; }

TMPM="$(mktemp)"; trap 'rm -f "$TMPM"' EXIT
git -C "$SRC" show "HEAD:$MANAGER" > "$TMPM"

{
  diff -u --label "a/$JSON_PATH" --label "b/$JSON_PATH" "$BASE" "$SRC/$JSON_PATH" || true
  diff -u --label "a/$MANAGER" --label "b/$MANAGER" "$TMPM" "$SRC/$MANAGER" || true
} > "$OUT"

echo "[buscador] $OUT ($(grep -c '^+++' "$OUT") ficheros)"
grep -qxF 'extra/ucsync/0007-chromper-default-search-engine.patch' "$FORK/patches/series" ||
  echo 'extra/ucsync/0007-chromper-default-search-engine.patch' >> "$FORK/patches/series"
echo "[buscador] nombre restaurado: $(grep -m1 '"name": "Google"' "$SRC/$JSON_PATH" || echo 'NO')"
