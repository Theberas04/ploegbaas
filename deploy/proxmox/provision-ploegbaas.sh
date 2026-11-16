#!/usr/bin/env bash
# Richt Ploegbaas in binnen een Debian-container. Draai als root:
#   bash provision-ploegbaas.sh
#
# Dit is de in-guest helft van de kit; create-ploegbaas-lxc.sh duwt hem naar
# binnen en draait hem. Los te gebruiken in een bestaande container.
#
# Bij te sturen met env-variabelen:
#   PLOEGBAAS_POORT=8123            poort van het dashboard
#   PLOEGBAAS_WACHTWOORD=...        anders wordt er één gegenereerd
#   PLOEGBAAS_LLM_URL=http://192.168.1.100:11434/v1   jouw eigen model (OpenAI-compatibel)
#   PLOEGBAAS_LLM_MODEL=Llama-3.2-3B-Instruct-Q4_K_M  welk model-id daarop
#   PLOEGBAAS_MELDWEBHOOK=http://... de webhook waar meldingen heen gaan
#   HERMES_INSTALLEREN=0            sla het installeren van de Hermes Agent over
set -euo pipefail

PB_POORT="${PLOEGBAAS_POORT:-8123}"
PB_MAP="${PLOEGBAAS_MAP:-/opt/ploegbaas}"
PB_DATA="${PLOEGBAAS_DATA:-/opt/ploegbaas/data}"
NODE_MAP="${NODE_MAP:-/opt/node24}"
NODE_VERSIE="${NODE_VERSIE:-24.22.3}"
MELDWEBHOOK="${PLOEGBAAS_MELDWEBHOOK:-}"
LLM_URL="${PLOEGBAAS_LLM_URL:-}"
LLM_MODEL="${PLOEGBAAS_LLM_MODEL:-}"
ALIAS="${PLOEGBAAS_LLM_ALIAS:-eigen}"
HERMES_DOEN="${HERMES_INSTALLEREN:-1}"
LOGIN_BESTAND="/root/ploegbaas-login.txt"
API="http://127.0.0.1:$PB_POORT"

log(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Draai dit als root."
[ -f "$PB_MAP/server.mjs" ] || die "$PB_MAP/server.mjs ontbreekt — draai dit vanuit de kit."

# --- 1. Basispakketten en Node --------------------------------------------------
# Ploegbaas gebruikt node:sqlite; de Node uit Debian is te oud (het moet 22.5 of
# hoger zijn). Node komt daarom naast de systeemversie in /opt/node24 te staan.
if ! "$NODE_MAP/bin/node" --version >/dev/null 2>&1; then
  log "Basispakketten installeren…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null || true
  apt-get install -y -qq ca-certificates curl xz-utils tar procps python3 git jq openssh-client >/dev/null

  log "Node $NODE_VERSIE ophalen…"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  case "$(dpkg --print-architecture)" in
    arm64) NODE_ARCH="arm64" ;;
    *) NODE_ARCH="x64" ;;
  esac
  curl -fsSL --retry 3 -o "$TMP/node.tar.xz" \
    "https://nodejs.org/dist/v$NODE_VERSIE/node-v$NODE_VERSIE-linux-$NODE_ARCH.tar.xz" \
    || die "Kon Node $NODE_VERSIE niet ophalen."
  mkdir -p "$NODE_MAP"
  tar -xJf "$TMP/node.tar.xz" -C "$NODE_MAP" --strip-components=1
  for b in node npm npx; do ln -sf "$NODE_MAP/bin/$b" "/usr/local/bin/$b"; done
fi
log "Node: $(node --version)"

# --- 2. Als service draaien ------------------------------------------------------
# De agent die Ploegbaas aanstuurt is de Hermes Agent; die komt in /root/.local/bin
# te staan, dus dat pad moet in de PATH van de service. Zonder dat vindt de
# hermes-adapter zijn commando niet.
mkdir -p "$PB_DATA" "$(dirname "$LOGIN_BESTAND")"
cat > /etc/systemd/system/ploegbaas.service <<EOF
[Unit]
Description=Ploegbaas — dashboard om een ploeg AI-agenten aan het werk te zetten
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$PB_MAP
Environment="PLOEGBAAS_POORT=$PB_POORT"
Environment="PLOEGBAAS_DATA=$PB_DATA"
Environment="PATH=/root/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin"
ExecStart=/usr/local/bin/node --no-warnings $PB_MAP/server.mjs
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=20
StandardOutput=append:$PB_DATA/ploegbaas.log
StandardError=append:$PB_DATA/ploegbaas.log

