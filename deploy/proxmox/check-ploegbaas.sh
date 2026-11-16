#!/usr/bin/env bash
# Controleert de Ploegbaas-installatie in deze container (of machine).
#   bash check-ploegbaas.sh
# Geeft per punt groen/geel/rood en eindigt met een samenvatting.
set -uo pipefail

PB_POORT="${PLOEGBAAS_POORT:-8123}"
PB_MAP="${PLOEGBAAS_MAP:-/opt/ploegbaas}"
PB_DATA="${PLOEGBAAS_DATA:-/opt/ploegbaas/data}"
API="http://127.0.0.1:$PB_POORT"
WACHTWOORD="$(cat "$PB_DATA/wachtwoord.txt" 2>/dev/null || echo '')"
COOKIES=/tmp/pb-check-cookies.txt

ok=0; let_op=0; fout=0
goed(){ printf '  \033[1;32m✓\033[0m %s\n' "$*"; ok=$((ok+1)); }
letop(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; let_op=$((let_op+1)); }
mis(){ printf '  \033[1;31m✗\033[0m %s\n' "$*"; fout=$((fout+1)); }

# Werkt de service systeembreed of als gebruikersdienst? Beide komen voor.
dienst_actief(){
  if systemctl is-active --quiet ploegbaas.service 2>/dev/null; then echo systeem; return 0; fi
  if systemctl --user is-active --quiet ploegbaas.service 2>/dev/null; then echo gebruiker; return 0; fi
  return 1
}

echo "Ploegbaas-controle — $(hostname) — $(date '+%Y-%m-%d %H:%M')"
echo

echo "Omgeving"
printf '  node: %s\n' "$(node --version 2>/dev/null || echo ontbreekt)"
[ -f "$PB_MAP/server.mjs" ] && goed "server.mjs staat in $PB_MAP" || mis "server.mjs ontbreekt in $PB_MAP"
[ -f "$PB_MAP/public/index.html" ] && goed "de pagina staat klaar" || mis "public/index.html ontbreekt"
[ -f "$PB_DATA/ploegbaas.db" ] && goed "database aanwezig ($(du -h "$PB_DATA/ploegbaas.db" 2>/dev/null | cut -f1))" || mis "database ontbreekt"
if command -v hermes >/dev/null 2>&1 || [ -x /root/.local/bin/hermes ] || [ -x "$HOME/.local/bin/hermes" ]; then
  goed "Hermes Agent gevonden (de agent kan echt werk doen)"
else
  letop "geen Hermes Agent: de hermes-adapter doet niets. Installeer hem met:
      curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
fi
echo

echo "Service"
if SOORT="$(dienst_actief)"; then
  goed "ploegbaas.service draait ($SOORT-dienst)"
  if [ "$SOORT" = "systeem" ]; then
    systemctl is-enabled --quiet ploegbaas.service 2>/dev/null && goed "start ook na een reboot" || letop "service staat niet 'enabled'"
  fi
else
  mis "ploegbaas.service draait niet"
fi
echo

echo "Dashboard"
GEZOND="$(curl -s -m 5 "$API/api/gezondheid" 2>/dev/null || true)"
if printf '%s' "$GEZOND" | grep -q '"status":"ok"'; then
  goed "API gezond op $API ($(printf '%s' "$GEZOND" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(str(d.get("agenten"))+" agenten")' 2>/dev/null))"
else
  mis "API antwoordt niet op $API"
fi
UI="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/" 2>/dev/null)"
[ "$UI" = "200" ] && goed "de pagina wordt geleverd (200)" || mis "de pagina gaf $UI"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/api/taken" 2>/dev/null)" = "401" ] \
  && goed "zonder inloggen geen toegang tot de API (401)" \
  || mis "de API is zonder inloggen bereikbaar — dat hoort niet"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -n "$IP" ]; then
  LAN="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$IP:$PB_POORT/" 2>/dev/null)"
  [ "$LAN" = "200" ] && goed "bereikbaar op het netwerk (http://$IP:$PB_POORT)" \
    || mis "netwerkadres http://$IP:$PB_POORT gaf $LAN"
fi
GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
if [ -n "$GW" ]; then
  if timeout 2 bash -c "echo > /dev/tcp/$GW/53" 2>/dev/null; then
    goed "de gateway ($GW) antwoordt via TCP"
  else
    letop "de gateway ($GW) antwoordt niet op TCP — controleer de bridge"
  fi
fi
# Let op: met 'set -o pipefail' wordt de status van 'ping | grep' de status van
# ping (die faalt), ook als grep wél vindt wat we zoeken. Daarom eerst opvangen.
PING_UIT="$(ping -c1 -W1 127.0.0.1 2>&1 || true)"
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
  goed "pingen werkt (ICMP)"
elif printf '%s' "$PING_UIT" | grep -q 'not permitted'; then
  letop "pingen mag niet in deze container (geen cap_net_raw). Zet één keer:
      sysctl -w net.ipv4.ping_group_range=\"0 2147483647\"
      en zet die regel in /etc/sysctl.d/90-ploegbaas-ping.conf. TCP-proeven werken wel."
