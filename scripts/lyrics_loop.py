"""Lyrics loop: two Whisper passes, lock agreeing time spans, redo only unlocked.

Repo source. Audio, stems, and state stay under C:\\nvme\\stt\\lyrics.
Whisper weights stay at C:\\nvme\\faster-whisper-large-v3. CPU only.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
import wave
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

FFMPEG = r"C:\Tools\ffmpeg\ffmpeg.exe"
MODEL = r"C:\nvme\faster-whisper-large-v3"
ROOT = Path(r"C:\nvme\stt\lyrics")
AGREE = 0.82


def slug_part(s: str) -> str:
    s = (s or "").strip().replace(" ", "_")
    s = re.sub(r"[^\w\-]+", "_", s)
    return s.strip("_-")


def work_dir(artist: str, album: str, name: str) -> Path:
    parts = [p for p in (slug_part(artist), slug_part(album), slug_part(name)) if p]
    if not parts:
        raise SystemExit("need --name (and optionally --artist --album)")
    return ROOT.joinpath(*parts)
WINDOW = 8.0
HALLUC = re.compile(
    r"^(thank you\.?|thanks for watching\.?|thanks for listening\.?|subscribe\.?|you)$",
    re.I,
)


def norm(s: str) -> str:
    s = s.lower().strip()
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def similar(a: str, b: str) -> float:
    na, nb = norm(a), norm(b)
    if not na and not nb:
        return 1.0
    if not na or not nb:
        return 0.0
    return SequenceMatcher(None, na, nb).ratio()


def write_wav_f32(path: Path, data: np.ndarray, sr: int) -> None:
    pcm = np.clip(data, -1, 1)
    if pcm.ndim == 1:
        pcm = pcm[:, None]
    ch = pcm.shape[1]
    pcm = (pcm * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def record_loopback(out_wav: Path, seconds: float) -> None:
    import warnings

    import soundcard as sc

    try:
        from soundcard.mediafoundation import SoundcardRuntimeWarning
    except Exception:
        SoundcardRuntimeWarning = UserWarning

    spk = sc.default_speaker()
    mic = sc.get_microphone(id=str(spk.name), include_loopback=True)
    sr = 48000
    block = sr // 5
    need = int(sr * seconds)
    print(f"record loopback {spk.name} {seconds:.0f}s chunk={block}", flush=True)
    chunks = []
    drops = 0
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always", SoundcardRuntimeWarning)
        with mic.recorder(samplerate=sr, blocksize=block) as rec:
            got = 0
            while got < need:
                n = min(block, need - got)
                c = rec.record(numframes=n)
                chunks.append(c)
                got += c.shape[0]
        drops = sum(
            1
            for w in caught
            if "discontinuity" in str(w.message).lower()
        )
    buf = np.concatenate(chunks, axis=0)
    if drops:
        print(f"loopback dropped {drops} buffers (WASAPI underrun, not fatal)", flush=True)
    write_wav_f32(out_wav, buf, sr)


def separate_vocals(mix: Path, vocals_16k: Path) -> Path:
    """htdemucs on CPU so the 4080 stays with VL. First run downloads the model."""
    out_root = mix.parent / "demucs"
    cmd = [
        "python",
        "-m",
        "demucs",
        "--two-stems",
        "vocals",
        "-n",
        "htdemucs",
        "-d",
        "cpu",
        "--shifts",
        "0",
        "-o",
        str(out_root),
        str(mix),
    ]
    print("htdemucs cpu (first run may download weights)", flush=True)
    t0 = time.time()
    subprocess.check_call(cmd)
    found = list(out_root.rglob("vocals.wav"))
    if not found:
        raise FileNotFoundError(f"demucs produced no vocals.wav under {out_root}")
    raw = found[0]
    print(f"htdemucs done {time.time()-t0:.1f}s -> {raw}", flush=True)
    to_16k_wav(raw, vocals_16k)
    return vocals_16k


def to_16k_wav(src: Path, dst: Path) -> None:
    subprocess.check_call(
        [
            FFMPEG,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(dst),
        ]
    )


def slice_wav(src: Path, dst: Path, t0: float, t1: float) -> None:
    subprocess.check_call(
        [
            FFMPEG,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-ss",
            f"{t0:.3f}",
            "-t",
            f"{max(0.2, t1 - t0):.3f}",
            "-i",
            str(src),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(dst),
        ]
    )


def transcribe(model, wav: Path, language: str, hint: str, beam: int, temperature: float, prev: bool):
    kw = dict(
        language=language,
        beam_size=beam,
        vad_filter=False,
        condition_on_previous_text=prev,
        temperature=temperature,
        word_timestamps=False,
    )
    segs, info = model.transcribe(str(wav), **kw)
    out = []
    for s in segs:
        text = (s.text or "").strip()
        if not text:
            continue
        if hint and similar(text, hint) >= 0.55:
            continue
        if re.match(r"^(outlaw country|gravel n bones|sung lyrics)", text, re.I):
            continue
        if not re.search(r"[A-Za-z0-9]", text):
            continue
        row = {"t0": round(float(s.start), 2), "t1": round(float(s.end), 2), "text": text}
        if is_hallucination(row):
            continue
        out.append(row)
    return out, info


def overlap(a0, a1, b0, b1) -> float:
    lo, hi = max(a0, b0), min(a1, b1)
    return max(0.0, hi - lo)


def is_hallucination(sa) -> bool:
    t = (sa.get("text") or "").strip()
    dur = float(sa["t1"]) - float(sa["t0"])
    words = len(norm(t).split())
    if HALLUC.match(t) and dur >= 6.0:
        return True
    if words <= 2 and dur >= 12.0:
        return True
    return False


def contain_ratio(a: str, b: str) -> float:
    na, nb = norm(a), norm(b)
    if not na or not nb:
        return 0.0
    if na == nb:
        return 1.0
    if len(na) >= 6 and na in nb:
        return 0.94
    if len(nb) >= 6 and nb in na:
        return 0.94
    wa, wb = na.split(), nb.split()
    if not wa or not wb:
        return similar(a, b)
    if len(wa) <= len(wb):
        best = 0.0
        n = len(wa)
        for i in range(0, len(wb) - n + 1):
            best = max(best, SequenceMatcher(None, wa, wb[i : i + n]).ratio())
        return best
    return similar(a, b)


def window_b_text(sa, b) -> str:
    bits = []
    for sb in b:
        if sb["t1"] < sa["t0"] - WINDOW:
            continue
        if sb["t0"] > sa["t1"] + WINDOW:
            continue
        bits.append(sb["text"])
    return " ".join(bits)


def merge_passes(a, b):
    """Lock A's lines when B says the same words nearby. Time overlap is optional."""
    segs = []
    for sa in a:
        if is_hallucination(sa):
            continue
        blob = window_b_text(sa, b)
        if blob:
            agree = max(similar(sa["text"], blob), contain_ratio(sa["text"], blob))
        elif b:
            agree = max(similar(sa["text"], sb["text"]) for sb in b)
        else:
            agree = 0.0
        segs.append(
            {
                "t0": sa["t0"],
                "t1": sa["t1"],
                "text": sa["text"],
                "locked": agree >= AGREE,
                "agree": round(agree, 3),
            }
        )
    return segs


