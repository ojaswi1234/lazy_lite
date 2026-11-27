"""Real-time ML acoustic finger-snap slide controller with anti-disturbance guards.

Architecture:
1. Fast Pre-Allocated Ring Floor:
   - Tracks a 2.5s rolling Median + MAD background floor in O(1) memory without
     collapsing during speech pauses or deadlocking when room noise rises.
2. Pitch-Formant VAD + 26-Feature Pure-NumPy MLP Neural Network:
   - Rejects solo human speech (plosives 't/k/p/ch + vowel', sibilants, coughs,
     tongue clicks), fan/AC hum, desk thuds, keyboard clacks, mouse double-clicks,
     and single-sample electrical glitches while supporting 2-4m far-field snaps.
3. Anti-Disturbance & Crowd Defenses:
   - Crowd-Safe Gesture Mode (--gesture-mode crowd): ignores random 1x troll snaps;
     requires 2x fast snaps for Next and 3x fast snaps for Previous.
   - Mid-Sentence Ambush Suppressor: tightens gate when active speech surrounds
     both sides of a transient impulse.
   - Disturbance Spam Circuit Breaker: pauses forward navigation for 8s if a rapid
     troll-snap burst (>= 4 snaps in 4.5s) occurs (always keeping Prev unlocked).
   - Live In-App Presenter Acoustic Lock: 3-snap room calibration learns personal
     timbre, Direct-to-Reverberant Ratio (DRR), and podium loudness to block
     distant audience disturbers.

Interactive stdin commands:
  STOP | CALIBRATE_START | CALIBRATE_CANCEL | MODE:solo | MODE:crowd | SENS:low|normal|high
"""

import argparse
import collections
import json
import math
import os
import queue
import sys
import threading
import time

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:
        pass

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
    from snap_features import (
        extract_snap_features,
        estimate_voiced_acf,
        compute_acoustic_signature,
        _highpass_fft,
    )
else:
    extract_snap_features = None
    estimate_voiced_acf = None
    compute_acoustic_signature = None
    _highpass_fft = None

DEFAULT_MODEL_PATH = os.path.join(SCRIPT_DIR, "snap_ml_model.npz")
DEFAULT_PROFILE_PATH = os.path.join(os.path.dirname(SCRIPT_DIR), "tempfiles", "snap_profile.json")

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
    "high": {
        "min_snr": 3.0,
        "mad_k": 4.5,
        "min_peak": 0.0020,
        "min_crest_pre": 1.90,
        "min_core_crest": 2.05,
        "min_attack": 2.0,
        "min_band_ratio": 0.72,
        "ml_thresh": 0.64,
        "speech_boost": 0.14,
        "clutter_boost": 0.08,
    },
    "normal": {
        "min_snr": 3.0,
        "mad_k": 5.0,
        "min_peak": 0.0036,
        "min_crest_pre": 2.05,
        "min_core_crest": 2.10,
        "min_attack": 2.25,
        "min_band_ratio": 0.68,
        "ml_thresh": 0.76,
        "speech_boost": 0.13,
        "clutter_boost": 0.08,
    },
    "low": {
        "min_snr": 4.8,
        "mad_k": 7.5,
        "min_peak": 0.0075,
        "min_crest_pre": 2.45,
        "min_core_crest": 2.60,
        "min_attack": 2.8,
        "min_band_ratio": 1.10,
        "ml_thresh": 0.85,
        "speech_boost": 0.10,
        "clutter_boost": 0.06,
    },
}


class _FloatRing:
    """Zero-allocation fixed-capacity NumPy circular buffer."""

    def __init__(self, cap):
        self.buf = np.zeros(cap, dtype=np.float32)
        self.cap = cap
        self.pos = 0
        self.size = 0

    def append(self, val):
        self.buf[self.pos] = val
        self.pos = (self.pos + 1) % self.cap
        if self.size < self.cap:
            self.size += 1

    def view(self):
        return self.buf[: self.size]


