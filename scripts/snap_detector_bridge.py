"""Real-time acoustic finger-snap detector for Lite XL PPTX Slideshow Mode.

Solves two core acoustic challenges without external ML dependencies (pure numpy):
1. False trigger rejection (speech, coughs, desk bumps, AC hum):
   - Uses 10 ms hop frames at 44.1 kHz / 48 kHz with rFFT spectral analysis.
   - Subtracts slowly-adapting ambient noise spectrum so constant room/fan hum
     does not skew spectral ratios.
   - Checks sharp onset attack slope, high crest factor (peak / RMS),
     high-frequency concentration (1.8-8.5 kHz vs < 1.1 kHz low band), and
     short < 80 ms decay tail to reject sustained speech, vowels, and coughs.
2. Far-field / distant presenter support (2-4 meters from microphone):
   - Tracks an adaptive per-band quiet room floor via slow asymmetric EMA
     instead of relying only on a high absolute volume gate.
   - Triggers on high-band SNR jump relative to the room baseline while enforcing
     a tiny electrical noise floor to guard dead silence.

Protocol (UTF-8 line-buffered JSON on stdout):
  {"event": "ready", "sample_rate": 48000, "sensitivity": "normal"}
  {"event": "snap", "count": 1, "action": "next", "snr": 12.4, "ratio": 3.8}
  {"event": "snap", "count": 2, "action": "prev", "snr": 11.1, "ratio": 3.2}
  {"event": "error", "message": "..."}
"""

import argparse
import collections
import json
import math
import queue
import sys
import threading
import time

try:
    import numpy as np
except ImportError:
    np = None

try:
    import sounddevice as sd
except ImportError:
    sd = None

# Ensure line-buffered UTF-8 output on Windows pipes so Lite XL receives events immediately
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        try:
            stream.reconfigure(encoding="utf-8", line_buffering=True)
        except Exception:
            pass


def emit_event(event_name, **kwargs):
    """Print a compact single-line JSON event and flush immediately."""
    payload = {"event": event_name}
    payload.update(kwargs)
    try:
        print(json.dumps(payload, ensure_ascii=False), flush=True)
    except Exception:
        pass


SENSITIVITY_PRESETS = {
    # Balanced for 0.4m - 3.5m range while blocking speech/desk bumps
    "normal": {
        "min_snr": 5.0,
        "min_peak": 0.0045,
        "min_crest": 3.0,
        "min_attack": 3.0,
        "min_band_ratio": 1.25,
        "min_snap_fraction": 0.42,
        "max_decay_ratio": 0.48,
    },
    # Extra sensitive for far presenter across a room (> 3m)
    "high": {
        "min_snr": 3.6,
        "min_peak": 0.0022,
        "min_crest": 2.75,
        "min_attack": 2.4,
        "min_band_ratio": 1.05,
        "min_snap_fraction": 0.36,
        "max_decay_ratio": 0.55,
    },
    # Strict for noisy environments or close laptop mics
    "low": {
        "min_snr": 7.0,
        "min_peak": 0.0100,
        "min_crest": 3.4,
        "min_attack": 3.8,
        "min_band_ratio": 1.55,
        "min_snap_fraction": 0.48,
        "max_decay_ratio": 0.42,
    },
}