def refuse_overwrite(stpath: Path, new_take: bool, force: bool) -> str | None:
    """A new mix must not land on top of locked lines unless --force."""
    if not new_take or force or not stpath.exists():
        return None
    try:
        state = load_state(stpath)
    except Exception:
        return None
    locked = [s for s in (state.get("segments") or []) if s.get("locked")]
    if not locked:
        return None
    return (
        f"locked lines exist ({len(locked)}); refusing to overwrite the mix. "
        "Pass --force to record again."
    )


def preserve_locks(new_segs, old_locked):
    """Operator-crowned lines survive a rematch of the same take."""
    out = [dict(s) for s in new_segs]
    for old in old_locked:
        hit = False
        for n in out:
            if overlap(n["t0"], n["t1"], old["t0"], old["t1"]) > 0.2:
                n["locked"] = True
                n["text"] = old["text"]
                n["agree"] = max(float(n.get("agree") or 0), float(old.get("agree") or 1))
                hit = True
        if not hit:
            out.append(dict(old))
    return sorted(out, key=lambda s: s["t0"])


def apply_locks(segs, ranges, locked: bool):
    for s in segs:
        for a, b in ranges:
            if overlap(s["t0"], s["t1"], a, b) > 0.2:
                s["locked"] = locked
    return segs


