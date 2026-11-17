#!/usr/bin/env bash
# Instala el navegador UC-Sync en CachyOS/Arch desde la terminal.
#
# Descarga el paquete del último release de este fork (o uno local) y lo instala con su
# lanzador. La extensión UC-Sync ya viene dentro del navegador: se abre en `chrome://ucsync`.
#
# Uso:
#   ./install_cachyos.sh                      # último release, en ~/.local (sin root)
#   ./install_cachyos.sh --system             # en /opt, con sandbox setuid (pide sudo)
#   ./install_cachyos.sh --tarball uc-sync-chromium-linux-x64.tar.gz
#   ./install_cachyos.sh --url https://…/ucsync-chromium-linux-x64.tar.gz
#   ./install_cachyos.sh --prefix ~/apps/ucsync
#   ./install_cachyos.sh --no-sandbox         # renuncia al sandbox (no recomendado)
#   ./install_cachyos.sh --skip-deps          # no comprueba los paquetes con pacman (otras distros)
#   ./install_cachyos.sh --uninstall
set -euo pipefail
REPO="dr0per250/ungoogled-chromium-ucsync"
ASSET="ucsync-chromium-linux-x64.tar.gz"
URL="${URL:-https://github.com/$REPO/releases/latest/download/$ASSET}"
TARBALL=""
SYSTEM=0
NO_SANDBOX=0
SKIP_DEPS=0
UNINSTALL=0
PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --system) SYSTEM=1; shift;;
    --tarball) TARBALL="$2"; shift 2;;
    --url) URL="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --no-sandbox) NO_SANDBOX=1; shift;;
    --skip-deps) SKIP_DEPS=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    *) echo "opción desconocida: $1"; exit 1;;
  esac
done

if [[ -z "$PREFIX" ]]; then
  [[ "$SYSTEM" == "1" ]] && PREFIX="/opt/ucsync-chromium" || PREFIX="$HOME/.local/share/ucsync-chromium"
fi
BIN_DIR="$( [[ "$SYSTEM" == "1" ]] && echo /usr/local/bin || echo "$HOME/.local/bin" )"
LAUNCHER="$BIN_DIR/ucsync-chromium"

sudo_() { if [[ "$SYSTEM" == "1" ]]; then sudo "$@"; else "$@"; fi; }

if [[ "$UNINSTALL" == "1" ]]; then
  rm -rf "$PREFIX" "$LAUNCHER"
  rm -f "$HOME/.local/share/applications/io.ucsync.chromium.desktop" \
        "$HOME/.local/share/icons/hicolor/scalable/apps/ucsync-chromium.svg"
  [[ "$SYSTEM" == "1" ]] && sudo rm -f /usr/share/applications/io.ucsync.chromium.desktop \
                              /usr/share/icons/hicolor/scalable/apps/ucsync-chromium.svg
  echo "[instala] Borrado $PREFIX y $LAUNCHER (el perfil ~/.config/ucsync-chromium se queda)."
  exit 0
fi

# 1) Librerías del sistema que el binario necesita (Chromium se compila con sysroot de Debian,
#    pero enlaza contra las librerías de la distribución).
NEEDED_PKGS=(nss dbus alsa-lib at-spi2-core cups gtk3 libgl libx11 expat fontconfig freetype2
             harfbuzz pango cairo libdrm mesa)
if [[ "$SKIP_DEPS" == "1" ]]; then
  echo "[instala] Comprobación de paquetes omitida (--skip-deps)."
elif ! command -v pacman >/dev/null 2>&1; then
  echo "[instala] Sin pacman: instala las librerías equivalentes de tu distro y usa --skip-deps"
  echo "          (${NEEDED_PKGS[*]})"
  exit 1
else
  MISSING=()
  for p in "${NEEDED_PKGS[@]}"; do pacman -Q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[instala] Faltan paquetes: ${MISSING[*]}"
    echo "          sudo pacman -S --needed ${MISSING[*]}"
    echo "          (ejecútalo y vuelve a lanzar este script)"
    exit 1
  fi
fi

# 2) Traer el paquete
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [[ -n "$TARBALL" ]]; then
  cp "$TARBALL" "$TMP/pkg.tar.gz"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  # El repo es privado: con `gh` autenticado se descarga el asset directamente.
  TAG="$(gh release view -R "$REPO" --json tagName -q .tagName)"
  echo "[instala] Descargando $ASSET del release $TAG (repo privado, con gh)"
  gh release download "$TAG" -R "$REPO" --pattern "$ASSET" --dir "$TMP" --clobber
  mv "$TMP/$ASSET" "$TMP/pkg.tar.gz"
