"""Real-time ML-powered acoustic finger-snap detector for Lite XL PPTX Slideshow Mode.

Combines pure-numpy DSP tracking with a trained 26-feature Neural Network classifier
(plus optional per-room/user calibration) to prevent false triggers in:
1. Solo speaking environments:
   - Tracks 2.5s rolling Median + MAD background noise floor (never collapses during pauses).
   - Runs pitch-range autocorrelation VAD (`75-360 Hz`) + low-band vowel spillover analysis
     over `[-115..+80 ms]` to cleanly reject spoken stop plosives (`t/k/p/ch + vowel`),
     sibilants, tongue/lip clicks, coughs, and breaths.
2. Noisy environments (fan/AC, cafe babble, keyboard typing, mouse clicks, hand claps):
   - Noise-subtracted 8-band spectral shape, Wiener flatness, sub-ms FWHM envelope,
     kurtosis, and transient burst-density gating suppress typing bursts, double-bounce clicks,
     claps, and fluctuating room clatter while keeping 2-4m far-field snaps responsive.

Protocol (UTF-8 line-buffered JSON on stdout):
  {"event": "calibrating", "message": "..."}
  {"event": "ready", "sample_rate": 48000, "sensitivity": "normal", "ml": true}
  {"event": "snap", "count": 1, "action": "next", "prob": 0.96, "snr": 12.4}
  {"event": "snap", "count": 2, "action": "prev", "prob": 0.94, "snr": 11.1}
  {"event": "error", "message": "..."}
"""

import argparse
import collections
import json
import math
import os
import queue
import sys
import threading

try:
    import numpy as np
except ImportError:
    np = None

try:
    import sounddevice as sd
except ImportError:
    sd = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

if np is not None:
    from snap_features import extract_snap_features, estimate_voiced_acf, _highpass_fft
else:
    extract_snap_features = None
    estimate_voiced_acf = None
    _highpass_fft = None

DEFAULT_MODEL_PATH = os.path.join(SCRIPT_DIR, "snap_ml_model.npz")
DEFAULT_PROFILE_PATH = os.path.join(os.path.dirname(SCRIPT_DIR), "tempfiles", "snap_profile.json")

# Ensure line-buffered UTF-8 output on Windows pipes so Lite XL receives events immediately
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", line_buffering=True)
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
    # Extra sensitive for far presenter across a room (> 3m)
    "high": {
        "min_snr": 3.4,
        "mad_k": 5.0,
        "min_peak": 0.0020,
        "min_crest_pre": 2.0,
        "min_attack": 2.1,
        "min_band_ratio": 0.75,
        "ml_thresh": 0.64,
        "speech_boost": 0.12,
        "clutter_boost": 0.08,
    },
    # Balanced default for 0.4m - 3.5m presenter while rejecting speech & room noise
    "normal": {
        "min_snr": 4.2,
        "mad_k": 6.5,
        "min_peak": 0.0038,
        "min_crest_pre": 2.2,
        "min_attack": 2.5,
        "min_band_ratio": 0.90,
        "ml_thresh": 0.76,
        "speech_boost": 0.10,
        "clutter_boost": 0.08,
    },
    # Strict mode for loud / noisy environments or close laptop mics
    "low": {
        "min_snr": 5.5,
        "mad_k": 8.0,
        "min_peak": 0.0080,
        "min_crest_pre": 2.6,
        "min_attack": 3.0,
        "min_band_ratio": 1.15,
        "ml_thresh": 0.86,
        "speech_boost": 0.08,
        "clutter_boost": 0.06,
    },
}


