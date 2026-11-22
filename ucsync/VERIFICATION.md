# Verificación del parche UC-Sync

## Compilación

- Chromium `157.0.8103.78` (el tag que fija `chromium_version.txt` en la rama `master`).
- Checkout de git + `gclient sync -D`, poda de binarios, 110 parches (los dos UC-Sync son `110/110` y
  `111/111`), sustitución de dominios, `gn gen out/Default` (36 568 targets) y `ninja chrome`.
- Resultado: `out/Default/chrome`, 647 MB, construido en ~11 h con `-j 16` en 20 núcleos.
- Dos dependencias de `DEPS` anidados que `gclient` no instala en un checkout de git se traen a mano:
  `ucsync/fetch_esbuild.sh` (esbuild de DevTools) y `ucsync/fetch_dawn_go.sh` (el Go que usa Dawn).
  El resto de herramientas condicionadas a `non_git_source` las instala `ucsync/install_deps.py`.

## Comprobación estática del parche

`python3 ucsync/verify_patch.py` descarga los ficheros tocados del tag fijado y hace
`patch --fuzz=0 --dry-run`:

- sobre `157.0.8103.78`: los dos parches aplican (salida 0);
- sobre `120.0.6099.109`: fallan (salida 1) → el script avisa cuando hay que readaptar el parche.

## Comprobación en ejecución

`./ucsync/verify_runtime.sh --chrome <ruta>` arranca el binario headless con una extensión mínima y
valida los tres comportamientos. Salida obtenida sobre el binario compilado:

| Comprobación | Resultado |
| --- | --- |
| `addUrl({url, visitTime})` con hace 30 días | `getVisits()` devuelve exactamente el timestamp pedido (`1792304829424`), `isLocal: true` |
| `addUrls({urls:[…])` con 11, 12 y 13 días | los tres timestamps se conservan exactos, en una sola llamada |
| `visitTime` en el futuro | rechazado: `visitTime must be a valid time that is not in the future.` y 0 visitas creadas |
| `chrome.history.search()` | las cuatro URLs con `dias: 30 / 11 / 12 / 13`, o sea `chrome://history` muestra la fecha real |

Detalles del parche: las visitas se registran con `SOURCE_EXTENSION` (no `SOURCE_SYNCED`), así la
«limpieza de visitas foreign» de Chrome Sync no las borra si se desactiva la sincronización de Chrome.

## UC-Sync embebido (sin extensión que instalar)

Sobre el binario compilado con los parches 0003 y 0004, en un perfil nuevo y sin cargar nada:

- La extensión se registra sola: el log dice `UC-Sync: registrada la extensión integrada de
  <exe>/ucsync` y `Preferences` lista `lidfhdhmbifmhikiaklbiehnhnkhoghe`.
- `chrome://ucsync` **es** la página de opciones, servida por el navegador desde el directorio
  embebido con lista blanca de ficheros (`chrome/browser/ui/webui/ucsync/ucsync_ui.cc`), y el
  navegador le concede las APIs de esa misma extensión (origen leído del navegador, nunca del
  renderer). Verificado en `Chromium 157.0.8103.78` con CDP sobre un perfil limpio:

  | comprobación | resultado |
  | --- | --- |
  | `typeof chrome.history`, `chrome.bookmarks`, `chrome.storage`, `chrome.permissions`, `chrome.runtime` en `chrome://ucsync` | `object` |
  | `chrome.history.addUrl({url, visitTime: ahora - 30 días})` | `getVisits` devuelve `1792321789653` (idéntico al pedido) |
  | `typeof chrome.history.addUrls` | `function` |
  | `chrome.permissions.contains({history, bookmarks, contentSettings})` | `true` |
  | `chrome.runtime.sendMessage({type:'app:state'})` | responde el service worker MV3 |
  | página en una pestaña normal (`about:blank`) | `chrome.history` **no** existe |
  | `chrome://ucsync/manifest.json`, `background.js`, `popup.html`, `../../etc/passwd` | página de error (fuera de la lista blanca) |

  La UI se ve (logo, título UC-Sync, campos y botones) y no hay `bad IPC message` en el log.
