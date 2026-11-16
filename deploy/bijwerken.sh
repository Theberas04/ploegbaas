#!/usr/bin/env bash
# Werkt Ploegbaas bij naar de nieuwste versie op GitHub.
#
#   bash deploy/bijwerken.sh            # halen, controleren, vervangen, service herstarten
#   DROOG=1 bash deploy/bijwerken.sh    # alleen halen en controleren, niets aanraken
#   bash deploy/bijwerken.sh --terug    # de vorige versie terugzetten
#
# Wat het doet: haalt de tarball van de tak (standaard main), controleert dat de
# nieuwe server.mjs door `node --check` komt, bewaart de huidige bestanden in
# .vorige/, vervangt de code (data/ blijft staan), herstart de service en wacht
# tot /api/gezondheid antwoordt. Komt de nieuwe versie niet op, dan zet het
# script de vorige terug en herstart opnieuw — je houdt dus altijd een werkend
# dashboard.
set -uo pipefail

MAP="${PLOEGBAAS_MAP:-/opt/ploegbaas}"
DATA="${PLOEGBAAS_DATA:-$MAP/data}"
REPO="${PLOEGBAAS_REPO:-Theberas04/ploegbaas}"
TAK="${PLOEGBAAS_TAK:-main}"
SERVICE="${PLOEGBAAS_SERVICE:-ploegbaas}"
POORT="${PLOEGBAAS_POORT:-8123}"
VORIGE="$MAP/.vorige"
DROOG="${DROOG:-0}"
NODE_BIN="${NODE_BIN:-$(command -v node || echo /usr/local/bin/node)}"

zeg() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
stop() { zeg "FOUT: $*"; exit "${2:-1}"; }

[ -f "$MAP/server.mjs" ] || stop "geen server.mjs in $MAP (zet PLOEGBAAS_MAP)"
mkdir -p "$DATA" "$VORIGE" || stop "kan $VORIGE niet maken"

herstart() {
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service"; then
    systemctl restart "$SERVICE"
  elif command -v systemctl >/dev/null && systemctl --user list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service"; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    systemctl --user restart "$SERVICE"
  else
    return 1
  fi
}

gezond() {
  local i
  for i in $(seq 1 40); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$POORT/api/gezondheid" 2>/dev/null | grep -q '"ok"\|"status"'; then
      return 0
    fi
    sleep 0.75
  done
  return 1
}

terugzetten() {
  zeg "vorige versie terugzetten…"
  [ -f "$VORIGE/server.mjs" ] || stop "geen vorige versie in $VORIGE"
  cp -a "$VORIGE/server.mjs" "$MAP/server.mjs"
  [ -d "$VORIGE/public" ] && cp -a "$VORIGE/public/." "$MAP/public/"
  herstart >/dev/null 2>&1 || zeg "let op: service niet herstart (start hem zelf opnieuw)"
  if gezond; then zeg "de vorige versie draait weer"; else zeg "de vorige versie antwoordt niet — kijk in het journaal"; fi
}

if [ "${1:-}" = "--terug" ]; then terugzetten; exit 0; fi

TMP="$(mktemp -d /tmp/ploegbaas-bijwerken.XXXXXX)" || stop "geen tijdelijke map"
trap 'rm -rf "$TMP"' EXIT

zeg "nieuwste versie halen: $REPO/$TAK"
echo "$$" > "$DATA/bijwerken.pid"
trap 'rm -rf "$TMP"; rm -f "$DATA/bijwerken.pid"' EXIT
if ! curl -fsSL --max-time 120 -o "$TMP/bron.tgz" "https://codeload.github.com/$REPO/tar.gz/refs/heads/$TAK"; then
  stop "kon de nieuwe versie niet downloaden (netwerk of naam van de repo)"
fi
mkdir -p "$TMP/nieuw"
tar -xzf "$TMP/bron.tgz" -C "$TMP/nieuw" --strip-components=1 || stop "kon de download niet uitpakken"

for f in server.mjs public/index.html; do
  [ -s "$TMP/nieuw/$f" ] || stop "de download mist $f — niets vervangen"
done

zeg "nieuwe code controleren"
if ! "$NODE_BIN" --check "$TMP/nieuw/server.mjs" 2>"$TMP/check.log"; then
  cat "$TMP/check.log"
  stop "de nieuwe server.mjs heeft een syntaxfout — niets vervangen"
fi
zeg "controle goed"

# De commit waar deze versie vandaan komt. Let op: de API stuurt compacte JSON
# (geen spaties), dus geen sed op '  "sha": …' — gebruik jq, met een grep-terugval.
COMMIT_JSON="$(curl -fsSL --max-time 10 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/commits/$TAK" 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  SHA="$(printf '%s' "$COMMIT_JSON" | jq -r '.sha // empty' 2>/dev/null | head -1)"
else
  SHA="$(printf '%s' "$COMMIT_JSON" | tr ',' '\n' | grep -m1 -oE '[0-9a-f]{40}')"
fi
SHA="${SHA:-}"
[ -n "$SHA" ] || zeg "let op: de commit kon niet opgehaald worden (GitHub-API); de versie wordt niet vastgelegd"

if [ "$DROOG" = "1" ]; then
  zeg "DROOG: niets vervangen. Nieuwe versie is klaar en controleert goed (${SHA:0:7})."
  exit 0
fi

zeg "huidige code bewaren in $VORIGE"
cp -a "$MAP/server.mjs" "$VORIGE/server.mjs"
rm -rf "$VORIGE/public"
cp -a "$MAP/public" "$VORIGE/public"

zeg "code vervangen (data blijft staan)"
cp -a "$TMP/nieuw/server.mjs" "$MAP/server.mjs"
for d in public scripts deploy; do
  if [ -d "$TMP/nieuw/$d" ]; then
    rm -rf "${MAP:?}/$d"
    cp -a "$TMP/nieuw/$d" "$MAP/$d"
  fi
done
if [ -s "$TMP/nieuw/README.md" ]; then
  mkdir -p "$MAP/docs"
  cp -a "$TMP/nieuw/README.md" "$MAP/docs/README.md"
fi

if [ -n "$SHA" ]; then
  printf '{"sha":"%s","kort":"%s","datum":"%s","bron":"%s/%s"}\n' \
    "$SHA" "${SHA:0:7}" "$(date -Is)" "$REPO" "$TAK" > "$DATA/geinstalleerd.json"
fi

zeg "service herstarten"
if ! herstart; then
  zeg "geen systemd-eenheid '$SERVICE' gevonden — herstart het dashboard zelf"
  zeg "KLAAR (code bijgewerkt, service niet herstart)"
  exit 0
fi

if gezond; then
  zeg "KLAAR — versie ${SHA:0:7} draait op poort $POORT"
  exit 0
fi

zeg "de nieuwe versie antwoordt niet na 30 seconden"
terugzetten
exit 3