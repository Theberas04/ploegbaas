#!/usr/bin/env python3
"""Maakt de rondleiding met Nederlandse voice-over.

Leest de opgenomen frames (tmp-video/frames.txt + meta.json met de merken), rekt
elk scherm op tot de ingesproken regel erin past (het laatste beeld blijft staan),
encodeert het beeld, en legt de stem plus een zachte muziekbed eronder.

    python3 scripts/maak-video.py
    python3 scripts/maak-video.py --uit docs/ploegbaas-rondleiding.mp4

Waarom oprekken: de opname heeft de echte tijd per scherm. Een regel die langer
duurt dan het scherm in beeld is, laat de stem over het volgende scherm heen
vallen. Door het laatste frame van dat scherm te herhalen klopt de synchronisatie
 zonder opnieuw op te nemen.
"""
import argparse
import json
import pathlib
import subprocess
import sys

HIER = pathlib.Path(__file__).resolve().parent.parent
TMP = HIER / "tmp-video"
STEM = TMP / "stem"
TITEL_KAART = HIER / "docs/screenshots/kaart-titel.png"
SLOT_KAART = HIER / "docs/screenshots/kaart-slot.png"

TITEL_S = 6.0      # titelkaart in beeld
SLOT_S = 7.0       # slotkaart in beeld
LEAD = 0.35        # stilte na het wisselen van scherm voordat de stem begint
TAIL = 0.50        # stilte na de zin, voordat het scherm wisselt
BED_VOLUME = 0.10  # muziekbed onder de stem

# De merken uit meta.json zijn de momenten waarop een scherm klaar stond. Ze
# begrenzen de fragmenten. 'dashboard' staat er bewust niet bij: tussen het
# inloggen en het dashboard zit geen eigen scherm, dus die twee horen bij elkaar
# en de regel over het dashboard loopt over dat hele stuk.
VOLGORDE = ["inloggen", "taken", "taak", "agenten", "runs", "routines", "meldingen", "logboek"]
NAMEN = ["inloggen", "dashboard"] + VOLGORDE[1:]


def duur(pad: pathlib.Path) -> float:
    uit = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(pad)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(uit)