- El bloqueo que impedía todo esto no era el WebUI sino la política de extensiones sin empaquetar:
  `DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION` (`disable_reasons [16777216]`) desactivaba la extensión
  porque vive como `kUnpacked`; `extension_management.cc` exime el ID de UC-Sync.

## DCHECK de Blink fatales en el binario de Linux (crash al abrir reddit)

Reportado por un usuario: al abrir `https://www.reddit.com/r/LocalLLaMA/` el navegador dejaba de
responder. El log del asset publicado traía el abort del renderer:

```text
FATAL:third_party/blink/renderer/core/layout/inline/inline_node.cc:2299]
DCHECK failed: (*max_size_out)->Round() == content_size.Round() (6305 vs. 6300)
  blink::ComputeContentSize() <- InlineNode::ComputeMinMaxSizes <- grid/flex track sizing
  <- LayoutView::HitTest <- EventHandler::HandleMouseMoveEvent <- BeginMainFrame
ptype = renderer · loaded-origin-0 = https://www.reddit.com
```

Causa raíz de build, no de nuestros parches: `build/config/dcheck_always_on.gni` pone
`dcheck_always_on = (build_with_chromium && !is_official_build) || dcheck_is_configurable`, y con
`disable_fieldtrial_testing_config = true` no hay field trial `DcheckIsFatal` que los vuelva no
fatales. El build de Windows se compila como oficial, así que ahí los DCHECK ni se incluyen: por eso
sólo petaba en Linux.

Corrección: `dcheck_always_on = false` y `enable_expensive_dchecks = false` en `ucsync/build.sh`.
Comprobado sobre el binario reconstruido (52.078/52.078 acciones, 0 `FAILED:`, 2 h 36 min):

| Comprobación | Resultado |
| --- | --- |
| cadenas `DCHECK failed` en el binario | 66 → 1 |
| literal del DCHECK `max_size_out` en el binario | 1 → 0 (el site ya no está compilado) |
| tamaño `out/Default/chrome` | 647 MB → 484 MB |
| `verify_runtime.sh` | `addUrl`/`addUrls` con hora real y hora futura rechazada: OK |
| `check_local.sh` | serie de 7 parches, choices de flags, UI sin PNG, `.ps1`: OK |
| reddit con binario nuevo, GUI, 70 s | sin `FATAL`, sin `Crashpad/completed` |

## Codecs propietarios: H.264/AAC (el vídeo de reddit no reproducía)

Síntoma: en reddit el `<video>` no arrancaba y el log traía
`FFmpegDemuxer: no supported streams`, `DEMUXER_ERROR_NO_SUPPORTED_STREAMS` y
`SetError {code=4}` (`MEDIA_ERR_UNSUPPORTED`). YouTube sí iba porque sirve VP9, libre y sí compilado.

Sonda `canPlayType()` por CDP (`ucsync/probe_codecs.mjs`) sobre el asset publicado y el binario nuevo:

| códec | asset publicado | binario con `proprietary_codecs` |
| --- | --- | --- |
| `video/mp4; codecs="avc1.42E01E"` (H.264) | `""` | `probably` |
| `video/mp4; codecs="avc1.640033"` (H.264 alto nivel) | `""` | `probably` |
| `video/mp4; codecs="mp4a.40.2"` (AAC) | `""` | `probably` |
| `application/vnd.apple.mpegurl` (HLS) | `""` | `maybe` |
| `video/webm; codecs="vp9"` | `probably` | `probably` |

Reproducción real (`ucsync/probe_playback.mjs`, `<video autoplay muted>` con un MP4 H.264+AAC):

