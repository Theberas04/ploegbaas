'use strict';
// Maakt het beeldmateriaal voor de README: schermafbeeldingen, de omslagkaarten
// en een rondleiding als videoframes.
//
//   node scripts/in-beeld.js --modus stills     → docs/screenshots/*.png (1440x900)
//   node scripts/in-beeld.js --modus platen     → omslag + titel- en slotkaart (docs/kaarten.html)
//   node scripts/in-beeld.js --modus video      → tmp-video/frames/*.jpg + frames.txt + meta.json
//
// Daarna de video maken:
//   ffmpeg -y -f concat -safe 0 -i tmp-video/frames.txt -vf 'scale=1280:720,setsar=1,fps=30' \
//     -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p tmp-video/inhoud.mp4
//
// Waarom zo: de screencast van Chrome stuurt alleen een frame als het beeld
// verandert, dus een stilstaand scherm levert niets op. Daarom een eigen lus die
// elke ~95 ms een schermafbeelding maakt, met de echte tijd per frame erbij.
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const HIER = path.resolve(__dirname, '..');
const arg = (naam, standaard) => {
  const i = process.argv.indexOf('--' + naam);
  return i > -1 ? process.argv[i + 1] : standaard;
};
const MODUS = arg('modus', 'stills');
const POORT_APP = Number(arg('poort', '8123'));
const BASIS = `http://127.0.0.1:${POORT_APP}`;
const FRAMES = path.resolve(arg('frames', path.join(HIER, 'tmp-video')));
const PR = path.resolve(arg('profiel', path.join(FRAMES, 'profiel')));
const SCHERMEN = path.join(HIER, 'docs', 'screenshots');
const CHROOM = process.env.CHROOM
  || path.join(process.env.HOME, '.hermes/tools/chromium-1208/chrome-linux64/chrome');
const LIB = [process.env.HOME + '/.local/chromelibs/root/usr/lib/x86_64-linux-gnu',
  process.env.HOME + '/.local/lib'].join(':');

const wacht = (ms) => new Promise((r) => setTimeout(r, ms));
const zeg = (t) => process.stdout.write(t + '\n');   // voortgang: anders zie je bij een hang niets

function wachtwoord() {
  const i = process.argv.indexOf('--wachtwoord');
  if (i > -1) return process.argv[i + 1];
  return fs.readFileSync(path.join(HIER, 'data', 'wachtwoord.txt'), 'utf8').trim();
}

// Chromium kiest zelf een vrije poort; met een vaste poort kan een browser van
// een eerdere sessie in de weg zitten en fotografeer je een andere app.
function startBrowser(breedte, hoogte) {
  fs.rmSync(PR, { recursive: true, force: true });
  fs.mkdirSync(PR, { recursive: true });
  const chrome = spawn(CHROOM, [
    '--headless=new', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
    '--disable-dev-shm-usage', '--remote-debugging-port=0',
    '--user-data-dir=' + PR, `--window-size=${breedte},${hoogte}`,
    '--force-device-scale-factor=1', 'about:blank',
  ], { env: { ...process.env, LD_LIBRARY_PATH: LIB }, stdio: ['ignore', 'ignore', 'pipe'] });
  return chrome;
}

