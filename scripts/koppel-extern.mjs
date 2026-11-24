#!/usr/bin/env node
// Koppelt een Hermes-gateway op een andere machine als collega in Ploegbaas.
//
//   node scripts/koppel-extern.mjs --url http://192.168.1.100:8642 \
//        --sleutel ~/.hermes/extern/gateway.key [--naam "Hermes .248"] [--rol ict-beheer]
//
// De proef is de poort: eerst praat het hulpcommando (hermes-extern.mjs) echt met de
// gateway; pas als dat lukt komt de agent in de lijst. Zo staat er nooit een dode
// collega in het dashboard.
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const HIER = resolve(dirname(new URL(import.meta.url).pathname), '..');
const HELP = join(HIER, 'scripts', 'hermes-extern.mjs');

function opt(naam, standaard = '') {
  const i = process.argv.indexOf(`--${naam}`);
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : standaard;
}

const url = (opt('url', 'http://192.168.1.100:8642')).replace(/\/+$/, '');
const sleutelPad = resolve(opt('sleutel', join(homedir(), '.hermes', 'extern', 'gateway.key')).replace(/^~(?=\/)/, homedir()));
const naam = opt('naam', `Hermes ${new URL(url).hostname.split('.').pop()}`);
const rol = opt('rol', 'ict-beheer');
const basis = opt('ploegbaas', 'http://127.0.0.1:8123');

if (!existsSync(sleutelPad)) {
  console.error(`geen sleutelbestand: ${sleutelPad}`);
  console.error('Zet de API_SERVER_KEY van die machine daar neer (chmod 600) en probeer opnieuw.');
  process.exit(3);
}
mkdirSync(dirname(sleutelPad), { recursive: true });
try { chmodSync(sleutelPad, 0o600); } catch {}
const modus = statSync(sleutelPad).mode & 0o777;
if (modus !== 0o600) console.warn(`let op: ${sleutelPad} staat op ${modus.toString(8)}; 600 is beter.`);

const omgeving = {
  HERMES_EXTERN_URL: url,
  HERMES_EXTERN_KEY_FILE: sleutelPad,
  HERMES_EXTERN_MODEL: opt('model', 'hermes-agent'),
  HERMES_EXTERN_TIMEOUT: opt('timeout', '1800'),
  ...(opt('sessie') ? { HERMES_EXTERN_SESSIE: opt('sessie') } : {}),
};

// 1. de poort: een echte, korte beurt op die gateway
console.log(`proef op ${url} ...`);
let proefUit;
try {
  proefUit = execFileSync('node', [HELP, 'Antwoord met precies één woord: ok'], {
    env: { ...process.env, ...omgeving }, encoding: 'utf8', timeout: 180_000,
  }).trim();
} catch (fout) {
  console.error('proef mislukt:');
  console.error(String(fout.stderr || fout.stdout || fout.message || fout).trim());
  process.exit(4);
}
console.log(`proef ok: ${proefUit.split('\n').pop().slice(0, 120)}`);

// 2. de sleutel van Ploegbaas zelf
const wachtwoordPad = join(HIER, 'data', 'wachtwoord.txt');
let wachtwoord = process.env.PLOEGBAAS_WACHTWOORD || '';
if (!wachtwoord && existsSync(wachtwoordPad)) {
  wachtwoord = readFileSync(wachtwoordPad, 'utf8').trim().split('\n').pop().trim();
}
if (!wachtwoord) {
  console.error(`geen Ploegbaas-wachtwoord: zet PLOEGBAAS_WACHTWOORD of ${wachtwoordPad}`);
  process.exit(5);
}
const inlog = await fetch(`${basis}/api/inloggen`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ wachtwoord }),
});
if (!inlog.ok) { console.error(`inloggen mislukte (${inlog.status})`); process.exit(5); }
const koek = (inlog.headers.getSetCookie?.() || []).map((c) => c.split(';')[0]).join('; ');

// 3. de agent aanmaken
const lijf = {
  naam, rol, titel: `Hermes-gateway op ${new URL(url).hostname}`,
  adapter: 'opdracht',
  adapter_config: {
    commando: 'node',
    args: [HELP],
    omgeving,
    timeout_seconden: Number(opt('timeout', '1800')),
  },
  heartbeat_aan: true,
  heartbeat_minuten: 30,
};
const maak = await fetch(`${basis}/api/agenten`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Cookie: koek },
  body: JSON.stringify(lijf),
});
const antwoord = await maak.text();
if (!maak.ok) { console.error(`aanmaken mislukte (${maak.status}): ${antwoord.slice(0, 400)}`); process.exit(6); }
const agent = JSON.parse(antwoord);
console.log(`gekoppeld: #${agent.id} ${agent.naam} (${agent.rol}) -> ${url}`);
console.log(`dashboard: ${basis}/#/agenten`);
