#!/usr/bin/env bash
# Instalador de una línea para CachyOS/Arch: Chromper (Chromium sin Google con UC-Sync).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/execute.sh)"
#
# Hace todo solo: instala las librerías que faltan, descarga el binario del último release, lo
# instala, deja lanzador + icono + entrada de aplicaciones, pone el sandbox setuid si puede,
# lo registra como navegador por defecto, arregla el PATH y abre chrome://ucsync.
#
# (Si el repo pasara a privado, la misma línea funciona con gh autenticado:)
#   bash -c "$(gh api repos/dr0per250/ungoogled-chromium-ucsync/contents/ucsync/execute.sh --jq .content | base64 -d)"
#
# Solo hay un posible gesto del usuario: la contraseña de sudo para el sandbox (si sudo no es
# sin contraseña). Para renunciar a ella: UCSYNC_NO_SANDBOX=1.
# Opt-out por entorno: UCSYNC_PREFIX, UCSYNC_NO_SANDBOX=1, UCSYNC_SKIP_DEPS=1,
# UCSYNC_NO_DEFAULT=1 (no cambiar el navegador por defecto), UCSYNC_NO_LAUNCH=1,
# UCSYNC_UNINSTALL=1, UCSYNC_TARBALL=<archivo> (instalar de un paquete local),
# UCSYNC_OPEN_UI=1 (abre chrome://ucsync al terminar; por defecto no abre nada).
set -euo pipefail
REPO="dr0per250/ungoogled-chromium-ucsync"
ASSET="chromper-linux-x64.tar.gz"
PREFIX="${UCSYNC_PREFIX:-$HOME/.local/share/chromper}"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/chromper"
DESKTOP_ID="io.chromper.desktop"
say() { printf '[ucsync] %s\n' "$*"; }

if [[ "${UCSYNC_UNINSTALL:-0}" == "1" ]]; then
  rm -rf "$PREFIX" "$LAUNCHER"
  rm -f "$HOME/.local/share/applications/$DESKTOP_ID" \
        "$HOME/.local/share/icons/hicolor/48x48/apps/chromper.png" \
        "$HOME/.local/share/icons/hicolor/scalable/apps/chromper.svg"
  # perfiles viejos de nombres anteriores no se borran nunca
  say "Borrado $PREFIX y $LAUNCHER (el perfil se conserva)."
  exit 0
fi

# 1) Librerías que necesita el binario (Chromium se compila con sysroot de Debian pero enlaza
#    contra las de la distribución).
if [[ "${UCSYNC_SKIP_DEPS:-0}" != "1" ]]; then
  if ! command -v pacman >/dev/null 2>&1; then
    say "No hay pacman: esto es para CachyOS/Arch."
    exit 1
  fi
  NEEDED=(nss dbus alsa-lib at-spi2-core cups gtk3 libgl libx11 expat fontconfig freetype2
          harfbuzz pango cairo libdrm mesa)
  MISSING=()
  for p in "${NEEDED[@]}"; do pacman -Q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    say "Instalando librerías que faltan: ${MISSING[*]}"
    sudo pacman -S --noconfirm --needed "${MISSING[@]}"
  fi
fi

# 2) Descarga (repo público: sin tokens). Con UCSYNC_TARBALL se usa un paquete local.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TAG=""
if [[ -n "${UCSYNC_TARBALL:-}" ]]; then
  say "Usando el paquete local $UCSYNC_TARBALL"
  cp "$UCSYNC_TARBALL" "$TMP/$ASSET"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  TAG="$(gh release view -R "$REPO" --json tagName -q .tagName)"
  say "Descargando $ASSET del release $TAG"
  gh release download "$TAG" -R "$REPO" --pattern "$ASSET" --dir "$TMP" --clobber
else
  TAG="$(curl -sf "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  say "Descargando $ASSET del release ${TAG:-latest}"
  curl -fL --retry 3 -o "$TMP/$ASSET" "https://github.com/$REPO/releases/download/${TAG:-latest}/$ASSET"
fi
tar xzf "$TMP/$ASSET" -C "$TMP"
PKG="$TMP/chromper"
[[ -x "$PKG/chromper" ]] || { say "El paquete no trae chromper"; exit 1; }