| | asset anterior | binario nuevo |
| --- | --- | --- |
| `canPlayType('video/mp4; codecs="avc1…,mp4a…"')` | `""` | `probably` |
| `error` | `{code: 4}` | `null` |
| `readyState` | `0` | `4` (`HAVE_ENOUGH_DATA`) |
| `currentTime` | `0` (no avanza) | `5,35 → 5,76` (avanza) |

Causa raíz: los args de build no ponían `proprietary_codecs = true` ni `ffmpeg_branding = "Chrome"`;
el ffmpeg de Chromium sólo incluye H.264/AAC con esa marca. El constructor de Windows ya los traía en
`flags.windows.gn` (`proprietary_codecs=true`, `ffmpeg_branding="Chrome"`,
`enable_mse_mpeg2ts_stream_parser=true`, `is_official_build=true`, `dcheck_always_on=false`), por eso
en Windows el vídeo sí funcionaba y tampoco petaba por DCHECKs.

El AV1 de software sí está disponible: `enable_av1_decoder = enable_dav1d_decoder`
(`media/media_options.gni:148`) y `out/Default/obj/third_party/dav1d` se compila. Sondeo con cadenas
válidas (el nivel va en dos dígitos; `av01.0.1M.08` es una cadena inválida y devuelve `""`):

| sonda | resultado |
| --- | --- |
| `video/mp4; codecs="av01.0.05M.08"` | `probably` |
| `video/mp4; codecs="av01.0.01M.08"` | `probably` |
| `MediaSource.isTypeSupported('video/mp4; codecs="av01.0.05M.08"')` | `true` |
| `video/webm; codecs="av01"` (cadena corta) | `""` — Chromium exige perfil y nivel |

Pendiente, y no bloqueante: la decodificación **por hardware** (VA-API en AMD con Mesa reciente) se
comprueba en `chrome://media-internals` mirando `video_decoder_type`; sin ella todo va por dav1d en
CPU, que funciona pero cuesta más en 4K.

## Tormenta de repintado con el UI web de `omp` (colapso del proceso navegador)

Síntoma reportado: al abrir `http://<host>:30177/` y pulsar el selector de espacio de trabajo («+»),
Chromper deja de responder y el proceso navegador consume memoria sin techo hasta morir.

Medido en la máquina del usuario (CachyOS, Wayland/KDE, perfil real), con `perf` instalado:

| medición | valor |
|---|---|
| RSS del proceso navegador | +350 MB/s, 14,3 GB en 40 s (y abortos por OOM) |
| `Chrome_IOThread` | 305 083 faults en 4 s; el resto del proceso ~18 500 |
| procesos hijos (red, GPU, storage, renderers) | ~0 faults: no asignan |
| renderer de la página | 8-18 % de CPU en `PageAnimator::ServiceScriptedAnimations` → `LocalFrameView::RunPaintLifecyclePhase` → `PaintLayerPainter::Paint`, con `ContainerNode::RecalcDescendantStyles` continuo |
| rama `WebContentsImpl::UpdateTitle → NotifyTitleUpdateForEntry → TabDataObserver::OnTabUIChange → Tab::OnTabDataChanged` | ~7 % de las muestras de CPU |

Descartado con A/B (mismo perfil, misma URL, 40 s de observación):

| variable | resultado |
|---|---|
| `--disable-gpu` | sigue explorando |
| `--disable-features=PictureInPicture` y con `MediaSession,MediaSessionApi` | sigue explorando |
| `NO_AT_BRIDGE=1` (puente AT-SPI) | sigue explorando |
| `--disable-extensions` | sigue explorando (con sesión de omp activa) |
| sin `--remote-debugging-port` (arranque idéntico al del usuario) | sigue explorando, 15 GB y aborta |
| fugas de conexiones | 6 sockets al puerto 30177, ~100 descriptores: no hay fuga |
| restauración de sesión | `Sessions/Tabs_*` no contienen la URL: no restaura nada |
| perfil (bisección: History, Local Storage, Sessions, Service Worker, IndexedDB, Web Storage) | 0 MB en los seis casos cuando **no hay sesión de omp activa** en el servidor |