class SnapMLClassifier:
    """Pure-NumPy MLP classifier + OOD guard + Presenter Acoustic Lock (DRR & timbre)."""

    def __init__(self, model_path=DEFAULT_MODEL_PATH, profile_path=DEFAULT_PROFILE_PATH, presenter_lock=True):
        self.loaded = False
        self.profile_path = profile_path
        self.presenter_lock_enabled = bool(presenter_lock)
        self.feat_mean = None
        self.feat_std = None
        self.proto_mean = None
        self.proto_std = None
        self.weights = None

        self.personal_mean = None
        self.personal_std = None
        self.personal_drr = None
        self.personal_rms = None

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

        self.load_profile(profile_path)

    def load_profile(self, path=None):
        p = path or self.profile_path
        if not p or not os.path.exists(p) or not self.loaded:
            return False
        try:
            with open(p, "r", encoding="utf-8") as f:
                prof = json.load(f)
            pm = np.array(prof.get("mean", []), dtype=np.float32)
            ps = np.array(prof.get("std", []), dtype=np.float32)
            if pm.shape == self.feat_mean.shape and ps.shape == self.feat_mean.shape:
                self.personal_mean = pm
                self.personal_std = np.maximum(ps, 0.35)
                self.personal_drr = float(prof["drr_med"]) if prof.get("drr_med") else None
                self.personal_rms = float(prof["rms_med"]) if prof.get("rms_med") else None
                return True
        except Exception:
            pass
        return False

    def save_profile(self, feats_list, sigs_list, sample_rate, path=None):
        if not self.loaded or not feats_list:
            return False
        p = path or self.profile_path
        mat = np.vstack(feats_list).astype(np.float32)
        z_mat = (mat - self.feat_mean) / self.feat_std
        pm = np.mean(z_mat, axis=0)
        ps = np.maximum(np.std(z_mat, axis=0), 0.38)
        drr_med = float(np.median([s["drr"] for s in sigs_list])) if sigs_list else 4.0
        rms_med = float(np.median([s["core_rms"] for s in sigs_list])) if sigs_list else 0.01

        prof = {
            "sample_rate": int(sample_rate),
            "count": len(feats_list),
            "mean": pm.tolist(),
            "std": ps.tolist(),
            "drr_med": drr_med,
            "rms_med": rms_med,
        }
        if p:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(prof, f, indent=2)
        self.personal_mean = pm.astype(np.float32)
        self.personal_std = ps.astype(np.float32)
        self.personal_drr = drr_med
        self.personal_rms = rms_med
        return True

    def check_presenter_match(self, z, sig):
        """Verify distance, DRR proximity, and amplitude when Presenter Lock is armed."""
        if not self.presenter_lock_enabled or self.personal_mean is None:
            return True, "unlocked"

        # Compare core timbre features (spectral shape + modal envelope, skip SNR/voiced slots 22..25)
        idx_timbre = slice(0, 22)
        p_dist = float(np.sqrt(np.mean(((z[idx_timbre] - self.personal_mean[idx_timbre]) / self.personal_std[idx_timbre]) ** 2)))
        if p_dist > 2.55:
            return False, f"timbre_mismatch({p_dist:.2f})"

        if sig is not None and self.personal_drr and self.personal_drr > 1.8:
            # Distant audience snap excites significantly more room reverb (lower DRR)
            if sig["drr"] < max(1.3, self.personal_drr * 0.35):
                return False, f"distant_reverb(drr={sig['drr']:.1f}<{self.personal_drr*0.35:.1f})"

        if sig is not None and self.personal_rms and self.personal_rms > 0.002:
            if sig["core_rms"] < self.personal_rms * 0.24:
                return False, f"too_quiet_for_podium(rms={sig['core_rms']:.4f})"

        return True, f"matched({p_dist:.2f})"

    def predict(self, feats, sig=None):
        """Return (prob_snap, ood_z_distance, z_vec, presenter_ok, presenter_reason)."""
        if not self.loaded:
            score = 0.25 * feats[12] + 0.25 * feats[13] + 0.20 * (1.0 - feats[11]) + 0.15 * feats[21] - 0.35 * feats[22]
            return float(max(0.0, min(1.0, score + 0.2))), 1.0, None, True, "no_model"

        z = (feats - self.feat_mean) / self.feat_std
        W1, b1, W2, b2, W3, b3 = self.weights
        a1 = np.maximum(0.0, z @ W1 + b1)
        a2 = np.maximum(0.0, a1 @ W2 + b2)
        logit = max(-30.0, min(30.0, float((a2 @ W3 + b3)[0])))
        prob = 1.0 / (1.0 + math.exp(-logit))
        ood_z = float(np.sqrt(np.mean(((z - self.proto_mean) / self.proto_std) ** 2)))

        ok_pres, pres_reason = self.check_presenter_match(z, sig)
        return float(prob), ood_z, z, ok_pres, pres_reason


