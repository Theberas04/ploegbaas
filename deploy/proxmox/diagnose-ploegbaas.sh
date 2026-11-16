#!/usr/bin/env bash
# Zoekt op de Proxmox-host uit waarom de container niet start of niet doorloopt.
# Draai als root op de host:
#   CTID=110 bash diagnose-ploegbaas.sh
set -uo pipefail

CTID="${CTID:-}"
[ -n "$CTID" ] || { echo "[fout] Geef het containernummer mee: CTID=110 bash diagnose-ploegbaas.sh" >&2; exit 1; }
log(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
kop(){ printf '\n\033[1m--- %s ---\033[0m\n' "$*"; }

kop "Host"
printf '  %s | kernel %s | lxc %s | cgroups %s\n' \
  "$(pveversion 2>/dev/null || echo 'geen pveversion')" "$(uname -r)" \
  "$(lxc-start --version 2>/dev/null || echo '?')" "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo '?')"

kop "Container $CTID"
pct status "$CTID" 2>&1 || echo "  (container bestaat niet of pct kan er niet bij)"
pct config "$CTID" 2>/dev/null | grep -E '^(hostname|cores|memory|rootfs|net0|unprivileged|features|onboot)' || true

kop "De laatste startpoging, met uitleg"
# De algemene regels ('Failed to spawn container') zeggen zelf nooit waarom; de
# oorzaak staat erboven en is alleen met --debug te lezen.
if pct status "$CTID" 2>/dev/null | grep -q running; then
  echo "  De container draait; alleen de laatste meldingen van het opstarten:"
  journalctl -u "pve-container@$CTID" -n 15 --no-pager 2>/dev/null | tail -10 || true
else
  pct start "$CTID" --debug 2>&1 | tail -30 | sed 's/^/    /'
  echo
  echo "  Herkenning (eerste passende regel geldt):"
  LOG="$(pct start "$CTID" --debug 2>&1 || true)"
  case "$LOG" in
    *'Failed to exec "/sbin/init"'*|*'/etc not present in CT'*|*'unexpected ostype'*)
      echo "    De rootfs is leeg of niet uitgepakt — meestal de opslag (NAS met root_squash)."
      echo "    Doe: pct destroy $CTID   en daarna opnieuw met een andere opslag:"
      echo "         ROOTFS_STORAGE=local-lvm bash create-ploegbaas-lxc.sh" ;;
    *'symlink encountered'*)
      echo "    Het opslagpad is een symlink (iSCSI/LVM op PVE 9). Kies een andere opslag voor de schijf." ;;
    *'Failed to clone a new set of namespaces'*|*'Failed to mount "proc"'*|*'Failed to load bpf program'*)
      echo "    De host houdt alle containers tegen (kernel- of lxc-update)."
      echo "    Doe: apt-get install -y --reinstall lxc-pve apparmor && systemctl restart apparmor"
      echo "    (of herstart de host als dat niet helpt)" ;;
    *'Failed to set up id mapping'*|*'newuidmap failed'*)
      echo "    /etc/subuid en /etc/subgid op de host missen de root-regel."
      echo "    Voeg in beide bestanden toe:  root:100000:65536" ;;
    *'apparmor'*|*'autodev hooks'*)
      echo "    AppArmor-profiel of hook houdt de start tegen."
      echo "    Probeer: pct set $CTID --features \"\"   en kijk met: aa-status" ;;
    *'Failed to mount'*)
      echo "    Er is een bind mount die niet bestaat. Kijk naar de mp/lxc.mount-regels:"
      pct config "$CTID" 2>/dev/null | grep -E '^(mp|lxc\.mount)' || true ;;
    *)
      echo "    Onbekend patroon. Bewaar het volledige log en stuur het door:"
      pct start "$CTID" --debug > "/tmp/ploegbaas-start-$CTID.log" 2>&1 || true
      echo "    /tmp/ploegbaas-start-$CTID.log" ;;
  esac
fi

if pct status "$CTID" 2>/dev/null | grep -q running; then
  kop "Binnenin: netwerk"
  pct exec "$CTID" -- ip -brief addr 2>&1 | head -5 || true
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 \
    && echo "  DNS werkt" || echo "  [fout] DNS werkt niet in de container (bridge/gateway/resolver)"
  pct exec "$CTID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 \
    && echo "  route naar buiten werkt" || echo "  [fout] geen route naar buiten"

  kop "Binnenin: installatie"
  pct exec "$CTID" -- node --version 2>/dev/null || echo "  node ontbreekt"
  pct exec "$CTID" -- test -f /opt/ploegbaas/server.mjs \
    && echo "  Ploegbaas staat in /opt/ploegbaas" || echo "  [fout] /opt/ploegbaas/server.mjs ontbreekt"
  pct exec "$CTID" -- systemctl is-active ploegbaas.service 2>/dev/null || true
  pct exec "$CTID" -- journalctl -u ploegbaas.service -n 25 --no-pager 2>/dev/null | tail -18 || true
  pct exec "$CTID" -- tail -20 /opt/ploegbaas/data/ploegbaas.log 2>/dev/null || true

  kop "Controle in de container"
  pct exec "$CTID" -- bash /opt/ploegbaas-kit/check-ploegbaas.sh 2>/dev/null || true
fi
