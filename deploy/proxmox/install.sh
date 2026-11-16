#!/usr/bin/env bash
# Ploegbaas — installatie op een Proxmox VE-host, in één regel.
#
# Draai dit als root in de shell van de Proxmox-host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Theberas04/ploegbaas/main/deploy/proxmox/install.sh)"
#
# Het script haalt de kit op naar /opt/ploegbaas-kit, pakt hem daar uit en draait
# create-ploegbaas-lxc.sh. De kit blijft staan, zodat check-ploegbaas.sh en
# diagnose-ploegbaas.sh daarna bij de hand zijn.
#
# Alles wat het maakscript kent mag je ervoor zetten:
#
#   CORES=2 MEMORY=4096 DISK=16 STATIC_IP=192.168.1.100/24 GATEWAY=192.168.1.1 \
#     PLOEGBAAS_LLM_URL=http://192.168.1.100:11434/v1 \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/Theberas04/ploegbaas/main/deploy/proxmox/install.sh)"
#
# Eerst alleen kijken wat er gebeurt, zonder iets aan te maken:
#   DROOG=1 bash -c "$(curl -fsSL .../install.sh)"
set -euo pipefail

REPO="${PB_REPO:-Theberas04/ploegbaas}"
TAK="${PB_TAK:-main}"
KIT="${PB_KIT_DIR:-/opt/ploegbaas-kit}"
DROOG="${DROOG:-0}"

log(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Draai dit als root op de Proxmox-host."
command -v pct >/dev/null || die "pct niet gevonden: dit is geen Proxmox VE-host."
command -v pveam >/dev/null || die "pveam niet gevonden: dit is geen Proxmox VE-host."
command -v curl >/dev/null || die "curl ontbreekt. Installeer het met: apt-get install -y curl"
command -v tar >/dev/null || die "tar ontbreekt."

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
URL="https://codeload.github.com/$REPO/tar.gz/refs/heads/$TAK"

if [ -e "$KIT" ]; then
  if [ -f "$KIT/deploy/proxmox/create-ploegbaas-lxc.sh" ]; then
    log "Oude kit in $KIT opruimen…"
    rm -rf "$KIT"
  else
    die "$KIT bestaat al en is niet de kit van deze app. Verplaats die map of geef een andere plek: PB_KIT_DIR=/pad/naar/kit"
  fi
fi
mkdir -p "$KIT"

log "Kit ophalen van $REPO ($TAK)…"
TARBALL="$(mktemp -t pb-kit.XXXXXXXX.tar.gz)"
trap 'rm -f "$TARBALL"' EXIT
if [ -n "$TOKEN" ]; then
  curl -fsSL --retry 3 -H "Authorization: Bearer ***" "$URL" -o "$TARBALL" \
    || die "Kon de kit niet ophalen. Klopt het token nog?"
else
  curl -fsSL --retry 3 "$URL" -o "$TARBALL" \
    || die "Kon de kit niet ophalen van $URL.
Staat de repo op privé? Zet dan een token ervoor: GH_TOKEN=... bash -c \"\$(curl ...)\""
fi

tar -xzf "$TARBALL" -C "$KIT" --strip-components=1
for f in server.mjs public/index.html deploy/proxmox/create-ploegbaas-lxc.sh deploy/proxmox/provision-ploegbaas.sh; do
  [ -f "$KIT/$f" ] || die "De kit is onvolledig: $f ontbreekt."
done

if [ "$DROOG" = "1" ]; then
  log "DROOG=1: ik maak niets aan. Dit zou er gebeuren:"
  echo "  - Debian 13-template zoeken (voor de architectuur van deze host) en een"
  echo "    unprivileged LXC aanmaken: ${CORES:-2} cores, ${MEMORY:-4096} MB, ${DISK:-16} GB"
  echo "  - Daarin: Node 24, Ploegbaas in /opt/ploegbaas, systemd-service op poort ${PLOEGBAAS_POORT:-8123}"
  echo "  - Meldingen: het meldkanaal staat klaar; de agent wordt meteen wakker bij nieuwe"
  echo "    taken en goedkeuringen (geen wachttijd), en elke gebeurtenis gaat als JSON naar"
  echo "    een webhook-adres dat je in het dashboard instelt"
  echo "  - Hermes Agent erbij installeren (HERMES_INSTALLEREN=${HERMES_INSTALLEREN:-1}), zodat de"
  echo "    agent echt werk kan doen; met PLOEGBAAS_LLM_URL wijst hij naar jouw eigen model"
  echo "  - Aan het eind: dashboard-URL en het wachtwoord"
  echo
  echo "Draai het echt met: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$REPO/$TAK/deploy/proxmox/install.sh)\""
  exit 0
fi

log "LXC aanmaken en inrichten…"
exec bash "$KIT/deploy/proxmox/create-ploegbaas-lxc.sh"
