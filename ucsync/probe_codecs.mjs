// Sonda de codecs de un binario Chromium por CDP (canPlayType). Sin argumentos usa el
// binario compilado; acepta BIN PUERTO PERFIL:
//   node ucsync/probe_codecs.mjs src/out/Default/chrome 9345 /tmp/probe-codecs
// Esperado en un build con proprietary_codecs: avc1 y mp4a = "probably".
import { spawn } from 'node:child_process';

const BIN = process.argv[2];
const PORT = process.argv[3] || '9333';
const PERFIL = process.argv[4] || `/tmp/probe-${PORT}`;
const BASE = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const child = spawn(BIN, [
  '--headless=new', '--no-sandbox', '--no-first-run', '--disable-gpu',
  `--user-data-dir=${PERFIL}`, `--remote-debugging-port=${PORT}`, 'about:blank',
], { stdio: 'ignore' });

let ws = null;
async function targets() { return (await fetch(`${BASE}/json`)).json(); }
function connect(wsUrl) {
  const w = new WebSocket(wsUrl);
  const pending = new Map();
  let seq = 0;
  w.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
    }
  });
  return {
    w,
    send: (method, params) => new Promise((res, rej) => {
      const id = ++seq; pending.set(id, { resolve: res, reject: rej });
      w.send(JSON.stringify({ id, method, params }));
    }),
  };
}

try {
  let page = null;
  for (let i = 0; i < 20; i++) {
    const list = await targets().catch(() => []);
    page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    if (page) break;
    await sleep(1000);
  }
  if (!page) throw new Error('no hay target de página');
  ws = connect(page.webSocketDebuggerUrl);
  await ws.w;
  await sleep(500);
  const expr = `(() => {
    const v = document.createElement('video');
    const probes = {
      'H.264 (avc1)': v.canPlayType('video/mp4; codecs="avc1.42E01E"'),
      'H.264 alto nivel': v.canPlayType('video/mp4; codecs="avc1.640033"'),
      'AAC (mp4a.40.2)': v.canPlayType('video/mp4; codecs="mp4a.40.2"'),
      'MP4 sin codecs': v.canPlayType('video/mp4'),
      'VP8 webm': v.canPlayType('video/webm; codecs="vp8,vorbis"'),
      'VP9 webm': v.canPlayType('video/webm; codecs="vp9"'),
      'AV1 mp4': v.canPlayType('video/mp4; codecs="av01.0.1M.08"'),
      'HLS (m3u8)': v.canPlayType('application/vnd.apple.mpegurl'),
      'MediaSource MSE': (typeof MediaSource !== 'undefined') ? 'existe' : 'no',
    };
    return JSON.stringify(probes, null, 1);
  })()`;
  const r = await ws.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  console.log(`### ${BIN}`);
  console.log(r.result.value);
} finally {
  child.kill('SIGKILL');
  if (ws) ws.w.close();
}
