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

El AV1 de software sigue sin anunciarse (`canPlayType('av01…')` = `""`); no bloquea reddit, que sirve
H.264/AAC, y queda apuntado como pendiente.