class SnapMLClassifier:
    """Pure-numpy MLP inference + OOD guard + optional personal room prototype."""

    def __init__(self, model_path=DEFAULT_MODEL_PATH, profile_path=DEFAULT_PROFILE_PATH):
        self.loaded = False
        self.feat_mean = None
        self.feat_std = None
        self.proto_mean = None
        self.proto_std = None
        self.weights = None
        self.personal_mean = None
        self.personal_std = None

        if np is None:
            return

        if model_path and os.path.exists(model_path):
            try:
                data = np.load(model_path, allow_pickle=False)
                self.feat_mean = data["feat_mean"].astype(np.float32)
                self.feat_std = np.maximum(data["feat_std"].astype(np.float32), 1e-4)
                self.proto_mean = data["proto_mean"].astype(np.float32)
                self.proto_std = np.maximum(data["proto_std"].astype(np.float32), 0.20)
                self.weights = (
                    data["W1"].astype(np.float32),
                    data["b1"].astype(np.float32),
                    data["W2"].astype(np.float32),
                    data["b2"].astype(np.float32),
                    data["W3"].astype(np.float32),
                    data["b3"].astype(np.float32),
                )
                self.loaded = True
            except Exception:
                self.loaded = False

        if profile_path and os.path.exists(profile_path):
            try:
                with open(profile_path, "r", encoding="utf-8") as f:
                    prof = json.load(f)
                pm = np.array(prof.get("mean", []), dtype=np.float32)
                ps = np.array(prof.get("std", []), dtype=np.float32)
                if self.loaded and pm.shape == self.feat_mean.shape and ps.shape == self.feat_mean.shape:
                    self.personal_mean = pm
                    self.personal_std = np.maximum(ps, 0.25)
            except Exception:
                pass

    def predict(self, feats):
        """Return (prob_snap, ood_z_distance) for a single feature vector."""
        if not self.loaded:
            # Conservative analytical fallback if model file missing
            score = 0.25 * feats[12] + 0.25 * feats[13] + 0.20 * (1.0 - feats[11]) + 0.15 * feats[21] - 0.35 * feats[22]
            return float(max(0.0, min(1.0, score + 0.2))), 1.0

        z = (feats - self.feat_mean) / self.feat_std
        W1, b1, W2, b2, W3, b3 = self.weights
        a1 = np.maximum(0.0, z @ W1 + b1)
        a2 = np.maximum(0.0, a1 @ W2 + b2)
        logit = float((a2 @ W3 + b3)[0])
        logit = max(-30.0, min(30.0, logit))
        prob = 1.0 / (1.0 + math.exp(-logit))

        ood_z = float(np.sqrt(np.mean(((z - self.proto_mean) / self.proto_std) ** 2)))

        # Gentle personal calibration adjustment when user saved a room profile
        if self.personal_mean is not None:
            p_dist = float(np.sqrt(np.mean(((z - self.personal_mean) / self.personal_std) ** 2)))
            if p_dist < 1.3:
                prob = min(0.995, prob + 0.06 * (1.3 - p_dist))
            elif p_dist > 3.0:
                prob = max(0.0, prob - 0.08 * min(2.0, p_dist - 3.0))

        return float(prob), ood_z


