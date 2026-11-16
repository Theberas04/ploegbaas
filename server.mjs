// Ploegbaas — eigen dashboard om een ploeg AI-agenten aan het werk te zetten.
//
// Eigen werk, geen overgenomen code: alles is geschreven op de onderdelen die
// Node zelf meebrengt (node:http, node:sqlite, node:child_process). Geen npm.
//
//   node --no-warnings server.mjs            # starten (poort uit PLOEGBAAS_POORT, standaard 8123)
//   node --no-warnings server.mjs controleer # controleert de opzet en de API
//
// De opzet in het kort:
//   * een agent heeft een adapter: "hermes" (Hermes Agent op deze machine),
//     "opdracht" (een eigen shell-commando) of "http" (een eigen endpoint).
//   * de hartslaglus kijkt elke 15 seconden of er een agent is met toegewezen
//     werk, start daarvoor een run en zet de uitkomst terug in de taak.
//   * een geslaagde run gaat naar "nakijken": een mens keurt goed of stuurt terug.

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HIER = path.dirname(fileURLToPath(import.meta.url));
const PUBLIEK = path.join(HIER, 'public');
const DATA = process.env.PLOEGBAAS_DATA || path.join(HIER, 'data');
const POORT = Number(process.env.PLOEGBAAS_POORT || 8123);
const RUNS = path.join(DATA, 'runs');
const TZ = process.env.TZ || 'Europe/Amsterdam';

fs.mkdirSync(DATA, { recursive: true });
fs.mkdirSync(RUNS, { recursive: true });

// --- beveiliging: één wachtwoord, ondertekende sessiecookie -------------------
const WACHTWOORD_BESTAND = path.join(DATA, 'wachtwoord.txt');
const GEHEIM_BESTAND = path.join(DATA, 'geheim.txt');

function zorgVoorBestand(pad, maker) {
  if (!fs.existsSync(pad)) {
    const waarde = maker();
    fs.writeFileSync(pad, waarde + '\n', { mode: 0o600 });
    return waarde;
  }
  return fs.readFileSync(pad, 'utf8').trim();
}
const WACHTWOORD = process.env.PLOEGBAAS_WACHTWOORD
  || zorgVoorBestand(WACHTWOORD_BESTAND, () => crypto.randomBytes(9).toString('base64url'));
const GEHEIM = zorgVoorBestand(GEHEIM_BESTAND, () => crypto.randomBytes(32).toString('hex'));
const COOKIE = 'ploegbaas-sessie';
const SESSIE_UREN = 12;

const sha = (s) => crypto.createHash('sha256').update(String(s)).digest();
const teken = (data) => crypto.createHmac('sha256', GEHEIM).update(data).digest('base64url');

function maakSessie() {
  const lijf = Buffer.from(JSON.stringify({ tot: Date.now() + SESSIE_UREN * 3600_000 })).toString('base64url');
  return lijf + '.' + teken(lijf);
}
function leesSessie(cookieHeader) {
  const ruw = (cookieHeader || '').split(';').map((d) => d.trim()).find((d) => d.startsWith(COOKIE + '='));
  if (!ruw) return false;
  const waarde = decodeURIComponent(ruw.slice(COOKIE.length + 1));
  const [lijf, handtekening] = waarde.split('.');
  if (!lijf || !handtekening) return false;
  const verwacht = teken(lijf);
  if (verwacht.length !== handtekening.length) return false;
  if (!crypto.timingSafeEqual(Buffer.from(verwacht), Buffer.from(handtekening))) return false;
  try {
    const { tot } = JSON.parse(Buffer.from(lijf, 'base64url').toString('utf8'));
    return Date.now() < tot;
  } catch { return false; }
}

// --- database ----------------------------------------------------------------
const db = new DatabaseSync(path.join(DATA, 'ploegbaas.db'));
db.exec('PRAGMA journal_mode = WAL');
db.exec('PRAGMA foreign_keys = ON');
db.exec(`
CREATE TABLE IF NOT EXISTS bedrijf (
  id INTEGER PRIMARY KEY, naam TEXT NOT NULL, doel TEXT DEFAULT '', aangemaakt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS agent (
  id INTEGER PRIMARY KEY, bedrijf_id INTEGER NOT NULL REFERENCES bedrijf(id) ON DELETE CASCADE,
  naam TEXT NOT NULL, rol TEXT DEFAULT 'algemeen', titel TEXT DEFAULT '', adapter TEXT NOT NULL,
  adapter_config TEXT DEFAULT '{}', model TEXT DEFAULT '', status TEXT DEFAULT 'actief',
  budget_maand_centen INTEGER DEFAULT 0, heartbeat_aan INTEGER DEFAULT 0, heartbeat_minuten INTEGER DEFAULT 30,
  laatste_run TEXT, aangemaakt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS taak (
  id INTEGER PRIMARY KEY, bedrijf_id INTEGER NOT NULL REFERENCES bedrijf(id) ON DELETE CASCADE,
  titel TEXT NOT NULL, omschrijving TEXT DEFAULT '', status TEXT DEFAULT 'nieuw', prioriteit TEXT DEFAULT 'normaal',
  agent_id INTEGER REFERENCES agent(id) ON DELETE SET NULL, labels TEXT DEFAULT '', ouder_id INTEGER,
  aangemaakt TEXT NOT NULL, bijgewerkt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS bericht (
  id INTEGER PRIMARY KEY, taak_id INTEGER NOT NULL REFERENCES taak(id) ON DELETE CASCADE,
  van_soort TEXT NOT NULL, van_naam TEXT DEFAULT '', tekst TEXT NOT NULL, tijd TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS run (
  id INTEGER PRIMARY KEY, taak_id INTEGER REFERENCES taak(id) ON DELETE SET NULL,
  agent_id INTEGER REFERENCES agent(id) ON DELETE CASCADE, status TEXT DEFAULT 'lopend',
  gestart TEXT NOT NULL, beeindigd TEXT, exit_code INTEGER, kosten_centen INTEGER DEFAULT 0,
  logpad TEXT DEFAULT '', uitkomst TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS goedkeuring (
  id INTEGER PRIMARY KEY, taak_id INTEGER NOT NULL REFERENCES taak(id) ON DELETE CASCADE,
  agent_id INTEGER, gevraagd TEXT NOT NULL, status TEXT DEFAULT 'open',
  besluit_door TEXT DEFAULT '', besluit_tijd TEXT, opmerking TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS activiteit (
  id INTEGER PRIMARY KEY, soort TEXT NOT NULL, tekst TEXT NOT NULL,
  agent_id INTEGER, taak_id INTEGER, tijd TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS routine (
  id INTEGER PRIMARY KEY, bedrijf_id INTEGER NOT NULL REFERENCES bedrijf(id) ON DELETE CASCADE,
  naam TEXT NOT NULL, agent_id INTEGER REFERENCES agent(id) ON DELETE SET NULL,
  interval_minuten INTEGER DEFAULT 60, actief INTEGER DEFAULT 1, laatste_start TEXT,
  taak_titel TEXT NOT NULL, taak_omschrijving TEXT DEFAULT ''
);
`);

