#!/usr/bin/env bash
# Comprueba en ejecución que este Chromium acepta visitas con timestamp real.
#
# Levanta un Chromium headless con una extensión mínima que, al instalarse:
#   1. `addUrl({url, visitTime})` con una hora de hace 30 días,
#   2. `addUrls({urls: [...]})` con tres horas distintas,
#   3. intenta una hora futura (debe rechazarse),
#   4. y `search()` para ver qué fecha guarda realmente `chrome://history`.
# La extensión envía el resultado a un pequeño servidor local; el script lo valida.
#
# Uso: ucsync/verify_runtime.sh [--chrome <ruta>] [--port 8177] [--keep]
set -euo pipefail
CHROME=/IA/chromium-build/src/out/Default/chrome
PORT=8177
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrome) CHROME="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --keep) KEEP=1; shift;;
    *) echo "opción desconocida: $1"; exit 1;;
  esac
done
[[ -x "$CHROME" ]] || { echo "No hay Chromium en $CHROME (compílalo con ucsync/build.sh --chrome)"; exit 1; }
command -v node >/dev/null || { echo "node no está en el PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXT="$WORK/ext"
RESULT="$WORK/result.json"
mkdir -p "$EXT"

cat > "$EXT/manifest.json" <<EOF
{
  "manifest_version": 3,
  "name": "ucsync patch check",
  "version": "0.1",
  "permissions": ["history"],
  "host_permissions": ["http://127.0.0.1:$PORT/*"],
  "background": { "service_worker": "sw.js" }
}
EOF

cat > "$EXT/sw.js" <<EOF
const DAY = 86400000;
const now = Date.now();
const visits = async (url) => (await chrome.history.getVisits({ url })).map((v) => v.visitTime);

async function probe() {
  const out = {};
  const past = now - 30 * DAY;
  const u1 = 'https://ucsync-patch-check.example/past-visit';
  try {
    await chrome.history.addUrl({ url: u1, visitTime: past });
    out.addUrl = { pedida: past, devuelta: await visits(u1) };
  } catch (err) { out.addUrl = { error: String((err && err.message) || err) }; }

  const rows = [
    { url: 'https://ucsync-patch-check.example/bulk-a', title: 'A', visitTime: now - 11 * DAY },
    { url: 'https://ucsync-patch-check.example/bulk-b', title: 'B', visitTime: now - 12 * DAY },
    { url: 'https://ucsync-patch-check.example/bulk-c', title: 'C', visitTime: now - 13 * DAY },
  ];
  if (typeof chrome.history.addUrls === 'function') {
    try {
      await chrome.history.addUrls({ urls: rows });
      out.bulk = { ok: true, seen: await Promise.all(rows.map(async (r) => ({ pedida: r.visitTime, devuelta: await visits(r.url) }))) };
    } catch (err) { out.bulk = { error: String((err && err.message) || err) }; }
  } else {
    out.bulk = { ausente: true };
  }

  try {
    await chrome.history.addUrl({ url: 'https://ucsync-patch-check.example/future', visitTime: now + 60000 });
    out.futuro = { rechazada: false };
  } catch (err) {
    out.futuro = { rechazada: true, mensaje: String((err && err.message) || err) };
  }
  out.busqueda = (await chrome.history.search({ text: '', startTime: 0, maxResults: 100 }))
    .filter((i) => (i.url || '').includes('ucsync-patch-check'))
    .map((i) => ({ url: i.url, dias: Math.round((Date.now() - i.lastVisitTime) / DAY) }));
  return out;
}

chrome.runtime.onInstalled.addListener(async () => {
  try {
    await fetch('http://127.0.0.1:$PORT/result', { method: 'POST', body: JSON.stringify(await probe(), null, 2) });
  } catch (err) { console.log('no se pudo reportar:', String((err && err.message) || err)); }
});
EOF

UCSYNC_RESULT="$RESULT"
export UCSYNC_RESULT
node -e "
const http=require('node:http'),fs=require('node:fs');
const destino = process.env.UCSYNC_RESULT;
http.createServer((req,res)=>{res.setHeader('Access-Control-Allow-Origin','*');
  if(req.method!=='POST'){res.writeHead(200).end('ok');return;}
  let b='';req.on('data',c=>b+=c);req.on('end',()=>{fs.writeFileSync(destino,b);res.writeHead(200).end('ok');});
}).listen($PORT,'127.0.0.1');
" &
COLLECTOR=$!
trap 'kill "$COLLECTOR" 2>/dev/null || true; rm -rf "$WORK"' EXIT

"$CHROME" --headless=new --no-sandbox --no-first-run --no-default-browser-check \
  --user-data-dir="$WORK/profile" --disable-extensions-except="$EXT" --load-extension="$EXT" \
  about:blank >"$WORK/chrome.log" 2>&1 &
BROWSER=$!

for _ in $(seq 1 60); do [[ -s "$RESULT" ]] && break; sleep 1; done
if [[ $KEEP -eq 1 ]]; then echo "navegador vivo en pid $BROWSER (matándolo al salir)"; fi
kill "$BROWSER" 2>/dev/null || true
wait "$BROWSER" 2>/dev/null || true

[[ -s "$RESULT" ]] || { echo "La extensión no reportó nada (¿chrome sin --load-extension?):"; tail -20 "$WORK/chrome.log"; exit 1; }
cat "$RESULT"
python3 - "$RESULT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
add = data.get("addUrl", {})
bulk = data.get("bulk", {})
ok_add = add.get("devuelta") and add["devuelta"][0] == add["pedida"]
ok_bulk = bulk.get("ok") and all(row["devuelta"] and row["devuelta"][0] == row["pedida"] for row in bulk["seen"])
ok_future = data.get("futuro", {}).get("rechazada") is True
if not (ok_add and ok_bulk and ok_future):
    print("\n[verify] NO pasa: el binario no se comporta como el parche espera.")
    sys.exit(1)
print("\n[verify] OK: addUrl con hora pasada, addUrls en lote y hora futura rechazada.")
PY
