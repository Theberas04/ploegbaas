#!/bin/bash
# Geeft de Hermes-agent in zijn container ssh-toegang tot de Proxmox-nodes,
# zodat hij pct/qm kan gebruiken. Draai dit als root op een node van het cluster:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Theberas04/ploegbaas/main/deploy/proxmox/geef-proxmox-toegang.sh)"
#
# Met CTID=102 kies je zelf de container; zonder die variabele zoekt het script de
# draaiende container waarin de Hermes-agent zit.
#
# Dit geeft volledige root-toegang tot de Proxmox-hosts. Weghalen: haal op elke
# node de regel met "hermes-ict-agent" uit /root/.ssh/authorized_keys.
set -euo pipefail

zeg()  { printf '%s\n' "$*"; }
stap() { printf '\n== %s ==\n' "$*"; }
fout() { printf 'FOUT: %s\n' "$*" >&2; exit 1; }
q()    { printf '%q' "$1"; }   # elk argument apart quoten voor de remote shell

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

# --- 0. het cluster --------------------------------------------------------
stap "0. cluster"
DEZE=$(hostname -s)
[ -d /etc/pve/nodes ] || fout "dit is geen Proxmox-node (/etc/pve/nodes ontbreekt)"
NODES=$(ls /etc/pve/nodes)
zeg "   deze host: $DEZE | nodes: $(echo "$NODES" | tr '\n' ' ')"
declare -A ADRES
for n in $NODES; do
  a=$(awk -v n="$n" '$1=="name:"{naam=$2} $1=="ring0_addr:"{if(naam==n){print $2; exit}}' /etc/pve/corosync.conf)
  [ -n "$a" ] || fout "geen adres voor node $n in /etc/pve/corosync.conf"
  ADRES[$n]=$a
  zeg "   node $n → $a"
done

# voert een commando uit op een node: lokaal, of via ssh op de andere node.
# </dev/null omdat pct en ssh anders de regels van een aanroepende leeslus opeten.
op_node() {
  local n="$1"; shift
  if [ "$n" = "$DEZE" ]; then
    "$@" </dev/null
  else
    $SSH root@"${ADRES[$n]}" "$(printf '%q ' "$@")" </dev/null
  fi
}

# --- 1. de container met de agent -----------------------------------------
stap "1. waar staat de agent?"
AGENT_NODE=""
if [ -n "${CTID:-}" ]; then
  zeg "   CTID=$CTID (zelf opgegeven)"
  for n in $NODES; do
    if op_node "$n" pct status "$CTID" >/dev/null 2>&1; then AGENT_NODE=$n; fi
  done
  [ -n "$AGENT_NODE" ] || fout "container $CTID bestaat niet in dit cluster"
else
  for n in $NODES; do
    zeg "   -- node $n --"
    while read -r cid status naam; do
      [ "$status" = "running" ] || continue
      if op_node "$n" pct exec "$cid" -- sh -c 'grep -qs API_SERVER_KEY /home/hermes/.hermes/.env /root/.hermes/.env' 2>/dev/null; then
        zeg "      container $cid ($naam): Hermes-agent ja"
        if [ -z "$AGENT_NODE" ]; then AGENT_NODE=$n; CTID=$cid; fi
      else
        zeg "      container $cid ($naam): nee"
      fi
    done < <(op_node "$n" pct list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $2, $NF}')
  done
  [ -n "$AGENT_NODE" ] || fout "geen draaiende container met een Hermes-agent gevonden; geef CTID=... mee"
fi
zeg "   gevonden: node $AGENT_NODE, container $CTID"

# --- 2. een sleutel in de container ---------------------------------------
stap "2. sleutel in de container"
op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c 'command -v ssh-keygen >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq openssh-client; }'
SLEUTEL=$(op_node "$AGENT_NODE" pct exec "$CTID" -- cat /root/.ssh/id_ed25519.pub 2>/dev/null || true)
if [ -z "$SLEUTEL" ]; then
  op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -q -t ed25519 -N "" -C "hermes-ict-agent@$(hostname)" -f /root/.ssh/id_ed25519'
  SLEUTEL=$(op_node "$AGENT_NODE" pct exec "$CTID" -- cat /root/.ssh/id_ed25519.pub)
  zeg "   nieuwe sleutel gemaakt"
else
  zeg "   bestaande sleutel gebruikt"
fi
[ -n "$SLEUTEL" ] || fout "kon geen sleutel in container $CTID maken"
zeg "   $(echo "$SLEUTEL" | awk '{print $1, substr($2,1,16)"…", $3}')"
# ook beschikbaar maken voor de gebruiker(s) in de container, niet alleen root
op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c 'for h in /home/*; do [ -d "$h" ] || continue; u=$(basename "$h"); mkdir -p "$h/.ssh" && chmod 700 "$h/.ssh"; cp -n /root/.ssh/id_ed25519 "$h/.ssh/id_ed25519" 2>/dev/null || true; cp -n /root/.ssh/id_ed25519.pub "$h/.ssh/id_ed25519.pub" 2>/dev/null || true; chown -R "$u:$u" "$h/.ssh" 2>/dev/null || true; chmod 600 "$h/.ssh/id_ed25519" 2>/dev/null || true; done; true'

# --- 3. de sleutel op elke node -------------------------------------------
stap "3. toegang op de nodes"
TOEVOEGEN="mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && { grep -qF $(q "$SLEUTEL") /root/.ssh/authorized_keys || echo $(q "$SLEUTEL") >> /root/.ssh/authorized_keys; }"
for n in $NODES; do
  if [ "$n" = "$DEZE" ]; then
    if bash -c "$TOEVOEGEN"; then zeg "   node $n: sleutel staat erin"; else zeg "   node $n: NIET gelukt"; fi
  else
    if $SSH root@"${ADRES[$n]}" "$TOEVOEGEN"; then zeg "   node $n: sleutel staat erin"; else zeg "   node $n: NIET gelukt"; fi
  fi
done

# --- 4. proef: kan de agent er zelf bij? ----------------------------------
stap "4. proef: kan de agent bij de nodes?"
for n in $NODES; do
  uit=$(op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c "$SSH root@${ADRES[$n]} 'hostname -s; pct list | head -3'" 2>&1 || true)
  if echo "$uit" | grep -qx "$n"; then
    zeg "   node $n: OK — $(echo "$uit" | tail -n +2 | head -2 | tr '\n' ' ')"
  else
    zeg "   node $n: NIET gelukt — $(echo "$uit" | tr '\n' ' ')"
  fi
done

# --- 5. klaar -------------------------------------------------------------
stap "5. klaar"
zeg "De agent in container $CTID (node $AGENT_NODE) kan nu als root op: $(echo "$NODES" | tr '\n' ' ')"
zeg "Hij kan daarmee pct/qm gebruiken, maar ook alles anders op de host — het is root."
zeg "Weghalen: haal op elke node de regel met hermes-ict-agent uit /root/.ssh/authorized_keys."
