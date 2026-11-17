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
