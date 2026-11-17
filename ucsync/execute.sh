#!/usr/bin/env bash
# Instalador de una línea para CachyOS/Arch: UC-Sync dentro del navegador.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/execute.sh)"
#
# (El repo es público: no hacen falta tokens. Si alguna vez pasa a privado, la misma línea
#  funciona con gh autenticado:)
#
#   bash -c "$(gh api repos/dr0per250/ungoogled-chromium-ucsync/contents/ucsync/execute.sh --jq .content | base64 -d)"
#
# Opciones por entorno: UCSYNC_SYSTEM=1 (en /opt con sandbox setuid, pide sudo),
# UCSYNC_PREFIX, UCSYNC_NO_SANDBOX=1, UCSYNC_SKIP_DEPS=1, UCSYNC_UNINSTALL=1,
# UCSYNC_SET_DEFAULT=1 (lo deja como navegador por defecto del escritorio).
set -euo pipefail
REPO="dr0per250/ungoogled-chromium-ucsync"
ASSET="ucsync-chromium-linux-x64.tar.gz"
SYSTEM="${UCSYNC_SYSTEM:-0}"
NO_SANDBOX="${UCSYNC_NO_SANDBOX:-0}"
SKIP_DEPS="${UCSYNC_SKIP_DEPS:-0}"
PREFIX="${UCSYNC_PREFIX:-}"
[[ "$SYSTEM" == "1" ]] && PREFIX="${PREFIX:-/opt/ucsync-chromium}" || PREFIX="${PREFIX:-$HOME/.local/share/ucsync-chromium}"
BIN_DIR="$( [[ "$SYSTEM" == "1" ]] && echo /usr/local/bin || echo "$HOME/.local/bin" )"
LAUNCHER="$BIN_DIR/ucsync-chromium"
sudo_() { if [[ "$SYSTEM" == "1" ]]; then sudo "$@"; else "$@"; fi; }
say() { printf '[ucsync] %s\n' "$*"; }

if [[ "${UCSYNC_UNINSTALL:-0}" == "1" ]]; then
  rm -rf "$PREFIX" "$LAUNCHER"
  rm -f "$HOME/.local/share/applications/io.ucsync.chromium.desktop" \
        "$HOME/.local/share/icons/hicolor/scalable/apps/ucsync-chromium.svg"
  say "Borrado $PREFIX y $LAUNCHER (el perfil se conserva)."
  exit 0
fi

if ! command -v pacman >/dev/null 2>&1 && [[ "$SKIP_DEPS" != "1" ]]; then
  say "Esto es para CachyOS/Arch (no hay pacman). En Debian/Ubuntu usa el tarball a mano."
  exit 1
fi
if [[ "$SKIP_DEPS" != "1" ]] && command -v pacman >/dev/null 2>&1; then
  NEEDED=(nss dbus alsa-lib at-spi2-core cups gtk3 libgl libx11 expat fontconfig freetype2 harfbuzz pango cairo libdrm mesa)
  MISSING=()
  for p in "${NEEDED[@]}"; do pacman -Q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    say "Instalando librerías que necesita el navegador: ${MISSING[*]}"
    sudo pacman -S --noconfirm --needed "${MISSING[@]}"
  fi
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  TAG="$(gh release view -R "$REPO" --json tagName -q .tagName)"
  say "Descargando $ASSET del release $TAG (con gh)"
  gh release download "$TAG" -R "$REPO" --pattern "$ASSET" --dir "$TMP" --clobber