def parse_ranges(s: str):
    out = []
    if not s:
        return out
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        a, b = part.split("-", 1)
        out.append((float(a), float(b)))
    return out


def apply_rewrite(segs, spec: str):
    """'0-30:(umm);40-50:hello' sets text and locks overlapping lines."""
    if not spec:
        return segs
    for part in spec.split(";"):
        part = part.strip()
        if not part or ":" not in part:
            continue
        rng, text = part.split(":", 1)
        a, b = rng.split("-", 1)
        a, b = float(a.strip()), float(b.strip())
        for s in segs:
            if overlap(s["t0"], s["t1"], a, b) > 0.2:
                s["text"] = text
                s["locked"] = True
                s["agree"] = 1.0
    return segs


def is_hum(text: str) -> bool:
    t = re.sub(r"[^a-z]", "", (text or "").lower())
    return t in {"umm", "um", "mm", "mmm", "hmm"} or bool(re.fullmatch(r"m+", t))


def parse_song(s: str):
    if not s:
        return None
    s = s.strip()
    if ":" in s:
        parts = [float(p) for p in s.split(":")]
        if len(parts) == 2:
            return parts[0] * 60.0 + parts[1]
        if len(parts) == 3:
            return parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
    return float(s)


def drop_ranges(segs, ranges):
    return [
        s
        for s in segs
        if not any(overlap(s["t0"], s["t1"], a, b) > 0.2 for a, b in ranges)
    ]


def insert_lines(segs, spec: str):
    """'36.5-39.8:MMmmmmm;40.2-41.3:MMmmmm' appends locked cues."""
    out = list(segs)
    if not spec:
        return out
    for part in spec.split(";"):
        part = part.strip()
        if not part or ":" not in part:
            continue
        rng, text = part.split(":", 1)
        a, b = rng.split("-", 1)
        out.append(
            {
                "t0": round(float(a.strip()), 2),
                "t1": round(float(b.strip()), 2),
                "text": text,
                "locked": True,
                "agree": 1.0,
            }
        )
    return sorted(out, key=lambda s: s["t0"])


def snap_first(segs, t: float):
    """Move the first sung line's start to t (YouTube / song clock)."""
    if t <= 0:
        return segs
    for s in segs:
        if is_hum(s.get("text") or ""):
            continue
        if s["t0"] < t:
            s["t0"] = round(t, 2)
            if s["t1"] <= s["t0"] + 0.3:
                s["t1"] = round(s["t0"] + 1.0, 2)
        break
    return segs