else
  letop "geen ping-antwoord van buiten (kan ook aan het netwerk liggen; TCP-proeven werken wel)"
fi
SSH_PUB="$([ -f $HOME/.ssh/id_ed25519.pub ] && echo ja || echo nee)"
if [ "$SSH_PUB" = "ja" ]; then
  goed "er staat een sleutel voor de agent ($HOME/.ssh/id_ed25519)"
  if timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 root@"${SSH_TEST:-$GW}" true 2>&1 | grep -q 'Permission denied'; then
    letop "inloggen op ${SSH_TEST:-$GW} lukt nog niet: de publieke sleutel moet daar nog in
      ~/.ssh/authorized_keys staan. Zet deze regel daar neer:
      $(cat $HOME/.ssh/id_ed25519.pub)"
  fi
else
  letop "geen sleutel voor de agent gevonden ($HOME/.ssh/id_ed25519.pub)"
fi
echo

echo "Werk en ploeg"
if [ -n "$WACHTWOORD" ]; then
  if curl -s -c "$COOKIES" -X POST "$API/api/inloggen" -H 'Content-Type: application/json' \
      -d "{\"wachtwoord\":\"$WACHTWOORD\"}" | grep -q '"ok":true'; then
    goed "inloggen met het wachtwoord uit $PB_DATA/wachtwoord.txt lukt"
    curl -s -b "$COOKIES" "$API/api/agenten" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for a in d: print("      -", a.get("naam"), "|", a.get("adapter"), "| model:", a.get("model") or "eigen keuze", "|", a.get("status"))' 2>/dev/null
    HERMES_AAN="$(curl -s -b "$COOKIES" "$API/api/agenten" | grep -c '"adapter":"hermes"' || true)"
    [ "${HERMES_AAN:-0}" -ge 1 ] && goed "er staat een agent op de hermes-adapter" || letop "geen agent op de hermes-adapter"
    RUNS="$(curl -s -b "$COOKIES" "$API/api/runs?limiet=50" 2>/dev/null)"
    GELUKT="$(printf '%s' "$RUNS" | python3 -c 'import json,sys
try: print(sum(1 for r in json.load(sys.stdin) if r.get("status")=="geslaagd"))
except Exception: print(0)' 2>/dev/null)"
    TOTAAL="$(printf '%s' "$RUNS" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null)"
    [ "${GELUKT:-0}" -ge 1 ] && goed "$GELUKT van $TOTAAL runs geslaagd" || letop "nog geen geslaagde run"
    NAKIJK="$(curl -s -b "$COOKIES" "$API/api/goedkeuringen" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null)"
    [ "${NAKIJK:-0}" -gt 0 ] && letop "$NAKIJK taak/taken wachten op jouw oordeel (pagina Nakijken)" || goed "niets te nakijken"
  else
    mis "inloggen via de API mislukte"
  fi
else
  letop "geen wachtwoordbestand gevonden in $PB_DATA"
fi
echo

echo "Meldingen"
if [ -n "$WACHTWOORD" ] && [ -f "$COOKIES" ]; then
  MELD="$(curl -s -b "$COOKIES" "$API/api/meldingen" 2>/dev/null)"
  KANAAL="$(printf '%s' "$MELD" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("kanaal") or "")
except Exception: print("")' 2>/dev/null)"
  AAN="$(printf '%s' "$MELD" | python3 -c 'import json,sys
try: print("ja" if json.load(sys.stdin).get("aan") else "nee")
except Exception: print("nee")' 2>/dev/null)"
  if [ "$AAN" = "ja" ] && [ -n "$KANAAL" ]; then
    goed "meldkanaal staat aan: $KANAAL"
    LIJST="$(printf '%s' "$MELD" | python3 -c 'import json,sys
l = json.load(sys.stdin).get("lijst") or []
print("; ".join("%s: %s" % (x["soort"], x["uitkomst"]) for x in l[:3]))' 2>/dev/null)"
    [ -n "$LIJST" ] && printf '      laatste: %s\n' "$LIJST"
    printf '%s' "$MELD" | grep -q '"uitkomst":"verzonden' \
      && goed "minstens één melding is met succes verstuurd" \
      || letop "nog geen melding met succes verstuurd — probeer 'Proefmelding sturen' op de pagina Meldingen"
  else
    letop "geen meldkanaal ingesteld — de agent krijgt alleen meldingen als je taken zelf oppakt.
      Zet het adres op de pagina Meldingen (bijvoorbeeld de webhookroute van je agent)."
  fi
else
  letop "meldkanaal niet te controleren (geen sessie)"
fi
echo

printf 'Samenvatting: %d goed, %d aandacht, %d fout\n' "$ok" "$let_op" "$fout"
[ "$fout" -eq 0 ] || exit 1
