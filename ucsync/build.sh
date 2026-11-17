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
#   WORK=/IA/chromium-build ./ucsync/build.sh --prepare    # fuente + poda + parches + domsub
#                                                          # (en git trae además los deps que
#                                                          #  gclient se salta: clang-format,
#                                                          #  esbuild de DevTools, el go de Dawn)
#   WORK=/IA/chromium-build ./ucsync/build.sh --chrome     # gn gen + ninja + coloca /ucsync
#   EXTRA_GN='target_cpu="x64"' WORK=... ./ucsync/build.sh # args GN extra
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
    echo "[ucsync] Inicializando el checkout de chromium/src"
    mkdir -p "$WORK" "$SRC"
    (cd "$SRC" && git init -q . && git remote add origin https://chromium.googlesource.com/chromium/src.git)
  fi
  # Sólo el tag fijado, con historia poco profunda y sin blobs: el historial completo de
  # chromium/src son ~1 M de commits y no hace falta para compilar una versión.
  echo "[ucsync] Traendo el tag $VERSION (profundidad 1, sin blobs)"
  git -C "$SRC" fetch --depth 1 --filter=blob:none origin "refs/tags/$VERSION:refs/tags/$VERSION"
  git -C "$SRC" checkout --force "refs/tags/$VERSION"
  git -C "$SRC" clean -fdq

  [[ -f "$WORK/.gclient" ]] || (cd "$WORK" && gclient config --name "$(basename "$SRC")" \
    https://chromium.googlesource.com/chromium/src.git)

  echo "[ucsync] gclient sync (third_party y toolchains: clang, rust)"
  (cd "$WORK" && gclient sync -D -j "$JOBS")
  install_deps_git
}

# Con un checkout de git (`non_git_source = False`) gclient se salta las entradas de DEPS que
# sólo trae el tarball oficial: los binarios de cipd/gcs (clang-format, gn, ninja) y dos 3pp
# que la compilación exige (esbuild de DevTools y el go de Dawn).
install_deps_git() {
  echo "[ucsync] Dependencias de DEPS que gclient no trae en un checkout de git"
  python3 "$ROOT/ucsync/install_deps.py" --src "$SRC" || echo "[ucsync] install_deps.py falló: repite con --filter <nombre> cuando haga falta"
  bash "$ROOT/ucsync/fetch_esbuild.sh" "$SRC" || echo "[ucsync] No se pudo traer esbuild de DevTools"
  bash "$ROOT/ucsync/fetch_dawn_go.sh" "$SRC" || echo "[ucsync] No se pudo traer el go de Dawn"
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
  # `domain_substitution.py` falla si la caché ya existe: se regenera en cada preparación.
  rm -f "$WORK/build/domsubcache.tar.gz"
  python3 "$ROOT/utils/domain_substitution.py" apply -r "$ROOT/domain_regex.list" \
    -f "$ROOT/domain_substitution.list" -c "$WORK/build/domsubcache.tar.gz" "$SRC"
}

build() {
  require_tools
  mkdir -p "$SRC/out/Default"
  cp "$ROOT/flags.gn" "$SRC/out/Default/args.gn"
  #Args verificados compilando aquí (sin símbolos: el binario con debug_info no cabe en 8 GB de RAM de enlace).
  {
    echo 'is_debug = false'
    echo 'is_official_build = false'
    echo 'symbol_level = 0'
    echo 'v8_symbol_level = 0'
    [[ "$(uname -s)" == "Linux" ]] && echo 'use_sysroot = true'
    [[ -n "${EXTRA_GN:-}" ]] && echo "$EXTRA_GN"
  } >> "$SRC/out/Default/args.gn"
  (cd "$SRC" && gn gen out/Default --fail-on-unused-args)
  (cd "$SRC" && ninja -C out/Default -j "$JOBS" chrome chromedriver chrome_sandbox)
  install_ucsync_extension
  echo "[ucsync] Binario: $SRC/out/Default/chrome"
}

# Las extensiones integradas van junto al binario: los loaders las buscan en `<exe>/ucsync` y
# `<exe>/chromium-web-store`.
install_embedded_extension() {
  local name="$1" id="$2"
  local embedded="$SRC/chrome/browser/resources/$name"
  local dest="$SRC/out/Default/$name"
  if [[ ! -f "$embedded/manifest.json" ]]; then
    echo "[ucsync] No hay extensión embebida en $embedded: el navegador arranca sin ella."
    return
  fi
  rm -rf "$dest"
  cp -a "$embedded" "$dest"
  echo "[ucsync] $name embebida en $dest (ID $id)"
}

install_ucsync_extension() {
  install_embedded_extension ucsync lidfhdhmbifmhikiaklbiehnhnkhoghe
  install_embedded_extension chromium-web-store ocaahdebbfolfmndjeplogmgcagdmblk
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