[Install]
WantedBy=multi-user.target
EOF
# Het meldkanaal mag ook via de omgeving komen; de pagina Meldingen kan het later
# overschrijven, want de instelling in de database gaat vóór.
if [ -n "$MELDWEBHOOK" ]; then
  sed -i "/^Environment=\"PLOEGBAAS_DATA/a Environment=\"PLOEGBAAS_MELDWEBHOOK=$MELDWEBHOOK\"" \
    /etc/systemd/system/ploegbaas.service
fi
systemctl daemon-reload
systemctl enable --now ploegbaas.service >/dev/null 2>&1 || true

log "Wachten tot het dashboard antwoordt…"
GEZOND=0
for i in $(seq 1 60); do
  if curl -s -m 3 "$API/api/gezondheid" | grep -q '"status":"ok"'; then GEZOND=1; break; fi
  sleep 2
done
[ "$GEZOND" = "1" ] || die "De server werd niet gezond. Laatste regels:
$(tail -20 "$PB_DATA/ploegbaas.log" 2>/dev/null)"

WACHTWOORD="$(cat "$PB_DATA/wachtwoord.txt" 2>/dev/null || echo '')"
[ -n "$WACHTWOORD" ] || die "Geen wachtwoord gevonden in $PB_DATA/wachtwoord.txt."
EIGEN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

# --- 3. Hermes Agent erbij (de agent die het werk doet) -------------------------
HERMES_PAD=""
if [ "$HERMES_DOEN" = "1" ]; then
  if command -v hermes >/dev/null 2>&1; then
    HERMES_PAD="$(command -v hermes)"
  else
    log "Hermes Agent installeren (de agent die de taken uitvoert)…"
    if curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash >/tmp/hermes-install.log 2>&1; then
      export PATH="$HOME/.local/bin:$PATH"
      command -v hermes >/dev/null 2>&1 && HERMES_PAD="$(command -v hermes)"
    else
      warn "Hermes installeren mislukte; zie /tmp/hermes-install.log. De adapters 'opdracht' en 'http' werken wel."
    fi
  fi
fi
if [ -n "$HERMES_PAD" ]; then
  log "Hermes gevonden: $HERMES_PAD ($("$HERMES_PAD" --version 2>/dev/null | head -1 || echo '?') )"
else
  warn "Geen Hermes Agent: het klaarstaande proefje op de hermes-adapter doet niets. Installeer hem later met:
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
fi

# Eigen model: één alias in Hermes, en die alias op de agent in Ploegbaas. Zo
# draait het agentwerk op jouw eigen LLM in plaats van op een cloudmodel.
if [ -n "$HERMES_PAD" ] && [ -n "$LLM_URL" ] && [ -n "$LLM_MODEL" ]; then
  log "Eigen model koppelen: $LLM_MODEL via $LLM_URL"
  "$HERMES_PAD" config set "model_aliases.$ALIAS.model" "$LLM_MODEL" >/dev/null 2>&1 || warn "model_aliases.$ALIAS.model zetten mislukte."
  "$HERMES_PAD" config set "model_aliases.$ALIAS.provider" custom >/dev/null 2>&1 || warn "provider zetten mislukte."
  "$HERMES_PAD" config set "model_aliases.$ALIAS.base_url" "$LLM_URL" >/dev/null 2>&1 || warn "base_url zetten mislukte."
  "$HERMES_PAD" config set "model_aliases.$ALIAS.api_key" "lokaal" >/dev/null 2>&1 || true
  "$HERMES_PAD" config set model "$ALIAS" >/dev/null 2>&1 || warn "standaardmodel zetten mislukte; kies hem met: hermes model"
  if curl -s -m 3 "${LLM_URL%/v1}/models" >/dev/null 2>&1 || curl -s -m 3 "${LLM_URL}/models" >/dev/null 2>&1; then
    log "Het model antwoordt op $LLM_URL."
  else
    warn "Geen antwoord van $LLM_URL — controleer het adres; de agent valt terug op zijn eigen modelkeuze."
  fi
elif [ -z "$LLM_URL" ]; then
  warn "Geen PLOEGBAAS_LLM_URL meegegeven: het agentwerk gebruikt dan het model dat Hermes zelf al kent.
