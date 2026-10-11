#!/usr/bin/env python3
"""Fill assets/birds/* with one recording and one photo per species.

Audio  : xeno-canto.org when you supply its free API key (quality-rated songs),
         otherwise iNaturalist.org sound observations (no key needed)
Photos : iNaturalist.org (Creative Commons licensed research-grade observations)

Usage (from the project folder; the cloud build runs this for you):
    python3 tools/fetch_assets.py                 # no key: iNaturalist only
    XC_API_KEY=your_key python3 tools/fetch_assets.py

Options:
    --force            re-download even if a folder already has files
    --only 07          only process folders whose name starts with this
    --country "Canada" prefer recordings from another country
    --skip-audio / --skip-images
    --index-only       download nothing; rebuild index.json after adding files by hand

Standard library only. Writes audio.mp3 (or .wav / .m4a), image.png (or
image.jpg when the macOS `sips` converter is missing), updates the credit
fields in each metadata.json, and rewrites assets/CREDITS.md.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")
BIRDS = os.path.join(ROOT, "birds")
UA = {"User-Agent": "BirdsongAlarm-personal/1.0 (asset backfill script)"}
XC_API = "https://xeno-canto.org/api/3/recordings"
INAT_API = "https://api.inaturalist.org/v1/observations"
MIN_SECONDS, MAX_SECONDS = 12, 120
AUDIO_EXTS = ("mp3", "wav", "m4a")
AUDIO_FILES = [f"audio.{ext}" for ext in AUDIO_EXTS]
MIN_BIRDS_WITH_AUDIO = 3


def get_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def download(url, dest):
    if url.startswith("//"):
        url = "https:" + url
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as out:
        shutil.copyfileobj(resp, out)
    if os.path.getsize(dest) < 2048:
        os.remove(dest)
        raise RuntimeError("downloaded file is suspiciously small")


def seconds(length):
    """xeno-canto lengths look like '0:42' or '1:02:03'."""
    try:
        total = 0
        for part in str(length).split(":"):
            total = total * 60 + int(part)
        return total
    except ValueError:
        return 0


def find_recording(genus, species, key, country):
    """Try strict filters first, then loosen until something usable turns up."""
    base = f'gen:"{genus}" sp:"{species}" grp:birds'
    attempts = [
        f'{base} type:song q:A cnt:"{country}"',
        f"{base} type:song q:A",
        f"{base} type:song q:B",
        f"{base} q:A",
        base,
    ]
    for query in attempts:
        url = XC_API + "?" + urllib.parse.urlencode({"query": query, "key": key, "per_page": 100})
        try:
            data = get_json(url)
        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", "replace")[:300]
            raise RuntimeError(f"xeno-canto said HTTP {err.code} for query [{query}]: {body}")
        if "recordings" not in data:
            raise RuntimeError(f"unexpected xeno-canto reply for [{query}]: {str(data)[:300]}")
        for rec in data["recordings"]:
            licence = str(rec.get("lic", ""))
            # Skip NoDerivatives: the app trims, fades and layers the audio.
            if "-nd" in licence.lower():
                continue
            if not MIN_SECONDS <= seconds(rec.get("length")) <= MAX_SECONDS:
                continue
            if not rec.get("file"):
                continue
            return rec
        time.sleep(1)
    return None


def find_inat_sound(scientific_name):
    """Keyless fallback: a Creative Commons sound from an iNaturalist observation."""
    params = {
        "taxon_name": scientific_name,
        "sounds": "true",
        "sound_license": "cc0,cc-by,cc-by-sa,cc-by-nc,cc-by-nc-sa",
        "quality_grade": "research",
        "order_by": "votes",
        "per_page": 30,
    }
    data = get_json(INAT_API + "?" + urllib.parse.urlencode(params))
    for obs in data.get("results", []):
        for sound in obs.get("sounds", []):
            url = sound.get("file_url")
            if not url:
                continue
            ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower().lstrip(".")
            if ext not in AUDIO_EXTS:
                continue
            return {
                "url": url,
                "ext": ext,
                "credit": f"{sound.get('attribution') or 'iNaturalist contributor'} {obs.get('uri') or ''}".strip(),
            }
    return None


def fetch_audio(meta, folder, key, country):
    """Downloads one recording into the folder and returns (credit, note)."""
    genus, _, species = meta["scientific_name"].partition(" ")
    choice, why_not_xc = None, ""
    if key:
        try:
            rec = find_recording(genus, species, key, country)
            if rec:
                original = str(rec.get("file-name", "")).lower()
                licence = str(rec.get("lic", "")).lstrip("/")
                choice = {
                    "url": rec["file"],
                    "ext": "wav" if original.endswith(".wav") else "mp3",
                    "credit": (f"{rec.get('rec', 'Unknown recordist')}, XC{rec.get('id')}, "
                               f"xeno-canto.org/{rec.get('id')}, {licence}"),
                    "note": f"xeno-canto XC{rec.get('id')} ({rec.get('length')}, quality {rec.get('q')})",
                }
        except Exception as err:
            why_not_xc = f" (xeno-canto failed: {err})"
    if choice is None:
        sound = find_inat_sound(meta["scientific_name"])
        if sound is None:
            raise RuntimeError("no suitable recording found" + why_not_xc)
        choice = dict(sound, note="iNaturalist" + why_not_xc)

    temp = os.path.join(folder, "audio.download")
    download(choice["url"], temp)
    for ext in AUDIO_EXTS:
        stale = os.path.join(folder, f"audio.{ext}")
        if os.path.exists(stale):
            os.remove(stale)
    os.replace(temp, os.path.join(folder, f"audio.{choice['ext']}"))
    return choice["credit"], choice["note"]


def find_photo(scientific_name):
    params = {
        "taxon_name": scientific_name,
        "photo_license": "cc0,cc-by,cc-by-sa,cc-by-nc,cc-by-nc-sa",
        "quality_grade": "research",
        "order_by": "votes",
        "per_page": 10,
    }
    data = get_json(INAT_API + "?" + urllib.parse.urlencode(params))
    for obs in data.get("results", []):
        for photo in obs.get("photos", []):
            url = photo.get("url")
            if url:
                return {
                    "url": url.replace("/square.", "/large."),
                    "attribution": photo.get("attribution") or "iNaturalist contributor",
                    "licence": photo.get("license_code") or "",
                    "page": obs.get("uri") or "",
                }
    return None


def to_png(jpg_path, png_path):
    """Uses the image converter that ships with macOS. Returns True on success."""
    if not shutil.which("sips"):
        return False
    result = subprocess.run(["sips", "-s", "format", "png", jpg_path, "--out", png_path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0 and os.path.exists(png_path)


def write_index(folders):
    """assets/birds/index.json tells the web app which files each folder has."""
    entries = []
    for name in folders:
        folder = os.path.join(BIRDS, name)
        pick = lambda names: next((n for n in names if os.path.exists(os.path.join(folder, n))), None)
        entries.append({"id": name,
                        "audio": pick(["audio.mp3", "audio.wav", "audio.m4a"]),
                        "image": pick(["image.png", "image.jpg", "image.jpeg"])})
    with open(os.path.join(BIRDS, "index.json"), "w", encoding="utf-8") as fh:
        json.dump({"birds": entries}, fh, indent=2)
        fh.write("\n")


def has_any(folder, names):
    return any(os.path.exists(os.path.join(folder, n)) for n in names)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--key", default=os.environ.get("XC_API_KEY", ""))
    parser.add_argument("--country", default="United States")
    parser.add_argument("--only", default="")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--skip-audio", action="store_true")
    parser.add_argument("--skip-images", action="store_true")
    parser.add_argument("--index-only", action="store_true",
                        help="download nothing; just rebuild index.json and CREDITS.md")
    args = parser.parse_args()
    if args.index_only:
        args.skip_audio = args.skip_images = True

    if not args.skip_audio and not args.key:
        print("No xeno-canto key given: using iNaturalist sounds only.\n")

    folders = sorted(d for d in os.listdir(BIRDS) if os.path.isdir(os.path.join(BIRDS, d)))
    problems = []

    for name in folders:
        if args.only and not name.startswith(args.only):
            continue
        folder = os.path.join(BIRDS, name)
        meta_path = os.path.join(folder, "metadata.json")
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
        print(f"{name}: {meta['name']}")

        if not args.skip_audio and (args.force or not has_any(folder, AUDIO_FILES)):
            try:
                meta["audio_credit"], note = fetch_audio(meta, folder, args.key, args.country)
                print(f"   audio  {note}")
            except Exception as err:  # keep going; report at the end
                problems.append(f"{name} audio: {err}")
                print(f"   audio  FAILED: {err}")
            time.sleep(1)

        if not args.skip_images and (args.force or not has_any(folder, ["image.png", "image.jpg"])):
            try:
                photo = find_photo(meta["scientific_name"])
                if photo is None:
                    raise RuntimeError("no openly licensed photo found")
                jpg = os.path.join(folder, "image.jpg")
                png = os.path.join(folder, "image.png")
                download(photo["url"], jpg)
                if to_png(jpg, png):
                    os.remove(jpg)
                meta["image_credit"] = f"{photo['attribution']} {photo['page']}".strip()
                print(f"   image  {photo['licence'] or 'licensed'}")
            except Exception as err:
                problems.append(f"{name} image: {err}")
                print(f"   image  FAILED: {err}")
            time.sleep(1)

        with open(meta_path, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    # Attribution file: the Creative Commons licences require credit.
    lines = ["# Credits", "",
             "Recordings from xeno-canto.org or iNaturalist.org, photos from iNaturalist.org, used under",
             "the Creative Commons licence named on each line. Personal, non-commercial use.", ""]
    for name in folders:
        with open(os.path.join(BIRDS, name, "metadata.json"), encoding="utf-8") as fh:
            meta = json.load(fh)
        lines.append(f"## {meta['name']}")
        lines.append(f"- Audio: {meta.get('audio_credit') or 'not fetched yet'}")
        lines.append(f"- Photo: {meta.get('image_credit') or 'not fetched yet'}")
        lines.append("")
    with open(os.path.join(ROOT, "CREDITS.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    write_index(folders)

    with_audio = sum(1 for name in folders if has_any(os.path.join(BIRDS, name), AUDIO_FILES))
    print(f"\n{with_audio} of {len(folders)} birds have a recording.")
    if problems:
        print("Problems:")
        for p in problems:
            print("  -", p)
    # A few gaps are fine (those birds are skipped). An empty deck is not.
    if not args.skip_audio and with_audio < MIN_BIRDS_WITH_AUDIO:
        sys.exit(f"Fewer than {MIN_BIRDS_WITH_AUDIO} recordings were downloaded. Stopping.")


if __name__ == "__main__":
    main()
