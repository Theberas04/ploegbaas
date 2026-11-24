#!/bin/bash
# Geeft één Hermes-agent ssh-toegang tot de Proxmox-nodes — en niet meer dan dat.
#
# Draai dit als root op een node van het cluster:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Theberas04/ploegbaas/main/deploy/proxmox/geef-proxmox-toegang.sh)"
#
# Wat het op elke node regelt:
#   - gebruiker "hermes": geen wachtwoord, alleen deze sleutel
#   - die sleutel werkt alleen vanaf het adres van de agent-container (VANAF=…)
#   - sudo alleen voor /usr/sbin/pct en /usr/sbin/qm — containers en VM's beheren,
#     maar niets anders op de host
#   - de sleutel van de eerdere root-variant wordt uit /root/.ssh/authorized_keys gehaald
#
# Opties: CTID=102 (anders zoekt het script de container), VANAF=192.168.1.248 of een
# kommalijst, GEBRUIKER=hermes. Weghalen: rm /etc/sudoers.d/hermes-ict en haal de regel
# met hermes-ict-agent uit /home/hermes/.ssh/authorized_keys op elke node.
set -euo pipefail

zeg()  { printf '%s\n' "$*"; }
stap() { printf '\n== %s ==\n' "$*"; }
fout() { printf 'FOUT: %s\n' "$*" >&2; exit 1; }
q()    { printf '%q' "$1"; }   # elk argument apart quoten voor de remote shell

GEBRUIKER=${GEBRUIKER:-hermes}
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

# --- 3. vanaf welk adres mag de sleutel werken? ---------------------------
stap "3. vanaf welk adres mag de sleutel werken?"
if [ -z "${VANAF:-}" ]; then
  VANAF=$(op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c "hostname -I 2>/dev/null | awk '{print \$1}'" | tr -d '\r' || true)
  [ -n "$VANAF" ] || fout "kon het adres van container $CTID niet bepalen; geef VANAF=... mee"
  zeg "   automatisch: $VANAF (het adres van container $CTID)"
else
  zeg "   zelf opgegeven: $VANAF"
fi

# --- 4. toegang op elke node ----------------------------------------------
stap "4. toegang op de nodes"
HUIS=/home/$GEBRUIKER
REGELS=$(cat <<EINDE
set -e
id -u $(q "$GEBRUIKER") >/dev/null 2>&1 || useradd -m -s /bin/bash $(q "$GEBRUIKER")
mkdir -p $(q "$HUIS/.ssh")
chmod 700 $(q "$HUIS/.ssh")
touch $(q "$HUIS/.ssh/authorized_keys")
sed -i '/hermes-ict-agent/d' $(q "$HUIS/.ssh/authorized_keys")
echo $(q "from=\"$VANAF\",restrict,pty $SLEUTEL") >> $(q "$HUIS/.ssh/authorized_keys")
chmod 600 $(q "$HUIS/.ssh/authorized_keys")
chown -R $(q "$GEBRUIKER"):$(q "$GEBRUIKER") $(q "$HUIS/.ssh")
printf '%s\n' $(q "$GEBRUIKER ALL=(root) NOPASSWD: /usr/sbin/pct, /usr/sbin/qm") > /etc/sudoers.d/hermes-ict.tmp
chmod 440 /etc/sudoers.d/hermes-ict.tmp
visudo -cf /etc/sudoers.d/hermes-ict.tmp >/dev/null
mv -f /etc/sudoers.d/hermes-ict.tmp /etc/sudoers.d/hermes-ict
if [ -f /root/.ssh/authorized_keys ]; then sed -i '/hermes-ict-agent/d' /root/.ssh/authorized_keys; fi
EINDE
)
for n in $NODES; do
  if [ "$n" = "$DEZE" ]; then
    if bash -c "$REGELS"; then zeg "   node $n: gebruiker $GEBRUIKER + sudo pct/qm geregeld"; else zeg "   node $n: NIET gelukt"; fi
  else
    if $SSH root@"${ADRES[$n]}" "$REGELS"; then zeg "   node $n: gebruiker $GEBRUIKER + sudo pct/qm geregeld"; else zeg "   node $n: NIET gelukt"; fi
  fi
done

# --- 5. proef: wat mag de agent wel en niet? ------------------------------
stap "5. proef vanaf de agent zelf"
for n in $NODES; do
  mag=$(op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c "$SSH -i /root/.ssh/id_ed25519 $GEBRUIKER@${ADRES[$n]} 'sudo /usr/sbin/pct list | head -3'" 2>&1 || true)
  mag_niet=$(op_node "$AGENT_NODE" pct exec "$CTID" -- sh -c "$SSH -i /root/.ssh/id_ed25519 $GEBRUIKER@${ADRES[$n]} 'sudo /usr/bin/id -u'" 2>&1 || true)
  if echo "$mag" | grep -q "VMID"; then
    zeg "   node $n: pct mag — $(echo "$mag" | tail -n +2 | head -1 | tr -s ' ')"
  else
    zeg "   node $n: pct mag NIET — $(echo "$mag" | tr '\n' ' ')"
  fi
  if echo "$mag_niet" | grep -qi "not allowed\|niet toegestaan"; then
    zeg "   node $n: iets anders dan pct/qm wordt geweigerd (goed)"
  else
    zeg "   node $n: LET OP, 'id -u' gaf: $(echo "$mag_niet" | tr '\n' ' ')"
  fi
done

# --- 6. klaar -------------------------------------------------------------
stap "6. klaar"
zeg "De agent in container $CTID (node $AGENT_NODE) kan vanaf $VANAF als $GEBRUIKER inloggen op:"
zeg "   $(echo "$NODES" | tr '\n' ' ')"
zeg "Zo gebruikt hij het:  ssh $GEBRUIKER@<node> 'sudo /usr/sbin/pct list'"
zeg "Hij komt daarmee aan containers en VM's, maar niet aan de host zelf."
zeg "Weghalen: rm /etc/sudoers.d/hermes-ict en haal de regel met hermes-ict-agent uit"
zeg "          /home/$GEBRUIKER/.ssh/authorized_keys op elke node."