Conclusión honesta: el disparador es el stream de eventos de una **sesión de omp en curso** (el UI
repinta y reasigna el título en bucle); el perfil y las extensiones no son necesarios.

Sobre los parches de título, en orden cronológico y con números:

- `0008-title-notify-throttle` (coalescencia en el navegador, `WebContentsImpl`) estaba verificado
  como endurecimiento — 400 escrituras rápidas de `document.title` terminan con el último título en
  el target de DevTools — pero **no cortaba la fuga medida**: 14,3 GB/40 s sin él frente a
  14,1 GB/40 s con él. **Se revirtió** (`1f52d7c9`), porque `0010` resuelve el mismo síntoma sin
  desviación extra en el navegador. El fichero revertido queda en `/tmp/0008-revertido.patch`.
- `0010-title-ipc-coalesce` (coalescencia del IPC `LocalFrameHost::UpdateTitle` en el renderer,
  `blink::Document`) sí corta el caudal. Con una página que reescribe el título en bucle
  (`/tmp/title_burst.html`, 300 escrituras cada 5 ms): con sólo `0008` 826 050 mensajes en 5 s y
  RSS 1 522 → 2 243 MB con CPU 129 %; con `0010` 589 482 mensajes en 5 s, RSS plano en 269 MB y
  CPU 38 %. Con el URL real de `omp` y sesión de streaming: 297–298 MB planos en 90 s, CPU del
  navegador 2 %, ~1 500 mensajes cada 3 s.

Resultado del revert de `0008` (build `94/94`, `rc=0`, `fallos=0`; binario 487 369 240 bytes,
104 menos que el anterior): `nm -C` sobre el binario instalado en la máquina del usuario encuentra
`Document::ScheduleTitleSendToBrowser` y `Document::SendTitleToBrowser` (0010 sigue dentro) y **0**
símbolos de `WebContentsImpl::NotifyTitleUpdateThrottled`/`FlushDeferredTitleUpdate` (0008 fuera).
Activo: paquete `chromper-linux-x64-157.0.8103.78.tar.gz`, 199 384 004 bytes,
SHA-256 `76d67359438d5fbf4864ff8a9351dc9d1bfcf35c43db7206255a657d5f231ef8`, instalado con
`ucsync/execute.sh` y medido con el URL real de `omp`: 414 MB planos en 25 s, CPU del navegador
5-11 %, IPC ~0-3 mensajes cada 3 s. Con el perfil real abierto: 388 MB.


Y el bug de origen, resuelto en su propio repo (`github.com/ompweb-dev/ompweb`, v0.7.4):
el efecto de `components/AppShell.tsx` observaba `document.head` con `subtree` y `characterData`, o
sea su propia escritura del `<title>`, y `hooks/useAgentSession.ts` escribía el título sin
compararlo. Reconstruido con `bun run build` e instalado, el navegador queda estable sin depender
de los apaños del bundle minificado (backups en `index-9231ff16.js.orig-titulo`,
`index-9231ff16.js.orig-setTitle` y `~/ompweb-dist-0.7.4.orig`).
## Origen medido de la tormenta (bpftrace + traza de arranque, máquina del usuario)

Con `bpftrace` enganchado al proceso navegador durante el flood (extensión instalada y también con
`--disable-extensions`, porque el flood es el mismo):