const nu = () => new Date().toISOString();
const rij = () => db.prepare('SELECT last_insert_rowid() AS id').get().id;

function logActiviteit(soort, tekst, { agentId = null, taakId = null } = {}) {
  db.prepare('INSERT INTO activiteit (soort, tekst, agent_id, taak_id, tijd) VALUES (?,?,?,?,?)')
    .run(soort, tekst, agentId, taakId, nu());
  zend({ soort: 'activiteit', tekst: `${tekst}` });
}

// --- live kanaal (server-sent events) ---------------------------------------
const kijkers = new Set();
function zend(bericht) {
  const regel = `data: ${JSON.stringify(bericht)}\n\n`;
  for (const antwoord of kijkers) {
    try { antwoord.write(regel); } catch { kijkers.delete(antwoord); }
  }
}

// --- zaad: alleen bij een lege database -------------------------------------
function zaai() {
  const aantal = db.prepare('SELECT COUNT(*) AS n FROM bedrijf').get().n;
  if (aantal > 0) return;
  const tijd = nu();
  db.prepare('INSERT INTO bedrijf (naam, doel, aangemaakt) VALUES (?,?,?)')
    .run('Werdens Media', 'Nederlandstalige apps en media voor eigen gebruik, netjes afgeleverd.', tijd);
  const bedrijf = rij();
  db.prepare(`INSERT INTO agent (bedrijf_id, naam, rol, titel, adapter, adapter_config, status,
              heartbeat_aan, heartbeat_minuten, aangemaakt)
              VALUES (?,?,?,?,?,?,?,?,?,?)`)
    .run(bedrijf, 'Hermes', 'algemeen', 'AI-agent op deze machine', 'hermes',
      JSON.stringify({ commando: 'hermes', args: ['chat', '-q'], timeout_seconden: 1800 }),
      'actief', 1, 30, tijd);
  const agent = rij();
  db.prepare(`INSERT INTO agent (bedrijf_id, naam, rol, titel, adapter, adapter_config, status,
              heartbeat_aan, heartbeat_minuten, aangemaakt)
              VALUES (?,?,?,?,?,?,?,?,?,?)`)
    .run(bedrijf, 'Wachtpost', 'onderzoek', 'Controleert de apps', 'opdracht',
      JSON.stringify({ commando: 'bash', args: ['-c', 'echo "controle: alles draait"'], timeout_seconden: 120 }),
      'actief', 0, 60, tijd);
  const wachtpost = rij();
  db.prepare(`INSERT INTO taak (bedrijf_id, titel, omschrijving, status, prioriteit, agent_id, labels, aangemaakt, bijgewerkt)
              VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(bedrijf, 'Kennismaking: laat zien dat je werkt',
      'Schrijf het bestand /tmp/ploegbaas-proef.txt met daarin één regel: Ploegbaas werkt.\nAntwoord daarna met een korte samenvatting.',
      'nieuw', 'hoog', agent, 'kennismaking', tijd, tijd);
  db.prepare(`INSERT INTO taak (bedrijf_id, titel, omschrijving, status, prioriteit, agent_id, labels, aangemaakt, bijgewerkt)
              VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(bedrijf, 'Controleer of alle apps nog antwoorden',
      'Loop de draaiende diensten na en meld welke niet antwoorden.', 'review', 'normaal', wachtpost, 'controle', tijd, tijd);
  const controlTaak = rij();
  db.prepare('INSERT INTO goedkeuring (taak_id, agent_id, gevraagd, status) VALUES (?,?,?,?)')
    .run(controlTaak, wachtpost, tijd, 'open');
  db.prepare(`INSERT INTO bericht (taak_id, van_soort, van_naam, tekst, tijd) VALUES (?,?,?,?,?)`)
    .run(controlTaak, 'agent', 'Wachtpost', 'Alle vier de diensten antwoorden; geen bijzonderheden.', tijd);
  db.prepare(`INSERT INTO routine (bedrijf_id, naam, agent_id, interval_minuten, actief, taak_titel, taak_omschrijving)
              VALUES (?,?,?,?,?,?,?)`)
    .run(bedrijf, 'Dagelijkse controle', wachtpost, 1440, 1, 'Dagelijkse controle van de apps',
      'Controleer de apps en meld afwijkingen.');
  logActiviteit('opzet', 'Ploegbaas is ingericht met bedrijf Werdens Media en twee agenten.');
}

// --- adapters: eigen proces, eigen opdracht of eigen endpoint ---------------
function taakOpdracht(agent, bedrijf, taak) {
  const regels = [
    `Je bent ${agent.naam}, ${agent.titel || agent.rol} bij ${bedrijf.naam}.`,
    bedrijf.doel ? `Doel van het bedrijf: ${bedrijf.doel}` : '',
    '', `Taak ${taak.id}: ${taak.titel}`, taak.omschrijving || '(geen omschrijving)',
    '', 'Werk deze taak uit met de middelen die je hebt.',
    'Sluit af met een korte samenvatting: wat je hebt gedaan, wat het resultaat is en wat er nog open staat.',
  ];
  return regels.filter((r) => r !== '').join('\n');
}

function startRun(agent, taak) {
  const bedrijf = db.prepare('SELECT * FROM bedrijf WHERE id = ?').get(agent.bedrijf_id);
  const tijd = nu();
  db.prepare('INSERT INTO run (taak_id, agent_id, status, gestart) VALUES (?,?,?,?)')
    .run(taak.id, agent.id, 'lopend', tijd);
  const runId = rij();
  const logpad = path.join(RUNS, `${runId}.log`);
  db.prepare('UPDATE run SET logpad = ? WHERE id = ?').run(logpad, runId);
  db.prepare("UPDATE taak SET status = 'bezig', bijgewerkt = ? WHERE id = ?").run(tijd, taak.id);
  logActiviteit('run', `${agent.naam} begint aan taak ${taak.id}: ${taak.titel}`, { agentId: agent.id, taakId: taak.id });
  zend({ soort: 'run', runId, status: 'lopend', agent: agent.naam, taak: taak.id });

  const log = fs.createWriteStream(logpad, { flags: 'a' });
  let afgerond = false;
  const klaar = (status, exitCode, uitkomst = '') => {
    if (afgerond) return;
    afgerond = true;
    const eind = nu();
    const schoon = schoonUitvoer(uitkomst);
    db.prepare('UPDATE run SET status = ?, beeindigd = ?, exit_code = ?, uitkomst = ? WHERE id = ?')
      .run(status, eind, exitCode, schoon.slice(0, 4000), runId);
    db.prepare('UPDATE agent SET laatste_run = ? WHERE id = ?').run(eind, agent.id);
    const samenvatting = schoon || '(geen uitvoer)';
    if (status === 'geslaagd') {
      db.prepare("UPDATE taak SET status = 'review', bijgewerkt = ? WHERE id = ?").run(eind, taak.id);
      db.prepare('INSERT INTO bericht (taak_id, van_soort, van_naam, tekst, tijd) VALUES (?,?,?,?,?)')
        .run(taak.id, 'agent', agent.naam, samenvatting, eind);
      db.prepare('INSERT INTO goedkeuring (taak_id, agent_id, gevraagd, status) VALUES (?,?,?,?)')
        .run(taak.id, agent.id, eind, 'open');
      logActiviteit('run', `${agent.naam} is klaar met taak ${taak.id}; wacht op nakijken.`, { agentId: agent.id, taakId: taak.id });
      zend({ soort: 'taak', taakId: taak.id, status: 'review' });
    } else {
      db.prepare("UPDATE taak SET status = 'geblokkeerd', bijgewerkt = ? WHERE id = ?").run(eind, taak.id);
      db.prepare('INSERT INTO bericht (taak_id, van_soort, van_naam, tekst, tijd) VALUES (?,?,?,?,?)')
        .run(taak.id, 'systeem', 'Ploegbaas', `Run ${status} (code ${exitCode}).\n\n${samenvatting}`, eind);
      logActiviteit('run', `${agent.naam} liep vast op taak ${taak.id} (${status}).`, { agentId: agent.id, taakId: taak.id });
      zend({ soort: 'taak', taakId: taak.id, status: 'geblokkeerd' });
    }
    zend({ soort: 'run', runId, status, agent: agent.naam, taak: taak.id });
    log.end();
    lopendeRuns.delete(runId);
  };

  const config = JSON.parse(agent.adapter_config || '{}');
  const timeout = (config.timeout_seconden || 900) * 1000;
  const omgeving = {
    ...process.env, ...(config.omgeving || {}), TZ,
    PLOEGBAAS_TAAK_ID: String(taak.id), PLOEGBAAS_TAAK_TITEL: taak.titel,
    PLOEGBAAS_TAAK_OMSCHRIJVING: taak.omschrijving || '', PLOEGBAAS_AGENT: agent.naam,
    PLOEGBAAS_BEDRIJF: bedrijf.naam,
  };
  let uitvoer = '';
  const bewaar = (stuk) => {
    const tekst = stuk.toString();
    uitvoer += tekst;
    if (uitvoer.length > 200_000) uitvoer = uitvoer.slice(-100_000);
    log.write(tekst);
    zend({ soort: 'log', runId, stuk: tekst.slice(-2000) });
  };

  try {
    if (agent.adapter === 'http') {
      const kop = new AbortController();
      const stopTimer = setTimeout(() => kop.abort(), timeout);
      lopendeRuns.set(runId, { stop: () => kop.abort() });
      fetch(config.url, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ taak, agent: { naam: agent.naam, rol: agent.rol }, bedrijf, opdracht: taakOpdracht(agent, bedrijf, taak) }),
        signal: kop.signal,
      }).then(async (antwoord) => {
        const tekst = await antwoord.text();
        bewaar(tekst);
        clearTimeout(stopTimer);
        klaar(antwoord.ok ? 'geslaagd' : 'mislukt', antwoord.status, tekst);
      }).catch((fout) => { clearTimeout(stopTimer); bewaar(String(fout)); klaar('mislukt', -1, String(fout)); });
      return runId;
    }

    const args = Array.isArray(config.args) ? [...config.args] : [];
    if (agent.adapter === 'hermes') {
      if (agent.model) args.push('-m', agent.model);
      if (!args.includes('-q') && !args.includes('--query')) args.push('-q', taakOpdracht(agent, bedrijf, taak));
      else args.push(taakOpdracht(agent, bedrijf, taak));
    } else {
      args.push(taakOpdracht(agent, bedrijf, taak));
    }
    const kind = spawn(config.commando || 'bash', args, { env: omgeving, cwd: config.map || HIER });
    lopendeRuns.set(runId, { stop: () => kind.kill('SIGTERM') });
    const timer = setTimeout(() => {
      bewaar(`\n[ploegbaas] tijdslimiet van ${config.timeout_seconden || 900} seconden bereikt; ik stop de run.\n`);
      kind.kill('SIGTERM');
    }, timeout);
    kind.stdout.on('data', bewaar);
    kind.stderr.on('data', bewaar);
    kind.on('error', (fout) => { clearTimeout(timer); bewaar(String(fout)); klaar('mislukt', -1, String(fout)); });
    kind.on('close', (code, signaal) => {
      clearTimeout(timer);
      if (signaal === 'SIGTERM' && code === null) return klaar('gestopt', 143, uitvoer);
      klaar(code === 0 ? 'geslaagd' : 'mislukt', code ?? -1, uitvoer);
    });
  } catch (fout) {
    bewaar(String(fout));
    klaar('mislukt', -1, String(fout));
  }
  return runId;
}

