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
