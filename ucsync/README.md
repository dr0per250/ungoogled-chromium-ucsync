# UC-Sync sobre Chromium: parches propios de la API de historial

Este repositorio es una **copia privada del repositorio público
[ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium)** con dos
parches propios sobre el código de Chromium, más la automatización para seguir a upstream.

Lo que se arregla: `chrome.history.addUrl()` registraba siempre la visita **ahora**, así que
una visita sincronizada perdía su fecha real en `chrome://history`. No era una limitación de
la API de datos: `HistoryService::AddPage(url, time, source)` y
`AddPagesWithDetails(rows, source)` aceptan cualquier marca de tiempo; sólo el bindings de
extensiones la fijaba a `base::Time::Now()`.

## Los dos parches

| Parche | Qué añade |
|---|---|
| `patches/extra/ucsync/0001-history-api-visit-time.patch` | `visitTime` opcional en `history.addUrl`: la visita se escribe con esa marca de tiempo (rechaza valores nulos o futuros). |
| `patches/extra/ucsync/0002-history-api-addurls-bulk.patch` | `history.addUrls({urls:[{url, title?, visitTime?}]})`: importa un lote con su propia marca de tiempo en una llamada (`AddPagesWithDetails`). Si alguna entrada es inválida, no registra nada. |

Ficheros de Chromium tocados:

* `chrome/common/extensions/api/history.json` — esquema (`visitTime` en `UrlDetails`, tipo `AddUrlsDetails`, función `addUrls`).
* `chrome/browser/extensions/api/history/history_api.{h,cc}` — `ParseVisitTime()`, `HistoryAddUrlFunction::Run()` y `HistoryAddUrlsFunction::Run()`.
* `chrome/browser/extensions/api/history/history_apitest.cc` — pruebas `AddUrl_WithVisitTime` y `AddUrls_Bulk`.
* `extensions/browser/extension_function_histogram_value.h` — `HISTORY_ADDURLS = 1993` (nuevo id al final del enum, como exige upstream).

Decisiones con consecuencia:

* Las visitas se registran con `SOURCE_EXTENSION`, no `SOURCE_SYNCED`: las fuentes
  "foreign" (`SOURCE_SYNCED`) las borra el backend cuando Chrome Sync se desactiva
  (`DeleteAllForeignVisitsAndResetIsKnownToSync`), y UC-Sync no usa Chrome Sync. Por eso
  `VisitItem.isLocal` sigue siendo `true`.
* Sin `visitTime` el comportamiento es idéntico al de upstream (`base::Time::Now()`), así que
  ninguna extensión existente cambia de comportamiento.
* El id de histograma nuevo debería acompañarse de
  `tools/metrics/histograms/update_extension_histograms.py`; en un build propio se omite (sólo
  afecta a presubmit y a la telemetría de métricas, que este fork no envía).

## Seguir a upstream

Upstream actualiza `chromium_version.txt` casi a diario; el parche toca código que puede
cambiar. La rutina es:

```sh
./ucsync/sync.sh              # fetch + merge de upstream/master + verificación + push
./ucsync/sync.sh --no-push    # merge y verificación, sin empujar
```

`ucsync/verify_patch.py` descarga de `chromium.googlesource.com` los ficheros que tocan
nuestros parches, en la versión fijada, y comprueba con `patch --dry-run -p1` que siguen
aplicando. **Si falla, no se empuja**: hay que readaptar el parche.

Para readaptar:

```sh
python3 ucsync/verify_patch.py --list      # ficheros tocados
./ucsync/make_workspace.sh                 # ucsync/work con los ficheros prístinos de la versión
# edita en ucsync/work y haz un commit por parche
./ucsync/rebuild_patches.sh                # vuelca los diffs a patches/extra/ucsync/
python3 ucsync/verify_patch.py             # verde antes de subir
```

`patches/series` lleva los dos parches al final (después de los de upstream) y
`revision.txt` va un punto por delante de upstream.

## Compilar

```sh
WORK=/IA/chromium-build ./ucsync/build.sh            # descarga, poda, parchea, domsub y compila
WORK=/IA/chromium-build ./ucsync/build.sh --prepare  # sólo hasta parchear
WORK=/IA/chromium-build ./ucsync/build.sh --chrome   # ninja chrome
```