const lopendeRuns = new Map();

// De Hermes-CLI zet zijn eigen banner, de echo van de opdracht en een
// hervat-blok in de uitvoer. Die regels zijn voor de lezer van de taak ruis:
// haal ze eruit voordat het bericht in de taak belandt.
const RUIS = [
  /^\s*⚠/, /manual restart still pending/i, /Ask its owner to relaunch/i,
  /^Query:\s/, /^Resume this session with:/, /^hermes (--resume|-c)\b/,
  /^Session:\s/, /^Title:\s/, /^Duration:\s/, /^Messages:\s/,
  /^[─-╿]+\s*$/, /^[☤✦]/, /^\[\d{2}:\d{2}:\d{2}\]\s*(INFO|DEBUG)/,
  /^∴/, /^📖/, /^⚙/, /^🧠/, /^✔/, /^⏳/, /^🛠/, /^🔎/, /^✗/, /^✔️/,
];
export function schoonUitvoer(tekst) {
  let regels = String(tekst || '').replace(/\r\n?/g, '\n').split('\n');
  // De CLI echoot de hele opdracht na "Query:". Die echo is soms tientallen
  // regels lang en zegt de lezer van de taak niets: knip hem weg tot het eerste
  // scheidingsblok of de naamregel.
  const echo = regels.findIndex((r) => /^Query:\s/.test(r));
  if (echo >= 0) {
    let eind = regels.findIndex((r, i) => i > echo && (/^[─-╿]{3,}/.test(r) || /^[☤✦]/.test(r)));
    if (eind < 0) eind = Math.min(echo + 60, regels.length);
    regels = [...regels.slice(0, echo), ...regels.slice(eind)];
  }
  regels = regels
    // Op de ingekorte regel toetsen: de CLI zet zijn hervat-blok met spaties
    // ervoor, en dan mist een patroon dat op het regelsein begint.
    .filter((r) => !RUIS.some((p) => p.test(r.trim())))
    .filter((r) => !/^[✗✘✖]\s*\$|\$ ls -la \+/.test(r));
  let uit = regels.join('\n');
  uit = uit.replace(/\n{3,}/g, '\n\n').trim();
  // Het antwoord staat onderaan; de aanloop erboven is meestal omgevingsruis.
  return uit.length > 3000 ? uit.slice(-3000) : uit;
}

