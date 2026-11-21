# **Chromper** — ungoogled-chromium con UC-Sync integrado

**Chromper** es el navegador de este repo: un Chromium sin Google (ungoogled-chromium) con la
extensión de sincronización cifrada **UC-Sync** integrada y su UI en `chrome://ucsync`. El nombre del
producto es Chromper (`chromper` es el ejecutable y el lanzador); *Chromium* sigue nombrando el motor,
y las URLs internas (`chrome://…`) mantienen su esquema. El repo se llama
`ungoogled-chromium-ucsync` porque es una copia de ungoogled-chromium que sigue a upstream
automáticamente.

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
| **Binarios** | Linux x64 (`chromper-linux-x64.tar.gz`, 190 MB) y Windows 11 x64 (`chromper-windows-x64.zip`, 188 MB) publicados en [Releases](https://github.com/dr0per250/ungoogled-chromium-ucsync/releases), en el tag `chromium-157.0.8103.78`. Los dos comprobados sobre el asset publicado: `--version`, `chrome://ucsync`, `addUrls` conservando la marca de tiempo, el buscador Google y los codecs H.264/AAC (`ucsync/verify_runtime.sh`, `ucsync/cdp_check_windows.ps1`). |
| Nombre del producto | **Chromper** también por dentro: `chromper --version` y el menú/Acerca de dicen Chromper (parche `0005`), ejecutable `chromper`/`chromper.exe`, lanzador `chromper`, entrada `io.chromper.desktop` con el icono de Chromium, perfil `~/.config/chromper`, `WM_CLASS=chromper`. El motor sigue siendo Chromium y la autoría sigue nombrando a The Chromium Authors. |
| Bóveda y servidor | [dr0per250/uc-sync](https://github.com/dr0per250/uc-sync) — [Releases](https://github.com/dr0per250/uc-sync/releases) con el zip si quieres la extensión suelta |
| Herramientas propias | [`ucsync/`](ucsync/README.md) (`build.sh`, `bump.sh`, `verify_patch.py`, `make_ucsync_patches.sh`, `verify_runtime.sh`) |
| Pruebas de comportamiento | [`ucsync/VERIFICATION.md`](ucsync/VERIFICATION.md) |

Lo de ungoogled (objetivos, características, FAQ, construcción genérica) sigue en el
[upstream](https://github.com/ungoogled-software/ungoogled-chromium) y en sus `docs/`.

---

## Instalar el binario (CachyOS / Arch)

El release `chromium-<versión>` trae `chromper-linux-x64.tar.gz` (190 MB: navegador, recursos,
idiomas recortados y las dos extensiones integradas). El repo es público: para instalar no hace
falta `gh` ni token.

Una línea y listo (estilo community-scripts):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/execute.sh)"
chromper
```

Sin clonar nada, sin tokens, sin compilar y **sin pasos extra**: el script instala las librerías que
faltan, descarga el binario del último release, lo instala, deja lanzador + icono + entrada de
aplicaciones, pone `chrome_sandbox` setuid root con sudo (sandbox real; sólo pide la contraseña de
sudo si no es sin contraseña), añade `~/.local/bin` al PATH si falta, registra UC-Sync como navegador
por defecto y comprueba en headless que la UI carga. **No abre ninguna ventana**: cuando termine,
lanza tú `chromper` (o `UCSYNC_OPEN_UI=1` si quieres que lo abra el script).

Reutiliza el perfil que ya exista, en este orden: `~/.config/chromper`,
`~/.config/ungoogled-chromium`, `~/.config/chromium`; si no hay ninguno, crea
`~/.config/chromper`. Así, si vienes de un ungoogled-chromium instalado con pacman/AUR,
marcadores, historial y el resto del perfil se conservan y UC-Sync se registra en ese mismo perfil.
Reinstalar no toca el perfil: `chrome.storage` de la extensión (`Local Extension Settings`) y tus
datos siguen ahí. Lo único que no puede hacer el script es escribir tu contraseña del servidor en la
terminal: eso se pone una vez en la propia UI.

`execute.sh` es un solo fichero autocontenido: descarga el tarball del último release, instala las
librerías que faltan (`pacman -S --noconfirm`), instala en `~/.local/share/chromper`, deja el
lanzador `chromper`, el icono y la entrada de aplicaciones, y comprueba el binario. Opciones
por entorno: `UCSYNC_SYSTEM=1` (en `/opt` con `chrome_sandbox` setuid root → sandbox real, pide
sudo), `UCSYNC_PREFIX`, `UCSYNC_NO_SANDBOX=1`, `UCSYNC_SKIP_DEPS=1`, `UCSYNC_NO_DEFAULT=1`,
`UCSYNC_NO_LAUNCH=1`, `UCSYNC_OPEN_UI=1`, `UCSYNC_TARBALL=<archivo>` (instalar un paquete local),
`UCSYNC_UNINSTALL=1` (desinstalar). El perfil queda en `~/.config/chromper` (`UCSYNC_PROFILE`).
queda en `~/.config/chromper` (`UCSYNC_PROFILE` para cambiarlo).

**Publicar un binario nuevo** tras compilar:

```sh
./ucsync/make_release.sh --src ~/ucbuild/src     # package_linux.sh + gh release upload
```

## Instalar el binario (Windows 11)

Una línea (o `-Zip` con el zip que hayas construido tú):

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/install_windows.ps1 -OutFile $env:TEMP\install-chromper.ps1; & $env:TEMP\install-chromper.ps1"
```

`raw.githubusercontent.com` sirve a veces una copia cacheada del commit anterior: tras publicar
scripts fija el SHA en la URL. Con el zip ya descargado, `-Zip` evita la descarga:

```powershell
.\ucsync\install_windows.ps1 -Zip D:\chromper\pkg\chromper-windows-x64.zip
```

Requisitos: Windows 10 22H2+ o Windows 11 x64 y PowerShell 5.1+ (el del sistema). No hace falta
ser admin, ni Visual Studio, ni el redistributable de VC++ (el CRT viaja dentro del zip).

El instalador coloca el navegador en `%LOCALAPPDATA%\chromper`, crea el atajo de escritorio (con
`--user-data-dir` propio, configurable con `-UserDataDir`), lo añade al `PATH` del usuario y
comprueba `chromper.exe --version`. No toca el perfil de Chrome: crea
`%LOCALAPPDATA%\chromper-profile`. Para traer marcadores e historial: `chrome://settings/importData`.

**Desinstalar** (quita el navegador, el atajo y la entrada del `PATH`; cierra Chromper si estaba
abierto, porque `chrome.dll` queda bloqueado, y tus datos se conservan):

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/install_windows.ps1 -OutFile $env:TEMP\uninstall-chromper.ps1; & $env:TEMP\uninstall-chromper.ps1 -Uninstall"
```

En Linux es el mismo instalador con `UCSYNC_UNINSTALL=1`. Los dos dejan el perfil donde estaba;
para borrar también los datos: `Remove-Item -Recurse -Force $env:LOCALAPPDATA\chromper-profile`
o `rm -rf ~/.config/chromper`.

## Compilar en CachyOS / Arch

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
la compilación (`is_debug = false`, `is_official_build = false`, `dcheck_always_on = false`,
`enable_expensive_dchecks = false`, `proprietary_codecs = true`, `ffmpeg_branding = "Chrome"`,
`enable_mse_mpeg2ts_stream_parser = true`, `symbol_level = 0`, `v8_symbol_level = 0`,
`use_sysroot = true`) y copia `chrome/browser/resources/ucsync/` a
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
| el renderer aborta al abrir ciertas webs (`FATAL … DCHECK failed` en `inline_node.cc`) | `dcheck_always_on = false`: con `is_official_build = false` los DCHECK de Blink se compilan y, sin field trials, son fatales |
| el vídeo de reddit no reproduce (YouTube sí) y el log dice `DEMUXER_ERROR_NO_SUPPORTED_STREAMS` con `SetError {code=4}` | `proprietary_codecs = true` y `ffmpeg_branding = "Chrome"`: sin la marca «Chrome» el ffmpeg de Chromium no incluye H.264/AAC, que es lo que sirve reddit por MSE/HLS; VP9 (YouTube) sí venía |
| `ninja: unknown target chrome_sandbox` | en otras plataformas: `ninja -C out/Default chrome chromedriver` |

## Compilar en Windows 11

La ruta nativa usa el constructor oficial
[ungoogled-chromium-windows](https://github.com/ungoogled-software/ungoogled-chromium-windows) y le
apunta el submódulo `ungoogled-chromium` a **este fork**, así se aplican nuestros 7 parches con el
mismo `patches/series`. Por pasos y reanudable:

```powershell
git clone https://github.com/dr0per250/ungoogled-chromium-ucsync.git $env:USERPROFILE\chromper-fork
cd $env:USERPROFILE\chromper-fork\ucsync
powershell -ExecutionPolicy Bypass -File .\diagnose_windows.ps1 -Workspace D:\chromper   # qué tienes y qué falta
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step install           # VS Build Tools (C++ + ATL + Debugging Tools), Python, 7-Zip, paginacion y rutas largas (admin)
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step check             # 17 comprobaciones: que no falte nada antes de clonar
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step clone  -Workspace D:\chromper
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step build  -Workspace D:\chromper   # gclient sync + poda + parches (horas)
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step genbuild -Workspace D:\chromper  # gn gen + bindgen/Crubit + ninja; esto es lo que se reanuda
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step package -Workspace D:\chromper
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step install-chromper -Workspace D:\chromper
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step publish -Workspace D:\chromper   # gh release upload (necesita gh en esa maquina)
```

Además de la carga de trabajo *C++*, el build de 157 necesita cosas que el instalador de Visual
Studio no trae por defecto y `bootstrap_windows.ps1 -Step install` añade ya:

* **C++ ATL** (`Microsoft.VisualStudio.Component.VC.ATL`): `base/win/atl_throw.h` pide `atldef.h`, y
  sin él ninja peta en `obj/base/base/atl_throw.obj`.
* **C++ Debugging Tools** (`VC.DiagnosticTools`, el DIA SDK con `msdia140.dll`) y `dbghelp.dll`; si
  no están, `-Step install` rellena `Windows Kits\10\Debuggers\x64` desde `System32`.
* Chromium 157 fija `SDK_VERSION = 10.0.28000.0` y `NTDDI_VERSION=NTDDI_WIN11_BR`, y Visual Studio 2022
  solo ofrece SDK 22621/26100. `bootstrap_windows.ps1` reescribe `SDK_VERSION` al SDK completo del
  disco y baja `NTDDI_VERSION` a `NTDDI_WIN11_GE` definiendo el alias `NTDDI_WIN11_BR=NTDDI_WIN11_GE`
  (sin el alias `base/win/windows_version.cc` hace `#error Windows 10.0.28000.0 SDK or higher required`).
* `bindgen` y Crubit no vienen hechos: `-Step genbuild` los compila, poniendo el Git real primero en
  el `PATH` porque el `git.bat` de depot_tools se cuelga clonando rust-bindgen.

Números reales de la compilación publicada (16 hilos, 30,9 GB de RAM): árbol de fuente ≈ 41 GB,
`ninja chrome` ≈ 57.700 acciones en ≈ 3 h con `-j 12`, y hace falta un archivo de paginación de
16 GB (con la paginación automática de 4 GB el enlace no cabe): `-Step install` lo deja en
16384-32768 MB por registro y avisa si hay que reiniciar.

Cada paso es reanudable y `-Step genbuild` es el que se repite si ninja peta a mitad (relanza
`gn gen`, bindgen/Crubit y ninja donde quedó). Los logs van a `<Workspace>`: `genbuild.ninja.log`
con las acciones de ninja en vivo, `genbuild.log.fallo` el del último intento y `registro.txt` el
registro completo; un fallo deja además `ALERTA.txt` con la firma del error. La vigilancia mata el
árbol si deja de avanzar 12 min y `ucsync\runner_windows.ps1` (tarea programada, reanuda tras los
reinicios de Windows Update) se detiene tras dos fallos idénticos en vez de gastar 10 intentos.

`diagnose_windows.ps1` revisa: Windows 10 22H2+ x64, 16 GB de RAM, ~120 GB libres, Visual Studio 2022
con la carga de trabajo *C++* y Windows SDK, Python 3.11+ con los módulos `httplib2` y `clang`, Git,
7-Zip y `LongPathsEnabled=1`. El `build.py` del constructor de Windows llama a `vcvars64` y pone
`DEPOT_TOOLS_WIN_TOOLCHAIN=0` (compila con el Visual Studio de tu máquina, no descarga el toolchain de
Google) y deja la salida en `build\src\out\Default`.

`package_windows.ps1` renombra el ejecutable a `chromper.exe`, recorta idiomas a
`es es-419 en-US pt-BR fr de it gl ca eu ja zh-CN zh-TW ru`, coloca `ucsync\` y `chromium-web-store\`
junto al ejecutable (donde los busca el loader con `base::DIR_EXE`) y escribe `VERSION` con la versión de
Chromium y la de las dos extensiones. El registro de la construcción queda en `<Workspace>\registro.txt`:
eso es lo que hay que pegar si un paso falla.

Si no tienes 120 GB libres o el equipo es justo, la alternativa es **WSL2** con la guía de Linux de
arriba (WSLg abre la ventana y el binario que sale es el de Linux).

El binario Linux se publica con `./ucsync/make_release.sh` (crea el release del tag y sube el
tarball). Para la extensión suelta, los releases de
[uc-sync](https://github.com/dr0per250/uc-sync/releases).

## Qué cambia en el navegador (detalle de los 7 parches)

- **`0001-history-api-visit-time`** — `chrome.history.addUrl({url, visitTime})` acepta horas pasadas
  y rechaza las futuras con el mensaje
  `visitTime must be a valid time that is not in the future.`
- **`0002-history-api-addurls-bulk`** — `chrome.history.addUrls({urls})` importa lotes con
  `HistoryService::AddPagesWithDetails`, cada fila con su `last_visit`; si una URL o una hora es
  inválida se rechaza el lote entero.
- **`0003-ucsync-browser-extension`** — el código de la extensión en
  `chrome/browser/resources/ucsync/` (texto puro; sin PNG, el logo es `logo.svg`).
- **`0004-ucsync-browser-registration`** — registra las dos extensiones integradas en cada perfil al
  arrancar (`EnsureUCSyncBuiltInExtension()` y `EnsureChromiumWebStoreBuiltInExtension()`), las exime
  de la política de extensiones sin empaquetar (si no, quedarían desactivadas por vivir como
  `kUnpacked`), sirve la UI en `chrome://ucsync` con las APIs de extensión concedidas a ese origen
  (decididas por el navegador, nunca reivindicadas por el renderer; **no** hay
  `web_accessible_resources`) y cambia el comportamiento del CRX: `IsOffstoreInstallAllowed()`
  responde `true` cuando `chrome://flags/#extension-mime-request-handling` está sin tocar, y la lista
  de esa bandera muestra «Always prompt for install (Chromper default)».
- **`0005-chromper-branding`** — el nombre interno del producto es **Chromper**:
  `chrome/app/theme/chromium/BRANDING` (`PRODUCT_FULLNAME`/`PRODUCT_SHORTNAME`), las cadenas del
  navegador (`chrome/app/chromium_strings.grd`, `chrome/app/settings_chromium_strings.grdp`,
  `chrome/app/settings_strings.grdp`) y sus traducciones al español (`chromium_strings_es*.xtb`,
  `generated_resources_es*.xtb`). Se ve en `chromper --version`, el menú, `chrome://version`,
  «Acerca de» y Ajustes. **La autoría se conserva**: `COMPANY_*`, el copyright y «Los creadores de
  Chromium» siguen nombrando a *The Chromium Authors*, y el motor y las URLs internas (`chrome://…`)
  mantienen el nombre Chromium. El `WM_CLASS` se fija con `--class=chromper` en el lanzador.
- **`0006-chromium-web-store-extension`** — [chromium-web-store](https://github.com/NeverDecaf/chromium-web-store)
  vendida en `chrome/browser/resources/chromium-web-store/`, con su `key` (ID estable
  `ocaahdebbfolfmndjeplogmgcagdmblk`, el mismo del CRX oficial) y los PNG sustituidos por un SVG con
  el icono en base64: `ucsync/vendor_webstore.sh` fija la versión y deja `ucsync/webstore.lock.json`.
  Con la bandera de CRX por defecto, se pueden instalar extensiones de la Chrome Web Store sin
  configurar nada.

Las pruebas `ExtensionManagementMimeHandlingTest` (en `extension_management_unittest.cc`, dentro de
`0004`) fijan ese comportamiento del CRX: por defecto se pregunta, con
`always-prompt-for-install` se pregunta y con `download-as-regular-file` se descarga. Necesitan un
checkout completo de Chromium (`third_party/test_fonts` y `chrome/test/data/webui`) para compilar el
blanco de pruebas; en un árbol podado como el de esta máquina no se construyen.

- **`0007-chromper-default-search-engine`** — **Google** como buscador por defecto. Deja el bloque
  `google` de `third_party/search_engines_data/resources/definitions/prepopulated_engines.json` como
  viene en upstream (ungoogled lo sustituye por el marcador «No Search», keyword `nosearch`), así los
  perfiles nuevos arrancan con Google — los ajustes regionales (`ES`, `AR`, …) lo ponen primero en su
  lista. Además las URL del motor se escriben explícitas (`https://www.google.com/…`): ungoogled
  sustituye el dominio de Google por `9oo91e.qjz9zk` en el código, y un buscador que apunte a ese
  marcador no resuelve en DNS. La migración limpia también el buscador por defecto guardado en el
  perfil cuando apunta a ese dominio sustituido, no sólo cuando es `nosearch`
  (`components/search_engines/default_search_manager.cc`), para que los perfiles creados antes de este
  cambio vuelvan a Google una sola vez; si después eliges otro motor en `chrome://settings/search`, no
  se vuelve a tocar. `ucsync/make_search_patch.sh` regenera el parche y `--refresh-baseline` rehace la
  base del JSON cuando el submódulo `external/search_engines_data` cambie.

- **`0008-title-notify-throttle`** — **caudal de cambios de título**. El proceso navegador se quedaba
  sin respuesta y consumía ~1 GB/s de RAM al abrir el UI web de `omp`: la página reasigna
  `document.title` sin límite y cada cambio recorre el UI de la pestaña
  (`WebContentsImpl::NotifyTitleUpdateForEntry` → `tabs::TabDataObserver::OnTabUIChange` →
  `Tab::OnTabDataChanged`, con su tooltip y su nombre accesible) y reenvía un `tabs.onUpdated` a cada
  extensión con permiso `tabs` (`extensions::ExtensionTabUtil::CreateTabObject`). Con varias
  extensiones activas eso satura el hilo de UI (~150 % de CPU) y la contabilidad de eventos en vuelo
  (`extensions::EventAckData::IncrementInflightEvent` → `content::ServiceWorkerVersion::
  StartExternalRequest`, un `std::map<base::Uuid,int>` que sólo se descuenta cuando el service worker
  confirma) crece sin techo. El parche coalesce las notificaciones de título a ~10 por segundo por
  pestaña, entregando siempre la última (`WebContentsImpl::NotifyTitleUpdateThrottled` y
  `FlushDeferredTitleUpdate`). Es una mitigación defensiva: cualquier página con un bucle de títulos
  deja de poder tumbar el navegador; el bug de origen está en la app (su `MutationObserver` sobre
  `document.head` observa su propia escritura del `<title>`).

- **`0009-chromper-single-profile`** — **modo genérico de un solo usuario, sin maquinaria de
  perfiles**. Chromium siempre necesita un `--user-data-dir`, así que «sin perfiles» se traduce en un
  perfil fijo y sin estado de sesión: `ProfileManager::GetLastUsedProfileBaseName()` devuelve siempre
  `Default` (aunque `local_state` haya guardado otro o el `ProfileInfoCache` liste varios por arranques
  antiguos) y `ChromeBrowserMainParts::PostProfileInit()` fija `profile.exit_type = "Normal"` más
  `SessionStartupPref::DEFAULT` en cada arranque. Desaparecen el selector de perfil, la restauración de
  pestañas y la burbuja de «sesión bloqueada» que salía tras cada salida anormal. **No se borra nada**:
  cookies, contraseñas y los ajustes de UC-Sync siguen en el mismo perfil; el historial y los marcadores
  los sostiene la extensión, que es la fuente de verdad. La serie queda en 9 parches propios.

Las visitas se escriben con `SOURCE_EXTENSION`, no con `SOURCE_SYNCED`: Chrome Sync no las borra
cuando se desactiva y `VisitItem.isLocal` sigue siendo `true` (se pueden borrar a mano).

### El prefijo del nombre anterior

Los perfiles instalados mientras el navegador se llamaba `ucsync-chromium` guardan en
`Preferences` la **ruta** de la extensión embebida (`~/.local/share/ucsync-chromium/ucsync`). Si ese
directorio desapareciera, la extensión quedaría sin ficheros y la UI mostraría imágenes rotas: el
instalador convierte ese prefijo en un **enlace simbólico** al nuevo (`~/.local/share/chromper`), así
las rutas viejas siguen apuntando a los ficheros actuales, y `UCSYNC_UNINSTALL=1` quita el
enlace si apuntaba al prefijo borrado. No se recarga la extensión descargándola
en caliente: quitarla y volverla a cargar en el arranque provoca un `DCHECK` en
`toolbar_actions_model.cc` (estado de los botones fijados), por eso se resuelve en el disco.

## Comprobaciones y actualización: todo en local
GitHub no ejecuta nada de esto (el fork no tiene workflows). Sólo guarda los parches y publica los
binarios ya compilados aquí; compilar Chromium siempre se hace en tu máquina (`ucsync/build.sh`).

```bash
./ucsync/check_local.sh                     # todas las comprobaciones, sin compilar
./ucsync/check_local.sh --src ~/chromium/src # además contra el árbol de trabajo
./ucsync/check_upstream.sh                  # ¿hay Chromium o chromium-web-store nuevos?
```

En Windows, además: `check_ps1_parse.ps1` (los `.ps1` tienen que parsear en PowerShell 5.1) y
`cdp_check_windows.ps1` (comprueba el navegador instalado sobre CDP: `chrome://ucsync`, `addUrls`
conservando la marca de tiempo, la visita marcada como local y el buscador Google compilado).

`check_local.sh` revisa en un minuto:

1. que los 7 parches propios aplican sobre la versión fijada (`ucsync/verify_patch.py`);
2. que ninguna choice de `chrome://flags` rompe `FeatureEntry::IsValid()` (`ucsync/check_flag_choices.py`);
3. que `patches/series` y los ficheros del disco coinciden;
4. que las extensiones integradas no referencian `icons/*.png` y que `ucsync/extension.lock.json` y
   `ucsync/webstore.lock.json` declaran su versión;
5. con `--src`: que el árbol tiene las dos extensiones, el branding `Chromper`, la autoría de Chromium
   intacta y Google con URL reales (`google.com`, no el dominio sustituido).

`verify_patch.py` guarda en `~/.cache/ucsync-chromium-files` (variable `UCSYNC_FILE_CACHE`) los ficheros
que descarga del tag: la primera vez baja 31 ficheros y después trabaja sin red (≈1,5 s). Además
distingue un 404 real (el fichero lo crea un parche de upstream) de un corte de red; confundirlos era
la causa de que esta comprobación fallara a veces sin motivo.

Actualizar una versión de Chromium, en orden:

```bash
./ucsync/check_upstream.sh                       # qué hay nuevo
./ucsync/verify_patch.py 158.0.8127.36           # los parches propios aplican sobre esa versión
./ucsync/bump.sh --to 158.0.8127.36 --apply      # fusiona upstream y actualiza la fijación
./ucsync/build.sh --prepare && ./ucsync/build.sh --chrome
./ucsync/make_ucsync_patches.sh --src … --extension …   # 0001-0004 y 0006
./ucsync/make_search_patch.sh --src …                  # 0005 branding y 0007 buscador
./ucsync/check_local.sh --src …
./ucsync/package_linux.sh --src … --out … && gh release upload chromium-<versión> …
```

Lo que sigue necesitando mano: readaptar un parche cuando un hunk choca contra código nuevo de Chromium.
`verify_patch.py` dice qué ficheros tocan y `ucsync/rebuild_patches.sh` regenera los `.patch`.

## Clave de la extensión

El ID `lidfhdhmbifmhikiaklbiehnhnkhoghe` sale del campo `key` del manifiesto. La clave privada está
en `../ucsync-extension-key.pem` (fuera de este repo): si se pierde o cambia, cambian el ID, las
claves de `chrome.storage` del usuario y el destino de `chrome://ucsync`.
