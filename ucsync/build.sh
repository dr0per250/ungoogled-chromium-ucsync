#!/usr/bin/env bash
# Compila el Chromium de UC-Sync (ungoogled-chromium + nuestros parches).
#
# Dos formas de obtener la fuente:
#   * GIT (por defecto): clon de chromium/src con `--filter=blob:none` y checkout
#     del tag fijado en chromium_version.txt, seguido de `gclient sync -D`, que es
#     lo que trae las toolchains (clang, rust) y los third_party que el tarball
#     "lite" no incluye.
#   * TARBALL=1: el archive oficial *-lite.tar.xz vía utils/downloads.py. Sirve
#     para inspeccionar o para plataformas que ya aportan las toolchains; para
#     compilar aquí usa GIT.
#
# Uso:
#   WORK=/IA/chromium-build ./ucsync/build.sh              # fuente + parches + compilación
#   WORK=/IA/chromium-build ./ucsync/build.sh --prepare    # hasta parchear y domsub
#   WORK=/IA/chromium-build ./ucsync/build.sh --chrome     # ninja chrome
#   PATH=/IA/chromium-build/depot_tools:$PATH WORK=/IA/chromium-build ./ucsync/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/IA/chromium-build}"
SRC="${SRC:-$WORK/src}"
VERSION="$(cat "$ROOT/chromium_version.txt")"
JOBS="${JOBS:-$(nproc)}"

require_tools() {
  for t in git curl patch python3 gn ninja gclient; do
    command -v "$t" >/dev/null 2>&1 || {
      echo "[ucsync] Falta '$t'. depot_tools: git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git && export PATH=\$PWD/depot_tools:\$PATH"
      exit 1
    }
  done
}

prepare_git() {
  if [[ ! -d "$SRC/.git" ]]; then
    echo "[ucsync] Clonando chromium/src (sin blobs) y checkout de $VERSION"
    mkdir -p "$WORK"
    git clone --filter=blob:none --no-checkout \
      https://chromium.googlesource.com/chromium/src.git "$SRC"
  fi
  git -C "$SRC" fetch --filter=blob:none origin --tags --prune
  git -C "$SRC" checkout --force "$VERSION"
  git -C "$SRC" clean -fdq

  [[ -f "$WORK/.gclient" ]] || (cd "$WORK" && gclient config --name "$(basename "$SRC")" \
    https://chromium.googlesource.com/chromium/src.git)

  echo "[ucsync] gclient sync (third_party y toolchains: clang, rust)"
  (cd "$WORK" && gclient sync -D --with_submodules -j "$JOBS")
}

prepare_tarball() {
  mkdir -p "$WORK/build/download_cache"
  python3 "$ROOT/utils/downloads.py" retrieve -c "$WORK/build/download_cache" -i "$ROOT/downloads.ini"
  python3 "$ROOT/utils/downloads.py" unpack -c "$WORK/build/download_cache" -i "$ROOT/downloads.ini" -- "$SRC"
}

prepare_patches() {
  echo "[ucsync] Poda de binarios"
  python3 "$ROOT/utils/prune_binaries.py" "$SRC" "$ROOT/pruning.list"

  echo "[ucsync] Aplicando parches (los de upstream y los de UC-Sync)"
  python3 "$ROOT/utils/patches.py" apply "$SRC" "$ROOT/patches"

  echo "[ucsync] Sustitución de dominios"
  python3 "$ROOT/utils/domain_substitution.py" apply -r "$ROOT/domain_regex.list" \
    -f "$ROOT/domain_substitution.list" -c "$WORK/build/domsubcache.tar.gz" "$SRC"
}

build() {
  require_tools
  mkdir -p "$SRC/out/Default"
  cp "$ROOT/flags.gn" "$SRC/out/Default/args.gn"
  (cd "$SRC" && gn gen out/Default --fail-on-unused-args)
  (cd "$SRC" && ninja -C out/Default -j "$JOBS" chrome chromedriver chrome_sandbox)
  echo "[ucsync] Binario: $SRC/out/Default/chrome"
}

case "${1:-}" in
  --prepare)
    if [[ "${TARBALL:-0}" == "1" ]]; then prepare_tarball; else prepare_git; fi
    prepare_patches
    ;;
  --chrome) build ;;
  "")
    if [[ "${TARBALL:-0}" == "1" ]]; then prepare_tarball; else prepare_git; fi
    prepare_patches
    build
    ;;
  *) echo "Opción desconocida: $1 (usa --prepare o --chrome)"; exit 1 ;;
esac