def srt_ts(t: float) -> str:
    t = max(0.0, float(t))
    h = int(t // 3600)
    m = int((t % 3600) // 60)
    sec = t % 60
    return f"{h:02d}:{m:02d}:{sec:06.3f}".replace(".", ",")


def detect_preroll(path: Path, thresh: float = 0.001, hop: float = 0.05) -> float:
    """Seconds of leading silence on mix.wav (record started, then play)."""
    if not path.exists():
        return 0.0
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        n = min(w.getnframes(), int(sr * 15))
        raw = w.readframes(n)
    pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    if ch > 1:
        pcm = pcm.reshape(-1, ch).mean(axis=1)
    pcm /= 32768.0
    hop_n = max(1, int(sr * hop))
    for i in range(0, len(pcm), hop_n):
        sl = pcm[i : i + hop_n]
        if float(np.sqrt(np.mean(sl * sl))) >= thresh:
            return round(i / sr, 2)
    return 0.0


def write_srt(path: Path, segs, song: float | None = None, preroll: float = 0.0):
    pr = float(preroll or 0.0)
    cues = []
    prev_end = -1.0
    n = 0
    for s in segs:
        t0 = float(s["t0"]) - pr
        t1 = float(s["t1"]) - pr
        if t1 <= 0:
            continue
        t0 = max(0.0, t0)
        if song is not None:
            if t0 >= song:
                continue
            t1 = min(t1, song)
        if t1 <= t0:
            continue
        if t0 < prev_end:
            t0 = prev_end
        if t1 <= t0:
            continue
        n += 1
        cues.append(f"{n}\n{srt_ts(t0)} --> {srt_ts(t1)}\n{s['text']}\n")
        prev_end = t1
    path.write_text("\n".join(cues) + ("\n" if cues else ""), encoding="utf-8")


def write_plain(path: Path, segs):
    lines = []
    last_t1 = None
    for s in segs:
        if is_hum(s.get("text") or ""):
            continue
        if last_t1 is not None and s["t0"] - last_t1 >= 2.8:
            lines.append("")
        lines.append(s["text"])
        last_t1 = s["t1"]
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def fmt_song(wav_t, preroll) -> str:
    t = max(0.0, float(wav_t) - float(preroll or 0.0))
    whole = int(round(t))
    return f"{whole // 60}:{whole % 60:02d}"


def timing_note_lines(locked, fresh, preroll, min_shift=0.5):
    """Suggest a song-clock move. Do not change the locked line."""
    notes = []
    for i, s in enumerate(locked, start=1):
        best = None
        best_rank = -1.0
        for f in fresh:
            score = max(similar(s["text"], f["text"]), contain_ratio(s["text"], f["text"]))
            if score < 0.72:
                continue
            dist = abs(float(f["t0"]) - float(s["t0"]))
            rank = score - min(dist, 40.0) * 0.008
            if rank > best_rank:
                best_rank = rank
                best = f
        if not best:
            continue
        if abs(float(best["t0"]) - float(s["t0"])) < min_shift:
            continue
        want = fmt_song(best["t0"], preroll)
        have = fmt_song(s["t0"], preroll)
        if want == have:
            continue
        notes.append(f"line {i} should be at {want} not {have}")
    return notes


def write_md(path: Path, name: str, segs, timing_notes=None):
    locked = [s for s in segs if s["locked"]]
    draft = [s for s in segs if not s["locked"]]
    notes = [n for n in (timing_notes or []) if n]
    lines = [
        f"# {name}",
        f"# locked={len(locked)} draft={len(draft)}  (redo only DRAFT; locked is never overwritten)",
        "# times below are wav clock; lyrics.srt subtracts preroll for YouTube",
        "",
        "## LOCKED",
        "",
    ]
    if not locked:
        lines.append("_(none yet)_")
        lines.append("")
    for s in locked:
        lines.append(f"[{s['t0']:7.1f} -> {s['t1']:7.1f}] {s['text']}")
    lines += ["", "## DRAFT", ""]
    if notes:
        lines.append("_(song clock — locked lines were not moved)_")
        lines.append("")
        lines.extend(notes)
        lines.append("")
    if not draft and not notes:
        lines.append("_(empty — all locked)_")
        lines.append("")
    for s in draft:
        lines.append(f"[{s['t0']:7.1f} -> {s['t1']:7.1f}] {s['text']}  {{agree={s['agree']:.2f}}}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def load_state(st: Path):
    return json.loads(st.read_text(encoding="utf-8"))


def save_state(st: Path, state):
    state["segments"] = sorted(state["segments"], key=lambda s: (float(s["t0"]), float(s["t1"])))
    st.write_text(json.dumps(state, indent=2), encoding="utf-8")
    segs = state["segments"]
    write_md(st.with_name("lyrics.md"), state["name"], segs, state.get("timing_notes") or [])
    write_srt(
        st.with_name("lyrics.srt"),
        segs,
        state.get("song_seconds"),
        state.get("preroll_seconds") or 0.0,
    )
    write_plain(st.with_name("lyrics.txt"), segs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--artist", default="")
    ap.add_argument("--album", default="")
    ap.add_argument("--path")
    ap.add_argument("--record", default="0")
    ap.add_argument("--language", default="en")
    ap.add_argument("--hint", default="")
    ap.add_argument("--threads", type=int, default=20)
    ap.add_argument("--lock", default="")
    ap.add_argument("--unlock", default="")
    ap.add_argument("--rewrite", default="")
    ap.add_argument("--drop", default="")
    ap.add_argument("--insert", default="")
    ap.add_argument("--snap-first", type=float, default=0)
    ap.add_argument("--song", default="")
    ap.add_argument("--preroll", type=float, default=None)
    ap.add_argument("--accept-draft", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--redo-unlocked", action="store_true")
    ap.add_argument("--recheck", action="store_true")
    ap.add_argument("--skip-demucs", action="store_true")
    args = ap.parse_args()

    work = work_dir(args.artist, args.album, args.name)
    work.mkdir(parents=True, exist_ok=True)
    mix = work / "mix.wav"
    wav = work / "vocals.wav"
    stpath = work / "state.json"
    rec = parse_song(args.record) or 0.0
    new_take = rec > 0 or bool(args.path)
    blocked = refuse_overwrite(stpath, new_take, args.force)
    if blocked:
        raise SystemExit(blocked)

    if rec > 0:
        record_loopback(mix, rec)
    elif args.path:
        subprocess.check_call(
            [
                FFMPEG,
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(Path(args.path)),
                "-ar",
                "48000",
                "-c:a",
                "pcm_s16le",
                str(mix),
            ]
        )
    has_edit = bool(
        args.lock
        or args.unlock
        or args.accept_draft
        or args.rewrite
        or args.drop
        or args.insert
        or args.snap_first
        or args.song
        or args.preroll is not None
    )
    # --song alone updates metadata. --song together with --record still separates and transcribes.
    pure_edit = (
        has_edit
        and rec <= 0
        and not args.path
        and not args.force
        and not args.redo_unlocked
        and stpath.exists()
        and wav.exists()
    )
    if not (wav.exists() or mix.exists()) and not pure_edit:
        raise SystemExit("pass --path or --record seconds")

    if not pure_edit:
        if args.skip_demucs:
            if not wav.exists():
                to_16k_wav(mix, wav)
            print("skip demucs, whisper on mix->16k", flush=True)
        elif mix.exists() and (rec > 0 or args.path or not wav.exists()):
            try:
                separate_vocals(mix, wav)
            except Exception as e:
                print(f"htdemucs failed ({e}); falling back to mix", flush=True)
                to_16k_wav(mix, wav)
        if not wav.exists() and mix.exists():
            print(f"vocals missing after demucs; 16k from mix -> {wav}", flush=True)
            to_16k_wav(mix, wav)

    if pure_edit:
        state = load_state(stpath)
        if args.drop:
            state["segments"] = drop_ranges(state["segments"], parse_ranges(args.drop))
        if args.insert:
            state["segments"] = insert_lines(state["segments"], args.insert)
        if args.rewrite:
            apply_rewrite(state["segments"], args.rewrite)
        if args.snap_first:
            snap_first(state["segments"], args.snap_first)
        if args.accept_draft:
            for s in state["segments"]:
                s["locked"] = True
                s["agree"] = max(float(s.get("agree") or 0), 1.0)
        if args.lock:
            apply_locks(state["segments"], parse_ranges(args.lock), True)
        if args.unlock:
            apply_locks(state["segments"], parse_ranges(args.unlock), False)
        state["name"] = args.name
        state["wav"] = str(wav)
        state["mix"] = str(mix)
        if args.artist:
            state["artist"] = args.artist
        if args.album:
            state["album"] = args.album
        if args.song:
            state["song_seconds"] = parse_song(args.song)
        if args.preroll is not None:
            state["preroll_seconds"] = args.preroll
        elif "preroll_seconds" not in state:
            pr = detect_preroll(mix)
            state["preroll_seconds"] = pr
            print(f"preroll {pr:.2f}s (leading silence on mix)", flush=True)
        save_state(stpath, state)
        print(f"locks updated -> {work / 'lyrics.md'}")
        print(f"youtube srt -> {work / 'lyrics.srt'}")
        print(f"plain text -> {work / 'lyrics.txt'}")
        return

    args.check_times = False
    if args.recheck:
        if not stpath.exists():
            raise SystemExit("no lyrics yet for this track; record first")
        prev = load_state(stpath)
        prev_segs = prev.get("segments") or []
        if not prev_segs:
            raise SystemExit("no segments yet; record first")
        n_draft = sum(1 for s in prev_segs if not s.get("locked"))
        if n_draft:
            args.redo_unlocked = True
            print(f"recheck: {n_draft} draft, re-running whisper", flush=True)
        else:
            args.check_times = True
            print("recheck: all locked, checking timestamps", flush=True)

    if (
        stpath.exists()
        and rec <= 0
        and not args.path
        and not args.force
        and not args.redo_unlocked
        and not args.check_times
    ):
        state = load_state(stpath)
        if state.get("pass_a") and state.get("pass_b"):
            print("rematch saved A/B (pass --force to re-transcribe)", flush=True)
            old_locked = [s for s in state["segments"] if s.get("locked")]
            segs = merge_passes(state["pass_a"], state["pass_b"])
            segs = preserve_locks(segs, old_locked)
            state["segments"] = segs
            state.pop("timing_notes", None)
            save_state(stpath, state)
            nlock = sum(1 for s in segs if s["locked"])
            print(f"DONE locked={nlock}/{len(segs)} (rematch) -> {work / 'lyrics.md'}")
            return
        print(
            "state exists; refusing to wipe. --force re-transcribe, --accept-draft, --lock, --rewrite",
            flush=True,
        )
        return

    import os

    os.environ["OMP_NUM_THREADS"] = str(args.threads)
    os.environ["MKL_NUM_THREADS"] = str(args.threads)
    from faster_whisper import WhisperModel

    print("load faster-whisper cpu int8", flush=True)
    t0 = time.time()
    model = WhisperModel(MODEL, device="cpu", compute_type="int8", cpu_threads=args.threads)
    print(f"loaded {time.time()-t0:.1f}s", flush=True)

    hint = args.hint or ""

    if args.check_times:
        if not wav.exists() and mix.exists():
            to_16k_wav(mix, wav)
        if not wav.exists():
            raise SystemExit("no vocals.wav or mix.wav to check")
        state = load_state(stpath)
        locked = [s for s in state["segments"] if s.get("locked")]
        print("pass A timing check", flush=True)
        fresh, _info = transcribe(model, wav, args.language, hint, 1, 0.0, False)
        notes = timing_note_lines(locked, fresh, state.get("preroll_seconds") or 0.0)
        state["timing_notes"] = notes
        save_state(stpath, state)
        print(f"DONE timing notes={len(notes)} -> {work / 'lyrics.md'}")
        return

    if args.redo_unlocked:
        state = load_state(stpath)
        segs = state["segments"]
        unlocked = [s for s in segs if not s["locked"]]
        if not unlocked:
            print("nothing unlocked")
            return
        # merge adjacent unlocked into clips
        groups = []
        cur = dict(unlocked[0])
        for s in unlocked[1:]:
            if s["t0"] <= cur["t1"] + 0.8:
                cur["t1"] = max(cur["t1"], s["t1"])
            else:
                groups.append(cur)
                cur = dict(s)
        groups.append(cur)
        new_unlocked = []
        for g in groups:
            clip = work / f"redo-{g['t0']:.1f}-{g['t1']:.1f}.wav"
            pad0 = max(0.0, g["t0"] - 0.25)
            slice_wav(wav if wav.exists() else mix, clip, pad0, g["t1"] + 0.25)
            print(f"redo {g['t0']:.1f}-{g['t1']:.1f}", flush=True)
            a, _ = transcribe(model, clip, args.language, hint, 1, 0.0, False)
            b, _ = transcribe(model, clip, args.language, hint, 5, 0.0, False)
            merged = merge_passes(a, b)
            for m in merged:
                m["t0"] = round(m["t0"] + pad0, 2)
                m["t1"] = round(m["t1"] + pad0, 2)
            new_unlocked.extend(merged)
        locked = [s for s in segs if s["locked"]]
        state["segments"] = sorted(locked + new_unlocked, key=lambda s: s["t0"])
        state.pop("timing_notes", None)
        save_state(stpath, state)
        nlock = sum(1 for s in state["segments"] if s["locked"])
        print(f"DONE locked={nlock}/{len(state['segments'])} -> {work / 'lyrics.md'}")
        return

    old_locked = []
    # A new recording has a new clock. Do not stamp the previous take's
    # locked sentences onto it.
    if stpath.exists() and not new_take:
        try:
            old_locked = [s for s in load_state(stpath)["segments"] if s.get("locked")]
        except Exception:
            old_locked = []

    # Pass B must stay temperature 0. Any temperature above 0 forces beam_size=1
    # inside faster-whisper, and condition_on_previous_text makes sung lines repeat
    # until the chunk is rejected. That is how pass B came back empty.
    t_pass = time.time()
    print("pass A", flush=True)
    a, info = transcribe(model, wav, args.language, hint, 1, 0.0, False)
    print(f"  pass A {len(a)} lines in {time.time() - t_pass:.0f}s", flush=True)
    t_pass = time.time()
    print("pass B", flush=True)
    b, _ = transcribe(model, wav, args.language, hint, 5, 0.0, False)
    print(f"  pass B {len(b)} lines in {time.time() - t_pass:.0f}s", flush=True)
    if not b:
        print("pass B empty, retry beam 5", flush=True)
        t_pass = time.time()
        b, _ = transcribe(model, wav, args.language, hint, 5, 0.0, False)
        print(f"  pass B retry {len(b)} lines in {time.time() - t_pass:.0f}s", flush=True)
    segs = preserve_locks(merge_passes(a, b), old_locked)
    state = {
        "name": args.name,
        "artist": args.artist,
        "album": args.album,
        "wav": str(wav),
        "mix": str(mix),
        "language": args.language,
        "hint": hint,
        "lang_prob": getattr(info, "language_probability", None),
        "pass_a": a,
        "pass_b": b,
        "segments": segs,
    }
    if args.song:
        state["song_seconds"] = parse_song(args.song)
    if args.preroll is not None:
        state["preroll_seconds"] = args.preroll
    elif mix.exists():
        state["preroll_seconds"] = detect_preroll(mix)
        print(f"preroll {state['preroll_seconds']:.2f}s (leading silence on mix)", flush=True)
    save_state(stpath, state)
    nlock = sum(1 for s in segs if s["locked"])
    print(f"DONE locked={nlock}/{len(segs)} lang={info.language} -> {work / 'lyrics.md'}")
    print(f"youtube srt -> {work / 'lyrics.srt'}")


if __name__ == "__main__":
    main()