// --- hartslag: routines, wakker maken, budgetten ----------------------------
function hartslag() {
  const tijd = nu();
  // 1. routines die weer mogen
  for (const r of db.prepare('SELECT * FROM routine WHERE actief = 1').all()) {
    const laatste = r.laatste_start ? Date.parse(r.laatste_start) : 0;
    if (Date.now() - laatste < r.interval_minuten * 60_000) continue;
    const bestaat = db.prepare("SELECT id FROM taak WHERE bedrijf_id = ? AND titel = ? AND status IN ('nieuw','bezig')")
      .get(r.bedrijf_id, r.taak_titel);
    if (!bestaat) {
      db.prepare(`INSERT INTO taak (bedrijf_id, titel, omschrijving, status, prioriteit, agent_id, labels, aangemaakt, bijgewerkt)
                  VALUES (?,?,?,?,?,?,?,?,?)`)
        .run(r.bedrijf_id, r.taak_titel, r.taak_omschrijving, 'nieuw', 'normaal', r.agent_id, 'routine', tijd, tijd);
      logActiviteit('routine', `Routine "${r.naam}" maakte een nieuwe taak.`, { agentId: r.agent_id });
    }
    db.prepare('UPDATE routine SET laatste_start = ? WHERE id = ?').run(tijd, r.id);
  }
  // 2. agenten met werk wakker maken — één run per agent tegelijk
  for (const a of db.prepare("SELECT * FROM agent WHERE status = 'actief'").all()) {
    if (a.budget_maand_centen > 0) {
      const besteed = db.prepare("SELECT COALESCE(SUM(kosten_centen),0) AS s FROM run WHERE agent_id = ? AND substr(gestart,1,7) = ?")
        .get(a.id, tijd.slice(0, 7)).s;
      if (besteed >= a.budget_maand_centen) {
        db.prepare("UPDATE agent SET status = 'gepauzeerd' WHERE id = ?").run(a.id);
        logActiviteit('budget', `${a.naam} is gepauzeerd: maandbudget bereikt.`, { agentId: a.id });
        continue;
      }
    }
    const bezig = db.prepare("SELECT COUNT(*) AS n FROM run WHERE agent_id = ? AND status = 'lopend'").get(a.id).n;
    if (bezig > 0) continue;
    const taak = db.prepare(`SELECT * FROM taak WHERE agent_id = ? AND status = 'nieuw'
                             ORDER BY CASE prioriteit WHEN 'hoog' THEN 0 WHEN 'normaal' THEN 1 ELSE 2 END, id LIMIT 1`)
      .get(a.id);
    if (taak) startRun(a, taak);
  }
}
setInterval(hartslag, 15_000).unref?.();

// --- hulpjes voor de API ----------------------------------------------------
const stuur = (antwoord, code, data) => {
  const lijf = JSON.stringify(data);
  antwoord.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  antwoord.end(lijf);
};
const fout = (antwoord, code, tekst) => stuur(antwoord, code, { fout: tekst });

async function leesLijf(verzoek) {
  const brokken = [];
  for await (const stuk of verzoek) {
    brokken.push(stuk);
    if (Buffer.concat(brokken).length > 1_000_000) throw new Error('te groot');
  }
  if (!brokken.length) return {};
  try { return JSON.parse(Buffer.concat(brokken).toString('utf8')); } catch { throw new Error('ongeldige JSON'); }
}

const mag = (v, lijst, standaard) => (lijst.includes(v) ? v : standaard);

function taakMetRelaties(id) {
  const taak = db.prepare(`SELECT t.*, a.naam AS agent_naam, a.adapter AS agent_adapter
                           FROM taak t LEFT JOIN agent a ON a.id = t.agent_id WHERE t.id = ?`).get(id);
  if (!taak) return null;
  taak.berichten = db.prepare('SELECT * FROM bericht WHERE taak_id = ? ORDER BY id').all(id);
  taak.runs = db.prepare('SELECT id, status, gestart, beeindigd, exit_code, kosten_centen FROM run WHERE taak_id = ? ORDER BY id DESC').all(id);
  taak.goedkeuringen = db.prepare('SELECT * FROM goedkeuring WHERE taak_id = ? ORDER BY id DESC').all(id);
  return taak;
}