Hace falta `depot_tools` en `PATH` (`gn`), `python3`, `patch`, `ninja` y unos **120 GB** libres
en `WORK`. La primera compilación son horas; las siguientes son incrementales. Los pasos son los
de [`docs/building.md`](../docs/building.md) (integration section).

## Contrato con la extensión UC-Sync

La extensión **no puede asumir** que el navegador esté parcheado: detecta la capacidad en
runtime (`addUrl` con `visitTime` verificado con `getVisits`, y si existe `addUrls`), y si no
está, degrada a `addUrl()` normal guardando la fecha real en su registro local. Con el parche,
las visitas sincronizadas aparecen en `chrome://history` con su hora auténtica; sin él, la hora
auténtica sólo se ve en *Ajustes → Historial sincronizado* de UC-Sync.

Comprobación: `ucsync/check_local.sh` ejecuta `devutils/check_patch_files.py` y
`ucsync/verify_patch.py` en local; en GitHub no corre nada (el fork no tiene `workflows/`).

## Dependencias que gclient se salta en un checkout de git

En un checkout de git `gclient sync` pone `non_git_source=False`, y con eso **no instala** las
herramientas condicionadas a esa variable (clang, rust, gn, ninja, mold, typescript, node,
los sysroots…). `ninja` se cae entonces con `missing and no known rule to make it`.

`ucsync/install_deps.py` lee `DEPS`, toma las entradas `cipd`/`gcs` de Linux/x64 y las instala
(con `cipd ensure` o descargando el tar del bucket de GCS):

```sh
python3 ucsync/install_deps.py --src "$SRC" --list      # qué instalaría
python3 ucsync/install_deps.py --src "$SRC"             # instala lo que falte
python3 ucsync/install_deps.py --src "$SRC" --filter typescript
```

Hay que instalar también `gn` y `ninja` en el checkout:

```sh
python3 ucsync/install_deps.py --src "$SRC" --filter buildtools/linux64
python3 ucsync/install_deps.py --src "$SRC" --filter third_party/ninja
```

Además, DevTools necesita el binario `esbuild`, que vive en un repositorio anidado cuyo `DEPS`
gclient no procesa: `ucsync/fetch_esbuild.sh <src>` lo descarga de npm (@esbuild/linux-x64,
con la versión que fija el `package.json` de DevTools).

`ucsync/fetch_dawn_go.sh <src>` hace lo mismo para el Go que Dawn necesita
(`third_party/dawn/tools/golang/linux-amd64/bin/go`, también de un `DEPS` anidado).

## UC-Sync dentro del navegador

Además de los parches de la API de historial, el fork embebe la extensión de UC-Sync:

- `0003-ucsync-browser-extension.patch`: el código de la extensión en
  `chrome/browser/resources/ucsync/` (texto puro; sin PNG, el logo es `logo.svg`).
- `0004-ucsync-browser-registration.patch`: `EnsureUCSyncBuiltInExtension()` registra la
  extensión en cada perfil al arrancar (ID fijo `lidfhdhmbifmhikiaklbiehnhnkhoghe`, derivado del
  campo `key` del manifiesto), y `chrome://ucsync` se sirve como página WebUI con los ficheros de
  la extensión y sus APIs de extensión concedidas a ese origen. Incluye la exención en
  `extension_management.cc` (si no, la extensión embebida queda desactivada por ser `kUnpacked`).
- `ucsync/make_ucsync_patches.sh` regenera ambos: 0003 desde `--extension <carpeta>` y 0004 desde
  el árbol de Chromium modificado, comparando contra la base **ya parcheada de upstream**
  (`ucsync/patch_sections.py` extrae de cada parche previo sólo la sección del fichero que toca).
- `ucsync/build.sh --chrome` copia `chrome/browser/resources/ucsync/` a `out/Default/ucsync/`, que
  es donde el loader busca la extensión (`<exe>/ucsync`). Si no está, el navegador funciona igual
  sin UC-Sync.

La clave privada que fija el ID está en `../ucsync-extension-key.pem` (fuera del fork): cambiarla
cambia el ID y con él las claves de `chrome.storage` y el destino de `chrome://ucsync`.

## Actualizar la versión de Chromium (todo en local)

GitHub no ejecuta nada de esto: el fork no tiene `workflows/` (estaban ahí y se quitaron porque
fallaban y mandaban correo; las comprobaciones se hacen en la máquina que compila). Cada paso es
un script local:

| script | qué hace |
| --- | --- |
| `ucsync/check_upstream.sh` | ¿hay Chromium o chromium-web-store nuevos? Dice además si la versión nueva trae el archivo oficial `lite`, la única con la que se valida la serie entera. |
| `ucsync/verify_patch.py <versión>` | validación rápida a nivel de fichero, sin compilar ni checkout: qué parches propios aplican sobre esa versión y qué ficheros rechazan. Guarda los ficheros del tag en `~/.cache/ucsync-chromium-files`, así que después trabaja sin red. |
| `ucsync/check_local.sh` | la serie en un minuto: parches propios, choices de `chrome://flags` que rompen `FeatureEntry::IsValid()`, `patches/series` contra el disco y que las extensiones embebidas no apuntan a PNG. |
| `ucsync/bump.sh --to <versión> --apply` | fusiona `upstream/master`, valida y sube el merge y la etiqueta `chromium-<versión>`; si rechaza, no sube nada a medias. |
| `ucsync/make_ucsync_patches.sh`, `make_search_patch.sh`, `rebuild_patches.sh` | regeneran los `.patch` desde el árbol de trabajo cuando un hunk choca contra código nuevo de Chromium. |

Regla que se aplica: sólo se fijan versiones con **archivo oficial `lite`** (la fuente con la que
se construye y se valida la serie completa). `157.0.8103.81` no lo tiene, y por eso la fijación se
quedó en `157.0.8103.78`, la versión compilada y verificada.

```sh
./ucsync/check_upstream.sh
./ucsync/verify_patch.py 158.0.8127.36
./ucsync/bump.sh --to 158.0.8127.36 --apply
```

Lo que **no** se automatiza: reescribir un parche cuando un hunk rechaza. Eso exige el árbol de
trabajo (`make_ucsync_patches.sh` regenera `0004` desde el Chromium ya modificado) y es un paso de
agente o humano; después se relanza el bump.

## Herramientas de Windows

La ruta nativa usa el constructor oficial `ungoogled-chromium-windows` con el submódulo apuntado a
este fork. `bootstrap_windows.ps1` es el orquestador reanudable por pasos:

```powershell
powershell -ExecutionPolicy Bypass -File .\diagnose_windows.ps1   -Workspace C:\chromper   # que tienes y que falta
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step install            # VS Build Tools (con ATL y Debugging Tools), Python, 7-Zip, paginacion, rutas largas
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step clone     -Workspace C:\chromper
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step build     -Workspace C:\chromper   # gclient sync + poda + parches (horas)
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step genbuild  -Workspace C:\chromper   # gn gen + bindgen/Crubit + ninja (esto es lo que se repite)
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step package   -Workspace C:\chromper   # chromper-windows-x64.zip
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step install-chromper -Workspace C:\chromper
powershell -ExecutionPolicy Bypass -File .\bootstrap_windows.ps1 -Step publish   -Workspace C:\chromper   # gh release upload
```

Cosas que este script adapta a la máquina, porque el árbol de Chromium 157 da por hecho cosas que
no siempre están: `SDK_VERSION` (fija 10.0.28000.0) al SDK completo instalado, `NTDDI_VERSION` con
su alias cuando el SDK no define `NTDDI_WIN11_BR`, `dbghelp.dll` del SDK de Debugging, el componente
C++ ATL, y el Git real delante de depot_tools (el `git.bat` de depot_tools se cuelga clonando
rust-bindgen). Compila bindgen y Crubit antes de ninja porque el constructor de Windows no los
trae hechos.

Para que un build largo no se quede mudo: cada paso va con vigilancia (`genbuild.ninja.log` con las
acciones en vivo, 12 min sin avance mata el árbol y deja `ALERTA.txt` con la firma del error,
`genbuild.log.fallo` con el intento fallido) y `runner_windows.ps1` reanuda tras los reinicios de
Windows Update como tarea programada, deteniéndose tras dos fallos idénticos.

`cdp_check_windows.ps1` comprueba el navegador instalado sobre CDP sin necesitar node ni gh:
`chrome://ucsync`, `chrome.history.addUrls({urls})` conservando la marca de tiempo (comprobada con
`getVisits`), la visita marcada como local y el buscador Google compilado en `chrome.dll`.
`check_ps1_parse.ps1` verifica que todos los `.ps1` parsean en Windows PowerShell 5.1.