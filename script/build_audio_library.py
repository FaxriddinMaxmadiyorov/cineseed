#!/usr/bin/env python3
"""Builds the trailer audio library (audio/manifest.json, audio/music/*.m4a, audio/sfx/*.m4a).

Development-time tool, not used at request time. Requirements: ffmpeg, Python 3 with
librosa, numpy and pyyaml; `apt-get` + `dpkg-deb` when --fetch is used.

    python3 script/build_audio_library.py --packages tmp/audio_packages --fetch

For every music track the strongest windows are located (tempo, beats and energy from librosa),
cut into short excerpts and loudness-normalized, so a trailer can pick a window and cut its shots
on the beat. Sound effects are trimmed, optionally reversed (risers), peak-normalized and
annotated with the moment of their peak so hits can be aligned exactly with picture cuts.
"""
import argparse
import json
import os
import re
import subprocess
import sys

import librosa
import numpy as np
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(ROOT, "audio")
EXCERPT = 11.0
SR = 22050
HOP = 512
CALM_MOODS = {"calm", "emotional", "romance", "wonder", "documentary", "drama"}


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def ensure_packages(cfg, pkgdir, fetch):
    os.makedirs(pkgdir, exist_ok=True)
    for pkg in cfg["packages"]:
        target = os.path.join(pkgdir, pkg)
        if os.path.isdir(target):
            continue
        if not fetch:
            sys.exit(f"missing {target}; pass --fetch (Debian/Ubuntu) or extract the package there")
        run(["apt-get", "download", pkg], cwd=pkgdir)
        deb = next(f for f in os.listdir(pkgdir) if f.startswith(pkg + "_") and f.endswith(".deb"))
        run(["dpkg-deb", "-x", deb, target], cwd=pkgdir)


def source_path(cfg, pkgdir, entry):
    pkg = cfg["packages"][entry["pkg"]]
    return os.path.join(pkgdir, entry["pkg"], pkg["root"], entry["file"])


def loudness(path, start=None, duration=None):
    cmd = ["ffmpeg", "-hide_banner", "-nostats"]
    if start is not None:
        cmd += ["-ss", f"{start:.3f}", "-t", f"{duration:.3f}"]
    cmd += ["-i", path, "-af", "loudnorm=print_format=json", "-f", "null", "-"]
    out = subprocess.run(cmd, capture_output=True, text=True).stderr
    data = json.loads(out[out.rindex("{"):out.rindex("}") + 1])
    return float(data["input_i"]), float(data["input_tp"])


def analyse(path):
    y, sr = librosa.load(path, sr=SR, mono=True)
    rms = librosa.feature.rms(y=y, hop_length=HOP)[0]
    onset = librosa.onset.onset_strength(y=y, sr=sr, hop_length=HOP)
    tempo, beats = librosa.beat.beat_track(onset_envelope=onset, sr=sr, hop_length=HOP)
    return {
        "rms": rms,
        "onset": onset,
        "tempo": float(np.atleast_1d(tempo)[0]),
        "beats": librosa.frames_to_time(beats, sr=sr, hop_length=HOP),
        "fps": sr / HOP,
        "duration": len(y) / sr,
    }


def windows(a, calm, count=2):
    fps, rms, onset = a["fps"], a["rms"], a["onset"]
    rmax, omax = max(rms.max(), 1e-6), max(onset.max(), 1e-6)
    n = int(EXCERPT * fps)
    scored = []
    for s in a["beats"]:
        if s < 1.0 or s + EXCERPT > a["duration"] - 0.5:
            continue
        i = int(s * fps)
        seg_r, seg_o = rms[i:i + n] / rmax, onset[i:i + n] / omax
        if len(seg_r) < n:
            continue
        silence = float((seg_r < 0.08).mean())
        mean_r, mean_o = float(seg_r.mean()), float(seg_o.mean())
        tail = float(seg_r[int(5 * fps):int(9 * fps)].mean())
        if calm:
            score = 0.6 * mean_r + 0.2 * (1 - abs(mean_o - 0.25)) - 0.3 * float(seg_r.std()) - 2 * silence
        else:
            score = 0.45 * mean_r + 0.3 * mean_o + 0.25 * tail - 2 * silence
        scored.append((score, float(s)))
    picked = []
    for score, s in sorted(scored, reverse=True):
        if all(abs(s - p) >= EXCERPT for _, p in picked):
            picked.append((score, s))
        if len(picked) == count:
            break
    return sorted(picked, key=lambda x: x[1])


def excerpt_meta(a, start):
    fps = a["fps"]
    beats = [round(float(b - start), 3) for b in a["beats"] if start <= b < start + EXCERPT]
    i, n = int(start * fps), int(EXCERPT * fps)
    onset = a["onset"][i:i + n]
    # bar phase: the beat index (mod 4) that carries the most onset energy
    phase = 0
    if len(beats) >= 8:
        strengths = [sum(onset[min(int(b * fps), len(onset) - 1)] for b in beats[p::4]) for p in range(4)]
        phase = int(np.argmax(strengths))
    rms = a["rms"][i:i + n] / max(a["rms"].max(), 1e-6)
    step = int(fps / 4)
    energy = [round(float(rms[k:k + step].mean()), 3) for k in range(0, len(rms) - step + 1, step)]
    peaks = librosa.util.peak_pick(onset, pre_max=8, post_max=8, pre_avg=8, post_avg=8, delta=0.3 * onset.max(), wait=10)
    hits = sorted(((float(onset[p]), round(p / fps, 3)) for p in peaks), reverse=True)[:8]
    return {
        "bpm": round(a["tempo"], 1),
        "beats": beats,
        "downbeats": beats[phase::4],
        "energy": energy,
        "hits": sorted(t for _, t in hits),
    }