// --- routes -----------------------------------------------------------------
async function verwerk(verzoek, antwoord) {
  const adres = new URL(verzoek.url, `http://${verzoek.headers.host || 'localhost'}`);
  const pad = adres.pathname.replace(/\/+$/, '') || '/';
  const methode = verzoek.method;
  const delen = pad.split('/').filter(Boolean);

  if (pad === '/api/gezondheid') {
    const n = db.prepare('SELECT COUNT(*) AS n FROM agent').get().n;
    return stuur(antwoord, 200, { status: 'ok', agenten: n, poort: POORT, tijd: nu() });
  }
  if (pad === '/api/inloggen' && methode === 'POST') {
    const lijf = await leesLijf(verzoek);
    const gegeven = sha(lijf.wachtwoord || '');
    const juist = sha(WACHTWOORD);
    if (gegeven.length !== juist.length || !crypto.timingSafeEqual(gegeven, juist)) {
      logActiviteit('beveiliging', 'Mislukte inlogpoging.');
      return fout(antwoord, 401, 'Wachtwoord klopt niet.');
    }
    antwoord.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Set-Cookie': `${COOKIE}=${maakSessie()}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${SESSIE_UREN * 3600}`,
    });
    return antwoord.end(JSON.stringify({ ok: true }));
  }
  if (pad === '/api/uitloggen' && methode === 'POST') {
    antwoord.writeHead(200, { 'Content-Type': 'application/json', 'Set-Cookie': `${COOKIE}=; Path=/; Max-Age=0` });
    return antwoord.end(JSON.stringify({ ok: true }));
  }

  // live kanaal
  if (pad === '/api/stromen') {
    if (!leesSessie(verzoek.headers.cookie)) return fout(antwoord, 401, 'Niet ingelogd.');
    antwoord.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    antwoord.write(`data: ${JSON.stringify({ soort: 'hallo', tijd: nu() })}\n\n`);
    kijkers.add(antwoord);
    const tik = setInterval(() => { try { antwoord.write(': tik\n\n'); } catch { /* nee */ } }, 25_000);
    verzoek.on('close', () => { clearInterval(tik); kijkers.delete(antwoord); });
    return;
  }

  const ingelogd = leesSessie(verzoek.headers.cookie);
  if (!ingelogd) return fout(antwoord, 401, 'Niet ingelogd.');

  // ------- overzicht
  if (pad === '/api/overzicht' && methode === 'GET') {
    const maand = nu().slice(0, 7);
    const perDag = [];
    for (let i = 13; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86_400_000).toISOString().slice(0, 10);
      const r = db.prepare(`SELECT
          SUM(CASE WHEN status = 'geslaagd' THEN 1 ELSE 0 END) AS gelukt,
          SUM(CASE WHEN status = 'mislukt' THEN 1 ELSE 0 END) AS mislukt,
          SUM(CASE WHEN status = 'lopend' THEN 1 ELSE 0 END) AS lopend
        FROM run WHERE substr(gestart,1,10) = ?`).get(d);
      perDag.push({ dag: d, gelukt: r.gelukt || 0, mislukt: r.mislukt || 0, lopend: r.lopend || 0 });
    }
    const agenten = db.prepare('SELECT * FROM agent ORDER BY naam').all();
    return stuur(antwoord, 200, {
      agenten,
      kpi: {
        agenten_actief: agenten.filter((a) => a.status === 'actief').length,
        agenten_totaal: agenten.length,
        taken_open: db.prepare("SELECT COUNT(*) AS n FROM taak WHERE status IN ('nieuw','bezig')").get().n,
        taken_nakijken: db.prepare("SELECT COUNT(*) AS n FROM taak WHERE status = 'review'").get().n,
        taken_geblokkeerd: db.prepare("SELECT COUNT(*) AS n FROM taak WHERE status = 'geblokkeerd'").get().n,
        runs_vandaag: db.prepare('SELECT COUNT(*) AS n FROM run WHERE substr(gestart,1,10) = ?').get(nu().slice(0, 10)).n,
        runs_lopend: db.prepare("SELECT COUNT(*) AS n FROM run WHERE status = 'lopend'").get().n,
        kosten_maand_centen: db.prepare('SELECT COALESCE(SUM(kosten_centen),0) AS s FROM run WHERE substr(gestart,1,7) = ?').get(maand).s,
      },
      per_dag: perDag,
      per_status: db.prepare('SELECT status, COUNT(*) AS n FROM taak GROUP BY status').all(),
      laatste_runs: db.prepare(`SELECT r.*, a.naam AS agent_naam, t.titel AS taak_titel FROM run r
                                LEFT JOIN agent a ON a.id = r.agent_id LEFT JOIN taak t ON t.id = r.taak_id
                                ORDER BY r.id DESC LIMIT 12`).all(),
      recente_taken: db.prepare(`SELECT t.*, a.naam AS agent_naam FROM taak t LEFT JOIN agent a ON a.id = t.agent_id
                                 ORDER BY t.bijgewerkt DESC LIMIT 8`).all(),
      activiteit: db.prepare('SELECT * FROM activiteit ORDER BY id DESC LIMIT 15').all(),
    });
  }

  // ------- bedrijven
  if (delen[1] === 'bedrijven') {
    if (methode === 'GET') return stuur(antwoord, 200, db.prepare('SELECT * FROM bedrijf ORDER BY id').all());
    if (methode === 'POST') {
      const lijf = await leesLijf(verzoek);
      if (!lijf.naam) return fout(antwoord, 400, 'Naam ontbreekt.');
      db.prepare('INSERT INTO bedrijf (naam, doel, aangemaakt) VALUES (?,?,?)').run(lijf.naam, lijf.doel || '', nu());
      const id = rij();
      logActiviteit('bedrijf', `Bedrijf "${lijf.naam}" toegevoegd.`);
      return stuur(antwoord, 201, db.prepare('SELECT * FROM bedrijf WHERE id = ?').get(id));
    }
    if (delen[3] && (methode === 'PATCH' || methode === 'PUT')) {
      const lijf = await leesLijf(verzoek);
      const oud = db.prepare('SELECT * FROM bedrijf WHERE id = ?').get(Number(delen[2]));
      if (!oud) return fout(antwoord, 404, 'Bedrijf bestaat niet.');
      db.prepare('UPDATE bedrijf SET naam = ?, doel = ? WHERE id = ?')
        .run(lijf.naam ?? oud.naam, lijf.doel ?? oud.doel, oud.id);
      return stuur(antwoord, 200, db.prepare('SELECT * FROM bedrijf WHERE id = ?').get(oud.id));
    }
  }

  // ------- agenten
  if (delen[1] === 'agenten') {
    if (methode === 'GET' && !delen[2]) return stuur(antwoord, 200, db.prepare('SELECT * FROM agent ORDER BY naam').all());
    if (methode === 'POST' && !delen[2]) {
      const lijf = await leesLijf(verzoek);
      if (!lijf.naam || !lijf.adapter) return fout(antwoord, 400, 'Naam en adapter zijn verplicht.');
      if (!['hermes', 'opdracht', 'http'].includes(lijf.adapter)) return fout(antwoord, 400, 'Onbekende adapter.');
      const bedrijf = db.prepare('SELECT id FROM bedrijf ORDER BY id LIMIT 1').get();
      if (!bedrijf) return fout(antwoord, 400, 'Er is nog geen bedrijf.');
      db.prepare(`INSERT INTO agent (bedrijf_id, naam, rol, titel, adapter, adapter_config, model, status,
                  budget_maand_centen, heartbeat_aan, heartbeat_minuten, aangemaakt)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`)
        .run(lijf.bedrijf_id || bedrijf.id, lijf.naam, lijf.rol || 'algemeen', lijf.titel || '', lijf.adapter,
          JSON.stringify(lijf.adapter_config || {}), lijf.model || '', 'actief',
          Number(lijf.budget_maand_centen || 0), lijf.heartbeat_aan ? 1 : 0, Number(lijf.heartbeat_minuten || 30), nu());
      const id = rij();
      logActiviteit('agent', `${lijf.naam} is aangenomen als ${lijf.rol || 'algemeen'}.`, { agentId: id });
      return stuur(antwoord, 201, db.prepare('SELECT * FROM agent WHERE id = ?').get(id));
    }
    const agent = db.prepare('SELECT * FROM agent WHERE id = ?').get(Number(delen[2]));
    if (!agent) return fout(antwoord, 404, 'Agent bestaat niet.');
    if (methode === 'GET') return stuur(antwoord, 200, agent);
    if (methode === 'PATCH' || methode === 'PUT') {
      const lijf = await leesLijf(verzoek);
      db.prepare(`UPDATE agent SET naam = ?, rol = ?, titel = ?, adapter = ?, model = ?, status = ?,
                  budget_maand_centen = ?, heartbeat_aan = ?, heartbeat_minuten = ?, adapter_config = ? WHERE id = ?`)
        .run(lijf.naam ?? agent.naam, lijf.rol ?? agent.rol, lijf.titel ?? agent.titel, lijf.adapter ?? agent.adapter,
          lijf.model ?? agent.model, mag(lijf.status, ['actief', 'gepauzeerd'], agent.status),
          Number(lijf.budget_maand_centen ?? agent.budget_maand_centen),
          lijf.heartbeat_aan === undefined ? agent.heartbeat_aan : (lijf.heartbeat_aan ? 1 : 0),
          Number(lijf.heartbeat_minuten ?? agent.heartbeat_minuten),
          JSON.stringify(lijf.adapter_config ?? JSON.parse(agent.adapter_config || '{}')), agent.id);
      return stuur(antwoord, 200, db.prepare('SELECT * FROM agent WHERE id = ?').get(agent.id));
    }
    if (methode === 'POST' && delen[3] === 'pauzeer') {
      db.prepare("UPDATE agent SET status = 'gepauzeerd' WHERE id = ?").run(agent.id);
      logActiviteit('agent', `${agent.naam} is gepauzeerd.`, { agentId: agent.id });
      return stuur(antwoord, 200, { ok: true });
    }
    if (methode === 'POST' && delen[3] === 'hervat') {
      db.prepare("UPDATE agent SET status = 'actief' WHERE id = ?").run(agent.id);
      logActiviteit('agent', `${agent.naam} is weer actief.`, { agentId: agent.id });
      return stuur(antwoord, 200, { ok: true });
    }
    if (methode === 'POST' && delen[3] === 'wek') {
      const taak = db.prepare(`SELECT * FROM taak WHERE agent_id = ? AND status = 'nieuw' ORDER BY id LIMIT 1`).get(agent.id);
      if (!taak) return fout(antwoord, 400, 'Deze agent heeft geen open taak.');
      const runId = startRun(agent, taak);
      return stuur(antwoord, 202, { run: runId });
    }
  }

  // ------- taken
  if (delen[1] === 'taken') {
    if (methode === 'GET' && !delen[2]) {
      const waar = [];
      const waarden = [];
      if (adres.searchParams.get('status')) { waar.push('t.status = ?'); waarden.push(adres.searchParams.get('status')); }
      if (adres.searchParams.get('agent_id')) { waar.push('t.agent_id = ?'); waarden.push(Number(adres.searchParams.get('agent_id'))); }
      const sql = `SELECT t.*, a.naam AS agent_naam,
                     (SELECT COUNT(*) FROM bericht b WHERE b.taak_id = t.id) AS aantal_berichten
                   FROM taak t LEFT JOIN agent a ON a.id = t.agent_id
                   ${waar.length ? 'WHERE ' + waar.join(' AND ') : ''}
                   ORDER BY t.bijgewerkt DESC LIMIT 200`;
      return stuur(antwoord, 200, db.prepare(sql).all(...waarden));
    }
    if (methode === 'POST' && !delen[2]) {
      const lijf = await leesLijf(verzoek);
      if (!lijf.titel) return fout(antwoord, 400, 'Titel ontbreekt.');
      const bedrijf = db.prepare('SELECT id FROM bedrijf ORDER BY id LIMIT 1').get();
      if (!bedrijf) return fout(antwoord, 400, 'Er is nog geen bedrijf.');
      const tijd = nu();
      db.prepare(`INSERT INTO taak (bedrijf_id, titel, omschrijving, status, prioriteit, agent_id, labels, ouder_id, aangemaakt, bijgewerkt)
                  VALUES (?,?,?,?,?,?,?,?,?,?)`)
        .run(lijf.bedrijf_id || bedrijf.id, lijf.titel, lijf.omschrijving || '',
          mag(lijf.status, ['nieuw', 'bezig', 'review', 'klaar', 'geblokkeerd'], 'nieuw'),
          mag(lijf.prioriteit, ['laag', 'normaal', 'hoog'], 'normaal'),
          lijf.agent_id ? Number(lijf.agent_id) : null, lijf.labels || '', lijf.ouder_id ? Number(lijf.ouder_id) : null, tijd, tijd);
      const id = rij();
      logActiviteit('taak', `Nieuwe taak ${id}: ${lijf.titel}`, { taakId: id });
      return stuur(antwoord, 201, taakMetRelaties(id));
    }
    const taak = db.prepare('SELECT * FROM taak WHERE id = ?').get(Number(delen[2]));
    if (!taak) return fout(antwoord, 404, 'Taak bestaat niet.');
    if (methode === 'GET' && !delen[3]) return stuur(antwoord, 200, taakMetRelaties(taak.id));
    if ((methode === 'PATCH' || methode === 'PUT') && !delen[3]) {
      const lijf = await leesLijf(verzoek);
      db.prepare(`UPDATE taak SET titel = ?, omschrijving = ?, status = ?, prioriteit = ?, agent_id = ?, labels = ?, bijgewerkt = ? WHERE id = ?`)
        .run(lijf.titel ?? taak.titel, lijf.omschrijving ?? taak.omschrijving,
          mag(lijf.status, ['nieuw', 'bezig', 'review', 'klaar', 'geblokkeerd'], taak.status),
          mag(lijf.prioriteit, ['laag', 'normaal', 'hoog'], taak.prioriteit),
          lijf.agent_id === undefined ? taak.agent_id : (lijf.agent_id ? Number(lijf.agent_id) : null),
          lijf.labels ?? taak.labels, nu(), taak.id);
      logActiviteit('taak', `Taak ${taak.id} bijgewerkt.`, { taakId: taak.id });
      return stuur(antwoord, 200, taakMetRelaties(taak.id));
    }
    if (methode === 'POST' && delen[3] === 'bericht') {
      const lijf = await leesLijf(verzoek);
      if (!lijf.tekst) return fout(antwoord, 400, 'Tekst ontbreekt.');
      db.prepare('INSERT INTO bericht (taak_id, van_soort, van_naam, tekst, tijd) VALUES (?,?,?,?,?)')
        .run(taak.id, 'mens', lijf.van_naam || 'Beheerder', lijf.tekst, nu());
      db.prepare('UPDATE taak SET bijgewerkt = ? WHERE id = ?').run(nu(), taak.id);
      if (lijf.herenig !== false && ['geblokkeerd', 'review'].includes(taak.status)) {
        db.prepare("UPDATE taak SET status = 'nieuw', agent_id = COALESCE(agent_id, ?) WHERE id = ?").run(taak.agent_id, taak.id);
      }
      zend({ soort: 'taak', taakId: taak.id });
      return stuur(antwoord, 201, taakMetRelaties(taak.id));
    }
    if (methode === 'POST' && (delen[3] === 'keur-goed' || delen[3] === 'keur-af')) {
      const lijf = await leesLijf(verzoek);
      const goed = delen[3] === 'keur-goed';
      const open = db.prepare("SELECT * FROM goedkeuring WHERE taak_id = ? AND status = 'open' ORDER BY id DESC").get(taak.id);
      if (open) {
        db.prepare('UPDATE goedkeuring SET status = ?, besluit_door = ?, besluit_tijd = ?, opmerking = ? WHERE id = ?')
          .run(goed ? 'goedgekeurd' : 'afgekeurd', lijf.door || 'Beheerder', nu(), lijf.opmerking || '', open.id);
      }
      db.prepare('UPDATE taak SET status = ?, bijgewerkt = ? WHERE id = ?')
        .run(goed ? 'klaar' : 'nieuw', nu(), taak.id);
      db.prepare('INSERT INTO bericht (taak_id, van_soort, van_naam, tekst, tijd) VALUES (?,?,?,?,?)')
        .run(taak.id, 'mens', lijf.door || 'Beheerder',
          (goed ? 'Goedgekeurd.' : 'Terug naar de agent.') + (lijf.opmerking ? '\n\n' + lijf.opmerking : ''), nu());
      logActiviteit('goedkeuring', `Taak ${taak.id} ${goed ? 'goedgekeurd' : 'afgekeurd'}.`, { taakId: taak.id, agentId: taak.agent_id });
      zend({ soort: 'taak', taakId: taak.id, status: goed ? 'klaar' : 'nieuw' });
      return stuur(antwoord, 200, taakMetRelaties(taak.id));
    }
  }

  // ------- runs
  if (delen[1] === 'runs') {
    if (methode === 'GET' && !delen[2]) {
      return stuur(antwoord, 200, db.prepare(`SELECT r.*, a.naam AS agent_naam, t.titel AS taak_titel FROM run r
        LEFT JOIN agent a ON a.id = r.agent_id LEFT JOIN taak t ON t.id = r.taak_id
        ORDER BY r.id DESC LIMIT ${Math.min(Number(adres.searchParams.get('limiet') || 50), 200)}`).all());
    }
    const run = db.prepare('SELECT * FROM run WHERE id = ?').get(Number(delen[2]));
    if (!run) return fout(antwoord, 404, 'Run bestaat niet.');
    if (methode === 'GET' && delen[3] === 'log') {
      let tekst = '';
      try { tekst = await fsp.readFile(run.logpad, 'utf8'); } catch { tekst = '(geen logbestand)'; }
      return stuur(antwoord, 200, { id: run.id, tekst });
    }
    if (methode === 'GET' && !delen[3]) return stuur(antwoord, 200, run);
    if (methode === 'POST' && delen[3] === 'stop') {
      const lopend = lopendeRuns.get(run.id);
      if (lopend) lopend.stop();
      return stuur(antwoord, 200, { ok: Boolean(lopend) });
    }
    if (methode === 'PATCH' && !delen[3]) {
      const lijf = await leesLijf(verzoek);
      db.prepare('UPDATE run SET kosten_centen = ? WHERE id = ?').run(Number(lijf.kosten_centen || 0), run.id);
      return stuur(antwoord, 200, db.prepare('SELECT * FROM run WHERE id = ?').get(run.id));
    }
  }

  // ------- goedkeuringen en activiteit
  if (delen[1] === 'goedkeuringen' && methode === 'GET') {
    return stuur(antwoord, 200, db.prepare(`SELECT g.*, t.titel AS taak_titel, a.naam AS agent_naam
      FROM goedkeuring g LEFT JOIN taak t ON t.id = g.taak_id LEFT JOIN agent a ON a.id = g.agent_id
      WHERE g.status = 'open' ORDER BY g.id DESC`).all());
  }
  if (delen[1] === 'activiteit' && methode === 'GET') {
    return stuur(antwoord, 200, db.prepare('SELECT * FROM activiteit ORDER BY id DESC LIMIT 200').all());
  }

  // ------- routines
  if (delen[1] === 'routines') {
    if (methode === 'GET') return stuur(antwoord, 200, db.prepare(`SELECT r.*, a.naam AS agent_naam FROM routine r
      LEFT JOIN agent a ON a.id = r.agent_id ORDER BY r.id`).all());
    if (methode === 'POST' && !delen[2]) {
      const lijf = await leesLijf(verzoek);
      if (!lijf.naam || !lijf.taak_titel) return fout(antwoord, 400, 'Naam en taaktitel zijn verplicht.');
      const bedrijf = db.prepare('SELECT id FROM bedrijf ORDER BY id LIMIT 1').get();
      db.prepare(`INSERT INTO routine (bedrijf_id, naam, agent_id, interval_minuten, actief, taak_titel, taak_omschrijving)
                  VALUES (?,?,?,?,?,?,?)`)
        .run(lijf.bedrijf_id || bedrijf.id, lijf.naam, lijf.agent_id ? Number(lijf.agent_id) : null,
          Number(lijf.interval_minuten || 60), lijf.actief === false ? 0 : 1, lijf.taak_titel, lijf.taak_omschrijving || '');
      return stuur(antwoord, 201, db.prepare('SELECT * FROM routine WHERE id = ?').get(rij()));
    }
    if (methode === 'PATCH' && delen[2]) {
      const lijf = await leesLijf(verzoek);
      const oud = db.prepare('SELECT * FROM routine WHERE id = ?').get(Number(delen[2]));
      if (!oud) return fout(antwoord, 404, 'Routine bestaat niet.');
      db.prepare('UPDATE routine SET naam = ?, interval_minuten = ?, actief = ?, taak_titel = ?, taak_omschrijving = ?, agent_id = ? WHERE id = ?')
        .run(lijf.naam ?? oud.naam, Number(lijf.interval_minuten ?? oud.interval_minuten),
          lijf.actief === undefined ? oud.actief : (lijf.actief ? 1 : 0), lijf.taak_titel ?? oud.taak_titel,
          lijf.taak_omschrijving ?? oud.taak_omschrijving,
          lijf.agent_id === undefined ? oud.agent_id : Number(lijf.agent_id), oud.id);
      return stuur(antwoord, 200, db.prepare('SELECT * FROM routine WHERE id = ?').get(oud.id));
    }
    if (methode === 'POST' && delen[3] === 'start') {
      const r = db.prepare('SELECT * FROM routine WHERE id = ?').get(Number(delen[2]));
      if (!r) return fout(antwoord, 404, 'Routine bestaat niet.');
      db.prepare('UPDATE routine SET laatste_start = NULL WHERE id = ?').run(r.id);
      hartslag();
      return stuur(antwoord, 202, { ok: true });
    }
  }

  return fout(antwoord, 404, 'Onbekend adres.');
}

