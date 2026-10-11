#!/usr/bin/env python3
"""Build one looping chorus clip per bird into Clips/.

The iPhone's system alarm (AlarmKit) can only play one short sound file that
sits at the root of the app, and it loops that file until the alarm is
stopped. So the dawn chorus has to live inside the clip itself. Each clip is
28 seconds of layered birdsong:

    0s   the day's bird fades in on its own
    8s   a second bird joins, quieter
    16s  a third bird joins, quieter still

    assets/birds/07_wood_thrush/audio.mp3 (+ two companions)
        ->  Clips/birdsong_07_wood_thrush.caf

Needs ffmpeg on the PATH (the cloud build installs it). Standard library only.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BIRDS = os.path.join(ROOT, "assets", "birds")
CLIPS = os.path.join(ROOT, "Clips")
SECONDS = 28.0           # stay under the 30-second limit iOS puts on alert sounds
RATE = 32000
# (enters at second, level, fade-in seconds) for the lead bird and its two companions
VOICES = [(0, 1.00, 2.5), (8, 0.45, 5.0), (16, 0.35, 5.0)]


def find_audio(folder):
    for name in ("audio.mp3", "audio.wav", "audio.m4a"):
        path = os.path.join(folder, name)
        if os.path.exists(path):
            return path
    return None


def build_clip(ffmpeg, sources, target):
    """sources: the lead recording first, then up to two companions."""
    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    for path in sources:
        command += ["-stream_loop", "-1", "-i", path]       # short recordings repeat to fill the clip

    chains, labels = [], []
    for index, (start, level, fade) in enumerate(VOICES[:len(sources)]):
        length = SECONDS - start
        chain = (f"[{index}:a]aformat=channel_layouts=mono,atrim=0:{length:.2f},asetpts=PTS-STARTPTS,"
                 f"loudnorm=I=-16:TP=-1.5:LRA=11,aresample={RATE},"
                 f"volume={level},afade=t=in:st=0:d={fade}")
        if start:
            chain += f",adelay={int(start * 1000)}"
        chains.append(chain + f"[v{index}]")
        labels.append(f"[v{index}]")
    mix = "".join(labels)
    if len(labels) > 1:
        mix += f"amix=inputs={len(labels)}:normalize=0:duration=longest,"
    # A limiter stops the layers clipping; soft edges keep the loop point from clicking.
    mix += f"alimiter=limit=0.95,atrim=0:{SECONDS},afade=t=out:st={SECONDS - 1.0}:d=1.0[out]"
    command += ["-filter_complex", ";".join(chains + [mix]), "-map", "[out]",
                "-t", str(SECONDS), "-ar", str(RATE), "-ac", "1", "-c:a", "pcm_s16le", "-f", "caf", target]
    result = subprocess.run(command, capture_output=True, text=True)
    ok = result.returncode == 0 and os.path.exists(target) and os.path.getsize(target) > 4096
    return ok, result.stderr.strip()[:300]


def main():
    ffmpeg = os.environ.get("FFMPEG") or shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("ffmpeg not found. Install it (Windows: winget install ffmpeg; Mac: brew install ffmpeg).")

    os.makedirs(CLIPS, exist_ok=True)
    for old in os.listdir(CLIPS):
        if old.startswith("birdsong_") and old.endswith(".caf"):
            os.remove(os.path.join(CLIPS, old))

    birds = []
    for name in sorted(os.listdir(BIRDS)):
        folder = os.path.join(BIRDS, name)
        if os.path.isdir(folder) and find_audio(folder):
            birds.append((name, find_audio(folder)))

    made, failed = 0, []
    count = len(birds)
    for index, (name, lead) in enumerate(birds):
        # Two fixed companions per bird, spread around the deck.
        companions = []
        for step in (7, 13):
            other = birds[(index + step) % count]
            if other[0] != name and other[1] not in companions:
                companions.append(other[1])
        target = os.path.join(CLIPS, f"birdsong_{name}.caf")
        ok, error = build_clip(ffmpeg, [lead] + companions, target)
        if ok:
            made += 1
            print(f"  {name}: chorus of {1 + len(companions)}")
        else:
            failed.append(name)
            print(f"  {name}: FAILED {error}")

    print(f"\n{made} chorus clips written to Clips/.")
    if failed:
        print("Birds without a clip ring with the standard alarm sound:", ", ".join(failed))
    if birds and not made:
        sys.exit("No clips could be built.")


if __name__ == "__main__":
    main()