async function start() {
  // De poort staat in DevToolsActivePort in het profiel.
  let poort = 0;
  for (let i = 0; i < 120; i++) {
    try {
      const regel = fs.readFileSync(path.join(PR, 'DevToolsActivePort'), 'utf8').split('\n')[0].trim();
      if (regel) { poort = Number(regel); break; }
    } catch (_) { /* nog niet klaar */ }
    await wacht(100);
  }
  if (!poort) throw new Error('Chromium kwam niet op (geen DevToolsActivePort)');

  let doel = '';
  for (let i = 0; i < 100; i++) {
    try {
      const lijst = await (await fetch(`http://127.0.0.1:${poort}/json/list`)).json();
      const pagina = lijst.find((t) => t.type === 'page');
      if (pagina) { doel = pagina.webSocketDebuggerUrl; break; }
    } catch (_) { /* nog niet klaar */ }
    await wacht(100);
  }
  if (!doel) throw new Error('Geen pagina gevonden via CDP');

  const ws = new WebSocket(doel);
  let id = 0;
  const wachtOp = new Map();
  // JS-fouten in de pagina verzamelen: een leeg of bevroren scherm in de video
  // is bijna altijd een fout in de app, en die zie je anders nergens.
  const fouten = [];
  const verkeer = [];   // laatste API-antwoorden: een onverwachte 401 wijst op sessieverlies
  const stuur = (method, params = {}) => new Promise((resolve, reject) => {
    const n = ++id;
    wachtOp.set(n, { resolve, reject });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.method === 'Runtime.exceptionThrown') {
      const d = m.params?.exceptionDetails;
      fouten.push((d?.exception?.description || d?.text || 'onbekende fout').split('\n')[0]);
      return;
    }
    if (m.method === 'Network.responseReceived' && m.params?.response?.url?.includes('/api/')) {
      verkeer.push(m.params.response.status + ' ' + m.params.response.url.replace(BASIS, ''));
      if (verkeer.length > 40) verkeer.shift();
      return;
    }
    const w = m.id && wachtOp.get(m.id);
    if (!w) return;
    wachtOp.delete(m.id);
    if (m.error) w.reject(new Error(m.error.message)); else w.resolve(m.result);
  });
  await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
  await stuur('Page.enable');
  await stuur('Runtime.enable');
  await stuur('Network.enable');

  const js = async (uitdrukking) => {
    const r = await stuur('Runtime.evaluate', { expression: uitdrukking, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + (r.exceptionDetails.exception?.description || ''));
    return r.result.value;
  };
  const maat = (breedte, hoogte) =>
    stuur('Emulation.setDeviceMetricsOverride', { width: breedte, height: hoogte, deviceScaleFactor: 1, mobile: false });
  const scherm = async (bestand) => {
    const r = await stuur('Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false });
    fs.mkdirSync(path.dirname(bestand), { recursive: true });
    fs.writeFileSync(bestand, Buffer.from(r.data, 'base64'));
    return r.data.length;
  };
  const totVoorwaarde = async (uitdrukking, ms = 12000) => {
    const eind = Date.now() + ms;
    while (Date.now() < eind) {
      if (await js(uitdrukking)) return true;
      await wacht(200);
    }
    return false;
  };
  const naar = async (hash, klaar) => {
    await js(`location.hash = ${JSON.stringify(hash)}`);
    if (klaar) {
      const ok = await totVoorwaarde(klaar);
      if (!ok) {
        const nu = await js(`JSON.stringify({ hash: location.hash, tekst: document.body.innerText.slice(0, 160), titel: document.title })`);
        throw new Error('scherm ' + hash + ' werd niet zichtbaar (' + klaar + '). Nu op de pagina: ' + nu
          + (fouten.length ? '\nJS-fouten: ' + fouten.join(' | ') : '')
          + (verkeer.length ? '\nLaatste API-antwoorden: ' + verkeer.slice(-8).join(' · ') : ''));
      }
    }
    await wacht(900);
  };

  return { ws, stuur, js, maat, scherm, naar, totVoorwaarde, wacht: wacht, fouten, verkeer, chrome: null };
}

async function inloggen(c) {
  await c.stuur('Page.navigate', { url: BASIS + '/' });
  await wacht(1600);
  const titel = await c.js('document.title');
  if (titel !== 'Ploegbaas') throw new Error('Dit is niet Ploegbaas maar "' + titel + '"');
  // De app leest de waarde bij het verzenden van het formulier; via de native
  // setter plus een input-event komt hij ook in de staat van de pagina terecht.
  const ingevuld = await c.js(`(() => {
    const el = document.querySelector('#w');
    if (!el) return false;
    const zet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    zet.call(el, ${JSON.stringify(wachtwoord())});
    el.dispatchEvent(new Event('input', { bubbles: true }));
    return el.value.length > 0;
  })()`);
  if (!ingevuld) throw new Error('Geen wachtwoordveld gevonden');
  await c.js(`document.querySelector('.inlog .knop').click()`);
  const binnen = await c.totVoorwaarde(`Boolean(document.querySelector('nav a[href="#/dashboard"]'))`);
  if (!binnen) throw new Error('Inloggen lukte niet');
  await wacht(1500);
}

// ── de schermen die op de foto gaan ──────────────────────────────────────────
const SCHERMEN_LIJST = [
  ['dashboard', '#/dashboard', `document.querySelectorAll('.kaart').length >= 4`],
  ['taken', '#/taken', `document.querySelectorAll('#takenlijst tbody tr').length > 1`],
  ['taak', '#/taken/4', `document.querySelectorAll('.bericht').length > 0`],
  ['agenten', '#/agenten', `document.querySelectorAll('tbody tr').length >= 2`],
  ['runs', '#/runs', `document.querySelectorAll('tbody tr').length > 1`],
  ['routines', '#/routines', `document.querySelectorAll('tbody tr').length >= 1`],
  ['meldingen', '#/meldingen', `Boolean(document.querySelector('#m-kanaal'))`],
  ['logboek', '#/activiteit', `document.querySelectorAll('tbody tr').length > 2`],
  ['nakijken', '#/goedkeuringen', `document.querySelectorAll('tbody tr').length >= 1`],
];

async function modusStills() {
  const chrome = startBrowser(1440, 900);
  try {
    const c = await start();
    c.chrome = chrome;
    await c.maat(1440, 900);
    await inloggen(c);
    // Inlogscherm eerst: daarvoor uitloggen en opnieuw fotograferen.
    await c.naar('#/dashboard', SCHERMEN_LIJST[0][2]);
    const uit = [];
    for (const [naam, hash, klaar] of SCHERMEN_LIJST) {
      await c.naar(hash, klaar);
      const overloop = await c.js('document.documentElement.scrollWidth <= window.innerWidth');
      const bytes = await c.scherm(path.join(SCHERMEN, naam + '.png'));
      uit.push({ naam, hash, bytes, geenOverloop: overloop });
    }
    // Het inlogscherm: uitloggen via de knop in de zijbalk.
    await c.js(`uitloggen()`);
    await c.totVoorwaarde(`Boolean(document.querySelector('#w'))`);
    await wacht(900);
    uit.unshift({ naam: 'inloggen', hash: '(uitgelogd)', bytes: await c.scherm(path.join(SCHERMEN, 'inloggen.png')), geenOverloop: true });
    console.log(JSON.stringify(uit, null, 2));
  } finally { chrome.kill('SIGKILL'); }
}

async function modusPlaten() {
  const chrome = startBrowser(1280, 720);
  try {
    const c = await start();
    const kaarten = [
      ['omslag', 1200, 630, 'omslag.png'],
      ['titel', 1280, 720, 'kaart-titel.png'],
      ['slot', 1280, 720, 'kaart-slot.png'],
    ];
    const uit = [];
    for (const [soort, b, h, bestand] of kaarten) {
      await c.maat(b, h);
      await c.stuur('Page.navigate', { url: `file://${path.join(HIER, 'docs', 'kaarten.html')}?soort=${soort}` });
      await c.totVoorwaarde(`document.body.dataset.klaar === '1'`);
      await c.js('document.fonts.ready');
      await wacht(600);
      uit.push({ soort, bytes: await c.scherm(path.join(SCHERMEN, bestand)) });
    }
    console.log(JSON.stringify(uit, null, 2));
  } finally { chrome.kill('SIGKILL'); }
}

async function modusVideo() {
  // Alleen de frames en het profiel opruimen — niet de hele map: daarin staat
  // ook de ingesproken tekst (tmp-video/stem), en die wil je niet elke opname
  // opnieuw hoeven inspreken.
  fs.rmSync(path.join(FRAMES, 'frames'), { recursive: true, force: true });
  fs.mkdirSync(path.join(FRAMES, 'frames'), { recursive: true });
  zeg('video: browser starten…');
  const chrome = startBrowser(1440, 900);
  try {
    const c = await start();
    zeg('video: verbonden met de pagina');
    // Geen Emulation.setDeviceMetricsOverride tijdens de opname: het venster is
    // al 1440 breed via --window-size, en de override is hier overbodig. Let op:
    // de állereerste captureScreenshot na een navigatie blijft soms hangen (het
    // antwoord komt nooit); de lus heeft daarom een tijdslimiet en slaat die
    // eerste poging over — daarna loopt het door.
    const maat = await c.js('JSON.stringify({ w: window.innerWidth, h: window.innerHeight })');
    zeg('video: venster ' + maat);
    // De opnamelus start na de eerste navigatie: anders fotografeert hij het
    // lege startscherm en begint de video met een wit beeld.
    await c.stuur('Page.navigate', { url: BASIS + '/' });
    await wacht(1200);

    const frames = [];
    let laatste = Date.now();
    let stoppen = false;
    let framesGeschreven = 0;
    const lus = (async () => {
      while (!stoppen) {
        try {
          // Met een tijdslimiet: als het antwoord uitblijft, wil je dat weten in
          // plaats van eindeloos te wachten op een schermafbeelding.
          const r = await Promise.race([
            c.stuur('Page.captureScreenshot', { format: 'jpeg', quality: 82, fromSurface: true }),
            wacht(6000).then(() => { throw new Error('geen antwoord op captureScreenshot binnen 6s'); }),
          ]);
          const nu = Date.now();
          const bestand = path.join(FRAMES, 'frames', `f${String(frames.length).padStart(5, '0')}.jpg`);
          fs.mkdirSync(path.dirname(bestand), { recursive: true });
          fs.writeFileSync(bestand, Buffer.from(r.data, 'base64'));
          frames.push({ bestand, van: laatste, tot: nu });
          laatste = nu;
          framesGeschreven++;
          if (framesGeschreven === 1) zeg('video: eerste frame binnen');
        } catch (fout) {
          // Eén gemiste frame is geen ramp, maar als er níets binnenkomt moet je
          // weten waarom — een stille catch kost anders een half uur zoeken.
          if (!frames.length) zeg('video: schermafbeelding mislukt: ' + fout.message);
        }
        await wacht(95);
      }
    })();

    const t0 = Date.now();
    const merken = {};
    const merk = (naam) => { merken[naam] = Date.now() - t0; };

    // Pas inloggen als er echt een frame binnen is: de allereerste
    // schermafbeelding blijft soms seconden hangen, en loggen we meteen in, dan
    // zit het inlogscherm niet in de opname en praat de eerste zin over het
    // dashboard.
    const wachtSinds = Date.now();
    while (!frames.length && Date.now() - wachtSinds < 20000) await wacht(200);
    zeg(`video: eerste frame na ${((Date.now() - wachtSinds) / 1000).toFixed(1)}s — nu inloggen`);

    await inloggen(c);
    merk('inloggen');
    zeg('video: ingelogd');
    await wacht(1400);

    // Rustig door de schermen, met beweging (scrollen) erbij: een stilstaand
    // scherm levert bijna geen frames op.
    const scrol = async (van, naar2, ms = 900) => c.js(`(async () => {
      const stappen = 24, dt = ${ms} / stappen;
      for (let i = 1; i <= stappen; i++) { window.scrollTo(0, ${van} + (${naar2} - ${van}) * i / stappen); await new Promise(r => setTimeout(r, dt)); }
      return true;
    })()`);

    await c.naar('#/dashboard', `document.querySelectorAll('.kaart').length >= 4`);
    merk('dashboard');
    await wacht(1500);
    await scrol(0, 420); await wacht(1200); await scrol(420, 0); await wacht(800);

    await c.naar('#/taken', `document.querySelectorAll('#takenlijst tbody tr').length > 1`);
    merk('taken');
    await wacht(2300);

    await c.naar('#/taken/4', `document.querySelectorAll('.bericht').length > 0`);
    merk('taak');
    await scrol(0, 560); await wacht(1600); await scrol(560, 0); await wacht(900);

    await c.naar('#/agenten', `document.querySelectorAll('tbody tr').length >= 2`);
    merk('agenten');
    await wacht(2300);

    await c.naar('#/runs', `document.querySelectorAll('tbody tr').length > 1`);
    merk('runs');
    await wacht(1200);
    // Binnen de inhoud zoeken, niet in de hele pagina: de zijbalk heeft ook
    // `.knop.los.klein` (Uitloggen) en die staat in de DOM vóór de inhoud.
    await c.js(`document.querySelector('main .knop.los.klein')?.click()`);
    await c.wacht(1600);
    await wacht(1800);

    await c.naar('#/routines', `document.querySelectorAll('tbody tr').length >= 1`);
    merk('routines');
    await wacht(2200);

    await c.naar('#/meldingen', `Boolean(document.querySelector('#m-kanaal'))`);
    merk('meldingen');
    await wacht(2400);

    await c.naar('#/activiteit', `document.querySelectorAll('tbody tr').length > 2`);
    merk('logboek');
    await scrol(0, 300); await wacht(1500);
    await wacht(1200);

    stoppen = true;
    await lus;
    try { c.ws.close(); } catch (_) {}
    chrome.kill('SIGKILL');

    frames[frames.length - 1].tot = Date.now();
    const regels = frames.map((f) => `file '${f.bestand.replace(/'/g, "'\\''")}'\nduration ${Math.max(0.02, (f.tot - f.van) / 1000).toFixed(3)}`);
    const lijst = path.join(FRAMES, 'frames.txt');
    fs.writeFileSync(lijst, regels.join('\n') + `\nfile '${frames[frames.length - 1].bestand}'\n`);
    const duur = frames.reduce((s, f) => s + (f.tot - f.van), 0) / 1000;
    fs.writeFileSync(path.join(FRAMES, 'meta.json'), JSON.stringify({ frames: frames.length, seconden: +duur.toFixed(2), merken, lijst }, null, 2));
    console.log(`klaar: ${frames.length} frames, ${duur.toFixed(1)}s → ${lijst}`);
    console.log('merken (ms):', JSON.stringify(merken));
  } catch (e) {
    chrome.kill('SIGKILL');
    throw e;
  }
}

(async () => {
  if (MODUS === 'stills') await modusStills();
  else if (MODUS === 'platen') await modusPlaten();
  else if (MODUS === 'video') await modusVideo();
  else throw new Error('Onbekende modus: ' + MODUS);
  process.exit(0);
})().catch((e) => { console.error('fout:', e.message); process.exit(1); });