// --- statische bestanden ----------------------------------------------------
const SOORTEN = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.webmanifest': 'application/manifest+json', '.ico': 'image/x-icon',
};

async function dienBestand(verzoek, antwoord, pad) {
  let bestand = path.join(PUBLIEK, pad === '/' ? 'index.html' : pad.replace(/^\/+/, ''));
  if (pad.startsWith('/uitslag/')) bestand = path.join(PUBLIEK, 'index.html');
  if (!bestand.startsWith(PUBLIEK)) return fout(antwoord, 403, 'Nee.');
  try {
    const inhoud = await fsp.readFile(bestand);
    antwoord.writeHead(200, { 'Content-Type': SOORTEN[path.extname(bestand)] || 'application/octet-stream' });
    antwoord.end(inhoud);
  } catch {
    const index = await fsp.readFile(path.join(PUBLIEK, 'index.html'));
    antwoord.writeHead(200, { 'Content-Type': SOORTEN['.html'] });
    antwoord.end(index);
  }
}

const server = http.createServer(async (verzoek, antwoord) => {
  const pad = (verzoek.url || '/').split('?')[0];
  try {
    if (pad.startsWith('/api/')) return await verwerk(verzoek, antwoord);
    return await dienBestand(verzoek, antwoord, pad);
  } catch (foutje) {
    return fout(antwoord, 400, foutje.message || 'Er ging iets mis.');
  }
});