# 3) Instalar
say "Instalando en $PREFIX"
mkdir -p "$PREFIX"
# --remove-destination: si `chrome_sandbox` quedó root:root setuid de una instalación previa,
# `cp` no puede escribirlo; borrando y recreando basta (somos dueños del directorio).
cp -a --remove-destination "$PKG/." "$PREFIX/"

# 4) Sandbox: setuid root sobre chrome_sandbox. Se intenta con sudo sin contraseña y, si no, con
#    sudo interactivo (una sola petición de contraseña). Sin eso, --no-sandbox en el lanzador.
EXTRA_FLAGS=""
if [[ "${UCSYNC_NO_SANDBOX:-0}" == "1" ]]; then
  EXTRA_FLAGS="--no-sandbox"; say "Sandbox renunciado (UCSYNC_NO_SANDBOX=1)."
elif [[ -f "$PREFIX/chrome_sandbox" ]]; then
  SAND_OK=0
  if sudo -n true 2>/dev/null; then SAND_OK=1; elif [[ -t 0 ]]; then
    say "El sandbox necesita root (una petición de sudo)."
    sudo true && SAND_OK=1
  fi
  if [[ "$SAND_OK" == "1" ]]; then
    sudo chown root:root "$PREFIX/chrome_sandbox" && sudo chmod 4755 "$PREFIX/chrome_sandbox"
    say "Sandbox activo: chrome_sandbox setuid root."
  else
    EXTRA_FLAGS="--no-sandbox"
    say "Sin sudo a mano: el lanzador usará --no-sandbox (repite con sudo para el sandbox real)."
  fi
else
  EXTRA_FLAGS="--no-sandbox"
fi

# 5) Lanzador
# Limpieza de nombres anteriores (lanzador y entrada de aplicaciones de la versión previa).
for viejo in "$BIN_DIR/ucsync-chromium" "$HOME/.local/share/applications/io.ucsync.chromium.desktop" \
             "$HOME/.local/share/icons/hicolor/scalable/apps/ucsync-chromium.svg"; do
  if [[ -e "$viejo" ]]; then
    rm -f "$viejo"
    say "Quitado el nombre anterior: ${viejo#"$HOME/"}"
  fi
done
mkdir -p "$BIN_DIR"
{
  echo '#!/usr/bin/env bash'
  echo "# Chromper ($(tr '\n' ' ' < "$PKG/VERSION"))"
  echo "PREFIX=\"$PREFIX\""
  echo 'resolve_profile() {'
  echo '  local p="${UCSYNC_PROFILE:-}"'
  echo '  if [[ -n "$p" ]]; then echo "$p"; return; fi'
  echo '  for c in "$HOME/.config/chromper" "$HOME/.config/ucsync-chromium" "$HOME/.config/ungoogled-chromium" "$HOME/.config/chromium"; do'
  echo '    # Sólo un perfil de verdad (no la carpeta de crashpad que se crea al ejecutar).'
  echo '    [[ -f "$c/Default/Preferences" ]] && { echo "$c"; return; }'
  echo '  done'
  echo '  echo "$HOME/.config/chromper"'
  echo '}'
  echo 'exec "$PREFIX/chromper" --user-data-dir="$(resolve_profile)" --class=chromper $EXTRA_FLAGS "$@"'

} > "$LAUNCHER"
chmod 755 "$LAUNCHER"

# 6) PATH: si ~/.local/bin no está, se añade al perfil del shell (sin pedir nada).
case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [[ -f "$rc" ]] || continue
    grep -qF 'HOME/.local/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
  done
  say "PATH: añadido ~/.local/bin a ~/.bashrc, ~/.zshrc y ~/.profile (vale en la próxima terminal)."
  export PATH="$BIN_DIR:$PATH"
  ;;
esac

# 7) Icono y entrada de aplicaciones
# Icono: el del propio Chromium (product_logo_48.png); si no viene, el logo de UC-Sync.
if [[ -f "$PKG/product_logo_48.png" ]]; then
  mkdir -p "$HOME/.local/share/icons/hicolor/48x48/apps"
  cp "$PKG/product_logo_48.png" "$HOME/.local/share/icons/hicolor/48x48/apps/chromper.png"
elif [[ -f "$PKG/ucsync/logo.svg" ]]; then
  mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps"
  cp "$PKG/ucsync/logo.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/chromper.svg"