def build_music(cfg, pkgdir):
    out_dir = os.path.join(AUDIO, "music")
    os.makedirs(out_dir, exist_ok=True)
    tracks = []
    for entry in cfg["music"]:
        path = source_path(cfg, pkgdir, entry)
        a = analyse(path)
        calm = bool(CALM_MOODS & set(entry["moods"])) and not ({"action", "epic", "war"} & set(entry["moods"]))
        for k, (score, start) in enumerate(windows(a, calm)):
            eid = f"{entry['id']}_{k + 1}"
            rel = f"music/{eid}.m4a"
            lufs, _ = loudness(path, start, EXCERPT)
            gain = max(min(-16.0 - lufs, 18.0), -18.0)
            run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-ss", f"{start:.3f}", "-t", f"{EXCERPT}", "-i", path,
                 "-af", f"volume={gain:.2f}dB,alimiter=limit=0.89:level=false,afade=t=out:st={EXCERPT - 0.4}:d=0.4",
                 "-ar", "44100", "-ac", "2", "-c:a", "aac", "-b:a", "112k", os.path.join(AUDIO, rel)])
            meta = excerpt_meta(a, start)
            tracks.append({
                "id": eid, "track": entry["id"], "file": rel, "moods": entry["moods"], "pkg": entry["pkg"],
                "source_start": round(start, 3), "duration": EXCERPT, "score": round(score, 3), **meta,
            })
            print(f"[music] {eid}: start={start:.1f}s bpm={meta['bpm']} beats={len(meta['beats'])} score={score:.2f}")
    return tracks


def build_sfx(cfg, pkgdir):
    out_dir = os.path.join(AUDIO, "sfx")
    os.makedirs(out_dir, exist_ok=True)
    effects = {}
    for kind, entries in cfg["sfx"].items():
        for entry in entries:
            path = source_path(cfg, pkgdir, entry)
            rel = f"sfx/{entry['id']}.m4a"
            filters = []
            if entry.get("reverse"):
                filters.append("areverse")
            filters.append("silenceremove=start_periods=1:start_threshold=-50dB")
            if entry.get("trim"):
                filters.append(f"atrim=0:{entry['trim']}")
            if entry.get("reverse"):
                filters.append("afade=t=in:d=1.2")
            filters.append("afade=t=out:st=0:d=0.01")  # replaced below once we know the duration
            tmp = os.path.join(out_dir, f".{entry['id']}.wav")
            run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", path, "-af", ",".join(filters[:-1]), "-ar", "44100", "-ac", "2", tmp])
            dur = float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", tmp]).stdout)
            vol = subprocess.run(["ffmpeg", "-hide_banner", "-i", tmp, "-af", "volumedetect", "-f", "null", "-"], capture_output=True, text=True).stderr
            peak = float(re.search(r"max_volume: (-?[\d.]+) dB", vol).group(1))
            run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", tmp,
                 "-af", f"volume={-1.0 - peak:.2f}dB,afade=t=out:st={max(dur - 0.15, 0):.3f}:d=0.15",
                 "-c:a", "aac", "-b:a", "112k", os.path.join(AUDIO, rel)])
            y, sr = librosa.load(tmp, sr=SR, mono=True)
            env = librosa.feature.rms(y=y, hop_length=HOP)[0]
            peak_at = float(np.argmax(env) * HOP / sr)
            os.remove(tmp)
            effects.setdefault(kind, []).append({"id": entry["id"], "file": rel, "duration": round(dur, 3), "peak_at": round(peak_at, 3), "pkg": entry["pkg"]})
            print(f"[sfx] {kind}/{entry['id']}: {dur:.2f}s peak at {peak_at:.2f}s")
    return effects


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--packages", default=os.path.join(ROOT, "tmp", "audio_packages"))
    parser.add_argument("--fetch", action="store_true")
    args = parser.parse_args()

    with open(os.path.join(AUDIO, "sources.yml")) as f:
        cfg = yaml.safe_load(f)
    ensure_packages(cfg, args.packages, args.fetch)
    manifest = {
        "version": 1,
        "excerpt_length": EXCERPT,
        "packages": {k: {"license": v["license"], "attribution": v["attribution"]} for k, v in cfg["packages"].items()},
        "music": build_music(cfg, args.packages),
        "sfx": build_sfx(cfg, args.packages),
    }
    with open(os.path.join(AUDIO, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
    print(f"music excerpts: {len(manifest['music'])}, sfx: {sum(len(v) for v in manifest['sfx'].values())}")


if __name__ == "__main__":
    main()
