// Comprueba reproducción REAL de un MP4 H.264+AAC por CDP (headless): monta un <video>
// autoplay y mira error/readyState/currentTime. BIN PUERTO PERFIL [URL]:
//   node ucsync/probe_playback.mjs src/out/Default/chrome 9352 /tmp/play-new
// Sin codecs propietarios da error.code=4 (MEDIA_ERR_UNSUPPORTED) y currentTime 0.
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const BIN = process.argv[2];
const PORT = process.argv[3] || '9351';
const PERFIL = process.argv[4] || `/tmp/play-${PORT}`;
const URL_VIDEO = process.argv[5] || 'https://download.samplelib.com/mp4/sample-5s.mp4';
const BASE = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

writeFileSync('/tmp/play.html', `<!doctype html><meta charset=utf-8>
<video id=v src="${URL_VIDEO}" autoplay muted playsinline></video>
<pre id=s></pre>`);

const child = spawn(BIN, ['--headless=new', '--no-sandbox', '--no-first-run', '--disable-gpu',
  `--user-data-dir=${PERFIL}`, `--remote-debugging-port=${PORT}`, 'about:blank'], { stdio: 'ignore' });

let ws = null;
async function targets() { return (await fetch(`${BASE}/json`)).json(); }
function connect(wsUrl) {
  const w = new WebSocket(wsUrl); const pending = new Map(); let seq = 0;
  w.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); }
  });
  return { w, send: (method, params) => new Promise((res, rej) => {
    const id = ++seq; pending.set(id, { resolve: res, reject: rej });
    w.send(JSON.stringify({ id, method, params })); }) };
}
try {
  let page = null;
  for (let i = 0; i < 20; i++) { const l = await targets().catch(() => []);
    page = l.find((t) => t.type === 'page' && t.webSocketDebuggerUrl); if (page) break; await sleep(1000); }
  if (!page) throw new Error('no hay página');
  ws = connect(page.webSocketDebuggerUrl); await ws.w; await sleep(400);
  await ws.send('Page.navigate', { url: 'file:///tmp/play.html' });
  await sleep(6000);
  const r = await ws.send('Runtime.evaluate', {
    expression: `(() => { const v = document.getElementById('v');
      return JSON.stringify({ error: v.error ? {code: v.error.code, name: v.error.name} : null,
        readyState: v.readyState, currentTime: v.currentTime, duration: v.duration,
        paused: v.paused, networkState: v.networkState,
        puede: v.canPlayType('video/mp4; codecs="avc1.42E01E,mp4a.40.2"') }, null, 1) })()`,
    returnByValue: true });
  console.log(`### ${BIN}\n${r.result.value}`);
  const r2 = await ws.send('Runtime.evaluate', {
    expression: `(() => { const v = document.getElementById('v');
      return JSON.stringify({ despues_de_3s: {currentTime: v.currentTime, readyState: v.readyState,
        error: v.error ? v.error.code : null} }) })()`, returnByValue: true });
  await sleep(3000);
  const r3 = await ws.send('Runtime.evaluate', {
    expression: `(() => { const v = document.getElementById('v');
      return JSON.stringify({ despues_de_mas: {currentTime: v.currentTime, readyState: v.readyState,
        error: v.error ? v.error.code : null, avance: v.currentTime > 0.5} }) })()`, returnByValue: true });
  console.log(r2.result.value, '\n', r3.result.value);
} finally { child.kill('SIGKILL'); if (ws) ws.w.close(); }