fi
mkdir -p "$HOME/.local/share/applications"
printf '%s\n' "[Desktop Entry]
Type=Application
Name=Chromper
Comment=Chromper: Chromium sin Google con UC-Sync integrado
Exec=$LAUNCHER %U
Icon=chromper
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=chromper
MimeType=x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true" > "$HOME/.local/share/applications/$DESKTOP_ID"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# 8) Navegador por defecto: se pone UC-Sync (UCSYNC_NO_DEFAULT=1 para no tocar el actual).
if [[ "${UCSYNC_NO_DEFAULT:-0}" != "1" ]] && command -v xdg-settings >/dev/null 2>&1; then
  CURRENT="$(xdg-settings get default-web-browser 2>/dev/null || echo '')"
  if [[ -n "$CURRENT" && "$CURRENT" != "$DESKTOP_ID" ]]; then
    say "Navegador por defecto: era $CURRENT, ahora Chromper (UCSYNC_NO_DEFAULT=1 para no cambiarlo)."
  fi
  xdg-settings set default-web-browser "$DESKTOP_ID" 2>/dev/null || true
  command -v xdg-mime >/dev/null 2>&1 &&
    xdg-mime default "$DESKTOP_ID" x-scheme-handler/http x-scheme-handler/https 2>/dev/null || true
fi

# 9) Comprobación: versión, y que la extensión está integrada y carga (headless, sin molestar).
"$LAUNCHER" --version || true
EXT_ID="lidfhdhmbifmhikiaklbiehnhnkhoghe"
if [[ -f "$PREFIX/ucsync/manifest.json" ]] && command -v timeout >/dev/null 2>&1; then
  PROBE_DIR="$(mktemp -d)/probe"
  if timeout 60 "$PREFIX/chromper" --headless=new --no-sandbox --no-first-run --disable-features=Translate \
       --user-data-dir="$PROBE_DIR" --dump-dom "chrome-extension://$EXT_ID/options.html" 2>/dev/null | grep -q "UC-Sync"; then
    rm -rf "$PROBE_DIR"
    say "Comprobado: la extensión está integrada y su UI carga (chrome://ucsync la sirve en la pestaña)."
  else
    rm -rf "$PROBE_DIR"
    say "Aviso: no se pudo verificar la UI en modo headless; abre chrome://ucsync para comprobarla."
  fi
fi

# 9b) Arranque real (sin ventana): `--headless` no pasa por `CreateFeatureList()`, así que una
# bandera mal definida aborta en silencio y el instalador lo daría por bueno.
if [[ "${UCSYNC_SKIP_BOOT_CHECK:-0}" != "1" ]] && command -v timeout >/dev/null 2>&1; then
  BOOT_DIR="$(mktemp -d)"
  BOOT_OUT="$(timeout 45 "$PREFIX/chromper" --no-sandbox --no-first-run --no-startup-window \
               --user-data-dir="$BOOT_DIR" 2>&1 | grep -cE "FATAL|DCHECK failed|must be empty" || true)"
  rm -rf "$BOOT_DIR"
  if [[ "${BOOT_OUT:-0}" != "0" ]]; then
    say "Aviso: el navegador aborta al arrancar ($BOOT_OUT líneas). Mira chrome://flags/#extension-mime-request-handling y las banderas MULTI_VALUE."
  else
    say "Comprobado: el navegador arranca sin abortar."
  fi
fi

# 10) No abre nada: instalar sin interferir. UCSYNC_OPEN_UI=1 para abrir chrome://ucsync.
if [[ "${UCSYNC_OPEN_UI:-0}" == "1" ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  say "Abriendo chrome://ucsync…"
  setsid "$LAUNCHER" chrome://ucsync >/dev/null 2>&1 < /dev/null &
  disown || true
fi

PERFIL_ELEGIDO="${UCSYNC_PROFILE:-}"
if [[ -z "$PERFIL_ELEGIDO" ]]; then
  for c in "$HOME/.config/chromper" "$HOME/.config/ucsync-chromium" "$HOME/.config/ungoogled-chromium" "$HOME/.config/chromium"; do
    [[ -f "$c/Default/Preferences" ]] && PERFIL_ELEGIDO="$c" && break
  done
  PERFIL_ELEGIDO="${PERFIL_ELEGIDO:-$HOME/.config/chromper (nuevo)}"
fi
say "Perfil que usará: $PERFIL_ELEGIDO (los marcadores e historial de ese perfil se conservan)."