Wil je je eigen LLM gebruiken, geef dan mee: PLOEGBAAS_LLM_URL=http://<adres>:11434/v1 PLOEGBAAS_LLM_MODEL=<model-id>"
fi

# --- 4. Praktisch: meldkanaal, netwerk en een proeftaak -------------------------
COOKIES=/tmp/pb-cookies.txt
curl -s -c "$COOKIES" -X POST "$API/api/inloggen" -H 'Content-Type: application/json' \
  -d "{\"wachtwoord\":\"$WACHTWOORD\"}" >/dev/null || warn "Inloggen via de API mislukte."
api(){
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -s -X "$m" "$API$p" -b "$COOKIES" -H 'Content-Type: application/json' -d "$d"
  else
    curl -s -X "$m" "$API$p" -b "$COOKIES"
  fi
}

if [ -n "$MELDWEBHOOK" ]; then
  log "Meldkanaal instellen op $MELDWEBHOOK…"
  api PATCH /api/instellingen \
    "{\"melden_aan\":true,\"meld_kanaal\":\"$MELDWEBHOOK\"}" >/dev/null \
    || warn "Meldkanaal instellen mislukte; doe het in het dashboard bij Meldingen."
fi

# De agent die klaarstaat, laten wijzen naar de eigen-LLM-alias.
if [ -n "$HERMES_PAD" ] && [ -n "$LLM_URL" ] && [ -n "$LLM_MODEL" ]; then
  AID="$(api GET /api/agenten | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(next((a["id"] for a in d if a.get("adapter")=="hermes"), ""))' 2>/dev/null || true)"
  [ -n "$AID" ] && api PATCH "/api/agenten/$AID" "{\"model\":\"$ALIAS\"}" >/dev/null \
    && log "Agent $AID draait op de alias '$ALIAS' (jouw eigen model)."
fi

if [ -n "$HERMES_PAD" ]; then
  log "Proeftaak: laat de agent echt iets doen…"
  rm -f /tmp/ploegbaas-proef.txt
  TID="$(api POST /api/taken '{"titel":"Proeftaak: schrijf een bestand","omschrijving":"Maak het bestand /tmp/ploegbaas-proef.txt met daarin één regel: Ploegbaas werkt.","agent_id":1,"prioriteit":"hoog"}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [ -n "$TID" ]; then
    STATUS=""
    for i in $(seq 1 60); do
      sleep 5
      STATUS="$(api GET "/api/taken/$TID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
      case "$STATUS" in review|klaar|geblokkeerd) break ;; esac
    done
    log "Taak $TID staat op: ${STATUS:-onbekend}"
    if [ -f /tmp/ploegbaas-proef.txt ]; then
      log "Bewijs op schijf: $(cat /tmp/ploegbaas-proef.txt)"
    else
      warn "De agent heeft het proefbestand (nog) niet geschreven; kijk in het dashboard bij de taak."
    fi
  fi
fi

# --- 5. Inloggegevens opbergen ---------------------------------------------------
( umask 077; cat > "$LOGIN_BESTAND" <<EOF
Ploegbaas — dashboard voor de ploeg AI-agenten
Adres:      http://${EIGEN_IP:-localhost}:$PB_POORT
Wachtwoord: $WACHTWOORD

Wachtwoordbestand: $PB_DATA/wachtwoord.txt
Gegevens:          $PB_DATA/ploegbaas.db  (back-up maken = dit bestand kopiëren)
Log:               $PB_DATA/ploegbaas.log
Meldingen:         vul bij "Meldingen" het webhook-adres in waar de agent op luistert
EOF
)
chmod 600 "$LOGIN_BESTAND"

printf '\n\033[1;32mPloegbaas staat klaar.\033[0m\n'
echo "  Dashboard:  http://${EIGEN_IP:-localhost}:$PB_POORT"
echo "  Wachtwoord: $LOGIN_BESTAND lezen (of $PB_DATA/wachtwoord.txt)"
echo "  Agent:      ${HERMES_PAD:-niet geïnstalleerd}"
echo "  Meldingen:  ${MELDWEBHOOK:-nog niet ingesteld — vul het in bij Meldingen in het dashboard}"
echo
echo "Controleren:  bash /opt/ploegbaas-kit/check-ploegbaas.sh"