| medición | resultado |
|---|---|
| `mojo::MessageDispatcher::Accept` | 2 381 706 en 6 s (≈ 400 000 mensajes/s); con `--disable-extensions` 1 908 369 en 4 s (≈ 477 000/s) |
| `IPC::ChannelAssociatedGroupController::Accept` | 2 219 586 en 6 s |
| `PartitionBucket::SlowPathAlloc` | 854 584 en 6 s; RSS 1 048 MB → 4 982 MB |
| `kprobe:tcp_sendmsg` desde `chromper` | **0** en 3 s; 7 sockets a `30177`, 295 `fd` → no hay red implicada |
| `net::ResolveContext` (constructor) | 0 en 5 s → no se crean peticiones |
| `InterfaceEndpointClient` (constructor) y `AssociateInterface` | 0 → no hay creación/cierre de endpoints |
| hojas `perf` | `__vdso_clock_gettime`, `base::ToLowerASCII`, `PartitionRoot::Alloc`, `FreeInUnknownRoot`, `ThreadCache::FillBucket`, `WeakReference::IsValid`, `WebContentsObserverList::NotifyObservers` |
| pila del aceptador | hilo de I/O: `Connector::ReadAllAvailableMessages → DispatchMessage → Accept` (2 356 982 en 5 s); hilo principal: `ChannelAssociatedGroupController::AcceptOnEndpointThread` (89 861 en 5 s) |

Traza de arranque (`--trace-startup --trace-startup-duration=4000`, 4 s, `/tmp/chrome.pftrace`):

| interfaz | llamadas en 4 s | con `--disable-extensions` |
|---|---|---|
| `ThemeService` | 71 342 | 9 922 (sigue habiendo ~2 500/s) |
| `TemplateURLServiceFactory` | 51 884 | 17 422 |
| `ExtensionRegistry` | 46 587 | **676** |
| `ProcessManager` | 45 791 | **29** |
| `ActivityLog` | 9 165 | **8** |
| `ExtensionPrefs` / `ExtensionSystem` | 9 381 / 9 446 | despreciable |

Lectura: las APIs de extensión multiplican el tráfico (factor ~70 en `ExtensionRegistry`, ~1 500 en
`ProcessManager`) pero **no son necesarias** para el colapso, que persiste idéntico con
`--disable-extensions`. El vehículo es un flujo de mensajes Mojo navegador↔renderer (~470 000/s)
provocado por la página, y el coste de memoria viene de la deserialización
(`ipcz::Message::DeserializeFromTransport` / `CopyDataAndValidateHeader`) más el trabajo de UI que
esa tasa arrastra (`views`, temas, favicon, notificaciones a observers).

Atribución del lado de la página, intentada y bloqueada: el agente de DevTools vive en el hilo de UI
saturado, así que `/json` deja de responder en ~2 s y ni `Profiler.stop` (40 s de tolerancia) ni
`--js-flags=--cpu-prof` ni `--perf-prof` llegaron a producir fichero. El único perfil JS obtenido es
el de la carga inicial (2 s, antes del flood), donde las funciones dominantes son las del bundle
`index-9231ff16.js`. Falta por tanto el nombre de la función de `omp` que genera el flujo; eso sólo
se puede obtener grabando un perfil de rendimiento en DevTools **antes** de que empiece el flood.

## Perfil nuevo y datos de navegacion borrados: el disparador estaba en los datos del sitio

Comprobacion en la maquina del usuario, en orden cronologico:

| estado | resultado |
|---|---|
| perfil real (450 MB) + sesion de omp activa | navegador 11 874 MB en 30 s y muerto; renderer ~160 % CPU |
| perfil nuevo (sin extensiones) + omp | navegador **plano** (265-267 MB), pero renderer subiendo a 100 % CPU |
| perfil nuevo + `setTitle` limitado a 200 ms en el bundle de `omp` | con sesion activa seguia a 1 386 927 mensajes/s y renderer 180 % |
| perfil nuevo tras borrar cache, cookies y todos los datos de navegacion, sesion de omp abierta y "+" pulsado | **sin parpadeo de titulo, sin colgarse**: 285 MB, CPU 2 %, 4 renderers |

Lectura: el disparador vive en los **datos del sitio del origen de `omp`** (localStorage/IndexedDB/
service worker del perfil viejo), no en Chromium ni en las extensiones. Con los datos limpios el UI
de `omp` no entra en bucle y Chromper se queda plano. El parche 0010 sigue siendo necesario: sin el
coalesce, cualquier bucle de titulo de cualquier pagina vuelve a explorar la memoria del navegador.