elif [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  echo "[instala] Descargando con GH_TOKEN"
  curl -fL --retry 3 -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" -o "$TMP/pkg.tar.gz" "$URL"
else
  echo "[instala] El repo del navegador es privado: autentica gh (\`gh auth login\`) o pasa el paquete local:"
  echo "          TAG=\$(gh release view -R $REPO --json tagName -q .tagName)"
  echo "          gh release download \$TAG -R $REPO -p $ASSET"
  echo "          ./install_cachyos.sh --tarball $ASSET"
  exit 1
fi
tar xzf "$TMP/pkg.tar.gz" -C "$TMP"
PKG="$TMP/ucsync-chromium"
[[ -x "$PKG/chrome" ]] || { echo "El paquete no trae chrome"; exit 1; }

# 3) Instalar
echo "[instala] Instalando en $PREFIX"
sudo_ mkdir -p "$PREFIX"
sudo_ cp -a "$PKG/." "$PREFIX/"
if [[ "$SYSTEM" == "1" ]]; then
  sudo_ chown -R root:root "$PREFIX"
  sudo_ chmod 755 "$PREFIX"
fi

# 4) Sandbox: chrome_sandbox necesita setuid root para usar el sandbox siendo usuario normal.
if [[ "$NO_SANDBOX" == "1" ]]; then
  EXTRA_FLAGS="--no-sandbox"
  echo "[instala] AVISO: sandbox desactivado por --no-sandbox (permanece en el lanzador)."
elif [[ -f "$PREFIX/chrome_sandbox" ]]; then
  if [[ "$SYSTEM" == "1" ]]; then
    sudo_ chown root:root "$PREFIX/chrome_sandbox"
    sudo_ chmod 4755 "$PREFIX/chrome_sandbox"
    EXTRA_FLAGS=""
    echo "[instala] Sandbox activo (chrome_sandbox setuid root)."
  else
    EXTRA_FLAGS="--no-sandbox"
    echo "[instala] Sin root no se puede poner chrome_sandbox setuid: el lanzador usará"
    echo "          --no-sandbox. Para el sandbox real: ./install_cachyos.sh --system"
  fi
else
  EXTRA_FLAGS="--no-sandbox"
  echo "[instala] El paquete no trae chrome_sandbox: el lanzador usará --no-sandbox."
fi

# 5) Lanzador
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<SH
#!/usr/bin/env bash
# UC-Sync Chromium ($(cat "$PKG/VERSION" | tr '\n' ' '))
PREFIX="$PREFIX"
PROFILE="\${UCSYNC_PROFILE:-\$HOME/.config/ucsync-chromium}"
exec "\$PREFIX/chrome" --user-data-dir="\$PROFILE" $EXTRA_FLAGS "\$@"
SH
chmod 755 "$LAUNCHER"

# 6) Icono y entrada de menú de aplicaciones
ICON_SRC="$PKG/ucsync/logo.svg"
if [[ -f "$ICON_SRC" ]]; then
  mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps"
  cp "$ICON_SRC" "$HOME/.local/share/icons/hicolor/scalable/apps/ucsync-chromium.svg"
  [[ "$SYSTEM" == "1" ]] && sudo_ cp "$ICON_SRC" /usr/share/icons/hicolor/scalable/apps/ucsync-chromium.svg
fi
DESKTOP=$(cat <<D
[Desktop Entry]
Type=Application
Name=Navegador UC-Sync
Comment=Chromium sin Google con UC-Sync integrado
Exec=$LAUNCHER %U
Icon=ucsync-chromium
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=ucsync-chromium
MimeType=x-scheme-handler/http;x-scheme-handler/https;
D
)
mkdir -p "$HOME/.local/share/applications"
printf '%s\n' "$DESKTOP" > "$HOME/.local/share/applications/io.ucsync.chromium.desktop"
if [[ "$SYSTEM" == "1" ]]; then
  sudo_ mkdir -p /usr/share/applications
  printf '%s\n' "$DESKTOP" | sudo_ tee /usr/share/applications/io.ucsync.chromium.desktop >/dev/null
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# 7) Comprobar
"$LAUNCHER" --version || true
echo "[instala] Listo: ucsync-chromium   (perfil: ~/.config/ucsync-chromium)"
echo "[instala] Ábrelo y ve a chrome://ucsync para conectar con tu servidor."
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "[instala] Añade $BIN_DIR al PATH para llamarlo por su nombre."; ;; esac