elif [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
  TAG="$(curl -sf -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  say "Descargando $ASSET del release $TAG (con GH_TOKEN)"
  curl -fL --retry 3 -H "Authorization: Bearer $TOKEN" -o "$TMP/$ASSET" \
    "https://github.com/$REPO/releases/download/$TAG/$ASSET"
else
  say "Descargando $ASSET del último release"
  curl -fL --retry 3 -o "$TMP/$ASSET" "https://github.com/$REPO/releases/latest/download/$ASSET"
fi
tar xzf "$TMP/$ASSET" -C "$TMP"
[[ -x "$TMP/ucsync-chromium/chrome" ]] || { say "El paquete no trae chrome"; exit 1; }
PKG="$TMP/ucsync-chromium"

say "Instalando en $PREFIX"
sudo_ mkdir -p "$PREFIX"
sudo_ cp -a "$PKG/." "$PREFIX/"
[[ "$SYSTEM" == "1" ]] && sudo_ chown -R root:root "$PREFIX"

EXTRA_FLAGS=""
if [[ "$NO_SANDBOX" == "1" ]]; then
  EXTRA_FLAGS="--no-sandbox"; say "AVISO: sandbox desactivado (UCSYNC_NO_SANDBOX=1)."
elif [[ -f "$PREFIX/chrome_sandbox" && "$SYSTEM" == "1" ]]; then
  sudo_ chown root:root "$PREFIX/chrome_sandbox" && sudo_ chmod 4755 "$PREFIX/chrome_sandbox"
  say "Sandbox activo (chrome_sandbox setuid root)."
elif [[ -f "$PREFIX/chrome_sandbox" ]]; then
  EXTRA_FLAGS="--no-sandbox"
  say "Sin root no se puede dejar chrome_sandbox setuid: se usará --no-sandbox."
  say "Para el sandbox real:  UCSYNC_SYSTEM=1 bash -c \"\$(…este mismo comando…)\""
else
  EXTRA_FLAGS="--no-sandbox"
fi

mkdir -p "$BIN_DIR"
{
  echo '#!/usr/bin/env bash'
  echo "# UC-Sync Chromium ($(tr '\n' ' ' < "$PKG/VERSION"))"
  echo "PREFIX=\"$PREFIX\""
  echo 'PROFILE="${UCSYNC_PROFILE:-$HOME/.config/ucsync-chromium}"'
  echo "exec \"\$PREFIX/chrome\" --user-data-dir=\"\$PROFILE\" $EXTRA_FLAGS \"\$@\""
} > "$LAUNCHER"
chmod 755 "$LAUNCHER"

if [[ -f "$PKG/ucsync/logo.svg" ]]; then
  mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps"
  cp "$PKG/ucsync/logo.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/ucsync-chromium.svg"
  [[ "$SYSTEM" == "1" ]] && sudo_ cp "$PKG/ucsync/logo.svg" /usr/share/icons/hicolor/scalable/apps/ucsync-chromium.svg
fi
DESKTOP="[Desktop Entry]
Type=Application
Name=Navegador UC-Sync
Comment=Chromium sin Google con UC-Sync integrado
Exec=$LAUNCHER %U
Icon=ucsync-chromium
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=ucsync-chromium
MimeType=x-scheme-handler/http;x-scheme-handler/https;"
mkdir -p "$HOME/.local/share/applications"
printf '%s\n' "$DESKTOP" > "$HOME/.local/share/applications/io.ucsync.chromium.desktop"
[[ "$SYSTEM" == "1" ]] && { sudo_ mkdir -p /usr/share/applications; printf '%s\n' "$DESKTOP" | sudo_ tee /usr/share/applications/io.ucsync.chromium.desktop >/dev/null; }
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# Las líneas `Not implemented` de Wayland/ozone al arrancar son ruido conocido de Chromium
# sobre Wayland; no indican que nada haya roto.
"$LAUNCHER" --version || true
if [[ "${UCSYNC_SET_DEFAULT:-0}" == "1" ]] && command -v xdg-settings >/dev/null 2>&1; then
  xdg-settings set default-web-browser io.ucsync.chromium.desktop && say "Navegador por defecto: UC-Sync."
  command -v xdg-mime >/dev/null 2>&1 && xdg-mime default io.ucsync.chromium.desktop x-scheme-handler/http x-scheme-handler/https 2>/dev/null || true
fi
say "Listo: ejecuta  ucsync-chromium   y abre chrome://ucsync"
say "Sandbox: si ves '--no-sandbox' arriba, reinstala con UCSYNC_SYSTEM=1 para el sandbox real (setuid)."
say "Perfil: ${UCSYNC_PROFILE:-$HOME/.config/ucsync-chromium}"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "Añade $BIN_DIR al PATH para llamarlo por su nombre."; ;; esac
