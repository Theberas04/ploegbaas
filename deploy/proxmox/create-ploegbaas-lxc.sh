#!/usr/bin/env bash
# Maakt een unprivileged Debian-LXC aan en richt daar Ploegbaas in.
# Draai als root op de Proxmox-host:  bash create-ploegbaas-lxc.sh
#
# Bij te sturen met env-variabelen, bijvoorbeeld:
#   CORES=4 MEMORY=8192 STATIC_IP=192.168.1.100/24 GATEWAY=192.168.1.1 \
#     PLOEGBAAS_LLM_URL=http://192.168.1.100:11434/v1 bash create-ploegbaas-lxc.sh
set -euo pipefail

CTID="${CTID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-ploegbaas}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
STATIC_IP="${STATIC_IP:-}"
GATEWAY="${GATEWAY:-}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
# Ploegbaas zelf is licht (Node + SQLite). De agent die er werk in doet (Hermes)
# heeft de ruimte nodig: 2 cores/4 GB is het minimum, 4 cores/8 GB werkt prettig
# als de agent ook bouwt of test.
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"
SWAP="${SWAP:-1024}"
DISK="${DISK:-16}"
DEBIAN_MAJOR="${DEBIAN_MAJOR:-13}"
PLOEGBAAS_POORT="${PLOEGBAAS_POORT:-8123}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

log(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Draai dit als root op de Proxmox-host."
command -v pct >/dev/null || die "pct niet gevonden: dit is geen Proxmox VE-host."
command -v pveam >/dev/null || die "pveam niet gevonden."
[ -f "$SCRIPT_DIR/provision-ploegbaas.sh" ] || die "$SCRIPT_DIR/provision-ploegbaas.sh ontbreekt."
[ -f "$APP_DIR/server.mjs" ] || die "$APP_DIR/server.mjs ontbreekt — draai dit vanuit de kit."
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' bestaat niet."

case "$ARCH" in
  amd64) ARCH_NAAM="x86-64" ;;
  arm64) ARCH_NAAM="arm64" ;;
  *) die "Onbekende architectuur '$ARCH'. Deze kit is er voor amd64 (Intel/AMD) en arm64." ;;
esac
log "Host: $ARCH ($ARCH_NAAM)"

# --- Opslag kiezen: lokaal eerst, en proeven of root er mag schrijven ----------
# Een NAS als opslag geeft 'Permission denied' (root_squash): dan mislukt het
# downloaden van de template en het maken van de schijf.
opslag_kandidaten(){
  pvesm status --content "$1" 2>/dev/null | awk 'NR>1 && $3=="active"{
      t=$2
      p = (t=="lvmthin" || t=="zfspool" || t=="btrfs") ? 1 : (t=="lvm" || t=="dir") ? 2 : 3
      printf "%d %019d %s\n", p, 999999999999999999-$6, $1
    }' | sort | awk '{print $3}'
}
opslag_pad(){
  local s="$1" t pad
  t="$(pvesm status 2>/dev/null | awk -v s="$s" 'NR>1 && $1==s{print $2}')"
  pad="$(awk -v s="$s" '$1 ~ /:$/ {naam=$2} naam==s && $1=="path" {print $2; exit}' \
    /etc/pve/storage.cfg 2>/dev/null)"
  if [ -z "$pad" ]; then
    case "$t" in nfs|cifs|glusterfs) pad="/mnt/pve/$s" ;; esac
  fi
  printf '%s' "$pad"
}
opslag_schrijfbaar(){
  local pad; pad="$(opslag_pad "$1")"
  [ -n "$pad" ] || return 0
  [ -d "$pad" ] || return 1
  local proef="$pad/.pb-schrijfproef.$$"
  touch "$proef" 2>/dev/null || return 1
  rm -f "$proef"; return 0
}
kies_opslag(){
  local k
  for k in $(opslag_kandidaten "$1"); do
    if opslag_schrijfbaar "$k"; then printf '%s' "$k"; return 0; fi
    warn "Opslag '$k' is niet beschrijfbaar door root (bijvoorbeeld een NAS met root_squash); ik sla die over."
  done
  return 1
}

if [ -z "$ROOTFS_STORAGE" ]; then
  ROOTFS_STORAGE="$(kies_opslag rootdir)" || die "Geen beschrijfbare opslag gevonden voor de schijf.
Kijk zelf met: pvesm status --content rootdir
Wijs er een aan met: ROOTFS_STORAGE=<naam> ..."
fi
if [ -z "$TEMPLATE_STORAGE" ]; then
  TEMPLATE_STORAGE="$(kies_opslag vztmpl)" || TEMPLATE_STORAGE="local"
fi
log "Schijf op '$ROOTFS_STORAGE', template op '$TEMPLATE_STORAGE'"

if [ -n "$STATIC_IP" ]; then
  [ -n "$GATEWAY" ] || die "Geef GATEWAY op bij STATIC_IP."
  NET0="name=eth0,bridge=$BRIDGE,ip=$STATIC_IP,gw=$GATEWAY,type=veth"