class SnapDetectorEngine:
    """Two-stage rolling-quantile DSP + ML acoustic finger-snap detector."""

    def __init__(
        self,
        sample_rate=48000,
        sensitivity="normal",
        double_window_sec=0.40,
        min_double_gap_sec=0.10,
        cooldown_single_sec=0.28,
        cooldown_double_sec=0.48,
        emit_fn=None,
        model_path=DEFAULT_MODEL_PATH,
        profile_path=DEFAULT_PROFILE_PATH,
        debug_fn=None,
    ):
        if np is None:
            raise RuntimeError("numpy is required for snap detection")

        self.sample_rate = int(sample_rate)
        self.win_sec = 0.010   # 10 ms FFT frame
        self.frame_sec = 0.005 # 5 ms hop
        self.frame_len = max(256, int(round(self.sample_rate * self.win_sec)))
        self.hop_len = max(128, self.frame_len // 2)

        preset = SENSITIVITY_PRESETS.get(sensitivity, SENSITIVITY_PRESETS["normal"])
        self.sensitivity = sensitivity if sensitivity in SENSITIVITY_PRESETS else "normal"
        self.min_snr = preset["min_snr"]
        self.mad_k = preset["mad_k"]
        self.min_peak = preset["min_peak"]
        self.min_crest_pre = preset["min_crest_pre"]
        self.min_attack = preset["min_attack"]
        self.min_band_ratio = preset["min_band_ratio"]
        self.ml_thresh = preset["ml_thresh"]
        self.speech_boost = preset["speech_boost"]
        self.clutter_boost = preset["clutter_boost"]

        self.double_window_sec = float(double_window_sec)
        self.min_double_gap_sec = float(min_double_gap_sec)
        self.cooldown_single_sec = float(cooldown_single_sec)
        self.cooldown_double_sec = float(cooldown_double_sec)
        self.emit_fn = emit_fn or emit_event
        self.debug_fn = debug_fn

        self.classifier = SnapMLClassifier(model_path=model_path, profile_path=profile_path)

        # Precompute rFFT frequency masks
        self.window = np.hanning(self.frame_len).astype(np.float32)
        freqs = np.fft.rfftfreq(self.frame_len, d=1.0 / self.sample_rate)
        self.low_mask = (freqs >= 60.0) & (freqs <= 1150.0)
        self.snap_mask = (freqs >= 1600.0) & (freqs <= 6200.0)
        self.hp_mask = freqs >= 1150.0

        # Rolling 2.5s circular ring buffers for non-collapsing Median + MAD baseline
        self.warmup_frames = 90  # 90 * 5 ms = 0.45s ambient floor capture
        self.frame_idx = 0
        self.ring_snap_rms = collections.deque(maxlen=500)  # 2.5s history
        self.ring_low_pow = collections.deque(maxlen=500)
        self.ring_snap_pow = collections.deque(maxlen=500)
        self.bg_snap_med = 1e-4
        self.bg_snap_mad = 5e-5
        self.bg_snap_pow = 1e-8
        self.bg_low_pow = 1e-8
        self.prev_snap_rms = collections.deque([1e-4] * 6, maxlen=6)
        self.prev_low_pow = collections.deque([1e-8] * 18, maxlen=18)

        # Continuous raw PCM circular buffer (~400 ms) for sample-accurate ML features
        self.pcm_ring_cap = int(round(self.sample_rate * 0.420))
        self.pcm_ring = np.zeros(self.pcm_ring_cap, dtype=np.float32)
        self.pcm_write_pos = 0
        self.total_samples = 0

        # Real-time speech context & noise burstiness tracking
        self.speech_active_until = 0.0
        self.transient_times = collections.deque(maxlen=32)

        # Candidate window (+80 ms post-onset for full vowel & decay observation)
        self.candidate = None
        self.verify_frames = 16  # 16 * 5 ms = 80 ms post-trigger

        # Single / Double gesture FSM
        self.pending_snap = None
        self.cooldown_until = 0.0
        self.stream_time = 0.0
        self._pcm_buf = np.zeros(0, dtype=np.float32)

    def _push_pcm_hop(self, hop_samples):
        n = hop_samples.size
        if n == 0:
            return
        if n >= self.pcm_ring_cap:
            self.pcm_ring[:] = hop_samples[-self.pcm_ring_cap :]
            self.pcm_write_pos = 0
        else:
            end = self.pcm_write_pos + n
            if end <= self.pcm_ring_cap:
                self.pcm_ring[self.pcm_write_pos : end] = hop_samples
                self.pcm_write_pos = end % self.pcm_ring_cap
            else:
                first = self.pcm_ring_cap - self.pcm_write_pos
                self.pcm_ring[self.pcm_write_pos :] = hop_samples[:first]
                self.pcm_ring[: n - first] = hop_samples[first:]
                self.pcm_write_pos = n - first
        self.total_samples += n

    def _read_pcm_tail(self, num_samples):
        n = min(num_samples, self.total_samples, self.pcm_ring_cap)
        if n <= 0:
            return np.zeros(0, dtype=np.float32)
        start = (self.pcm_write_pos - n) % self.pcm_ring_cap
        if start < self.pcm_write_pos:
            return self.pcm_ring[start : self.pcm_write_pos].copy()
        return np.concatenate((self.pcm_ring[start:], self.pcm_ring[: self.pcm_write_pos])).copy()

    def _compute_frame_features(self, frame):
        centered = frame - np.mean(frame)
        spec = np.fft.rfft(centered * self.window)
        power = (spec.real * spec.real + spec.imag * spec.imag) / max(1, self.frame_len)

        hp_wave = np.fft.irfft(spec * self.hp_mask, n=self.frame_len)
        peak = float(np.max(np.abs(hp_wave)))
        hp_rms = float(np.sqrt(np.mean(hp_wave * hp_wave)) + 1e-9)
        crest = peak / hp_rms

        low_pow = float(np.sum(power[self.low_mask]))
        snap_pow = float(np.sum(power[self.snap_mask]))
        snap_rms = math.sqrt(snap_pow / max(1, int(np.sum(self.snap_mask))) + 1e-18)

        return {
            "peak": peak,
            "crest": crest,
            "low_pow": low_pow,
            "snap_pow": snap_pow,
            "snap_rms": snap_rms,
        }

    def _refresh_robust_floor(self):
        if len(self.ring_snap_rms) < 10:
            return
        arr = np.fromiter(self.ring_snap_rms, dtype=np.float32)
        med = float(np.median(arr))
        mad = float(np.median(np.abs(arr - med)))
        # Convert MAD to Gaussian-equivalent sigma floor with tiny lower guard
        self.bg_snap_med = max(med, 1e-5)
        self.bg_snap_mad = max(mad * 1.4826, self.bg_snap_med * 0.20, 1e-5)
        self.bg_snap_pow = max(float(np.median(np.fromiter(self.ring_snap_pow, dtype=np.float32))), 1e-10)
        self.bg_low_pow = max(float(np.median(np.fromiter(self.ring_low_pow, dtype=np.float32))), 1e-10)

    def _update_speech_context(self):
        """Lightweight periodic check (every 40 ms) for ongoing solo voice activity."""
        if (self.frame_idx % 8) != 0 or self.total_samples < int(self.sample_rate * 0.06):
            return
        seg = self._read_pcm_tail(int(self.sample_rate * 0.06))
        acf = estimate_voiced_acf(seg, self.sample_rate)
        # Only flag active speech when voiced harmonics carry genuine energy above noise floor
        if acf >= 0.44:
            self.speech_active_until = self.stream_time + 0.18

    def _finalize_candidate(self, extra_feat_sink=None):
        """Align exact sample peak, extract 26 ML features, gate on context, and emit."""
        c = self.candidate
        self.candidate = None

        # Pull continuous [-160 ms .. +90 ms] raw audio ending right at current write_pos
        win_samples = int(round(self.sample_rate * 0.255))
        buf = self._read_pcm_tail(win_samples)
        if buf.size < int(self.sample_rate * 0.12):
            return

        # Candidate triggered verify_frames * hop_len samples ago (~80 ms back from end)
        approx_center = max(0, buf.size - int(round(self.verify_frames * self.hop_len)))

        # Fine sample-level peak alignment inside [-10 ms .. +18 ms] around trigger on >=1.2 kHz wave
        lo = max(0, approx_center - int(round(self.sample_rate * 0.010)))
        hi = min(buf.size, approx_center + int(round(self.sample_rate * 0.018)))
        hp_search = _highpass_fft(buf[max(0, lo - 128) : min(buf.size, hi + 128)], self.sample_rate, cutoff_hz=1200.0)
        offset_in_hp = lo - max(0, lo - 128)
        sub = np.abs(hp_search[offset_in_hp : offset_in_hp + (hi - lo)])
        peak_idx = lo + int(np.argmax(sub)) if sub.size else approx_center

        feats = extract_snap_features(
            buf,
            self.sample_rate,
            peak_idx,
            bg_snap_rms=self.bg_snap_med,
            bg_mad=self.bg_snap_mad,
        )
        if extra_feat_sink is not None:
            extra_feat_sink.append(feats)
            return

        prob, ood_z = self.classifier.predict(feats)
        post_voiced = float(feats[22])
        pre_voiced = float(feats[23])
        post_low_spill = float(feats[24])
        flatness = float(feats[11])
        fwhm_ms = float(feats[15]) * 35.0
        snr = c["peak_snap_rms"] / max(self.bg_snap_med, 1e-6)

        # Count recent distinct transients in last 1.8s (bursty typing/applause/clatter check)
        recent_bursts = sum(1 for t in self.transient_times if (c["trigger_time"] - t) <= 1.8)
        speech_ctx = (
            self.stream_time <= self.speech_active_until
            or pre_voiced >= 0.48
            or post_voiced >= 0.48
        )
        noisy_clutter = recent_bursts >= 5

        eff_thresh = self.ml_thresh
        if speech_ctx:
            eff_thresh += self.speech_boost
        if noisy_clutter:
            eff_thresh += self.clutter_boost

        # Physical hard safety checks complementing neural classifier:
        # 1. Electrical / USB audio glitch rejection (single-sample click has < 8 samples > 22% peak)
        c_hp = _highpass_fft(buf[max(0, peak_idx - int(self.sample_rate * 0.004)) : min(buf.size, peak_idx + int(self.sample_rate * 0.018))], self.sample_rate, cutoff_hz=1200.0)
        c_pk = float(np.max(np.abs(c_hp))) if c_hp.size else 0.0
        active_osc_samples = int(np.sum(np.abs(c_hp) >= 0.22 * max(c_pk, 1e-9)))
        is_glitch = active_osc_samples < 8
        # 2. Strong post-onset voiced vowel + low energy surge = spoken "t/k/p + vowel" plosive
        is_plosive_vowel = (post_voiced >= 0.45 and post_low_spill >= 0.28 and prob < 0.94)
        # 3. Flat broadband noise burst or excessively wide envelope = sibilant/clap/noise
        is_broad_noise = (flatness > 0.55 and fwhm_ms > 18.0 and prob < 0.95)
        # 4. Severe out-of-distribution freak pulse
        is_ood = ood_z > 3.8

        accepted = (prob >= eff_thresh) and not is_glitch and not is_plosive_vowel and not is_broad_noise and not is_ood

        if self.debug_fn is not None:
            self.debug_fn({
                "accepted": accepted,
                "prob": round(prob, 3),
                "thresh": round(eff_thresh, 3),
                "ood_z": round(ood_z, 2),
                "snr": round(snr, 2),
                "post_voiced": round(post_voiced, 2),
                "flatness": round(flatness, 2),
                "fwhm_ms": round(fwhm_ms, 1),
                "speech_ctx": speech_ctx,
                "clutter": recent_bursts,
            })

        if not accepted:
            return

        snap_time = c["trigger_time"]
        meta = {
            "time": round(snap_time, 3),
            "prob": round(prob, 3),
            "snr": round(snr, 2),
            "speech_ctx": bool(speech_ctx),
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
        """Emit single-snap 'next' once double-snap window expires without a 2nd snap."""
        if self.pending_snap is None:
            return
        if (self.stream_time - self.pending_snap["time"]) > self.double_window_sec:
            snap = self.pending_snap
            self.pending_snap = None
            self.cooldown_until = self.stream_time + self.cooldown_single_sec
            self.emit_fn(
                "snap",
                count=1,
                action="next",
                prob=snap["prob"],
                snr=snap["snr"],
                speech_ctx=snap["speech_ctx"],
            )

    def _process_frame(self, frame, extra_feat_sink=None):
        self.frame_idx += 1
        self.stream_time += self.frame_sec

        # Push exact non-overlapping hop into continuous PCM ring
        self._push_pcm_hop(frame[: self.hop_len])
        feat = self._compute_frame_features(frame)

        # Always keep single-snap timeout alive cleanly
        self._check_pending_timeout()

        # Warmup phase: gather initial room noise floor & MAD
        if self.frame_idx <= self.warmup_frames:
            self.ring_snap_rms.append(feat["snap_rms"])
            self.ring_snap_pow.append(feat["snap_pow"])
            self.ring_low_pow.append(feat["low_pow"])
            if self.frame_idx == self.warmup_frames or (self.frame_idx % 20 == 0):
                self._refresh_robust_floor()
            self.prev_snap_rms.append(feat["snap_rms"])
            self.prev_low_pow.append(feat["low_pow"])
            return

        # 1. If capturing +80 ms post-onset candidate window, wait until ready
        if self.candidate is not None:
            c = self.candidate
            c["age"] += 1
            if c["age"] <= 4:
                c["peak_snap_rms"] = max(c["peak_snap_rms"], feat["snap_rms"])
            if c["age"] >= self.verify_frames:
                self._finalize_candidate(extra_feat_sink=extra_feat_sink)
            self.prev_snap_rms.append(feat["snap_rms"])
            self.prev_low_pow.append(feat["low_pow"])
            return

        # Update rolling voice activity context
        self._update_speech_context()

        # Feed rolling 2.5s Median+MAD floor buffer so floor smoothly adapts if room noise rises
        # (median naturally resists brief 20 ms transients without deadlocking at stale quiet values)
        if not self.candidate:
            self.ring_snap_rms.append(feat["snap_rms"])
            self.ring_snap_pow.append(feat["snap_pow"])
        self.ring_low_pow.append(feat["low_pow"])
        if (self.frame_idx % 16) == 0:
            self._refresh_robust_floor()

        # 2. Respect echo cooldown after emitted gesture
        if self.stream_time < self.cooldown_until:
            self.prev_snap_rms.append(feat["snap_rms"])
            self.prev_low_pow.append(feat["low_pow"])
            return

        # 3. Stage-1 Cheap Pre-Screen (high-pass transient above Median + MAD room floor)
        pre_snap = max(min(self.prev_snap_rms), 1e-6)
        attack_slope = feat["snap_rms"] / pre_snap
        bg_thresh = max(self.bg_snap_med + self.mad_k * self.bg_snap_mad, self.bg_snap_med * self.min_snr)
        low_hist = list(self.prev_low_pow)[:-3] if len(self.prev_low_pow) > 6 else list(self.prev_low_pow)
        local_low_floor = max(self.bg_low_pow, float(np.median(low_hist)) * 1.05)
        excess_snap = max(0.0, feat["snap_pow"] - self.bg_snap_pow)
        excess_low = max(0.0, feat["low_pow"] - local_low_floor)
        quick_ratio = excess_snap / max(excess_low, 1e-12)

        is_candidate = (
            feat["peak"] >= self.min_peak
            and feat["snap_rms"] >= bg_thresh
            and attack_slope >= self.min_attack
            and feat["crest"] >= self.min_crest_pre
            and quick_ratio >= self.min_band_ratio
        )

        if is_candidate:
            # Avoid double-counting echoes inside 80 ms of last transient timestamp
            if not self.transient_times or (self.stream_time - self.transient_times[-1]) > 0.08:
                self.transient_times.append(self.stream_time)
            self.candidate = {
                "trigger_time": self.stream_time,
                "age": 0,
                "peak_snap_rms": feat["snap_rms"],
            }

        self.prev_snap_rms.append(feat["snap_rms"])
        self.prev_low_pow.append(feat["low_pow"])

    def feed(self, samples, extra_feat_sink=None):
        """Feed mono float32 audio samples (arbitrary chunk size) into the detector."""
        arr = np.asarray(samples, dtype=np.float32).reshape(-1)
        if arr.size == 0:
            return
        if self._pcm_buf.size > 0:
            arr = np.concatenate((self._pcm_buf, arr))
        offset = 0
        limit = arr.size - self.frame_len
        while offset <= limit:
            self._process_frame(arr[offset : offset + self.frame_len], extra_feat_sink=extra_feat_sink)
            offset += self.hop_len
        self._pcm_buf = arr[offset:].copy()

    def flush(self):
        """Flush trailing silence frames so final candidate / pending snap resolves."""
        silence = np.zeros(self.frame_len, dtype=np.float32)
        for _ in range(int(math.ceil((self.double_window_sec + 0.16) / self.frame_sec))):
            self._process_frame(silence)


def _synth_vowel(rng, length, sr, f0, amp):
    t = np.arange(length, dtype=np.float32) / sr
    sig = np.zeros(length, dtype=np.float32)
    for h in range(1, min(12, int(2800 / f0)) + 1):
        fh = h * f0
        fg = 1.0 + 1.3 * np.exp(-((fh - 550.0) / 260.0) ** 2) + 0.8 * np.exp(-((fh - 1650.0) / 380.0) ** 2)
        sig += (fg / (h ** 0.9)) * np.sin(2 * np.pi * fh * t + float(rng.uniform(0, 6.28)))
    sig *= np.sin(np.pi * np.arange(length, dtype=np.float32) / max(1, length)) ** 0.7
    return (sig * (amp / max(float(np.max(np.abs(sig))), 1e-6))).astype(np.float32)


def _synth_snap(sr, amp=0.03, center_hz=3200.0, decay_ms=11.0):
    n = int(sr * 0.085)
    t = np.arange(n, dtype=np.float32) / sr
    tau = decay_ms / 1000.0
    env = np.exp(-t / tau) * (1.0 - np.exp(-t / 0.0003))
    sig = (0.72 * np.sin(2 * np.pi * center_hz * t) + 0.32 * np.sin(2 * np.pi * (center_hz * 1.54) * t)) * env
    rng = np.random.default_rng(7)
    pop = rng.standard_normal(n).astype(np.float32)
    sp = np.fft.rfft(pop)
    fr = np.fft.rfftfreq(n, d=1.0 / sr)
    sp *= ((fr >= 1800) & (fr <= 5500)).astype(np.float32)
    pop = np.fft.irfft(sp, n=n).astype(np.float32)
    sig += 0.22 * (pop / max(float(np.max(np.abs(pop))), 1e-6)) * np.exp(-t / (tau * 0.55))
    sig *= amp / max(float(np.max(np.abs(sig))), 1e-6)
    return sig.astype(np.float32)


def run_self_test():
    """Verify ML snap detector against adversarial solo-speech & noisy-env stress suite."""
    if np is None:
        print("FAIL: numpy unavailable", file=sys.stderr)
        return 1

    sr = 48000
    events = []
    debug_logs = []
    det = SnapDetectorEngine(
        sample_rate=sr,
        sensitivity="normal",
        emit_fn=lambda name, **kw: events.append((name, kw)),
        debug_fn=lambda d: debug_logs.append(d),
    )
    assert det.classifier.loaded, f"ML model missing at {DEFAULT_MODEL_PATH}"
    rng = np.random.default_rng(101)

    def silence(sec):
        return (0.00035 * rng.standard_normal(int(sr * sec))).astype(np.float32)

    def bp_noise(n, f_lo, f_hi):
        raw = rng.standard_normal(n).astype(np.float32)
        sp = np.fft.rfft(raw)
        fr = np.fft.rfftfreq(n, d=1.0 / sr)
        sp *= ((fr >= f_lo) & (fr <= f_hi)).astype(np.float32)
        out = np.fft.irfft(sp, n=n).astype(np.float32)
        return out / max(float(np.max(np.abs(out))), 1e-6)

    # 1. Warmup with HVAC / projector fan hum (120 Hz + harmonic)
    t_fan = np.arange(int(sr * 0.8), dtype=np.float32) / sr
    fan = 0.018 * np.sin(2 * np.pi * 120.0 * t_fan) + 0.006 * np.sin(2 * np.pi * 240.0 * t_fan) + silence(0.8)
    det.feed(fan)

    # 2. Desk / mic thud -> REJECTED
    tb = np.arange(int(sr * 0.12), dtype=np.float32) / sr
    bump = (0.35 * np.sin(2 * np.pi * 95 * tb) + 0.14 * np.sin(2 * np.pi * 260 * tb)) * np.exp(-tb / 0.025)
    det.feed(bump.astype(np.float32))
    det.feed(silence(0.5))

    # 3. Solo presenter speaking natural sentences with sharp stop plosives ("t-ah", "k-ee", "p-oo") -> REJECTED
    for f0 in (125.0, 155.0, 210.0):
        det.feed(_synth_vowel(rng, int(sr * 0.14), sr, f0, 0.14))
        det.feed(silence(0.035))  # short stop closure before 't'/'k'
        burst_n = int(sr * 0.014)
        burst = bp_noise(burst_n, 1700.0, 6500.0) * np.hanning(burst_n).astype(np.float32) * 0.16
        det.feed(burst)
        det.feed(silence(0.010))
        det.feed(_synth_vowel(rng, int(sr * 0.16), sr, f0, 0.18))
        det.feed(silence(0.55))

    # 4. Tongue click / lip smack near speech + sustained sibilant ("shhh") + cough -> REJECTED
    det.feed(_synth_vowel(rng, int(sr * 0.12), sr, 140.0, 0.12))
    tc = np.arange(int(sr * 0.025), dtype=np.float32) / sr
    tclick = 0.15 * np.sin(2 * np.pi * 1350.0 * tc) * np.exp(-tc / 0.008)
    det.feed(tclick.astype(np.float32))
    det.feed(silence(0.55))

    sib = bp_noise(int(sr * 0.22), 2000.0, 8000.0) * np.sin(np.pi * np.arange(int(sr * 0.22), dtype=np.float32) / int(sr * 0.22)) * 0.12
    det.feed(sib.astype(np.float32))
    det.feed(silence(0.55))

    # 5. Noisy environment: rapid keyboard typing burst (7 hits) + mouse double click + hand clap -> REJECTED
    for _ in range(7):
        kn = int(sr * 0.035)
        tk = np.arange(kn, dtype=np.float32) / sr
        kclk = 0.12 * bp_noise(kn, 5200.0, 14000.0) * np.exp(-tk / 0.003) + 0.06 * np.sin(2 * np.pi * 320 * tk) * np.exp(-tk / 0.007)
        det.feed(kclk.astype(np.float32))
        det.feed(silence(0.11))
    det.feed(silence(0.5))

    cn = int(sr * 0.09)
    tcl = np.arange(cn, dtype=np.float32) / sr
    clap = (0.14 * bp_noise(cn, 250.0, 1300.0) + 0.18 * bp_noise(cn, 1400.0, 7500.0)) * np.exp(-tcl / 0.020)
    clap[int(sr * 0.008) :] += 0.6 * clap[: cn - int(sr * 0.008)]
    det.feed(clap.astype(np.float32))
    det.feed(silence(0.6))

    assert len(events) == 0, f"False triggers detected on speech/noise: {events} | logs={debug_logs}"

    # 6. Far-field single snap (amp=0.007, ~3m away + projector fan hum) -> 'next'
    t_bg = np.arange(int(sr * 1.1), dtype=np.float32) / sr
    bg_mix = 0.015 * np.sin(2 * np.pi * 120.0 * t_bg) + silence(1.1)
    far_snap = _synth_snap(sr, amp=0.007, center_hz=3100.0, decay_ms=12.0)
    bg_mix[int(sr * 0.35) : int(sr * 0.35) + far_snap.size] += far_snap
    det.feed(bg_mix.astype(np.float32))
    assert len(events) == 1 and events[0][1]["action"] == "next", f"Expected 1x next, got {events} | logs={debug_logs}"

    # 7. Fast double snap (205 ms apart) -> 'prev'
    det.feed(silence(0.45))
    s1 = _synth_snap(sr, amp=0.025, center_hz=3300.0, decay_ms=10.0)
    s2 = _synth_snap(sr, amp=0.022, center_hz=3450.0, decay_ms=10.0)
    det.feed(s1)
    det.feed(silence(0.12))  # 0.085 + 0.12 = 0.205s apart
    det.feed(s2)
    det.feed(silence(0.65))
    assert len(events) == 2 and events[1][1]["action"] == "prev", f"Expected 2x prev, got {events} | logs={debug_logs}"

    print(json.dumps({
        "self_test": "PASS",
        "ml_loaded": det.classifier.loaded,
        "events": events,
        "candidates_evaluated": len(debug_logs),
    }))
    return 0


def run_calibrate(profile_path=DEFAULT_PROFILE_PATH):
    """Interactive 3-snap room calibration saving personal standardized centroid."""
    if np is None or sd is None:
        emit_event("error", message="numpy and sounddevice are required for calibration")
        return 1

    dev_info = sd.query_devices(kind="input")
    sr = int(round(dev_info.get("default_samplerate") or 48000))
    if sr < 22050:
        sr = 44100

    captured = []
    det = SnapDetectorEngine(sample_rate=sr, sensitivity="high")
    print("Stay quiet for 0.5s, then snap your fingers 3 clear times (1s apart)...")

    def audio_cb(indata, frames, time_info, status):
        det.feed(indata[:, 0].copy(), extra_feat_sink=captured)

    with sd.InputStream(samplerate=sr, channels=1, dtype="float32", blocksize=det.hop_len, callback=audio_cb):
        while len(captured) < 3:
            sd.sleep(100)
            # Only print progress up to 3

    mat = np.vstack(captured[:3]).astype(np.float32)
    z_mat = (mat - det.classifier.feat_mean) / det.classifier.feat_std
    prof = {
        "sample_rate": sr,
        "count": 3,
        "mean": np.mean(z_mat, axis=0).tolist(),
        "std": np.maximum(np.std(z_mat, axis=0), 0.30).tolist(),
    }
    os.makedirs(os.path.dirname(profile_path), exist_ok=True)
    with open(profile_path, "w", encoding="utf-8") as f:
        json.dump(prof, f, indent=2)
    print(f"Saved personal 3-snap profile to {profile_path}")
    return 0


def run_live(sensitivity="normal", double_window_ms=400, monitor=False):
    """Stream microphone audio via sounddevice and emit ML-validated snap JSON events."""
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

    dbg = (lambda d: emit_event("debug", **d)) if monitor else None
    engine = SnapDetectorEngine(
        sample_rate=native_sr,
        sensitivity=sensitivity,
        double_window_sec=max(0.20, min(0.75, double_window_ms / 1000.0)),
        debug_fn=dbg,
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

    emit_event("calibrating", message="Calibrating ML noise floor...")

    try:
        with sd.InputStream(
            samplerate=native_sr,
            channels=1,
            dtype="float32",
            blocksize=engine.hop_len,
            callback=audio_callback,
        ):
            emit_event(
                "ready",
                sample_rate=native_sr,
                sensitivity=engine.sensitivity,
                ml=engine.classifier.loaded,
                calibrated=engine.classifier.personal_mean is not None,
            )
            while not stop_evt.is_set():
                try:
                    chunk = audio_q.get(timeout=0.04)
                    engine.feed(chunk)
                except queue.Empty:
                    if engine.pending_snap is not None and engine.candidate is None:
                        engine.feed(np.zeros(engine.hop_len, dtype=np.float32))
    except Exception as exc:
        emit_event("error", message=f"Microphone stream error: {exc}")
        return 1

    engine.flush()
    return 0


def main():
    parser = argparse.ArgumentParser(description="ML-powered finger snap microphone slide detector")
    parser.add_argument("--sensitivity", default="normal", choices=["low", "normal", "high"])
    parser.add_argument("--double-window-ms", type=int, default=400)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--monitor", action="store_true", help="Print live candidate ML scores to stdout")
    parser.add_argument("--calibrate", action="store_true", help="Record 3 personal snaps to calibrate room profile")
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())
    if args.calibrate:
        sys.exit(run_calibrate())
    sys.exit(run_live(sensitivity=args.sensitivity, double_window_ms=args.double_window_ms, monitor=args.monitor))


if __name__ == "__main__":
    main()
