#!/usr/bin/env bash
# Comprobaciones del fork, todas en local (no hay CI propia en GitHub).
#
#   ./ucsync/check_local.sh                 # sobre el árbol del fork
#   ./ucsync/check_local.sh --src <ruta>    # además sobre el árbol de chromium/src
#
# Usa caché en ~/.cache/ucsync-chromium-files: la primera vez descarga los ficheros de
# chromium/src del tag fijado, y después funciona sin red.
set -uo pipefail
FORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    *) echo "argumento desconocido: $1"; exit 1;;
  esac
done

fallos=0
bien() { printf '  ✓ %s\n' "$1"; }
mal() { printf '  ✗ %s\n' "$1"; fallos=$((fallos + 1)); }

echo "== 1. los parches propios aplican sobre el Chromium fijado =="
if python3 "$FORK/ucsync/verify_patch.py"; then bien "todos los parches propios aplican"; else mal "algún parche propio no aplica"; fi

echo "== 2. invariantes de chrome://flags (FeatureEntry) =="
if out=$(python3 "$FORK/ucsync/check_flag_choices.py" 2>&1); then bien "las choices mantienen la invariante"; else printf '%s\n' "$out" | sed 's/^/  /'; mal "una choice rompe FeatureEntry::IsValid()"; fi

echo "== 3. patches/series == parches en el disco =="
while IFS= read -r linea; do
  [[ -z "$linea" || "$linea" == \#* ]] && continue
  [[ -f "$FORK/patches/$linea" ]] || mal "$linea está en la serie pero no en patches/"
done < "$FORK/patches/series"
for fich in "$FORK"/patches/extra/ucsync/*.patch; do
  rel="extra/ucsync/$(basename "$fich")"
  grep -qxF "$rel" "$FORK/patches/series" || mal "$rel no está en patches/series"
done
[[ $fallos -eq 0 ]] && bien "la serie y los ficheros coinciden"

echo "== 4. extensiones integradas (UI sin PNG) =="
# En el fork las extensiones van dentro de los parches 0003 y 0006 (sólo texto): se comprueba ahí.
for par in "UC-Sync:patches/extra/ucsync/0003-ucsync-browser-extension.patch" \
           "chromium-web-store:patches/extra/ucsync/0006-chromium-web-store-extension.patch"; do
  nombre="${par%%:*}"; parche="${par#*:}"
  [[ -f "$FORK/$parche" ]] || { mal "$nombre: falta el parche $parche"; continue; }
  grep -q '^+++ b/chrome/browser/resources/.*/manifest.json' "$FORK/$parche" ||
    mal "$nombre: el parche no crea manifest.json"
  n="$(grep -c '^+.*icons/[a-z0-9_-]*\.png' "$FORK/$parche" || true)"
  [[ "$n" == "0" ]] && bien "$nombre: ningún icons/*.png referenciado" ||
    mal "$nombre: $n referencias a icons/*.png (el navegador no empaqueta PNG)"
done
for par in "extension:extensionVersion" "webstore:extensionVersion"; do
  f="$FORK/ucsync/${par%%:*}.lock.json"
  if [[ -f "$f" ]]; then
    v="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['${par#*:}'])" "$f" 2>/dev/null)"
    [[ -n "$v" ]] && bien "${par%%:*}.lock.json → $v" || mal "${par%%:*}.lock.json no tiene ${par#*:}"
  else
    mal "falta ucsync/${par%%:*}.lock.json (./ucsync/record_extension_lock.sh, ./ucsync/vendor_webstore.sh --commit)"
  fi
done

if [[ -n "$SRC" ]]; then
  echo "== 5. árbol de chromium/src =="
  [[ -f "$SRC/chrome/browser/resources/ucsync/manifest.json" ]] && bien "extensión UC-Sync presente en el árbol" || mal "falta chrome/browser/resources/ucsync en el árbol"
  n="$(grep -rl 'icons/[a-z0-9_-]*\.png' "$SRC/chrome/browser/resources/ucsync"/*.html 2>/dev/null | wc -l)"
  [[ "$n" == "0" ]] && bien "la UI de UC-Sync no pide PNG" || mal "$n páginas de UC-Sync piden icons/*.png"
  [[ -f "$SRC/chrome/browser/resources/chromium-web-store/manifest.json" ]] && bien "chromium-web-store presente en el árbol" || mal "falta chrome/browser/resources/chromium-web-store en el árbol"
  grep -q 'PRODUCT_FULLNAME=Chromper' "$SRC/chrome/app/theme/chromium/BRANDING" && bien "branding = Chromper" || mal "BRANDING no dice Chromper"
  if grep -q "PRODUCT_FULLNAME=\"Los creadores" "$SRC/chrome/app/chromium_strings.grd"; then
    mal "la autoría se renombró por error (debe seguir siendo «Los creadores de Chromium»)"
  else
    bien "la autoría sigue siendo Chromium"
  fi
  grep -q '"name": "Google"' "$SRC/third_party/search_engines_data/resources/definitions/prepopulated_engines.json" && bien "buscador por defecto = Google" || mal "el JSON de buscadores no tiene Google"
  if grep -q "9oo91e.qjz9zk/search" "$SRC/third_party/search_engines_data/resources/definitions/prepopulated_engines.json"; then
    mal "el motor Google apunta al dominio sustituido (no resuelve en DNS)"
  else
    bien "las URL de Google son reales (google.com)"
  fi
fi

echo "== 6. scripts de Windows (Windows PowerShell 5.1) =="
if out=$(python3 "$FORK/ucsync/check_ps1.py" "$FORK" 2>&1); then
  printf '%s\n' "$out" | tail -1 | sed 's/^  /  ✓ /'
else
  printf '%s\n' "$out" | sed 's/^/  /'
  mal "los .ps1 no pasan la comprobación de PowerShell 5.1"
fi

echo
if [[ $fallos -gt 0 ]]; then
  echo "[comprobación] $fallos fallos"
  exit 1
fi
echo "[comprobación] todo correcto"
