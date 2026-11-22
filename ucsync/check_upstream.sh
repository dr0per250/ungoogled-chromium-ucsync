#!/usr/bin/env bash
# Detección local de novedades, sin escribir nada en GitHub.
#
#   ./ucsync/check_upstream.sh          # ¿hay Chromium nuevo? ¿hay chromium-web-store nuevo?
#
# Imprime qué hay y los comandos a ejecutar. La compilación siempre es local
# (`ucsync/build.sh`); GitHub sólo guarda los parches y los binarios ya compilados.
set -uo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIJADO="$(cat "$FORK/chromium_version.txt" 2>/dev/null | tr -d '\r')"
LOCK_WEBSTORE="$FORK/ucsync/webstore.lock.json"

echo "== Chromium =="
ultima="$(curl -fsSLm 30 https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json |
    python3 -c "import json,sys;print(json.load(sys.stdin)['channels']['Stable']['version'])" 2>/dev/null)";
echo "  fijado en el fork: $FIJADO"
echo "  último estable:    $ultima"
if [[ "$ultima" == "$FIJADO" ]]; then
  echo "  ✓ el fork está al día"
else
  echo "  → hay versión nueva. Comprobación local:"
  echo "      ./ucsync/verify_patch.py $ultima"
  echo "    y para preparar el árbol:"
  echo "      ./ucsync/bump.sh --to $ultima   # quita --apply/--issue si sólo quieres mirar"
fi

echo "== chromium-web-store =="
if [[ -f "$LOCK_WEBSTORE" ]]; then
  fijado="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['extensionVersion'])" "$LOCK_WEBSTORE")"
else
  fijado="(sin lock)"
fi
nueva="$(gh api repos/NeverDecaf/chromium-web-store/tags --jq '.[0].name' 2>/dev/null || echo "(no se pudo leer)")"
echo "  empaquetada: $fijado"
echo "  último tag:  $nueva"
if [[ "${nueva#v}" == "$fijado" ]]; then
  echo "  ✓ sin cambios"
else
  echo "  → actualizar con: ./ucsync/vendor_webstore.sh --version $nueva --commit"
fi

echo "== UC-Sync =="
# La extensión vive en su propio proyecto, separado de este fork.
UC_SYNC_DIR="${UC_SYNC_DIR:-/IA/uc-sync}"
[[ -d "$UC_SYNC_DIR" ]] || UC_SYNC_DIR="$HOME/uc-sync"
if command -v npm >/dev/null 2>&1 && [[ -f "$UC_SYNC_DIR/extension/manifest.json" ]]; then
  fijado="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$UC_SYNC_DIR/extension/manifest.json" 2>/dev/null)"
  echo "  en el repositorio de la extensión ($UC_SYNC_DIR): $fijado"
  echo "  recopilar y regenerar parches:     cd $UC_SYNC_DIR && npm test --prefix extension && $FORK/ucsync/make_ucsync_patches.sh --src <chromium/src> --extension $UC_SYNC_DIR/extension"
fi

echo
echo "Después de cualquier cambio: ./ucsync/check_local.sh (--src <chromium/src> si quieres comprobar el árbol)"
