#!/usr/bin/env bash
# Compila el Chromium de UC-Sync (ungoogled-chromium + nuestros parches).
#
# Requisitos: python3, curl, patch, git, ninja, y depot_tools en PATH (para `gn`
# y `gclient`). Reserva ~120 GB en el disco de WORK y varias horas la primera vez.
#
# Uso:
#   WORK=/IA/chromium-build ./ucsync/build.sh            # descarga, parchea y compila
#   WORK=/IA/chromium-build ./ucsync/build.sh --prepare  # sólo descarga y parchea
#   WORK=/IA/chromium-build ./ucsync/build.sh --chrome   # ninja -C out/Default chrome
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/IA/chromium-build}"
SRC="$WORK/build/src"
JOBS="${JOBS:-$(nproc)}"

prepare() {
  mkdir -p "$WORK/build/download_cache"
  echo "[ucsync] Descargando Chromium $(cat "$ROOT/chromium_version.txt")"
  python3 "$ROOT/utils/downloads.py" retrieve -c "$WORK/build/download_cache" -i "$ROOT/downloads.ini"
  python3 "$ROOT/utils/downloads.py" unpack -c "$WORK/build/download_cache" -i "$ROOT/downloads.ini" -- "$SRC"

  echo "[ucsync] Poda de binarios"
  python3 "$ROOT/utils/prune_binaries.py" "$SRC" "$ROOT/pruning.list"

  echo "[ucsync] Aplicando parches (incluidos los de UC-Sync)"
  python3 "$ROOT/utils/patches.py" apply "$SRC" "$ROOT/patches"

  echo "[ucsync] Sustitución de dominios"
  python3 "$ROOT/utils/domain_substitution.py" apply -r "$ROOT/domain_regex.list" \
    -f "$ROOT/domain_substitution.list" -c "$WORK/build/domsubcache.tar.gz" "$SRC"
}

build() {
  command -v gn >/dev/null 2>&1 || {
    echo "[ucsync] Falta 'gn': instala depot_tools y ponlo en PATH (git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git)"
    exit 1
  }
  mkdir -p "$SRC/out/Default"
  cp "$ROOT/flags.gn" "$SRC/out/Default/args.gn"
  gn gen "$SRC/out/Default" --fail-on-unused-args
  ninja -C "$SRC/out/Default" chrome chromedriver chrome_sandbox
  echo "[ucsync] Binario: $SRC/out/Default/chrome"
}

case "${1:-}" in
  --prepare) prepare ;;
  --chrome) build ;;
  "") prepare; build ;;
  *) echo "Opción desconocida: $1 (usa --prepare o --chrome)"; exit 1 ;;
esac