class SnapDetectorEngine:
    """High-efficiency DSP + ML snap detector with anti-disturbance guards."""

    def __init__(
        self,
        sample_rate=48000,
        sensitivity="normal",
        gesture_mode="solo",
        double_window_sec=0.58,
        min_double_gap_sec=0.10,
        cooldown_single_sec=0.22,
        cooldown_double_sec=0.45,
        emit_fn=None,
        model_path=DEFAULT_MODEL_PATH,
        profile_path=DEFAULT_PROFILE_PATH,
        presenter_lock=True,
        debug_fn=None,
    ):
        if np is None:
            raise RuntimeError("numpy is required for snap detection")

        self.sample_rate = int(sample_rate)
        self.win_sec = 0.010
        self.frame_sec = 0.005
        self.frame_len = max(256, int(round(self.sample_rate * self.win_sec)))
        self.hop_len = max(128, self.frame_len // 2)

        self.set_sensitivity(sensitivity)
        self.gesture_mode = gesture_mode if gesture_mode in ("solo", "crowd") else "solo"

        self.double_window_sec = float(double_window_sec)
        self.triple_window_sec = min(0.50, float(double_window_sec))
        self.min_double_gap_sec = float(min_double_gap_sec)
        self.cooldown_single_sec = float(cooldown_single_sec)
        self.cooldown_double_sec = float(cooldown_double_sec)
        self.emit_fn = emit_fn or emit_event
        self.debug_fn = debug_fn

        self.classifier = SnapMLClassifier(
            model_path=model_path,
            profile_path=profile_path,
            presenter_lock=presenter_lock,
        )

        # Precompute rFFT masks
        self.window = np.hanning(self.frame_len).astype(np.float32)
        freqs = np.fft.rfftfreq(self.frame_len, d=1.0 / self.sample_rate)
        self.low_mask = (freqs >= 60.0) & (freqs <= 1150.0)
        self.speech_mask = (freqs >= 220.0) & (freqs <= 1150.0)
        self.snap_mask = (freqs >= 1600.0) & (freqs <= 6200.0)
        self.hp_mask = freqs >= 1150.0
        self._n_snap_bins = max(1, int(np.sum(self.snap_mask)))
        self._n_speech_bins = max(1, int(np.sum(self.speech_mask)))

        # Pre-allocated circular floor buffers (2.5s)
        self.warmup_frames = 90
        self.frame_idx = 0
        self.ring_snap_rms = _FloatRing(500)
        self.ring_low_pow = _FloatRing(500)
        self.ring_snap_pow = _FloatRing(500)
        self.ring_speech_rms = _FloatRing(500)
        self.bg_snap_med = 1e-4
        self.bg_snap_mad = 5e-5
        self.bg_snap_pow = 1e-8
        self.bg_low_pow = 1e-8
        self.bg_speech_med = 1e-4
        self.bg_speech_mad = 5e-5
        self.prev_snap_rms = collections.deque([1e-4] * 6, maxlen=6)
        self.prev_low_pow = collections.deque([1e-8] * 18, maxlen=18)

        # Circular raw PCM buffer (~420 ms)
        self.pcm_ring_cap = int(round(self.sample_rate * 0.420))
        self.pcm_ring = np.zeros(self.pcm_ring_cap, dtype=np.float32)
        self.pcm_write_pos = 0
        self.total_samples = 0

        # Context & Disturbance Circuit Breaker trackers
        self.speech_active_until = 0.0
        self.transient_times = collections.deque(maxlen=32)
        self.spam_snap_times = collections.deque(maxlen=12)
        self.breaker_until = 0.0

        # Live calibration state
        self.cal_active = False
        self.cal_feats = []
        self.cal_sigs = []
        self.cal_target = 3

        # Gesture FSM state
        self.candidate = None
        self.verify_frames = 16  # +80 ms post-onset observation
        self.pending = None  # {"count": int, "first_time": float, "last_time": float, "meta": dict}
        self.cooldown_until = 0.0
        self.stream_time = 0.0
        self._pcm_buf = np.zeros(0, dtype=np.float32)

    def set_sensitivity(self, sensitivity):
        preset = SENSITIVITY_PRESETS.get(sensitivity, SENSITIVITY_PRESETS["normal"])
        self.sensitivity = sensitivity if sensitivity in SENSITIVITY_PRESETS else "normal"
        self.min_snr = preset["min_snr"]
        self.mad_k = preset["mad_k"]
        self.min_peak = preset["min_peak"]
        self.min_crest_pre = preset["min_crest_pre"]
        self.min_core_crest = preset["min_core_crest"]
        self.min_attack = preset["min_attack"]
        self.min_band_ratio = preset["min_band_ratio"]
        self.ml_thresh = preset["ml_thresh"]
        self.speech_boost = preset["speech_boost"]
        self.clutter_boost = preset["clutter_boost"]

    def start_calibration(self, count=3):
        self.cal_active = True
        self.cal_feats = []
        self.cal_sigs = []
        self.cal_target = max(2, int(count))
        self.pending = None
        self.emit_fn("cal_progress", captured=0, total=self.cal_target)

    def cancel_calibration(self):
        self.cal_active = False
        self.cal_feats = []
        self.cal_sigs = []

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
        speech_pow = float(np.sum(power[self.speech_mask]))
        snap_pow = float(np.sum(power[self.snap_mask]))
        snap_rms = math.sqrt(snap_pow / self._n_snap_bins + 1e-18)
        # Match waveform bandpass RMS scale (160-1150 Hz) used by compute_acoustic_signature
        # Parseval with Hann window (mean(win^2) == 0.375)
        speech_rms = math.sqrt(max(0.0, 2.0 * speech_pow / (max(1, self.frame_len) * 0.375)) + 1e-18)

        return {
            "peak": peak,
            "crest": crest,
            "low_pow": low_pow,
            "snap_pow": snap_pow,
            "snap_rms": snap_rms,
            "speech_rms": speech_rms,
        }

    def _refresh_robust_floor(self):
        arr = self.ring_snap_rms.view()
        if arr.size < 10:
            return
        med = float(np.median(arr))
        mad = float(np.median(np.abs(arr - med)))
        self.bg_snap_med = max(med, 1e-5)
        self.bg_snap_mad = max(mad * 1.4826, self.bg_snap_med * 0.20, 1e-5)
        self.bg_snap_pow = max(float(np.median(self.ring_snap_pow.view())), 1e-10)
        self.bg_low_pow = max(float(np.median(self.ring_low_pow.view())), 1e-10)

        sp_arr = self.ring_speech_rms.view()
        if sp_arr.size >= 10:
            s_med = float(np.median(sp_arr))
            s_mad = float(np.median(np.abs(sp_arr - s_med)))
            self.bg_speech_med = max(s_med, 1e-5)
            self.bg_speech_mad = max(s_mad * 1.4826, self.bg_speech_med * 0.25, 1e-5)

    def _update_speech_context(self, cur_speech_rms=0.0, is_snap_onset=False):
        # Skip transient snap-onset frames so broadband impulse spill never self-triggers speech_ctx
        if is_snap_onset:
            return
        # Fast unvoiced murmur / whisper envelope check (160-1150 Hz jump above 2.5s floor)
        sp_thresh = max(self.bg_speech_med + 4.5 * self.bg_speech_mad, self.bg_speech_med * 2.6, 0.0022)
        if cur_speech_rms >= sp_thresh:
            self.speech_active_until = self.stream_time + 0.28
            return
        if (self.frame_idx % 8) != 0 or self.total_samples < int(self.sample_rate * 0.06):
            return
        # Require speech-band energy to sit near/above floor and show modulation if room floor is noisy,
        # so stationary ceiling/laptop fan periodicity never latches speech_ctx forever.
        if cur_speech_rms < max(0.0018, self.bg_speech_med * 0.90):
            return
        seg = self._read_pcm_tail(int(self.sample_rate * 0.06))
        if estimate_voiced_acf(seg, self.sample_rate) >= 0.44:
            # Stationary motor/fan hum has tiny variation relative to its floor and high steady baseline
            if self.bg_speech_med < 0.006 or cur_speech_rms >= self.bg_speech_med * 1.25:
                self.speech_active_until = self.stream_time + 0.28

    def _handle_validated_snap(self, snap_time, meta):
        """Route a validated snap impulse into Solo (1x/2x) or Crowd-Safe (2x/3x) gesture FSM."""
        if self.pending is not None:
            dt_prev = snap_time - self.pending["last_time"]
            max_gap = self.double_window_sec if self.pending["count"] == 1 else self.triple_window_sec
            if self.min_double_gap_sec <= dt_prev <= max_gap:
                if self.gesture_mode == "solo":
                    # Solo Mode: 2nd fast snap immediately fires Previous Slide (always unlocked!)
                    self.pending = None
                    self.cooldown_until = snap_time + self.cooldown_double_sec
                    self.emit_fn("snap", count=2, action="prev", dt=round(dt_prev, 3), **meta)
                    return
                else:
                    # Crowd-Safe Mode: 2x -> wait briefly for 3x; 3x -> immediate Previous Slide
                    self.pending["count"] += 1
                    self.pending["last_time"] = snap_time
                    self.pending["meta"] = meta
                    if self.pending["count"] >= 3:
                        total_dt = round(snap_time - self.pending["first_time"], 3)
                        self.pending = None
                        self.cooldown_until = snap_time + self.cooldown_double_sec
                        self.emit_fn("snap", count=3, action="prev", dt=total_dt, **meta)
                    return

        self.pending = {
            "count": 1,
            "first_time": snap_time,
            "last_time": snap_time,
            "meta": meta,
        }

    def _record_spam_burst_and_check_breaker(self, now_t):
        """Trip 8s forward-navigation lockout if >= 4 isolated/spam attempts hit within 4.5s."""
        self.spam_snap_times.append(now_t)
        recent = [t for t in self.spam_snap_times if (now_t - t) <= 4.5]
        if len(recent) >= 4:
            self.breaker_until = now_t + 8.0
            self.emit_fn("guard", reason="spam_breaker", duration=8.0, message="Disturbance spam guard active (8s)")
            return True
        return False

    def _check_pending_timeout(self):
        """Resolve pending gesture once inter-snap window closes."""
        if self.pending is None:
            return
        cnt = self.pending["count"]
        window = self.double_window_sec if cnt == 1 else self.triple_window_sec
        if (self.stream_time - self.pending["last_time"]) <= window:
            return

        snap_t = self.pending["first_time"]
        meta = self.pending["meta"]
        self.pending = None

        if self.gesture_mode == "crowd":
            if cnt == 1:
                if not self._record_spam_burst_and_check_breaker(snap_t):
                    self.emit_fn("guard", reason="crowd_single_ignored", prob=meta["prob"], snr=meta["snr"])
                return
            if cnt == 2:
                if self.stream_time < self.breaker_until or self._record_spam_burst_and_check_breaker(snap_t):
                    self.emit_fn("guard", reason="spam_breaker", message="Forward blocked by disturbance guard")
                    return
                self.cooldown_until = self.stream_time + self.cooldown_single_sec
                self.emit_fn("snap", count=2, action="next", **meta)
                return
        else:
            # Solo Mode: 1x -> Next Slide (blocked if Disturbance Breaker trips or active)
            if self.stream_time < self.breaker_until or self._record_spam_burst_and_check_breaker(snap_t):
                self.emit_fn("guard", reason="spam_breaker", message="Forward blocked by disturbance guard")
                return
            self.cooldown_until = self.stream_time + self.cooldown_single_sec
            self.emit_fn("snap", count=1, action="next", **meta)

    def _finalize_candidate(self, extra_feat_sink=None):
        """Align peak, compute 26 ML features + DRR signature, verify guards, and dispatch."""
        c = self.candidate
        self.candidate = None

        win_samples = int(round(self.sample_rate * 0.255))
        buf = self._read_pcm_tail(win_samples)
        if buf.size < int(self.sample_rate * 0.12):
            return

        approx_center = max(0, buf.size - int(round(self.verify_frames * self.hop_len)))
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
        sig = compute_acoustic_signature(
            buf, self.sample_rate, peak_idx,
            bg_snap_rms=self.bg_snap_med,
            bg_speech_rms=self.bg_speech_med,
        )

        if extra_feat_sink is not None:
            extra_feat_sink.append((feats, sig))
            return

        prob, ood_z, _, pres_ok, pres_reason = self.classifier.predict(feats, sig=sig)
        post_voiced = float(feats[22])
        pre_voiced = float(feats[23])
        post_low_spill = float(feats[24])
        flatness = float(feats[11])
        fwhm_ms = float(feats[15]) * 35.0
        snr = c["peak_snap_rms"] / max(self.bg_snap_med, 1e-6)

        sp_floor = max(self.bg_speech_med + 4.0 * self.bg_speech_mad, self.bg_speech_med * 2.4, 0.0020)
        murmur_pre = sig["speech_pre"] >= sp_floor
        murmur_post = sig["speech_post"] >= sp_floor
        low_isolation = sig["isolation"] < 3.4

        # Gate periodic ACF against stationary fan hum (which never elevates above ambient speech floor)
        voiced_pre_active = (pre_voiced >= 0.45) and (
            self.bg_speech_med < 0.006 or sig["speech_pre"] >= self.bg_speech_med * 1.15 or low_isolation
        )
        voiced_post_active = (post_voiced >= 0.45) and (
            self.bg_speech_med < 0.006 or sig["speech_post"] >= self.bg_speech_med * 1.15 or low_isolation
        )

        recent_bursts = sum(1 for t in self.transient_times if (c["trigger_time"] - t) <= 1.8)
        speech_ctx = (
            self.stream_time <= self.speech_active_until
            or voiced_pre_active
            or voiced_post_active
            or murmur_pre
            or murmur_post
        )
        mid_sentence_ambush = ((voiced_pre_active or murmur_pre) and (post_voiced >= 0.40 or murmur_post))
        noisy_clutter = recent_bursts >= 5

        eff_thresh = self.ml_thresh
        if speech_ctx:
            eff_thresh += self.speech_boost
        if mid_sentence_ambush:
            eff_thresh += 0.14  # Harder bar for impulses buried right inside continuous talking/murmuring
        if noisy_clutter:
            eff_thresh += self.clutter_boost

        # Physical hard safety checks
        c_hp = _highpass_fft(buf[max(0, peak_idx - int(self.sample_rate * 0.004)) : min(buf.size, peak_idx + int(self.sample_rate * 0.018))], self.sample_rate, cutoff_hz=1200.0)
        c_pk = float(np.max(np.abs(c_hp))) if c_hp.size else 0.0
        active_osc_samples = int(np.sum(np.abs(c_hp) >= 0.22 * max(c_pk, 1e-9)))
        is_glitch = active_osc_samples < 5
        # Allow soft-clipped / laptop-AGC snaps (core_crest 1.45..2.10) when ML confidence & isolation are strong
        is_soft_mouth_pop = (
            sig["core_crest"] < 1.45
            or (sig["core_crest"] < self.min_core_crest and (prob < 0.84 or sig["isolation"] < 4.5 or speech_ctx))
        )
        is_murmur_embedded = speech_ctx and low_isolation and (sig["core_crest"] < 4.5 or prob < 0.96)
        is_plosive_vowel = (voiced_post_active and post_low_spill >= 0.26 and prob < 0.95)
        is_broad_noise = (flatness > 0.55 and fwhm_ms > 18.0 and prob < 0.95)
        is_ood = (ood_z > 5.2) or (
            ood_z > 4.2 and (prob < 0.85 or snr < 8.0 or sig["isolation"] < 5.0 or speech_ctx)
        )

        # Live calibration capture accepts strong clean ML snaps (ignoring presenter lock while learning)
        if self.cal_active:
            cal_ok = (prob >= 0.72) and not is_glitch and not is_plosive_vowel and not is_broad_noise and not is_ood
            if cal_ok:
                self.cal_feats.append(feats)
                self.cal_sigs.append(sig)
                self.emit_fn("cal_progress", captured=len(self.cal_feats), total=self.cal_target, drr=round(sig["drr"], 1))
                if len(self.cal_feats) >= self.cal_target:
                    self.classifier.save_profile(self.cal_feats, self.cal_sigs, self.sample_rate)
                    self.cal_active = False
                    self.cal_feats = []
                    self.cal_sigs = []
                    self.cooldown_until = self.stream_time + 0.50
                    self.emit_fn(
                        "cal_done",
                        calibrated=True,
                        drr_med=round(self.classifier.personal_drr or 0.0, 2),
                        rms_med=round(self.classifier.personal_rms or 0.0, 4),
                    )
            return

        accepted = (
            (prob >= eff_thresh)
            and not is_glitch
            and not is_soft_mouth_pop
            and not is_murmur_embedded
            and not is_plosive_vowel
            and not is_broad_noise
            and not is_ood
            and pres_ok
        )

        if self.debug_fn is not None:
            self.debug_fn({
                "accepted": accepted,
                "prob": round(prob, 3),
                "thresh": round(eff_thresh, 3),
                "ood_z": round(ood_z, 2),
                "snr": round(snr, 2),
                "drr": round(sig["drr"], 2),
                "crest": round(sig["core_crest"], 2),
                "iso": round(sig["isolation"], 2),
                "pres": pres_reason,
                "post_voiced": round(post_voiced, 2),
                "mid_ambush": mid_sentence_ambush,
                "flatness": round(flatness, 2),
                "fwhm_ms": round(fwhm_ms, 1),
                "speech_ctx": speech_ctx,
                "clutter": recent_bursts,
            })

        if not accepted:
            if (prob >= eff_thresh) and not is_glitch and not is_soft_mouth_pop and not is_murmur_embedded and not is_plosive_vowel and not is_broad_noise and not is_ood and not pres_ok:
                self.emit_fn("guard", reason="presenter_mismatch", detail=pres_reason, prob=round(prob, 2))
            return

        snap_time = c["trigger_time"]
        meta = {
            "time": round(snap_time, 3),
            "prob": round(prob, 3),
            "snr": round(snr, 2),
            "drr": round(sig["drr"], 2),
            "speech_ctx": bool(speech_ctx),
        }
        self._handle_validated_snap(snap_time, meta)

    def _process_frame(self, frame, extra_feat_sink=None):
        self.frame_idx += 1
        self.stream_time += self.frame_sec

        self._push_pcm_hop(frame[: self.hop_len])
        feat = self._compute_frame_features(frame)

        # Warmup phase
        if self.frame_idx <= self.warmup_frames:
            self.ring_snap_rms.append(feat["snap_rms"])
            self.ring_snap_pow.append(feat["snap_pow"])
            self.ring_low_pow.append(feat["low_pow"])
            self.ring_speech_rms.append(feat["speech_rms"])
            if self.frame_idx == self.warmup_frames or (self.frame_idx % 20 == 0):
                self._refresh_robust_floor()
            self.prev_snap_rms.append(feat["snap_rms"])
            self.prev_low_pow.append(feat["low_pow"])
            return

        # 1. Wait for candidate's +80 ms verification window before timing out pending_snap
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

        # 2. Resolve expired pending single/double gesture only when no candidate is in-flight
        self._check_pending_timeout()

        if self.stream_time < self.cooldown_until:
            self._update_speech_context(feat["speech_rms"], is_snap_onset=False)
            self.ring_snap_rms.append(feat["snap_rms"])
            self.ring_snap_pow.append(feat["snap_pow"])
            self.ring_low_pow.append(feat["low_pow"])
            self.ring_speech_rms.append(feat["speech_rms"])
            if (self.frame_idx % 16) == 0:
                self._refresh_robust_floor()
            self.prev_snap_rms.append(feat["snap_rms"])
            self.prev_low_pow.append(feat["low_pow"])
            return

        # 3. Stage-1 Pre-Screen BEFORE speech-context update so snap onset never poisons speech_ctx
        pre_snap = max(min(self.prev_snap_rms), 1e-6)
        attack_slope = feat["snap_rms"] / pre_snap
        bg_thresh = max(self.bg_snap_med + self.mad_k * self.bg_snap_mad, self.bg_snap_med * self.min_snr)
        low_hist = list(self.prev_low_pow)[:-3] if len(self.prev_low_pow) > 6 else list(self.prev_low_pow)
        local_low_floor = max(self.bg_low_pow, float(np.median(low_hist)) * 1.05)
        excess_snap = max(0.0, feat["snap_pow"] - self.bg_snap_pow)
        excess_low = max(0.0, feat["low_pow"] - local_low_floor * 1.25)
        quick_ratio = excess_snap / max(excess_low, 1e-12)

        is_candidate = (
            feat["peak"] >= self.min_peak
            and feat["snap_rms"] >= bg_thresh
            and attack_slope >= self.min_attack
            and feat["crest"] >= self.min_crest_pre
            and quick_ratio >= self.min_band_ratio
        )

        is_snap_spike = is_candidate or (feat["crest"] >= 2.2 and quick_ratio >= 1.4 and feat["snap_rms"] >= bg_thresh * 0.85)
        self._update_speech_context(feat["speech_rms"], is_snap_onset=is_snap_spike)

        # Feed pre-allocated rolling Median+MAD rings (only feed quiet/non-candidate baseline frames into floor)
        if not is_candidate:
            self.ring_snap_rms.append(feat["snap_rms"])
            self.ring_snap_pow.append(feat["snap_pow"])
            self.ring_low_pow.append(feat["low_pow"])
            self.ring_speech_rms.append(feat["speech_rms"])
            if (self.frame_idx % 16) == 0:
                self._refresh_robust_floor()

        if is_candidate:
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
        silence = np.zeros(self.frame_len, dtype=np.float32)
        for _ in range(int(math.ceil((self.double_window_sec + 0.20) / self.frame_sec))):
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


def _synth_snap(sr, amp=0.03, center_hz=3200.0, decay_ms=11.0, reverb_mix=0.0):
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
    if reverb_mix > 0.0:
        rev = rng.standard_normal(n).astype(np.float32) * np.exp(-t / 0.032) * reverb_mix
        rsp = np.fft.rfft(rev) * ((fr >= 1600) & (fr <= 6000)).astype(np.float32)
        sig += np.fft.irfft(rsp, n=n).astype(np.float32) * float(np.max(np.abs(sig)))
    sig *= amp / max(float(np.max(np.abs(sig))), 1e-6)
    return sig.astype(np.float32)


def run_self_test():
    """Verify ML snap detector + Solo/Crowd modes + Spam Breaker + Presenter Lock."""
    if np is None:
        print("FAIL: numpy unavailable", file=sys.stderr)
        return 1

    sr = 48000
    rng = np.random.default_rng(101)
    def silence(sec): return (0.00035 * rng.standard_normal(int(sr * sec))).astype(np.float32)
    def bp_noise(n, f_lo, f_hi):
        raw = rng.standard_normal(n).astype(np.float32)
        sp = np.fft.rfft(raw)
        fr = np.fft.rfftfreq(n, d=1.0 / sr)
        sp *= ((fr >= f_lo) & (fr <= f_hi)).astype(np.float32)
        out = np.fft.irfft(sp, n=n).astype(np.float32)
        return out / max(float(np.max(np.abs(out))), 1e-6)

    # --- PART A: Solo Mode + False Trigger Rejection + Single/Double ---
    events, logs = [], []
    det = SnapDetectorEngine(
        sample_rate=sr, sensitivity="normal", gesture_mode="solo",
        presenter_lock=False,
        emit_fn=lambda n, **kw: events.append((n, kw)),
        debug_fn=lambda d: logs.append(d),
    )
    assert det.classifier.loaded

    t_fan = np.arange(int(sr * 0.8), dtype=np.float32) / sr
    det.feed((0.018 * np.sin(2 * np.pi * 120 * t_fan) + 0.006 * np.sin(2 * np.pi * 240 * t_fan) + silence(0.8)).astype(np.float32))

    # Desk bump + Plosives+Vowels + Tongue click + Sibilant + Keyboard + Clap -> 0 snaps
    tb = np.arange(int(sr * 0.12), dtype=np.float32) / sr
    det.feed(((0.35 * np.sin(2 * np.pi * 95 * tb) + 0.14 * np.sin(2 * np.pi * 260 * tb)) * np.exp(-tb / 0.025)).astype(np.float32))
    det.feed(silence(0.5))

    for f0 in (125.0, 155.0, 210.0):
        det.feed(_synth_vowel(rng, int(sr * 0.14), sr, f0, 0.14))
        det.feed(silence(0.035))
        det.feed((bp_noise(int(sr * 0.014), 1700, 6500) * np.hanning(int(sr * 0.014)) * 0.16).astype(np.float32))
        det.feed(silence(0.010))
        det.feed(_synth_vowel(rng, int(sr * 0.16), sr, f0, 0.18))
        det.feed(silence(0.55))

    # Murmured / whispered speech + word-ending unvoiced consonant stop ("t." / "k." -> silence) -> MUST BE REJECTED
    m_n = int(sr * 0.20)
    tm = np.arange(m_n, dtype=np.float32) / sr
    murmur = 0.05 * bp_noise(m_n, 180, 950) + 0.025 * bp_noise(m_n, 1700, 3800) * (0.4 + 0.6 * np.sin(2 * np.pi * 5.0 * tm))
    det.feed(murmur.astype(np.float32))
    w_t = np.arange(int(sr * 0.014), dtype=np.float32) / sr
    word_end_t = (0.04 * bp_noise(w_t.size, 1800, 5800) * np.hanning(w_t.size) + 0.02 * np.sin(2 * np.pi * 3100 * w_t) * np.exp(-w_t / 0.006))
    det.feed(word_end_t.astype(np.float32))
    det.feed(silence(0.65))

    for _ in range(6):
        kn = int(sr * 0.035); tk = np.arange(kn, dtype=np.float32) / sr
        det.feed((0.12 * bp_noise(kn, 5200, 14000) * np.exp(-tk / 0.003) + 0.06 * np.sin(2 * np.pi * 320 * tk) * np.exp(-tk / 0.007)).astype(np.float32))
        det.feed(silence(0.11))
    det.feed(silence(0.6))
    assert not any(n == "snap" for n, _ in events), f"False triggers in Solo mode: {events}"

    # Far snap -> next; Double snap -> prev
    t_bg = np.arange(int(sr * 1.1), dtype=np.float32) / sr
    bg_mix = 0.015 * np.sin(2 * np.pi * 120 * t_bg) + silence(1.1)
    fs = _synth_snap(sr, amp=0.007, center_hz=3100, decay_ms=12)
    bg_mix[int(sr * 0.25) : int(sr * 0.25) + fs.size] += fs
    det.feed(bg_mix.astype(np.float32))
    snap_ev = [kw for n, kw in events if n == "snap"]
    assert len(snap_ev) == 1 and snap_ev[0]["action"] == "next", f"Expected 1x next: {events}"

    det.feed(silence(0.45))
    det.feed(_synth_snap(sr, amp=0.025, center_hz=3300, decay_ms=10))
    det.feed(silence(0.28))  # 0.365s gap cleanly inside 580ms window
    det.feed(_synth_snap(sr, amp=0.020, center_hz=3400, decay_ms=10))
    det.feed(silence(0.70))
    snap_ev = [kw for n, kw in events if n == "snap"]
    assert len(snap_ev) == 2 and snap_ev[1]["action"] == "prev", f"Expected 2x prev: {events}"

    # --- PART B: Crowd-Safe Mode (1x random troll IGNORED, 2x -> next, 3x -> prev) ---
    c_events = []
    det_c = SnapDetectorEngine(
        sample_rate=sr, sensitivity="normal", gesture_mode="crowd",
        presenter_lock=False, emit_fn=lambda n, **kw: c_events.append((n, kw)),
    )
    det_c.feed(silence(0.7))
    det_c.feed(_synth_snap(sr, amp=0.04, center_hz=3200, decay_ms=11))  # 1x random troll snap!
    det_c.feed(silence(0.75))
    assert not any(n == "snap" for n, _ in c_events), f"Crowd-Safe failed to ignore 1x troll snap: {c_events}"
    assert any(n == "guard" and kw.get("reason") == "crowd_single_ignored" for n, kw in c_events)

    det_c.feed(_synth_snap(sr, amp=0.04, center_hz=3200, decay_ms=11))
    det_c.feed(silence(0.22))
    det_c.feed(_synth_snap(sr, amp=0.04, center_hz=3200, decay_ms=11))
    det_c.feed(silence(0.75))
    c_snaps = [kw for n, kw in c_events if n == "snap"]
    assert len(c_snaps) == 1 and c_snaps[0]["action"] == "next" and c_snaps[0]["count"] == 2

    det_c.feed(_synth_snap(sr, amp=0.04, center_hz=3200, decay_ms=11))
    det_c.feed(silence(0.20))
    det_c.feed(_synth_snap(sr, amp=0.04, center_hz=3200, decay_ms=11))
    det_c.feed(silence(0.20))
    det_c.feed(_synth_snap(sr, amp=0.04, center_hz=3200, decay_ms=11))
    det_c.feed(silence(0.75))
    c_snaps = [kw for n, kw in c_events if n == "snap"]
    assert len(c_snaps) == 2 and c_snaps[1]["action"] == "prev" and c_snaps[1]["count"] == 3

    # --- PART C: Presenter Lock (blocks distant low-DRR crowd troll, accepts presenter) ---
    p_events = []
    det_p = SnapDetectorEngine(
        sample_rate=sr, sensitivity="normal", gesture_mode="solo",
        profile_path=None, presenter_lock=True,
        emit_fn=lambda n, **kw: p_events.append((n, kw)),
    )
    det_p.feed(silence(0.7))
    det_p.start_calibration(3)
    for _ in range(3):
        det_p.feed(_synth_snap(sr, amp=0.06, center_hz=3000, decay_ms=9, reverb_mix=0.0))
        det_p.feed(silence(0.7))
    assert any(n == "cal_done" for n, _ in p_events), f"Calibration failed: {p_events}"

    # Simulate distant crowd troll (quiet amp=0.008 + room reverb + 4.3 kHz different hand) -> REJECTED!
    p_events.clear()
    det_p.feed(_synth_snap(sr, amp=0.008, center_hz=4300, decay_ms=16, reverb_mix=0.45))
    det_p.feed(silence(0.7))
    assert not any(n == "snap" for n, _ in p_events), f"Presenter lock allowed distant troll: {p_events}"

    # Matching presenter snap -> ACCEPTED!
    det_p.feed(_synth_snap(sr, amp=0.055, center_hz=3050, decay_ms=9.5, reverb_mix=0.0))
    det_p.feed(silence(0.7))
    assert any(n == "snap" and kw["action"] == "next" for n, kw in p_events), f"Presenter lock rejected owner: {p_events}"

    print(json.dumps({
        "self_test": "PASS",
        "solo_checks": "PASS",
        "crowd_mode_2x_3x": "PASS",
        "presenter_drr_lock": "PASS",
        "candidates_eval": len(logs),
    }))
    return 0


def run_calibrate(profile_path=DEFAULT_PROFILE_PATH):
    """CLI 3-snap calibration saving personal timbre + DRR + RMS profile."""
    if np is None or sd is None:
        emit_event("error", message="numpy and sounddevice are required for calibration")
        return 1

    dev_info = sd.query_devices(kind="input")
    sr = int(round(dev_info.get("default_samplerate") or 48000))
    if sr < 22050:
        sr = 44100

    captured = []
    det = SnapDetectorEngine(sample_rate=sr, sensitivity="high", presenter_lock=False)
    print("Stay quiet for 0.5s, then snap 3 clear times at normal distance (1s apart)...")

    def audio_cb(indata, frames, time_info, status):
        det.feed(indata[:, 0].copy(), extra_feat_sink=captured)

    with sd.InputStream(samplerate=sr, channels=1, dtype="float32", blocksize=det.hop_len, callback=audio_cb):
        prev_cnt = 0
        while len(captured) < 3:
            if len(captured) > prev_cnt:
                prev_cnt = len(captured)
                print(f"  Captured snap {prev_cnt}/3 (DRR={captured[-1][1]['drr']:.1f})")
            sd.sleep(60)

    feats_list = [c[0] for c in captured[:3]]
    sigs_list = [c[1] for c in captured[:3]]
    det.classifier.save_profile(feats_list, sigs_list, sr, path=profile_path)
    print(f"Saved presenter acoustic profile to {profile_path}")
    return 0


def run_live(sensitivity="normal", gesture_mode="solo", double_window_ms=580, presenter_lock=True, monitor=False):
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
        gesture_mode=gesture_mode,
        double_window_sec=max(0.25, min(0.85, double_window_ms / 1000.0)),
        presenter_lock=presenter_lock,
        debug_fn=dbg,
    )

    audio_q = queue.Queue(maxsize=128)
    cmd_q = queue.Queue()
    stop_evt = threading.Event()

    def stdin_watcher():
        is_win = (sys.platform == "win32")
        if is_win:
            try:
                import ctypes
                import msvcrt
                handle = msvcrt.get_osfhandle(sys.stdin.fileno())
                avail = ctypes.c_ulong(0)
                while not stop_evt.is_set():
                    ok = ctypes.windll.kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(avail), None)
                    if not ok:
                        stop_evt.set()
                        break
                    if avail.value > 0:
                        line = sys.stdin.readline()
                        if not line:
                            stop_evt.set()
                            break
                        cmd = line.strip()
                        if cmd.upper() == "STOP":
                            stop_evt.set()
                            break
                        if cmd:
                            cmd_q.put(cmd)
                    else:
                        time.sleep(0.05)
                return
            except Exception:
                pass
        try:
            for line in sys.stdin:
                cmd = line.strip()
                if not cmd:
                    continue
                if cmd.upper() == "STOP":
                    stop_evt.set()
                    break
                cmd_q.put(cmd)
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
            blocksize=0,
            callback=audio_callback,
        ):
            emit_event(
                "ready",
                sample_rate=native_sr,
                sensitivity=engine.sensitivity,
                gesture_mode=engine.gesture_mode,
                ml=engine.classifier.loaded,
                presenter_lock=(engine.classifier.presenter_lock_enabled and engine.classifier.personal_mean is not None),
            )
            while not stop_evt.is_set():
                # Drain any dynamic UI commands safely in the engine loop thread
                while not cmd_q.empty():
                    cmd = cmd_q.get_nowait()
                    up = cmd.upper()
                    if up == "CALIBRATE_START":
                        engine.start_calibration(3)
                    elif up == "CALIBRATE_CANCEL":
                        engine.cancel_calibration()
                    elif up.startswith("MODE:"):
                        m = cmd.split(":", 1)[1].strip().lower()
                        if m in ("solo", "crowd"):
                            engine.gesture_mode = m
                            engine.pending = None
                            emit_event("mode_changed", gesture_mode=m)
                    elif up.startswith("SENS:"):
                        s = cmd.split(":", 1)[1].strip().lower()
                        if s in SENSITIVITY_PRESETS:
                            engine.set_sensitivity(s)
                            emit_event("sens_changed", sensitivity=s)

                try:
                    chunk = audio_q.get(timeout=0.04)
                    engine.feed(chunk)
                except queue.Empty:
                    if (engine.pending is not None or engine.cal_active) and engine.candidate is None:
                        engine.feed(np.zeros(engine.hop_len, dtype=np.float32))
    except Exception as exc:
        emit_event("error", message=f"Microphone stream error: {exc}")
        return 1

    engine.flush()
    return 0


def main():
    parser = argparse.ArgumentParser(description="ML finger-snap slide controller with crowd guards")
    parser.add_argument("--sensitivity", default="normal", choices=["low", "normal", "high"])
    parser.add_argument("--gesture-mode", default="solo", choices=["solo", "crowd"])
    parser.add_argument("--double-window-ms", type=int, default=580)
    parser.add_argument("--no-presenter-lock", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--monitor", action="store_true")
    parser.add_argument("--calibrate", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())
    if args.calibrate:
        sys.exit(run_calibrate())
    sys.exit(run_live(
        sensitivity=args.sensitivity,
        gesture_mode=args.gesture_mode,
        double_window_ms=args.double_window_ms,
        presenter_lock=not args.no_presenter_lock,
        monitor=args.monitor,
    ))


if __name__ == "__main__":
    main()
