# Ploegbaas

Eigen dashboard om een **ploeg AI-agenten** aan het werk te zetten: je maakt een
taak, wijst hem toe aan een agent, en Ploegbaas laat die agent werken, houdt de log
bij, en legt het resultaat bij jou neer om na te kijken. Alles in het Nederlands,
met een eigen huisstijl.

Het is bewust **eigen werk**: één Node-server (`node:http`, `node:sqlite`,
`node:child_process`) en één pagina HTML. Geen npm-afhankelijkheden, geen framework.
Functioneel geïnspireerd op Paperclip (MIT, paperclipai/paperclip) — er is **geen
regel code uit dat project overgenomen**; zie "Herkomst" onderaan.

![Het dashboard: agenten, taken, runs en het logboek](docs/screenshots/dashboard.png)

## Zo werkt het

1. **Taak** — je schrijft op wat er moet gebeuren en wijst hem toe aan een agent.
2. **Hartslag** — elke 15 seconden kijkt Ploegbaas of een agent werk heeft. Is er
   een open taak, dan start hij een **run** en zet de taak op *bezig*.
3. **Uitvoering** — de agent draait via zijn **adapter**:
   - `hermes` — start de Hermes Agent op deze machine met de taak als opdracht;
   - `opdracht` — draait een eigen shell-commando (de opdracht staat in de omgeving);
   - `http` — stuurt de taak als JSON naar een eigen endpoint.
4. **Nakijken** — een geslaagde run zet de taak op *nakijken* en maakt een
   goedkeuring aan. Jij keurt goed, of stuurt hem terug naar de agent met uitleg.
5. **Logboek** — elke start, uitkomst, goedkeuring en fout staat in het logboek.

![Een taak: overleg met de agent, de runs en het nakijk-paneel](docs/screenshots/taak.png)

Daarnaast: **routines** (terugkerend werk dat zelf taken aanmaakt), **budgetten**
(een agent wordt automatisch gepauzeerd als zijn maandbudget op is), en een **live
kanaal** zodat de pagina zichzelf bijwerkt terwijl een agent bezig is.

## Snel starten

```bash
node --no-warnings server.mjs          # standaard op poort 8123, huisstijl-poort instelbaar
```

Het wachtwoord wordt de eerste keer aangemaakt en staat in `data/wachtwoord.txt`.
Open daarna `http://<adres>:8123` en log in. Bij een lege database richt Ploegbaas
zichzelf in met een bedrijf, twee agenten en een paar taken, zodat je meteen ziet
hoe het werkt.

Instellen met omgevingsvariabelen: `PLOEGBAAS_POORT` (standaard 8123),
`PLOEGBAAS_DATA` (standaard `./data`), `PLOEGBAAS_WACHTWOORD` (anders gegenereerd).

Controle dat alles staat:

```bash
node --no-warnings server.mjs controleer
```

Als service (start ook na een reboot):

```bash
sudo cp deploy/systemd/ploegbaas.service /etc/systemd/system/   # in een container/VM
sudo systemctl enable --now ploegbaas
```

Wil je de Hermes-adapter gebruiken, dan moet de Hermes Agent op die machine staan
(`curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`). Zonder
Hermes werken de adapters `opdracht` en `http` gewoon.

## Wat er wel en niet in zit

Eerlijke functielijst, naast wat Paperclip heeft. **ja** = werkt hier · **deels** =
aanwezig met een beperking · **nee** = niet gebouwd.

| Functie | Hier | Toelichting |
|---|---|---|
| Dashboard met inlogwachtwoord | ja | Eén wachtwoord, ondertekende sessiecookie; de API geeft 401 zonder sessie |
| Taken met status, prioriteit, labels en ouder-taak | ja | *nieuw · bezig · nakijken · klaar · geblokkeerd* |
| Overleg per taak (thread) met de agent | ja | Een bericht van jou zet de taak terug op *nieuw* |
| Agenten met rol, titel en adapter | ja | `hermes`, `opdracht`, `http` |
| Hartslag: agent pakt zelf toegewezen werk | ja | Elke 15 seconden; één run per agent tegelijk |
| Runs met volledige log en live bijwerken | ja | Logbestand per run plus een live kanaal (SSE) in de pagina |
| Nakijken en goedkeuren | ja | Goedkeuren of terugsturen met opmerking |
| Routines (terugkerend werk) | ja | Interval in minuten, met een knop om er nu één te starten |
| Budgetten met harde stop | deels | Je vult een maandbudget in en Ploegbaas pauzeert de agent als het op is; kosten per run zijn **handmatig** (er is nog geen prijstabel per model) |
| Logboek en audittrail | ja | Elke mutatie en run |
| Meerdere bedrijven | deels | De tabel staat er en de API kan het; de pagina toont nu één bedrijf |
| Org-chart met rapportagelijnen | nee | Rollen en titels zijn er, een hiërarchie nog niet |
| Meerdere mensen met eigen accounts en rechten | nee | Bewust één beheerder met één wachtwoord |
| Skills, evaluaties, teamtemplates | nee | Nog niet gebouwd |
| Connectors (GitHub, Notion, MCP) en chat-kanalen | nee | De `http`-adapter is het haakje voor eigen koppelingen |
| Zoeken over alles heen | deels | Zoeken in de takenlijst; niet over logs en berichten |
| Mobiel bruikbaar | ja | Responsieve pagina, dus bruikbaar vanaf je telefoon op het netwerk |

## Bestanden

```
server.mjs              de hele server: API, hartslag, adapters, uitvoering, logboek
public/index.html       de hele pagina (HTML + CSS + JavaScript, geen bouwstap)
deploy/systemd/         service-eenheid voor een container of VM
data/                   database, wachtwoord, run-logs (horen niet in git)
docs/screenshots/       de schermafbeeldingen uit deze README
```

De database is één SQLite-bestand (`data/ploegbaas.db`) met de tabellen `bedrijf`,
`agent`, `taak`, `bericht`, `run`, `goedkeuring`, `activiteit` en `routine`. Een
back-up is het bestand kopiëren.

## Herkomst en licentie

Ploegbaas is eigen werk van Werdens Media: de server, de pagina, de adapters, de
hartslag en de goedkeuringslus zijn hier geschreven. De **functionaliteit** is
geïnspireerd op het MIT-gelicenseerde [paperclipai/paperclip](https://github.com/paperclipai/paperclip)
(een dashboard om agentteams aan te sturen); er is **geen code, bestandsindeling,
endpointnaam of schermtekst uit dat project overgenomen**. Draai je liever het
origineel, gebruik dan de kit daarvoor.

© Werdens Media — alle rechten voorbehouden.