// --- controle opdracht ------------------------------------------------------
async function controleer() {
  const uit = [];
  const zeg = (goed, tekst) => { uit.push(`${goed ? '  ✓' : '  ✗'} ${tekst}`); return goed; };
  console.log(`Ploegbaas-controle — ${path.join(DATA, 'ploegbaas.db')}\n`);
  zeg(true, `database bereikbaar (${db.prepare('SELECT COUNT(*) AS n FROM taak').get().n} taken, ${db.prepare('SELECT COUNT(*) AS n FROM agent').get().n} agenten)`);
  zeg(db.prepare('SELECT COUNT(*) AS n FROM bedrijf').get().n > 0, 'minstens één bedrijf');
  const h = await fetch(`http://127.0.0.1:${POORT}/api/gezondheid`).then((r) => r.json()).catch(() => null);
  zeg(Boolean(h), `server antwoordt op poort ${POORT}`);
  zeg(await fetch(`http://127.0.0.1:${POORT}/api/taken`).then((r) => r.status === 401).catch(() => false),
    'de API vraagt om inloggen (401 zonder sessie)');
  const agenten = db.prepare('SELECT * FROM agent').all();
  for (const a of agenten) {
    const commando = JSON.parse(a.adapter_config || '{}').commando;
    if (a.adapter === 'hermes' && commando) {
      const { execFile } = await import('node:child_process');
      const bestaat = await new Promise((klaar) => execFile('sh', ['-c', `command -v ${commando}`], (e) => klaar(!e)));
      zeg(bestaat, `adapter van ${a.naam}: "${commando}" staat op deze machine`);
    } else {
      zeg(true, `adapter van ${a.naam}: ${a.adapter}`);
    }
  }
  const runs = db.prepare('SELECT COUNT(*) AS n FROM run').get().n;
  const gelukt = db.prepare("SELECT COUNT(*) AS n FROM run WHERE status = 'geslaagd'").get().n;
  zeg(runs > 0, `${runs} run(s) in de geschiedenis, waarvan ${gelukt} geslaagd`);
  console.log(uit.join('\n'));
  console.log(`\nDashboard: http://127.0.0.1:${POORT}  (wachtwoord: ${WACHTWOORD_BESTAND})`);
  process.exit(uit.some((r) => r.startsWith('  ✗')) ? 1 : 0);
}

const directGestart = process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (directGestart && process.argv[2] === 'controleer') {
  await import('node:child_process');
  await controleer();
} else if (directGestart) {
  zaai();
  server.listen(POORT, '0.0.0.0', () => {
    console.log(`Ploegbaas draait op http://0.0.0.0:${POORT}`);
    console.log(`  data:      ${DATA}`);
    console.log(`  wachtwoord: ${fs.existsSync(WACHTWOORD_BESTAND) ? WACHTWOORD_BESTAND : '(uit PLOEGBAAS_WACHTWOORD)'}`);
    console.log(`  hartslag:  elke 15 seconden kijken of een agent werk heeft`);
  });
  const sluit = () => {
    for (const [, r] of lopendeRuns) r.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000);
  };
  process.on('SIGTERM', sluit);
  process.on('SIGINT', sluit);
}