Backup del perfil real conservado en `~/.config/ucsync-chromium.backup-real` (450 MB). El limitador
de `setTitle` (200 ms) se aplico sobre el bundle servido por el servidor de `omp` de la maquina
`10.7.93.10`, con backup en `dist/assets/index-9231ff16.js.orig-setTitle`.

## Parche 0010: el renderer coalesce el IPC de `document.title` (origen del colapso)

La pila del emisor, trazada en el renderer culpable (`bpftrace` + `addr2line`/`nm`):

```
blink::MutationObserverAgentData::DeliverMutations -> MutationObserver::Deliver   (callback JS)
  -> v8_document::TitleAttributeSetCallback          (document.title = ...)
    -> HTMLTitleElement::setText -> Document::SetTitleElement -> Document::UpdateTitle
      -> Document::DispatchDidReceiveTitle -> GetLocalFrameHostRemote().UpdateTitle(...)
```

Cada escritura del titulo era un IPC al navegador. Prueba determinista con una pagina que reescribe
`document.title` en bucle (300 escrituras cada 5 ms), en la maquina del usuario:

| binario | `mojo::MessageDispatcher::Accept` en 5 s | RSS | CPU del navegador |
|---|---|---|---|
| viejo (0008, throttle solo en el navegador) | 826 050 | 1 522 -> 2 243 MB (+360 MB/5 s) | 129 % |
| nuevo (0010) | 589 482 | **269 MB plano** | 38 % |

El parche (`third_party/blink/renderer/core/dom/document.{h,cc}`) mueve el corte al lado del
renderer: `Document::ScheduleTitleSendToBrowser()` envia como mucho 10/s y deja pendiente un
`HeapTaskRunnerTimer` (`title_send_timer_`, `kMinTitleSendInterval = 100 ms`) que entrega siempre el
ultimo titulo. Con `omp web` abierto y sesion activa, el proceso navegador quedo en 302 MB estables
a los 30 s (antes 11 874 MB y muerto). Tres fallos de compilacion encadenados y sus causas:
`MakeWeakPersistent` no existe en Chromium 157, `TimerBase` de Blink no expone `IsRunning()` y el
flag `title_send_pending_` quedo duplicado en `document.h`. El parche se genera contra la base de
upstream ya aplicada (`ucsync/make_one_patch.py`); `verify_patch.py` confirma los 10 parches.

## Modo genérico: un solo perfil, sin restauración ni burbuja (parche 0009)

Petición del usuario: Chromper lo usa una sola persona, así que no debe tener maquinaria de perfiles
(historial y marcadores los sincroniza la extensión UC-Sync). Nada se borra: sólo se fija el perfil y
se elimina el estado de sesión. Verificado sobre `out/Default/chrome` (487 369 024 b, 21-11 18:47) con
Xvfb:

| prueba | resultado |
|---|---|
| perfil con `profile.exit_type = "Crashed"` y `session.restore_on_startup = 4` + `startup_urls` | al arrancar con `about:blank` sólo hay `about:blank` → **restauración desactivada** |
| `ProfileInfoCache` con varios perfiles en `Local State` | se abre siempre `Default` |
| UC-Sync con el binario nuevo (`ucsync/verify_runtime.sh`) | OK: `addUrl` con hora pasada, `addUrls` en lote y hora futura rechazada |
| compilación | 2 acciones incrementales, 0 `FAILED`; `verify_patch.py`: los 9 parches propios aplican sobre 157.0.8103.78 |
| `ucsync/check_local.sh` | todo correcto (serie ↔ ficheros, flags, UI sin PNG, `.ps1` de Windows 5.1) |

Consecuencia práctica: tras un `kill -9` (o un cierre anormal) el navegador ya no muestra «¿Quieres
restaurar las pestañas?» ni la burbuja de perfil bloqueado, y el `SingletonLock` residual no arrastra
otros perfiles. Los datos del perfil se conservan intactos.