else
  NET0="name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth"
fi

if [ -z "$CTID" ]; then CTID="$(pvesh get /cluster/nextid 2>/dev/null || true)"; fi
[ -n "$CTID" ] || die "Kon geen vrij CTID bepalen; geef CTID=... mee."
pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID bestaat al."

# --- Template -----------------------------------------------------------------
log "Debian $DEBIAN_MAJOR-template zoeken voor $ARCH_NAAM…"
pveam update >/dev/null 2>&1 || warn "pveam update mislukte; de lokale lijst wordt gebruikt."
# De lijst bevat templates voor meerdere architecturen; zonder filter pakt
# 'sort -V | tail -1' de arm64-versie en start de container niet.
TEMPLATE="$(pveam available --section system 2>/dev/null \
  | awk -v m="$DEBIAN_MAJOR" -v a="$ARCH_NAAM" '$2 ~ ("^debian-" m "\\..*" a "\\.tar") {print $2}' \
  | sort -V | tail -1 || true)"
[ -n "$TEMPLATE" ] || die "Geen Debian-$DEBIAN_MAJOR-template gevonden voor $ARCH_NAAM. Draai 'pveam update' en probeer opnieuw."
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  log "Template $TEMPLATE downloaden naar '$TEMPLATE_STORAGE'…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || die "Template downloaden mislukte."
fi
log "Template: $TEMPLATE"

# --- Container ------------------------------------------------------------------
log "Container $CTID aanmaken ($CORES cores, ${MEMORY} MB, ${DISK} GB)…"
if ! pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
  --rootfs "$ROOTFS_STORAGE:$DISK" \
  --net0 "$NET0" \
  --nameserver "$DNS_SERVER" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 >/dev/null; then
  die "pct create mislukte. Kijk met: diagnose-ploegbaas.sh (op de host)."
fi

if ! pct start "$CTID"; then
  warn "Container $CTID startte niet. De oorzaak staat in de regels hierboven;"
  warn "dit is de volledige uitleg van de laatste poging:"
  pct start "$CTID" --debug 2>&1 | tail -25 | sed 's/^/    /'
  die "De container is aangemaakt maar draait niet.
Voor gewone taal bij de oorzaak:  CTID=$CTID bash $SCRIPT_DIR/diagnose-ploegbaas.sh
Weghalen kan met: pct destroy $CTID"
fi

log "Wachten tot de container netwerk heeft…"
for i in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  [ "$i" -eq 60 ] && die "De container kreeg geen netwerk. Controleer bridge '$BRIDGE' en DNS."
  sleep 2
done

# --- Inrichten ------------------------------------------------------------------
log "Bestanden naar de container brengen…"
pct exec "$CTID" -- mkdir -p /opt/ploegbaas-kit /opt/ploegbaas/public
pct push "$CTID" "$APP_DIR/server.mjs" /opt/ploegbaas/server.mjs
pct push "$CTID" "$APP_DIR/public/index.html" /opt/ploegbaas/public/index.html
if [ -f "$APP_DIR/README.md" ]; then
  pct exec "$CTID" -- mkdir -p /opt/ploegbaas/docs
  pct push "$CTID" "$APP_DIR/README.md" /opt/ploegbaas/docs/README.md
fi
for s in provision-ploegbaas.sh check-ploegbaas.sh; do
  [ -f "$SCRIPT_DIR/$s" ] && pct push "$CTID" "$SCRIPT_DIR/$s" "/opt/ploegbaas-kit/$s"
done
pct exec "$CTID" -- chmod +x /opt/ploegbaas-kit/*.sh 2>/dev/null || true

PUSH_ENV=()
for v in PLOEGBAAS_POORT PLOEGBAAS_WACHTWOORD PLOEGBAAS_LLM_URL PLOEGBAAS_LLM_MODEL \
         PLOEGBAAS_MELDWEBHOOK HERMES_INSTALLEREN BEDRIJF AGENT_NAAM; do
  eval "w=\${$v:-}"
  [ -n "$w" ] && PUSH_ENV+=("$v=$w")
done
PUSH_ENV+=("PLOEGBAAS_POORT=$PLOEGBAAS_POORT")

log "Ploegbaas inrichten in container $CTID…"
pct exec "$CTID" -- env "${PUSH_ENV[@]}" bash /opt/ploegbaas-kit/provision-ploegbaas.sh

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n\033[1;32mKlaar.\033[0m\n'
printf '  Dashboard:  http://%s:%s\n' "${IP:-<ip-van-container>}" "$PLOEGBAAS_POORT"
printf '  Wachtwoord: staat in de container in /root/ploegbaas-login.txt\n'
printf '  Controle:   pct exec %s -- bash /opt/ploegbaas-kit/check-ploegbaas.sh\n' "$CTID"
printf '  Bij storing:CTID=%s bash %s/diagnose-ploegbaas.sh\n\n' "$CTID" "$SCRIPT_DIR"
