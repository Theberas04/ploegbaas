#!/usr/bin/env node
// Praat met een Hermes-gateway op een andere machine (OpenAI-compatibel
// /v1/chat/completions). Bedoeld als commando voor een Ploegbaas-agent met
// adapter "opdracht", zodat een Hermes elders als collega in het dashboard staat.
//
//   node hermes-extern.mjs "<opdracht>"
//
// Instellingen via de omgeving (zet ze in adapter_config.omgeving):
//   HERMES_EXTERN_URL        basisadres van de gateway   (default http://192.168.1.100:8642)
//   HERMES_EXTERN_KEY_FILE   bestand met de API_SERVER_KEY (default ~/.hermes/extern/gateway.key)
//   HERMES_EXTERN_KEY        sleutel zelf (gaat voor op het bestand)
//   HERMES_EXTERN_MODEL      modelalias                 (default hermes-agent)
//   HERMES_EXTERN_TIMEOUT    seconden                   (default 900)
//   HERMES_EXTERN_SESSIE     vaste sessiesleutel (X-Hermes-Session-Key) voor continuiteit
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const url = (process.env.HERMES_EXTERN_URL || 'http://192.168.1.100:8642').replace(/\/+$/, '');
const model = process.env.HERMES_EXTERN_MODEL || 'hermes-agent';
const timeout = Number(process.env.HERMES_EXTERN_TIMEOUT || 900) * 1000;
const opdracht = process.argv.slice(2).join(' ').trim();

function sleutel() {
  if (process.env.HERMES_EXTERN_KEY) return process.env.HERMES_EXTERN_KEY.trim();
  const bestand = process.env.HERMES_EXTERN_KEY_FILE || join(homedir(), '.hermes', 'extern', 'gateway.key');
  try {
    return readFileSync(bestand, 'utf8').trim();
  } catch {
    throw new Error(`geen sleutel: ${bestand} bestaat niet en HERMES_EXTERN_KEY is leeg`);
  }
}

if (!opdracht) {
  console.error('gebruik: node hermes-extern.mjs "<opdracht>"');
  process.exit(2);
}

let k;
try {
  k = sleutel();
} catch (fout) {
  console.error(String(fout.message || fout));
  process.exit(3);
}

const kop = { 'Content-Type': 'application/json', Authorization: `Bearer ${k}` };
if (process.env.HERMES_EXTERN_SESSIE) kop['X-Hermes-Session-Key'] = process.env.HERMES_EXTERN_SESSIE;

try {
  const antwoord = await fetch(`${url}/v1/chat/completions`, {
    method: 'POST',
    headers: kop,
    body: JSON.stringify({ model, messages: [{ role: 'user', content: opdracht }], stream: false }),
    signal: AbortSignal.timeout(timeout),
  });
  const tekst = await antwoord.text();
  if (!antwoord.ok) {
    console.error(`${url} antwoordde ${antwoord.status}: ${tekst.slice(0, 500)}`);
    process.exit(1);
  }
  let gegevens;
  try { gegevens = JSON.parse(tekst); } catch { console.log(tekst); process.exit(0); }
  const inhoud = gegevens?.choices?.[0]?.message?.content;
  console.log(typeof inhoud === 'string' && inhoud.trim() ? inhoud.trim() : tekst.slice(0, 2000));
} catch (fout) {
  console.error(`kon ${url} niet bereiken: ${fout.message || fout}`);
  process.exit(1);
}
