# ungoogled-chromium **UC-Sync**

Copia de [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium) que sigue a
upstream automáticamente y añade **UC-Sync dentro del navegador**: la extensión de sincronización
cifrada de marcadores, historial y permisos por sitio viene integrada, y `chrome://ucsync` es su UI.

Por qué está integrado y no se instala: `chrome.history.addUrl()` sólo sabe crear visitas «ahora», así
que la fecha real de cada visita exige parchear la API de historial de Chromium. Y para eso ya hay
que compilar el navegador, así que la extensión viaja con él.

```
   parches propios (patches/extra/ucsync/)
   0001  chrome.history.addUrl({url, visitTime})      hora real en chrome://history
   0002  chrome.history.addUrls({urls})               importación en lotes
   0003  chrome/browser/resources/ucsync/             el código de la extensión, en el árbol
   0004  registro en el arranque + chrome://ucsync    ID fijo, APIs concedidas a ese origen
```

| Cosas de aquí | |
| --- | --- |
| Versión fijada | la de [`chromium_version.txt`](chromium_version.txt) (verificada compilando `157.0.8103.78`) |
| ID de la extensión | `lidfhdhmbifmhikiaklbiehnhnkhoghe`, fijado por el campo `key` del manifiesto |
| UI | `chrome://ucsync` (servida por el navegador desde los ficheros embebidos, con lista blanca) |
| **Binarios** | Linux x64 publicado en [Releases](https://github.com/dr0per250/ungoogled-chromium-ucsync/releases) (`chromium-157.0.8103.78`). Windows: aún no hay binario (no se ha compilado aquí); está `package_windows.ps1` para producirlo. |
| Bóveda y servidor | [dr0per250/uc-sync](https://github.com/dr0per250/uc-sync) — [Releases](https://github.com/dr0per250/uc-sync/releases) con el zip si quieres la extensión suelta |
| Herramientas propias | [`ucsync/`](ucsync/README.md) (`build.sh`, `bump.sh`, `verify_patch.py`, `make_ucsync_patches.sh`, `verify_runtime.sh`) |
| Pruebas de comportamiento | [`ucsync/VERIFICATION.md`](ucsync/VERIFICATION.md) |

Lo de ungoogled (objetivos, características, FAQ, construcción genérica) sigue en el
[upstream](https://github.com/ungoogled-software/ungoogled-chromium) y en sus `docs/`.

---

## Instalar el binario (CachyOS / Arch)

El release `chromium-<versión>` trae `ucsync-chromium-linux-x64.tar.gz` (≈ 240 MB: navegador, recursos,
idiomas recortados y la extensión integrada). Los repos son **privados**, así que la descarga va con
`gh` autenticado (`gh auth login`) o con `GH_TOKEN`.

Una línea y listo (estilo community-scripts):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/execute.sh)"
ucsync-chromium
```

Como el repo es **privado**, esa línea aún no funciona sin credenciales: con `gh` autenticado es la
misma operación en una línea, y `curl` con `GH_TOKEN` también vale:

```sh
bash -c "$(gh api repos/dr0per250/ungoogled-chromium-ucsync/contents/ucsync/execute.sh --jq .content | base64 -d)"
# o:  GH_TOKEN=… bash -c "$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" https://raw.githubusercontent.com/…/ucsync/execute.sh)"
```

`execute.sh` es un solo fichero autocontenido: descarga el tarball del último release, instala las
librerías que faltan (`pacman -S --noconfirm`), instala en `~/.local/share/ucsync-chromium`, deja el
lanzador `ucsync-chromium`, el icono y la entrada de aplicaciones, y comprueba el binario. Opciones
por entorno: `UCSYNC_SYSTEM=1` (en `/opt` con `chrome_sandbox` setuid root → sandbox real, pide
sudo), `UCSYNC_PREFIX`, `UCSYNC_NO_SANDBOX=1`, `UCSYNC_SKIP_DEPS=1`, `UCSYNC_UNINSTALL=1`. El perfil
queda en `~/.config/ucsync-chromium` (`UCSYNC_PROFILE` para cambiarlo).

**Publicar un binario nuevo** tras compilar:

```sh
./ucsync/make_release.sh --src ~/ucbuild/src     # package_linux.sh + gh release upload
```

## Instalar el binario (Windows 11)

Todavía **no hay binario publicado**: no se ha compilado en Windows. Cuando lo tengas (compilando
abajo o en un runner propio), empaquétalo e instálalo con los dos scripts:

```powershell
.\ucsync\package_windows.ps1 -Src C:\ucbuild\src -Out C:\paquetes
.\ucsync\install_windows.ps1 -Zip C:\paquetes\ucsync-chromium-windows-x64.zip
# o, con gh autenticado y el asset publicado:  .\ucsync\install_windows.ps1
```

El instalador coloca el navegador en `%LOCALAPPDATA%\ucsync-chromium`, crea el atajo de escritorio
(con `--user-data-dir` propio), lo añade al `PATH` del usuario y comprueba `chrome.exe --version`.
`-Uninstall` lo quita.

## Compilar en CachyOS / Arch

Verificado con `Chromium 157.0.8103.78` en 20 núcleos y 125 GB de RAM. Calcula **80 GB libres**
(fuente ≈ 40 GB con `third_party`, salida ≈ 8 GB) y unos 16 GB de RAM para enlazar
(`symbol_level = 0`): el enlace con `debug_info` no cabe. Tiempo observado: ≈ 2 h.

```sh
# 1) Pacman sólo da lo que depot_tools no trae (clang, ninja y gn vienen de depot_tools)
sudo pacman -S --needed base-devel git python3 curl

# 2) depot_tools
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
export PATH="$HOME/depot_tools:$PATH"

# 3) Este fork
git clone https://github.com/dr0per250/ungoogled-chromium-ucsync.git ~/uc-fork

# 4) Fuente (tag de chromium_version.txt) + poda + serie de parches + sustitución de dominios
#    + los deps de DEPS que gclient se salta en un checkout de git (clang-format, esbuild, go de Dawn)
WORK="$HOME/ucbuild" ~/uc-fork/ucsync/build.sh --prepare

# 5) gn gen + ninja, y coloca la extensión integrada junto al binario
WORK="$HOME/ucbuild" ~/uc-fork/ucsync/build.sh --chrome
```

`build.sh --chrome` escribe `out/Default/args.gn` con `flags.gn` más los args con los que se verificó
la compilación (`is_debug = false`, `is_official_build = false`, `symbol_level = 0`,
`v8_symbol_level = 0`, `use_sysroot = true`) y copia `chrome/browser/resources/ucsync/` a
`out/Default/ucsync/`: el navegador busca la extensión en `<exe>/ucsync`
(puedes forzarlo con `--ucsync-extension-dir=<ruta>`).

```sh
~/ucbuild/src/out/Default/chrome --user-data-dir="$HOME/.ucsync-profile"
```

En el navegador: **`chrome://ucsync`** → URL del servidor (`http://10.7.93.19:8443`) → contraseña
(≥ 8) → **Conectar**. Los permisos son estáticos en el manifiesto, así que el navegador no pide nada
por el camino, y no hay que instalar ninguna extensión.

Autocomprobación:

```sh
curl http://10.7.93.19:8443/v1/info                 # status online; hasVault true tras conectar
# chrome://ucsync  → la UI de UC-Sync
# chrome://history → las visitas con su fecha real (no «ahora»)
# chrome://version → Chromium 157.x sin servicios de Google
./uc-fork/ucsync/verify_runtime.sh --chrome ~/ucbuild/src/out/Default/chrome --port 8185
# [verify] OK: addUrl con hora pasada, addUrls en lote y hora futura rechazada.
```

### Qué puede faltar en Arch

| Síntoma | Arreglo |
| --- | --- |
| falta `buildtools/linux64-format` / `clang-format` | `python3 ~/uc-fork/ucsync/install_deps.py --src ~/ucbuild/src --filter clang-format` |
| DevTools: falta `third_party/devtools-frontend/src/third_party/esbuild/esbuild` | `bash ~/uc-fork/ucsync/fetch_esbuild.sh ~/ucbuild/src` |
| Dawn: `third_party/dawn/tools/golang/linux-amd64/bin/go` no existe | `bash ~/uc-fork/ucsync/fetch_dawn_go.sh ~/ucbuild/src` |
| enlace `out of memory` | `JOBS=8` y confirma `symbol_level = 0` en `out/Default/args.gn` |
| `ninja: unknown target chrome_sandbox` | en otras plataformas: `ninja -C out/Default chrome chromedriver` |

## Compilar en Windows 11

**No lo hemos compilado aquí**: lo verificado es Linux. Los parches son C++/JSON independientes del
sistema y el loader localiza la extensión con `base::DIR_EXE` (así que `<exe>\ucsync` funciona igual),
 pero la ventana de Windows no está probada.

1. **WSL2** (lo más simple, son los mismos comandos de arriba): `wsl --install -d Ubuntu-24.04`,
   `sudo apt install python3 git curl`, depot_tools y `build.sh`. WSLg abre la ventana.
2. **Nativo**, con Visual Studio 2022 (*Desktop development with C++*), Windows SDK 10.0.22621 y
   depot_tools (guía `build/win/README.md` del árbol de Chromium):

   ```bat
   set WORK=%USERPROFILE%\ucbuild
   python uc-fork\utils\patches.py apply %WORK%\src uc-fork\patches
   cd %WORK%\src
   gn gen out\Release --args="is_debug=false is_official_build=false symbol_level=0"
   ninja -C out\Release chrome chromedriver
   xcopy /E /I chrome\browser\resources\ucsync out\Release\ucsync
   ```

   Abre `out\Release\chrome.exe` y ve a `chrome://ucsync`. Si un hunk rechaza, abre un issue con el
   rechazo exacto: la serie se valida contra la versión fijada en Linux.

El binario Linux se publica con `./ucsync/make_release.sh` (crea el release del tag y sube el
tarball). Para la extensión suelta, los releases de
[uc-sync](https://github.com/dr0per250/uc-sync/releases).

## Qué cambia en el navegador (detalle de los 4 parches)

- **`0001-history-api-visit-time`** — `chrome.history.addUrl({url, visitTime})` acepta horas pasadas
  y rechaza las futuras con el mensaje
  `visitTime must be a valid time that is not in the future.`
- **`0002-history-api-addurls-bulk`** — `chrome.history.addUrls({urls})` importa lotes con
  `HistoryService::AddPagesWithDetails`, cada fila con su `last_visit`; si una URL o una hora es
  inválida se rechaza el lote entero.
- **`0003-ucsync-browser-extension`** — el código de la extensión en
  `chrome/browser/resources/ucsync/` (texto puro; sin PNG, el logo es `logo.svg`).
- **`0004-ucsync-browser-registration`** — `EnsureUCSyncBuiltInExtension()` registra la extensión en
  cada perfil al arrancar, la exime de la política de extensiones sin empaquetar (si no, queda
  desactivada por vivir como `kUnpacked`), y sirve la UI en `chrome://ucsync` con las APIs de
  extensión concedidas a ese origen (decididas por el navegador, nunca reivindicadas por el renderer;
  **no** hay `web_accessible_resources`).

Las visitas se escriben con `SOURCE_EXTENSION`, no con `SOURCE_SYNCED`: Chrome Sync no las borra
cuando se desactiva y `VisitItem.isLocal` sigue siendo `true` (se pueden borrar a mano).

## Actualización contra upstream

| Trabajo | Qué hace |
| --- | --- |
| **UC-Sync upstream bump** (diario + manual) | fusiona `upstream/master`, valida la serie y, si aplica, sube `master` y etiqueta `chromium-<versión>`; si rechaza, **revierte y abre un issue**. Sólo acepta versiones con archivo oficial `lite`. |
| **UC-Sync apply completo** (diario) | aplica la serie entera sobre el tarball `lite` de la versión fijada y comprueba que tras parchear siguen `ParseVisitTime`, `HistoryAddUrlsFunction`, los recursos de UC-Sync, `ucsync_ui.cc` y el ID. |
| **UC-Sync patch check** (push y manual) | validación rápida a nivel de fichero (`ucsync/verify_patch.py`), sin compilar. |
| **UC-Sync vendor extensión** | re-vende `0003` desde el repo UC-Sync y escribe `ucsync/extension.lock.json` (commit, versión de la extensión, sha256 del parche). Necesita el secret `UCSYNC_PAT`. |

Lo que **no** se automatiza: readaptar un parche cuando un hunk choca contra código nuevo de
Chromium. Eso exige el árbol de trabajo y `ucsync/make_ucsync_patches.sh --src <árbol> --extension <uc-sync>`;
el bot deja el issue con los rechazos y `master` queda intacto.

## Clave de la extensión

El ID `lidfhdhmbifmhikiaklbiehnhnkhoghe` sale del campo `key` del manifiesto. La clave privada está
en `../ucsync-extension-key.pem` (fuera de este repo): si se pierde o cambia, cambian el ID, las
claves de `chrome.storage` del usuario y el destino de `chrome://ucsync`.