def lees_frames(lijst: pathlib.Path):
    """Concat-lijst met 'file …' en 'duration …' regels → [(pad, duur), …]."""
    frames = []
    huidig = None
    for regel in lijst.read_text(encoding="utf-8").splitlines():
        regel = regel.strip()
        if regel.startswith("file "):
            huidig = regel[5:].strip().strip("'")
        elif regel.startswith("duration ") and huidig:
            frames.append((huidig, float(regel.split()[1])))
            huidig = None
    return frames


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--uit", default=str(HIER / "docs/ploegbaas-rondleiding.mp4"))
    args = p.parse_args()

    meta = json.loads((TMP / "meta.json").read_text(encoding="utf-8"))
    merken = meta["merken"]
    frames = lees_frames(TMP / "frames.txt")
    if not frames:
        print("[fout] geen frames gevonden in tmp-video/frames.txt", file=sys.stderr)
        return 1

    stemmen = {i: duur(STEM / f"n{i:02d}.mp3") for i in range(1, 11)}
    print("stemmen:", ", ".join(f"n{i}={stemmen[i]:.2f}s" for i in sorted(stemmen)))

    # Schermgrenzen in seconden vanaf het begin van de opname.
    grenzen = [0.0] + [merken[n] / 1000 for n in VOLGORDE] + [sum(d for _, d in frames)]
    # Elk scherm i (0-based) hoort bij stem n{i+1}; n10 hoort bij de slotkaart.
    nieuw = []
    tijdlijn = []
    namen = NAMEN
    for i in range(len(grenzen) - 1):
        van, tot = grenzen[i], grenzen[i + 1]
        stem = stemmen[i + 1] if (i + 1) in stemmen else 0.0
        gewenst = max(tot - van, LEAD + stem + TAIL) if stem else (tot - van)
        nieuw.append((van, tot, gewenst, stem))
        tijdlijn.append({"scherm": namen[i], "van": round(van, 2), "tot": round(tot, 2),
                         "nieuw": round(gewenst, 2), "stem": round(stem, 2)})

    # Frames toewijzen aan schermen; het laatste beeld van een scherm blijft staan
    # als de regel langer is dan het scherm.
    regels = []
    t = 0.0
    for i, (van, tot, gewenst, stem) in enumerate(nieuw):
        selectie = []
        tt = 0.0
        for pad, d in frames:
            if van <= tt < tot:
                selectie.append((pad, d))
            tt += d
        if not selectie:                      # leeg scherm: houd het vorige beeld
            vorige = regels[-1][0] if regels else frames[0][0]
            selectie = [(vorige, max(0.02, tot - van))]
        # Elk scherm moet precies `gewenst` duren, anders schuift de stem op ten
        # opzichte van het beeld: frames die over de grens heen lopen maken het
        # geheel langer dan de som die ik hier bereken. Daarom eerst inkorten tot
        # het past en dan pas opvullen met een stilstaand beeld.
        selectie = list(selectie)
        while selectie and sum(d for _, d in selectie) - gewenst > 0.02:
            overschot = sum(d for _, d in selectie) - gewenst
            pad, d = selectie[-1]
            if d - overschot >= 0.02:
                selectie[-1] = (pad, d - overschot)
            else:
                selectie.pop()
        tekort = gewenst - sum(d for _, d in selectie)
        if tekort > 0.02:
            selectie.append((selectie[-1][0] if selectie else frames[0][0], tekort))
        regels.extend(selectie)

    lijst = TMP / "frames-audio.txt"
    lijst.write_text("\n".join(f"file '{p}'\nduration {d:.3f}" for p, d in regels) + "\n", encoding="utf-8")

    # 1) inhoud: frames met hun eigen tijd, op 1280x720 met de pagina-kleur eromheen.
    inhoud = TMP / "inhoud-audio.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(lijst),
        "-vf", "scale=1280:672,setsar=1,fps=30,pad=1280:720:0:24:color=0xf4f7fb",
        "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", str(inhoud),
    ], check=True)
    inhoud_s = duur(inhoud)

    # 2) titelkaart + inhoud + slotkaart (zonder geluid).
    totaal = TITEL_S + inhoud_s + SLOT_S
    beeld = TMP / "beeld.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-loop", "1", "-t", str(TITEL_S), "-i", str(TITEL_KAART),
        "-i", str(inhoud),
        "-loop", "1", "-t", str(SLOT_S), "-i", str(SLOT_KAART),
        "-filter_complex",
        "[0:v]scale=1280:720,setsar=1,fps=30[v0];[1:v]setsar=1,fps=30[v1];[2:v]scale=1280:720,setsar=1,fps=30[v2];"
        "[v0][v1][v2]concat=n=3:v=1:a=0[b]",
        "-map", "[b]", "-c:v", "libx264", "-preset", "medium", "-crf", "22",
        "-pix_fmt", "yuv420p", str(beeld),
    ], check=True)

    # 3) De stem plaatsen: absolute tijd = titel + begin van het scherm in de nieuwe
    #    tijdlijn + LEAD. Nooit stilte tussen clips plakken — dat loopt uit de pas.
    starts = []
    t = TITEL_S
    for i, (van, tot, gewenst, stem) in enumerate(nieuw):
        if stem:
            starts.append(round(t + LEAD, 3))
            tijdlijn[i]["stem_start"] = round(t + LEAD, 3)
        t += gewenst
    starts.append(round(TITEL_S + inhoud_s + 1.0, 3))   # n10 op de slotkaart
    tijdlijn.append({"scherm": "slotkaart", "stem_start": starts[-1], "stem": round(stemmen[10], 2)})

    filters = []
    # Invoer 0..9 zijn de stemmen, 10 is de bed, 11 is het beeld.
    for idx, start in enumerate(starts):
        ms = int(start * 1000)
        filters.append(
            f"[{idx}:a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,"
            f"adelay={ms}|{ms},volume=1.0[v{idx + 1}]"
        )
    # 4) Zachte bed: drie licht ontstemde sinusparen, tremolo en echo, laag niveau.
    T = totaal + 0.5
    bed = TMP / "bed.wav"
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", f"sine=f=130.81:d={T}",
        "-f", "lavfi", "-i", f"sine=f=131.60:d={T}",
        "-f", "lavfi", "-i", f"sine=f=196.00:d={T}",
        "-f", "lavfi", "-i", f"sine=f=196.90:d={T}",
        "-f", "lavfi", "-i", f"sine=f=261.63:d={T}",
        "-f", "lavfi", "-i", f"sine=f=262.40:d={T}",
        "-filter_complex",
        "[0:a]volume=0.50[s0];[1:a]volume=0.34[s1];[2:a]volume=0.50[s2];[3:a]volume=0.34[s3];"
        "[4:a]volume=0.50[s4];[5:a]volume=0.34[s5];"
        "[s0][s1][s2][s3][s4][s5]amix=inputs=6:normalize=0,lowpass=f=760,tremolo=f=0.11:d=0.32,"
        "aecho=0.8:0.9:120|260:0.30|0.15,volume=0.62,"
        f"afade=t=in:d=2.5,afade=t=out:st={max(0.0, T-4):.1f}:d=4[bed]",
        "-map", "[bed]", "-ac", "2", "-ar", "44100", str(bed),
    ], check=True)

    # 5) Stem + bed mixen en aan het beeld plakken.
    mappen = "".join(f"[v{i}]" for i in range(1, 11))
    mixes = "[bed]".join([""])  # placeholder om duidelijk te maken dat bed apart meegaat
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        *sum([["-i", str(STEM / f"n{i:02d}.mp3")] for i in range(1, 11)], []),
        "-i", str(bed),
        "-i", str(beeld),
        "-filter_complex",
        ";" .join(filters) + ";" + mappen + "[10:a]amix=inputs=11:normalize=0:duration=longest,"
        f"alimiter=limit=0.95,volume=1.0[a]",
        "-map", "11:v", "-map", "[a]",
        "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", "-ac", "2", "-ar", "44100",
        "-t", f"{totaal:.2f}", "-movflags", "+faststart", args.uit,
    ], check=True)

    (TMP / "timings.json").write_text(json.dumps(
        {"titel": TITEL_S, "inhoud": round(inhoud_s, 2), "slot": SLOT_S, "totaal": round(totaal, 2),
         "schermen": tijdlijn}, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"klaar: {args.uit}")
    print(f"  titel {TITEL_S}s + inhoud {inhoud_s:.2f}s + slot {SLOT_S}s = {totaal:.2f}s")
    for s in tijdlijn:
        print(f"  {s['scherm']:<12} stem op {s.get('stem_start')}s ({s['stem']}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())