#!/bin/bash
# Zet ssh aan in elke draaiende container op het cluster en leg één sleutel in
# /root/.ssh/authorized_keys, zodat je (of je ICT-agent) overal in kan.
#
# Draai dit als root op een node van het cluster:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Theberas04/ploegbaas/main/deploy/proxmox/ssh-op-alles.sh)"
#
# Standaard is dat de sleutel van de Hermes-agent (die in zijn eigen container
# staat); met SLEUTEL="ssh-ed25519 AAAA… jij@laptop" zet je je eigen publieke
# sleutel erbij. CTID=102 kiest de agent-container zelf. VM's worden getoond maar
# niet aangeraakt: daar moet ssh in de gast zelf aan staan.
set -euo pipefail

zeg()  { printf '%s\n' "$*"; }
stap() { printf '\n== %s ==\n' "$*"; }
fout() { printf 'FOUT: %s\n' "$*" >&2; exit 1; }
q()    { printf '%q' "$1"; }

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

# </dev/null: pct en ssh eten anders de regels van een aanroepende leeslus op
op_node() {
  local n="$1"; shift
  if [ "$n" = "$DEZE" ]; then
    "$@" </dev/null
  else
    $SSH root@"${ADRES[$n]}" "$(printf '%q ' "$@")" </dev/null
  fi
}

# --- 1. de sleutel ---------------------------------------------------------
stap "1. welke sleutel komt er in?"
if [ -n "${SLEUTEL:-}" ]; then
  zeg "   eigen sleutel opgegeven: $(echo "$SLEUTEL" | awk '{print $1, substr($2,1,16)"…"}')"
  AGENT_NODE=""; AGENT_CTID=""
else
  AGENT_NODE=""
  if [ -n "${CTID:-}" ]; then
    AGENT_CTID=$CTID
    for n in $NODES; do
      if op_node "$n" pct status "$AGENT_CTID" >/dev/null 2>&1; then AGENT_NODE=$n; fi
    done
    [ -n "$AGENT_NODE" ] || fout "container $AGENT_CTID bestaat niet in dit cluster"
  else
    for n in $NODES; do
      while read -r cid status naam; do
        [ "$status" = "running" ] || continue
        if op_node "$n" pct exec "$cid" -- sh -c 'grep -qs API_SERVER_KEY /home/hermes/.hermes/.env /root/.hermes/.env' 2>/dev/null; then
          if [ -z "$AGENT_NODE" ]; then AGENT_NODE=$n; AGENT_CTID=$cid; fi
        fi
      done < <(op_node "$n" pct list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $2, $NF}')
    done
    [ -n "$AGENT_NODE" ] || fout "geen agent-container gevonden; geef CTID=... of SLEUTEL=... mee"
  fi
  SLEUTEL=$(op_node "$AGENT_NODE" pct exec "$AGENT_CTID" -- cat /root/.ssh/id_ed25519.pub 2>/dev/null || true)
  [ -n "$SLEUTEL" ] || fout "container $AGENT_CTID heeft nog geen sleutel; draai eerst geef-proxmox-toegang.sh"
  zeg "   sleutel van de agent in container $AGENT_CTID (node $AGENT_NODE)"
fi
zeg "   $(echo "$SLEUTEL" | awk '{print $1, substr($2,1,16)"…", $3}')"

# --- 2. wat er in elke container moet gebeuren -----------------------------
BINNEN=$(cat <<EINDE
if command -v sshd >/dev/null 2>&1; then echo "SSHD=ja"; else
  apt-get update -qq >/dev/null 2>&1
  if DEBIAN_FRONTEND=noninteractive timeout 240 apt-get install -y -qq openssh-server >/dev/null 2>&1; then echo "SSHD=nieuw"; else echo "SSHD=nee"; fi
fi
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then echo "DIENST=ja"; else echo "DIENST=nee"; fi
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sshd start >/dev/null 2>&1 || true
  if rc-service sshd status >/dev/null 2>&1; then echo "DIENST=ja"; else echo "DIENST=nee"; fi
else
  /etc/init.d/ssh start >/dev/null 2>&1 || true
  if ss -ltn 2>/dev/null | grep -q ':22 '; then echo "DIENST=ja"; else echo "DIENST=nee"; fi
fi
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qF $(q "$SLEUTEL") /root/.ssh/authorized_keys || echo $(q "$SLEUTEL") >> /root/.ssh/authorized_keys
if grep -qF $(q "$SLEUTEL") /root/.ssh/authorized_keys; then echo "SLEUTEL=ja"; else echo "SLEUTEL=nee"; fi
echo "IP=\$(hostname -I 2>/dev/null | awk '{print \$1}')"
EINDE
)