class SnapDetectorEngine:
    """Frame-by-frame numpy DSP finger-snap detector & single/double state machine."""

    def __init__(
        self,
        sample_rate=48000,
        sensitivity="normal",
        double_window_sec=0.40,
        min_double_gap_sec=0.10,
        cooldown_single_sec=0.28,
        cooldown_double_sec=0.48,
        emit_fn=None,
    ):
        if np is None:
            raise RuntimeError("numpy is required for snap detection")

        self.sample_rate = int(sample_rate)
        self.win_sec = 0.010   # 10 ms FFT window
        self.frame_sec = 0.005 # 5 ms hop (50% overlap prevents Hann taper blind spots)
        self.frame_len = max(256, int(round(self.sample_rate * self.win_sec)))
        self.hop_len = max(128, self.frame_len // 2)

        preset = SENSITIVITY_PRESETS.get(sensitivity, SENSITIVITY_PRESETS["normal"])
        self.sensitivity = sensitivity if sensitivity in SENSITIVITY_PRESETS else "normal"
        self.min_snr = preset["min_snr"]
        self.min_peak = preset["min_peak"]
        self.min_crest = preset["min_crest"]
        self.min_attack = preset["min_attack"]
        self.min_band_ratio = preset["min_band_ratio"]
        self.min_snap_fraction = preset["min_snap_fraction"]
        self.max_decay_ratio = preset["max_decay_ratio"]

        self.double_window_sec = float(double_window_sec)
        self.min_double_gap_sec = float(min_double_gap_sec)
        self.cooldown_single_sec = float(cooldown_single_sec)
        self.cooldown_double_sec = float(cooldown_double_sec)
        self.emit_fn = emit_fn or emit_event

        # Precompute rFFT frequency masks for 10 ms Hann-windowed frames
        self.window = np.hanning(self.frame_len).astype(np.float32)
        freqs = np.fft.rfftfreq(self.frame_len, d=1.0 / self.sample_rate)
        self.low_mask = (freqs >= 60.0) & (freqs <= 1150.0)
        self.snap_mask = (freqs >= 1800.0) & (freqs <= 8500.0)
        self.hp_mask = freqs >= 1200.0
        self.total_mask = freqs >= 60.0

        # Adaptive ambient baseline (seeded conservatively, warms up during first ~0.25s)
        self.warmup_frames = 50  # 50 * 5 ms = 250 ms ambient baseline capture
        self.frame_idx = 0
        self.bg_snap_rms = 1e-4
        self.bg_low_rms = 1e-4
        self.bg_snap_pow = 1e-8
        self.bg_low_pow = 1e-8
        self.prev_snap_rms = collections.deque([1e-4] * 5, maxlen=5)
        self.hist_features = collections.deque(maxlen=18)  # ~90 ms lookback for pre-onset floor

        # Candidate peak-and-decay verification state
        self.candidate = None  # dict while inspecting +60 ms decay tail
        self.verify_frames = 12  # 12 * 5 ms = 60 ms decay verification horizon

        # Single / Double snap disambiguation state machine
        self.pending_snap = None  # dict from first validated snap
        self.cooldown_until = 0.0
        self.stream_time = 0.0

        # Residual accumulator when feed() receives arbitrary chunk lengths
        self._pcm_buf = np.zeros(0, dtype=np.float32)

    def _compute_frame_features(self, frame):
        """Extract time-domain & high-pass spectral features for one 10 ms window."""
        centered = frame - np.mean(frame)
        spec = np.fft.rfft(centered * self.window)
        power = (spec.real * spec.real + spec.imag * spec.imag) / max(1, self.frame_len)

        # Compute crest & peak on >=1.2 kHz high-passed wave so fan/AC hum never masks snaps
        hp_wave = np.fft.irfft(spec * self.hp_mask, n=self.frame_len)
        peak = float(np.max(np.abs(hp_wave)))
        hp_rms = float(np.sqrt(np.mean(hp_wave * hp_wave)) + 1e-9)
        crest = peak / hp_rms

        low_pow = float(np.sum(power[self.low_mask]))
        snap_pow = float(np.sum(power[self.snap_mask]))
        total_pow = float(np.sum(power[self.total_mask]))

        snap_rms = math.sqrt(snap_pow / max(1, int(np.sum(self.snap_mask))) + 1e-18)
        low_rms = math.sqrt(low_pow / max(1, int(np.sum(self.low_mask))) + 1e-18)

        return {
            "peak": peak,
            "rms": hp_rms,
            "crest": crest,
            "low_pow": low_pow,
            "snap_pow": snap_pow,
            "total_pow": total_pow,
            "snap_rms": snap_rms,
            "low_rms": low_rms,
        }

    def _update_baseline(self, feat):
        """Update quiet room floor asymmetrically (fast decay down, slow drift on persistent noise)."""
        if self.frame_idx <= self.warmup_frames:
            alpha = 0.12 if self.frame_idx > 1 else 1.0
            self.bg_snap_rms = (1.0 - alpha) * self.bg_snap_rms + alpha * feat["snap_rms"]
            self.bg_low_rms = (1.0 - alpha) * self.bg_low_rms + alpha * feat["low_rms"]
            self.bg_snap_pow = (1.0 - alpha) * self.bg_snap_pow + alpha * feat["snap_pow"]
            self.bg_low_pow = (1.0 - alpha) * self.bg_low_pow + alpha * feat["low_pow"]
            return

        # Quiet/steady frames track normally; loud sudden shifts still nudge very slowly so floor never deadlocks
        if feat["snap_rms"] < self.bg_snap_rms * 2.2:
            alpha = 0.03 if feat["snap_rms"] >= self.bg_snap_rms else 0.06
            self.bg_snap_rms = (1.0 - alpha) * self.bg_snap_rms + alpha * feat["snap_rms"]
            self.bg_snap_pow = (1.0 - alpha) * self.bg_snap_pow + alpha * feat["snap_pow"]
        else:
            self.bg_snap_rms = 0.996 * self.bg_snap_rms + 0.004 * feat["snap_rms"]
            self.bg_snap_pow = 0.996 * self.bg_snap_pow + 0.004 * feat["snap_pow"]

        if feat["low_rms"] < self.bg_low_rms * 2.2:
            alpha = 0.04 if feat["low_rms"] >= self.bg_low_rms else 0.06
            self.bg_low_rms = (1.0 - alpha) * self.bg_low_rms + alpha * feat["low_rms"]
            self.bg_low_pow = (1.0 - alpha) * self.bg_low_pow + alpha * feat["low_pow"]
        else:
            self.bg_low_rms = 0.985 * self.bg_low_rms + 0.015 * feat["low_rms"]
            self.bg_low_pow = 0.985 * self.bg_low_pow + 0.015 * feat["low_pow"]

    def _local_low_floor(self):
        """Estimate immediate pre-onset low-band room hum (absorbs steady fan/AC beat)."""
        if len(self.hist_features) < 6:
            return self.bg_low_pow
        pre = [f["low_pow"] for f in list(self.hist_features)[:-3]]
        return max(self.bg_low_pow, float(np.percentile(pre, 90)) * 1.05)

    def _finalize_candidate(self):
        """Evaluate accumulated 60 ms peak + decay envelope and emit to gesture FSM."""
        c = self.candidate
        self.candidate = None

        # Peak metrics across the first 2 frames (0..20 ms) cover boundary-split snaps
        peak_snap_rms = c["peak_snap_rms"]
        snr = peak_snap_rms / max(self.bg_snap_rms, 1e-6)
        band_ratio = c["core_excess_snap"] / max(c["core_excess_low"], 1e-12)
        snap_fraction = c["core_excess_snap"] / max(c["core_excess_total"], 1e-12)

        # Tail decay: inspect frames +4..+6 (40-70 ms post-onset); speech/coughs linger high
        tail = c["tail_snap_rms"]
        tail_level = min(tail) if tail else peak_snap_rms
        decay_ratio = tail_level / max(peak_snap_rms, 1e-9)

        passed = (
            snr >= self.min_snr
            and c["max_crest"] >= self.min_crest
            and band_ratio >= self.min_band_ratio
            and snap_fraction >= self.min_snap_fraction
            and decay_ratio <= self.max_decay_ratio
        )
        if not passed:
            return

        snap_time = c["trigger_time"]
        meta = {
            "time": round(snap_time, 3),
            "snr": round(snr, 2),
            "ratio": round(min(band_ratio, 99.9), 2),
            "crest": round(c["max_crest"], 2),
            "decay": round(decay_ratio, 2),
        }

        if self.pending_snap is not None:
            dt = snap_time - self.pending_snap["time"]
            if self.min_double_gap_sec <= dt <= self.double_window_sec:
                self.pending_snap = None
                self.cooldown_until = snap_time + self.cooldown_double_sec
                self.emit_fn("snap", count=2, action="prev", dt=round(dt, 3), **meta)
                return

        self.pending_snap = meta

    def _check_pending_timeout(self):
        """Emit single-snap 'next' once double-snap window closes without a second impulse."""
        if self.pending_snap is None or self.candidate is not None:
            return
        if (self.stream_time - self.pending_snap["time"]) > self.double_window_sec:
            snap = self.pending_snap
            self.pending_snap = None
            self.cooldown_until = self.stream_time + self.cooldown_single_sec
            self.emit_fn(
                "snap",
                count=1,
                action="next",
                snr=snap["snr"],
                ratio=snap["ratio"],
                crest=snap["crest"],
                decay=snap["decay"],
            )

    def _process_frame(self, frame):
        """Process one exact `frame_len` mono float32 frame."""
        self.frame_idx += 1
        self.stream_time += self.frame_sec
        feat = self._compute_frame_features(frame)

        # Warmup: measure initial ambient background before arming triggers
        if self.frame_idx <= self.warmup_frames:
            self._update_baseline(feat)
            self.prev_snap_rms.append(feat["snap_rms"])
            self.hist_features.append(feat)
            return

        # 1. If currently verifying a candidate's +60 ms decay tail, gather tail frames
        if self.candidate is not None:
            c = self.candidate
            c["age"] += 1
            low_floor = c["low_floor"]
            excess_snap = max(0.0, feat["snap_pow"] - c["snap_floor"])
            excess_low = max(0.0, feat["low_pow"] - low_floor)
            excess_tot = max(0.0, feat["total_pow"] - (c["snap_floor"] + low_floor))

            if c["age"] <= 3:
                # Frames +1..+3 (5-15 ms) capture impulse straddling Hann window center
                c["peak_snap_rms"] = max(c["peak_snap_rms"], feat["snap_rms"])
                c["max_crest"] = max(c["max_crest"], feat["crest"])
                c["core_excess_snap"] += excess_snap
                c["core_excess_low"] += excess_low
                c["core_excess_total"] += excess_tot
            elif c["age"] >= 8:
                # +40..+60 ms tail window confirms rapid impulse decay (< 80 ms)
                c["tail_snap_rms"].append(feat["snap_rms"])

            if c["age"] >= self.verify_frames:
                self._finalize_candidate()
            self.prev_snap_rms.append(feat["snap_rms"])
            self.hist_features.append(feat)
            return

        # 2. Check if pending single snap timed out waiting for a double snap
        self._check_pending_timeout()

        # 3. During echo-suppression cooldown, allow baseline tracking on quiet frames only
        if self.stream_time < self.cooldown_until:
            self._update_baseline(feat)
            self.prev_snap_rms.append(feat["snap_rms"])
            self.hist_features.append(feat)
            return

        # 4. Detect sharp high-frequency impulse onset
        pre_snap = max(min(self.prev_snap_rms), 1e-6)
        attack_slope = feat["snap_rms"] / pre_snap
        snr = feat["snap_rms"] / max(self.bg_snap_rms, 1e-6)

        low_floor = self._local_low_floor()
        snap_floor = self.bg_snap_pow
        excess_snap = max(0.0, feat["snap_pow"] - snap_floor)
        excess_low = max(0.0, feat["low_pow"] - low_floor)
        excess_tot = max(0.0, feat["total_pow"] - (snap_floor + low_floor))
        quick_ratio = excess_snap / max(excess_low, 1e-12)

        is_candidate = (
            feat["peak"] >= self.min_peak
            and snr >= self.min_snr
            and attack_slope >= self.min_attack
            and feat["crest"] >= (self.min_crest * 0.70)  # full crest checked across center hops
            and quick_ratio >= (self.min_band_ratio * 0.75)
        )

        if is_candidate:
            self.candidate = {
                "trigger_time": self.stream_time,
                "age": 0,
                "low_floor": low_floor,
                "snap_floor": snap_floor,
                "peak_snap_rms": feat["snap_rms"],
                "max_crest": feat["crest"],
                "core_excess_snap": excess_snap,
                "core_excess_low": excess_low,
                "core_excess_total": excess_tot,
                "tail_snap_rms": [],
            }
        else:
            self._update_baseline(feat)

        self.prev_snap_rms.append(feat["snap_rms"])
        self.hist_features.append(feat)

    def feed(self, samples):
        """Feed mono float32 audio samples (arbitrary chunk size) into the detector."""
        arr = np.asarray(samples, dtype=np.float32).reshape(-1)
        if arr.size == 0:
            return
        if self._pcm_buf.size > 0:
            arr = np.concatenate((self._pcm_buf, arr))
        offset = 0
        limit = arr.size - self.frame_len
        while offset <= limit:
            self._process_frame(arr[offset : offset + self.frame_len])
            offset += self.hop_len
        self._pcm_buf = arr[offset:].copy()

    def flush(self):
        """Flush trailing silence frames so final pending snap / candidate resolves cleanly."""
        silence = np.zeros(self.frame_len, dtype=np.float32)
        for _ in range(int(math.ceil((self.double_window_sec + 0.12) / self.frame_sec))):
            self._process_frame(silence)


def _synth_snap(sr, amp=0.03, center_hz=3200.0, decay_ms=14.0):
    """Synthesize a physically realistic finger snap impulse (damped 2-6 kHz burst)."""
    n = int(sr * 0.090)
    t = np.arange(n, dtype=np.float32) / sr
    tau = decay_ms / 1000.0
    env = np.exp(-t / tau)
    sig = (
        0.65 * np.sin(2 * np.pi * center_hz * t)
        + 0.35 * np.sin(2 * np.pi * (center_hz * 1.58) * t)
    ) * env
    rng = np.random.default_rng(7)
    sig += 0.25 * rng.standard_normal(n).astype(np.float32) * np.exp(-t / (tau * 0.5))
    sig *= amp / max(float(np.max(np.abs(sig))), 1e-9)
    return sig.astype(np.float32)


def run_self_test():
    """Run offline synthetic DSP tests verifying false-trigger rejection and far snaps."""
    if np is None:
        print("FAIL: numpy unavailable", file=sys.stderr)
        return 1

    sr = 48000
    events = []
    det = SnapDetectorEngine(
        sample_rate=sr,
        sensitivity="normal",
        emit_fn=lambda name, **kw: events.append((name, kw)),
    )
    rng = np.random.default_rng(42)

    def silence(sec):
        return (0.00025 * rng.standard_normal(int(sr * sec))).astype(np.float32)

    # 1. Room warmup + quiet steady HVAC / projector fan hum (120 Hz)
    t_fan = np.arange(int(sr * 0.5), dtype=np.float32) / sr
    fan = 0.015 * np.sin(2 * np.pi * 120.0 * t_fan) + silence(0.5)
    det.feed(fan)

    # 2. Loud desk bump (90 Hz + 220 Hz thud) -> MUST BE REJECTED
    t_bump = np.arange(int(sr * 0.12), dtype=np.float32) / sr
    bump = 0.35 * np.sin(2 * np.pi * 95.0 * t_bump) * np.exp(-t_bump / 0.025)
    bump += 0.12 * np.sin(2 * np.pi * 240.0 * t_bump) * np.exp(-t_bump / 0.018)
    det.feed(bump.astype(np.float32))
    det.feed(silence(0.6))

    # 3. Presenter talking normally (voiced vowels 180-750 Hz + mild sibilant over 220 ms) -> REJECTED
    t_sp = np.arange(int(sr * 0.25), dtype=np.float32) / sr
    speech = (
        0.18 * np.sin(2 * np.pi * 185.0 * t_sp)
        + 0.12 * np.sin(2 * np.pi * 520.0 * t_sp)
        + 0.05 * np.sin(2 * np.pi * 2400.0 * t_sp)
    ) * np.sin(np.pi * t_sp / 0.25)
    det.feed(speech.astype(np.float32))
    det.feed(silence(0.6))

    # 4. Sustained cough burst (chest thump 140-400 Hz + long 150 ms turbulent noise) -> REJECTED
    t_cg = np.arange(int(sr * 0.18), dtype=np.float32) / sr
    cough = (
        0.22 * np.sin(2 * np.pi * 210.0 * t_cg)
        + 0.09 * rng.standard_normal(t_cg.size).astype(np.float32)
    ) * np.exp(-t_cg / 0.075)
    det.feed(cough.astype(np.float32))
    det.feed(silence(0.6))

    # 4b. Sustained high-frequency sibilant speech ("shhhh") -> REJECTED via crest & decay
    n_sib = int(sr * 0.25)
    raw_sib = rng.standard_normal(n_sib).astype(np.float32)
    # Emphasize 2-6 kHz sibilant energy using FFT bandpass
    sib_spec = np.fft.rfft(raw_sib)
    sib_f = np.fft.rfftfreq(n_sib, d=1.0 / sr)
    sib_spec *= ((sib_f >= 2000.0) & (sib_f <= 7000.0)).astype(np.float32)
    sib = np.fft.irfft(sib_spec, n=n_sib).astype(np.float32)
    sib *= 0.08 / max(float(np.max(np.abs(sib))), 1e-9)
    sib *= np.sin(np.pi * np.arange(n_sib, dtype=np.float32) / n_sib)
    det.feed(sib)
    det.feed(silence(0.6))

    assert len(events) == 0, f"False triggers detected: {events}"

    # 5. Far-field single soft snap (low amp=0.008, ~3m away + projector fan hum) -> 'next'
    t_snap_pad = np.arange(int(sr * 1.1), dtype=np.float32) / sr
    fan_bg = 0.015 * np.sin(2 * np.pi * 120.0 * t_snap_pad) + silence(1.1)
    far_snap = _synth_snap(sr, amp=0.008, center_hz=3100.0, decay_ms=18.0)
    buf = fan_bg.copy()
    buf[int(sr * 0.4) : int(sr * 0.4) + far_snap.size] += far_snap
    det.feed(buf.astype(np.float32))
    assert len(events) == 1 and events[0][1]["action"] == "next", f"Expected single next, got {events}"

    # 6. Fast double snap (200 ms apart) -> 'prev'
    det.feed(silence(0.4))
    snap1 = _synth_snap(sr, amp=0.025, center_hz=3400.0, decay_ms=14.0)
    snap2 = _synth_snap(sr, amp=0.022, center_hz=3500.0, decay_ms=14.0)
    det.feed(snap1)
    det.feed(silence(0.11))  # 0.09s snap + 0.11s silence = 0.20s apart
    det.feed(snap2)
    det.feed(silence(0.6))
    assert len(events) == 2 and events[1][1]["action"] == "prev", f"Expected double prev, got {events}"

    print(json.dumps({"self_test": "PASS", "events": events}))
    return 0


def run_live(sensitivity="normal", double_window_ms=400):
    """Stream microphone audio via sounddevice and emit snap JSON events."""
    if np is None or sd is None:
        missing = "numpy" if np is None else "sounddevice"
        emit_event("error", message=f"Python package '{missing}' not installed. Run: pip install numpy sounddevice")
        return 1

    try:
        dev_info = sd.query_devices(kind="input")
        native_sr = int(round(dev_info.get("default_samplerate") or 48000))
        if native_sr < 22050:
            native_sr = 44100
    except Exception as exc:
        emit_event("error", message=f"No input microphone available: {exc}")
        return 1

    engine = SnapDetectorEngine(
        sample_rate=native_sr,
        sensitivity=sensitivity,
        double_window_sec=max(0.20, min(0.75, double_window_ms / 1000.0)),
    )

    audio_q = queue.Queue(maxsize=128)
    stop_evt = threading.Event()

    def stdin_watcher():
        try:
            for line in sys.stdin:
                if line.strip().upper() == "STOP":
                    stop_evt.set()
                    break
        except Exception:
            pass

    threading.Thread(target=stdin_watcher, daemon=True).start()

    def audio_callback(indata, frames, time_info, status):
        if stop_evt.is_set():
            return
        try:
            audio_q.put_nowait(indata[:, 0].copy())
        except queue.Full:
            pass

    emit_event("calibrating", message="Calibrating room noise floor...")

    try:
        with sd.InputStream(
            samplerate=native_sr,
            channels=1,
            dtype="float32",
            blocksize=engine.hop_len,
            callback=audio_callback,
        ):
            emit_event("ready", sample_rate=native_sr, sensitivity=engine.sensitivity)
            while not stop_evt.is_set():
                try:
                    chunk = audio_q.get(timeout=0.05)
                    engine.feed(chunk)
                except queue.Empty:
                    # Advance timeout slightly only if pending single snap is waiting during stall
                    if engine.pending_snap is not None and engine.candidate is None:
                        engine.feed(np.zeros(engine.hop_len, dtype=np.float32))
    except Exception as exc:
        emit_event("error", message=f"Microphone stream error: {exc}")
        return 1

    engine.flush()
    return 0


def main():
    parser = argparse.ArgumentParser(description="Finger snap microphone slide detector")
    parser.add_argument("--sensitivity", default="normal", choices=["low", "normal", "high"])
    parser.add_argument("--double-window-ms", type=int, default=400)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())
    sys.exit(run_live(sensitivity=args.sensitivity, double_window_ms=args.double_window_ms))


if __name__ == "__main__":
    main()