# --- 3. elke draaiende container langs -------------------------------------
stap "2. containers langs"
RIJEN=/tmp/ssh-op-alles-rijen.$$
: > "$RIJEN"
VM_LIJST=""
for n in $NODES; do
  zeg "   -- node $n --"
  while read -r cid status naam; do
    [ "$status" = "running" ] || continue
    uit=$(op_node "$n" pct exec "$cid" -- sh -c "$BINNEN" 2>&1 || true)
    sshd=$(echo "$uit" | sed -n 's/^SSHD=//p' | tail -1)
    dienst=$(echo "$uit" | sed -n 's/^DIENST=//p' | tail -1)
    sleutel=$(echo "$uit" | sed -n 's/^SLEUTEL=//p' | tail -1)
    ip=$(echo "$uit" | sed -n 's/^IP=//p' | tail -1)
    # eerst wat in de containerconfig staat (net0), anders wat de container zelf zegt (dhcp)
    ip=$(op_node "$n" pct config "$cid" 2>/dev/null | sed -n 's/.*net0:.*ip=\([0-9][0-9.]*\).*/\1/p' | head -1)
    [ -n "$ip" ] || ip=$(echo "$uit" | sed -n 's/^IP=//p' | tail -1)
    # proef: kan de agent er echt in?
    proef="-"
    if [ -n "$ip" ] && [ "$dienst" = "ja" ] && [ "$sleutel" = "ja" ] && [ -n "$AGENT_NODE" ]; then
      p=$(op_node "$AGENT_NODE" pct exec "$AGENT_CTID" -- sh -c "$SSH -i /root/.ssh/id_ed25519 root@$ip 'echo OK'" 2>&1 || true)
      case "$p" in *OK*) proef="ok";; *) proef="mislukt";; esac
    fi
    [ -n "$ip" ] || ip="?"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$cid" "$naam" "$ip" "$dienst" "$proef" >> "$RIJEN"
    zeg "      $cid $naam ($ip): sshd=${sshd:-?} dienst=${dienst:-?} sleutel=${sleutel:-?} proef=$proef"
  done < <(op_node "$n" pct list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $2, $NF}')
  # VM's alleen melden (de qm-tabel heeft een naam met spaties, dus niet ontleden)
  vm=$(op_node "$n" qm list 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d' || true)
  if [ -n "$vm" ]; then
    VM_LIJST="$VM_LIJST
   -- node $n --"
    VM_LIJST="$VM_LIJST
$(echo "$vm" | sed 's/^/      /')"
  fi
done

# --- 4. samenvatting -------------------------------------------------------
stap "3. samenvatting"
AANTAL=$(wc -l < "$RIJEN")
OK=$(awk -F'\t' '$6=="ok"' "$RIJEN" | wc -l)
DIENST_JA=$(awk -F'\t' '$5=="ja"' "$RIJEN" | wc -l)
zeg "   $AANTAL draaiende containers, $DIENST_JA daarvan met een draaiende ssh, $OK met een geslaagde proef."
if [ "$OK" -lt "$AANTAL" ]; then
  zeg "   Deze vragen nog aandacht:"
  awk -F'\t' '$6!="ok" {printf "      %s (%s) op node %s: dienst=%s proef=%s\n", $3, $4, $1, $5, $6}' "$RIJEN"
fi
if [ -n "$VM_LIJST" ]; then
  zeg "   VM's (niet aangeraakt: ssh moet in de gast zelf aan staan):"
  printf '%s\n' "$VM_LIJST" | sed '/^[[:space:]]*$/d'
fi
rm -f "$RIJEN"
zeg ""
zeg "Inloggen: ssh root@<ip>  (sleutel: $(echo "$SLEUTEL" | awk '{print $3}'))"
zeg "Sleutel weghalen doe je per container: haal de regel uit /root/.ssh/authorized_keys."