# -*- coding: utf-8 -*-
"""Train and export compact pure-numpy Neural Network ML classifier for finger-snap detection.

Generates diverse physically realistic waveforms across both 44.1 kHz and 48 kHz:
- Positives: Near & far-field finger snaps (1-3 damped cavity modes, varied Q & pre-brush)
  under quiet rooms, HVAC hum, reverberant tails, pink noise, and background chatter.
- Hard Negatives: Solo speaker plosives+vowels ('t/k/p/ch + vowel'), isolated fricatives,
  coughs, tongue/lip clicks, hand claps, keyboard clacks & mouse double-clicks,
  desk bumps, glass/pen clinks, paper rustle, and noisy room babble surges.

Outputs `scripts/snap_ml_model.npz` (MLP weights + scaler + class prototype).
"""

import math
import os
import sys
import time
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from snap_features import extract_snap_features, NUM_FEATURES, FEATURE_NAMES


def _bandpass_noise(rng, n, sr, f_lo, f_hi):
    raw = rng.standard_normal(n).astype(np.float32)
    spec = np.fft.rfft(raw)
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    mask = ((freqs >= f_lo) & (freqs <= f_hi)).astype(np.float32)
    return np.fft.irfft(spec * mask, n=n).astype(np.float32)


def _pink_noise(rng, n):
    raw = rng.standard_normal(n).astype(np.float32)
    spec = np.fft.rfft(raw)
    k = np.arange(1, spec.size + 1, dtype=np.float32)
    spec /= np.sqrt(k)
    out = np.fft.irfft(spec, n=n).astype(np.float32)
    out /= max(float(np.std(out)), 1e-6)
    return out


def _apply_reverb(sig, sr, rt60, rng):
    if rt60 <= 0.04:
        return sig
    ir_len = min(int(sr * 0.08), sig.size)
    t_ir = np.arange(ir_len, dtype=np.float32) / sr
    decay = np.exp(-t_ir / max(rt60 * 0.16, 0.008))
    ir = rng.standard_normal(ir_len).astype(np.float32) * decay * 0.14
    ir[0] = 1.0
    n_fft = 1 << int(np.ceil(np.log2(sig.size + ir_len - 1)))
    out = np.fft.irfft(np.fft.rfft(sig, n=n_fft) * np.fft.rfft(ir, n=n_fft), n=n_fft)[: sig.size]
    return out.astype(np.float32)


def _make_background(rng, n, sr, bg_type):
    t = np.arange(n, dtype=np.float32) / sr
    bg = rng.standard_normal(n).astype(np.float32) * 0.0004
    if bg_type in ("fan", "noisy_room", "babble"):
        hum_f = float(rng.uniform(55.0, 180.0))
        bg += float(rng.uniform(0.004, 0.025)) * np.sin(2 * np.pi * hum_f * t)
        bg += float(rng.uniform(0.002, 0.010)) * np.sin(2 * np.pi * (2.0 * hum_f) * t)
    if bg_type in ("noisy_room", "babble"):
        bg += _pink_noise(rng, n) * float(rng.uniform(0.003, 0.020))
    if bg_type == "babble":
        # Distant chatter harmonic modulation in 140..1200 Hz
        for _ in range(int(rng.integers(2, 5))):
            f0 = float(rng.uniform(110.0, 260.0))
            mod = 0.5 + 0.5 * np.sin(2 * np.pi * float(rng.uniform(2.0, 6.0)) * t + float(rng.uniform(0, 6.28)))
            v = (
                np.sin(2 * np.pi * f0 * t)
                + 0.7 * np.sin(2 * np.pi * (f0 * 2.1) * t)
                + 0.5 * np.sin(2 * np.pi * (f0 * 3.8) * t)
            ) * mod
            bg += v.astype(np.float32) * float(rng.uniform(0.003, 0.015))
    return bg.astype(np.float32)


def _synth_vowel_segment(rng, length, sr, f0, amp):
    t = np.arange(length, dtype=np.float32) / sr
    # Pulse train approximation (F0 + harmonics up to 3.2 kHz, tilted -6dB/oct)
    sig = np.zeros(length, dtype=np.float32)
    max_h = min(14, int(3000.0 / max(f0, 80.0)))
    for h in range(1, max_h + 1):
        ph = float(rng.uniform(0, 2 * np.pi))
        w = 1.0 / (h ** 0.9)
        # Mild formant boost near F1 (~500 Hz) and F2 (~1500 Hz)
        fh = h * f0
        f_gain = 1.0 + 1.4 * np.exp(-((fh - 550.0) / 280.0) ** 2) + 0.9 * np.exp(-((fh - 1650.0) / 420.0) ** 2)
        sig += float(w * f_gain) * np.sin(2 * np.pi * fh * t + ph)
    env = np.sin(np.pi * np.arange(length, dtype=np.float32) / max(1, length)) ** 0.65
    sig *= env * (amp / max(float(np.max(np.abs(sig))), 1e-6))
    return sig.astype(np.float32)


def generate_example(rng, sr, cls_label):
    """Simulate a 240 ms PCM clip centered around an event at ~145 ms."""
    n = int(round(sr * 0.240))
    c = int(round(sr * 0.145))

    if cls_label == 1:
        bg_type = rng.choice(["quiet", "fan", "noisy_room", "babble"], p=[0.25, 0.30, 0.25, 0.20])
        buf = _make_background(rng, n, sr, bg_type)
        # Optionally put prior spoken phrase fading out before -35 ms (speaker pauses and snaps)
        if rng.random() < 0.25:
            sp_len = int(sr * rng.uniform(0.04, 0.09))
            buf[max(0, c - int(sr * 0.04) - sp_len) : c - int(sr * 0.04)] += _synth_vowel_segment(
                rng, sp_len, sr, float(rng.uniform(100, 240)), float(rng.uniform(0.015, 0.08))
            )

        # Realistic multi-modal damped cavity snap + tiny pre-brush
        amp = float(10 ** rng.uniform(np.log10(0.003), np.log10(0.45)))
        f1 = float(rng.uniform(1950.0, 4600.0))
        f2 = f1 * float(rng.uniform(1.32, 1.92))
        tau1 = float(rng.uniform(0.0045, 0.018))
        tau2 = tau1 * float(rng.uniform(0.45, 0.85))
        sn_len = min(n - c, int(sr * 0.085))
        t = np.arange(sn_len, dtype=np.float32) / sr
        attack = 1.0 - np.exp(-t / float(rng.uniform(0.00015, 0.0008)))
        snap = attack * (
            float(rng.uniform(0.55, 0.85)) * np.sin(2 * np.pi * f1 * t) * np.exp(-t / tau1)
            + float(rng.uniform(0.20, 0.50)) * np.sin(2 * np.pi * f2 * t) * np.exp(-t / tau2)
        )
        # Broadband percussive skin click component shaped inside 1.5..6 kHz
        pop = _bandpass_noise(rng, sn_len, sr, 1500.0, min(6500.0, sr * 0.45))
        pop /= max(float(np.max(np.abs(pop))), 1e-6)
        snap += float(rng.uniform(0.10, 0.35)) * pop * np.exp(-t / (tau1 * 0.55))

        # Tiny optional finger friction pre-brush 2..5 ms before pop
        if rng.random() < 0.45:
            br_len = int(sr * rng.uniform(0.002, 0.005))
            br = _bandpass_noise(rng, br_len, sr, 2500.0, 8000.0)
            br *= (0.12 * float(np.max(np.abs(snap)))) / max(float(np.max(np.abs(br))), 1e-6)
            buf[c - br_len : c] += br

        snap = _apply_reverb(snap, sr, float(rng.uniform(0.0, 0.35)), rng)
        snap *= amp / max(float(np.max(np.abs(snap))), 1e-6)
        buf[c : c + sn_len] += snap
        event_center = c + int(np.argmax(np.abs(snap[: int(sr * 0.015)])))
    else:
        neg_kind = rng.choice([
            "plosive_vowel",
            "murmur_whisper",
            "word_ending_stop",
            "sibilant",
            "tongue_click",
            "cough",
            "hand_clap",
            "keyboard_mouse",
            "desk_bump",
            "babble_burst",
        ], p=[0.18, 0.16, 0.14, 0.10, 0.10, 0.08, 0.08, 0.08, 0.04, 0.04])
        bg_type = rng.choice(["quiet", "fan", "noisy_room", "babble"], p=[0.20, 0.30, 0.30, 0.20])
        buf = _make_background(rng, n, sr, bg_type)
        amp = float(10 ** rng.uniform(np.log10(0.006), np.log10(0.55)))
        event_center = c

        if neg_kind == "murmur_whisper":
            # Soft continuous murmured/whispered speech (low F0 vocal fry 160-950 Hz + breathy F2/F3 formants 1.2-3.8 kHz)
            m_len = min(n - int(sr * 0.02), int(sr * rng.uniform(0.140, 0.210)))
            m_start = max(0, c - int(m_len * rng.uniform(0.35, 0.65)))
            tm = np.arange(m_len, dtype=np.float32) / sr
            lo_m = _bandpass_noise(rng, m_len, sr, 170.0, 950.0)
            hi_m = _bandpass_noise(rng, m_len, sr, float(rng.uniform(1600, 2400)), float(rng.uniform(3200, 4800)))
            # Syllabic amplitude envelope + brief soft glottal burst near c
            syll = 0.5 + 0.5 * np.sin(2 * np.pi * float(rng.uniform(3.5, 7.5)) * tm + float(rng.uniform(0, 6.28)))
            pop_t = np.exp(-((np.arange(m_len) - (c - m_start)) ** 2) / max(1.0, (sr * float(rng.uniform(0.005, 0.015))) ** 2))
            murmur = (0.75 * lo_m * syll + 0.45 * hi_m * (0.4 * syll + 0.9 * pop_t))
            murmur *= np.sin(np.pi * np.arange(m_len, dtype=np.float32) / m_len) ** 0.5
            murmur *= amp / max(float(np.max(np.abs(murmur))), 1e-6)
            m_end = min(n, m_start + m_len)
            buf[m_start:m_end] += murmur[: m_end - m_start]
            event_center = c

        elif neg_kind == "word_ending_stop":
            # Spoken/murmured word ending in crisp unvoiced 't'/'k'/'p' before silence!
            pre_len = int(sr * rng.uniform(0.05, 0.095))
            gap = int(sr * rng.uniform(0.012, 0.040))
            s0 = max(0, c - gap - pre_len)
            buf[s0 : s0 + pre_len] += _synth_vowel_segment(rng, pre_len, sr, float(rng.uniform(95, 240)), amp * 0.85)
            if rng.random() < 0.5:
                buf[s0 : s0 + pre_len] += _bandpass_noise(rng, pre_len, sr, 180, 900) * (amp * 0.4)
            b_len = int(sr * rng.uniform(0.008, 0.022))
            tb = np.arange(b_len, dtype=np.float32) / sr
            burst = _bandpass_noise(rng, b_len, sr, 1600.0, 6500.0) * np.hanning(b_len).astype(np.float32)
            # Include vocal-tract F3 formant peak right inside 2.3..3.9 kHz
            burst += 0.45 * np.sin(2 * np.pi * float(rng.uniform(2300, 3900)) * tb) * np.exp(-tb / 0.007)
            burst *= (amp * float(rng.uniform(0.4, 0.9))) / max(float(np.max(np.abs(burst))), 1e-6)
            buf[c : c + b_len] += burst
            event_center = c + int(np.argmax(np.abs(burst)))

        elif neg_kind == "plosive_vowel":
            # Stop consonant burst ("t"/"k"/"p"/"ch") followed by voiced vowel (+12..40 ms later)
            if rng.random() < 0.55:
                # Preceding spoken syllable before short stop gap
                pre_len = int(sr * rng.uniform(0.04, 0.09))
                gap = int(sr * rng.uniform(0.015, 0.045))
                s0 = max(0, c - gap - pre_len)
                buf[s0 : s0 + pre_len] += _synth_vowel_segment(rng, pre_len, sr, float(rng.uniform(95, 250)), amp * 0.8)

            burst_ms = float(rng.uniform(0.008, 0.024))
            b_len = int(sr * burst_ms)
            f_lo = float(rng.uniform(1200.0, 2600.0))
            f_hi = float(rng.uniform(4200.0, 9000.0))
            burst = _bandpass_noise(rng, b_len, sr, f_lo, min(f_hi, sr * 0.45))
            burst *= np.hanning(b_len).astype(np.float32)
            # Some plosives ("t"/"k") also have a short modal peak
            if rng.random() < 0.5:
                tb = np.arange(b_len, dtype=np.float32) / sr
                burst += 0.35 * np.sin(2 * np.pi * float(rng.uniform(2200, 4400)) * tb) * np.exp(-tb / 0.006)
            burst *= (amp * float(rng.uniform(0.35, 1.0))) / max(float(np.max(np.abs(burst))), 1e-6)
            buf[c : c + b_len] += burst
            event_center = c + int(np.argmax(np.abs(burst)))

            # Trailing vowel starts right after burst
            v_delay = b_len + int(sr * rng.uniform(0.002, 0.025))
            v_len = min(n - (c + v_delay), int(sr * rng.uniform(0.055, 0.090)))
            if v_len > int(sr * 0.025):
                buf[c + v_delay : c + v_delay + v_len] += _synth_vowel_segment(
                    rng, v_len, sr, float(rng.uniform(95, 260)), amp * float(rng.uniform(0.55, 1.3))
                )

        elif neg_kind == "sibilant":
            # "s", "sh", "ch", sharp breath (longer duration 30..160 ms, broadband/high flat noise)
            s_len = min(n - c, int(sr * rng.uniform(0.032, 0.140)))
            f_lo = float(rng.uniform(1800.0, 4500.0))
            f_hi = float(rng.uniform(6000.0, 12000.0))
            sib = _bandpass_noise(rng, s_len, sr, f_lo, min(f_hi, sr * 0.46))
            sib *= np.sin(np.pi * np.arange(s_len, dtype=np.float32) / s_len) ** 0.7
            sib *= amp / max(float(np.max(np.abs(sib))), 1e-6)
            buf[c : c + s_len] += sib
            event_center = c + int(sr * 0.010)

        elif neg_kind == "tongue_click":
            # Wet mouth click / lip smack: lower centroid (900..2300 Hz) OR speech embedded
            if rng.random() < 0.75:
                v_len = int(sr * rng.uniform(0.05, 0.09))
                if rng.random() < 0.5:
                    buf[max(0, c - v_len - 400) : c - 400] += _synth_vowel_segment(rng, v_len, sr, float(rng.uniform(100, 240)), amp * 0.9)
                else:
                    buf[c + 600 : min(n, c + 600 + v_len)] += _synth_vowel_segment(rng, min(v_len, n - c - 600), sr, float(rng.uniform(100, 240)), amp * 0.9)
            c_len = min(n - c, int(sr * 0.035))
            tc = np.arange(c_len, dtype=np.float32) / sr
            fc = float(rng.uniform(850.0, 2150.0))
            clk = (np.sin(2 * np.pi * fc * tc) + 0.5 * np.sin(2 * np.pi * fc * 1.45 * tc)) * np.exp(-tc / float(rng.uniform(0.005, 0.014)))
            clk += 0.25 * _bandpass_noise(rng, c_len, sr, 500.0, 3500.0) * np.exp(-tc / 0.008)
            clk *= amp / max(float(np.max(np.abs(clk))), 1e-6)
            buf[c : c + c_len] += clk
            event_center = c + int(np.argmax(np.abs(clk[: int(sr * 0.01)])))

        elif neg_kind == "cough":
            c_len = min(n - c, int(sr * rng.uniform(0.065, 0.140)))
            tc = np.arange(c_len, dtype=np.float32) / sr
            low_ch = 0.7 * np.sin(2 * np.pi * float(rng.uniform(140, 380)) * tc)
            turb = _bandpass_noise(rng, c_len, sr, 500.0, 5500.0)
            cg = (low_ch + 0.65 * turb / max(float(np.std(turb)), 1e-6)) * np.exp(-tc / float(rng.uniform(0.025, 0.075)))
            cg *= amp / max(float(np.max(np.abs(cg))), 1e-6)
            buf[c : c + c_len] += cg
            event_center = c + int(sr * 0.006)

        elif neg_kind == "hand_clap":
            # Palm thump (250..1300 Hz) + broadband slap (1.4..7 kHz) + multi-finger delay (wider FWHM)
            c_len = min(n - c, int(sr * 0.095))
            tc = np.arange(c_len, dtype=np.float32) / sr
            palm = _bandpass_noise(rng, c_len, sr, 240.0, 1400.0)
            slap = _bandpass_noise(rng, c_len, sr, 1400.0, 8000.0)
            env = np.exp(-tc / float(rng.uniform(0.014, 0.032)))
            clap = (float(rng.uniform(0.6, 1.2)) * palm + slap) * env
            # Finger stagger second mini-pulse 4..12 ms later
            shift = int(sr * rng.uniform(0.004, 0.012))
            clap[shift:] += 0.65 * clap[: c_len - shift]
            clap = _apply_reverb(clap, sr, float(rng.uniform(0.08, 0.45)), rng)
            clap *= amp / max(float(np.max(np.abs(clap))), 1e-6)
            buf[c : c + c_len] += clap
            event_center = c + int(np.argmax(np.abs(clap[: int(sr * 0.02)])))

        elif neg_kind == "keyboard_mouse":
            # Sharp ultra-high switch click (> 5.5 kHz) + mechanical double bounce (5..20 ms apart) + low key bottom-out
            k_len = min(n - c, int(sr * 0.060))
            tk = np.arange(k_len, dtype=np.float32) / sr
            hi_pop = _bandpass_noise(rng, k_len, sr, 5000.0, min(15500.0, sr * 0.48)) * np.exp(-tk / 0.003)
            lo_thud = np.sin(2 * np.pi * float(rng.uniform(160, 550)) * tk) * np.exp(-tk / 0.008)
            click = hi_pop / max(float(np.max(np.abs(hi_pop))), 1e-6) + 0.55 * lo_thud
            # Secondary switch release / bounce 5..22 ms later
            d_samp = int(sr * rng.uniform(0.005, 0.022))
            if d_samp < k_len - 20:
                click[d_samp:] += float(rng.uniform(0.45, 0.85)) * click[: k_len - d_samp]
            click *= amp / max(float(np.max(np.abs(click))), 1e-6)
            buf[c : c + k_len] += click
            event_center = c + int(np.argmax(np.abs(click[: int(sr * 0.008)])))

        elif neg_kind == "desk_bump":
            b_len = min(n - c, int(sr * 0.110))
            tb = np.arange(b_len, dtype=np.float32) / sr
            bump = (
                np.sin(2 * np.pi * float(rng.uniform(70, 220)) * tb)
                + 0.4 * np.sin(2 * np.pi * float(rng.uniform(220, 620)) * tb)
            ) * np.exp(-tb / float(rng.uniform(0.015, 0.045)))
            bump *= amp / max(float(np.max(np.abs(bump))), 1e-6)
            buf[c : c + b_len] += bump
            event_center = c + int(sr * 0.004)

        else:  # babble_burst
            b_len = min(n - c, int(sr * rng.uniform(0.045, 0.100)))
            burst = _bandpass_noise(rng, b_len, sr, 350.0, 6500.0)
            burst *= np.sin(np.pi * np.arange(b_len, dtype=np.float32) / b_len)
            burst *= amp / max(float(np.max(np.abs(burst))), 1e-6)
            buf[c : c + b_len] += burst
            event_center = c + int(sr * 0.012)

    # Measure background rms/mad cleanly from pre-window so SNR feature aligns with runtime
    bg_slice = buf[: max(128, c - int(sr * 0.025))]
    step = max(64, int(sr * 0.005))
    rms_list = [
        float(np.sqrt(np.mean(bg_slice[i : i + step] ** 2) + 1e-14))
        for i in range(0, bg_slice.size - step, step)
    ]
    bg_med = float(np.median(rms_list)) if rms_list else 1e-4
    bg_mad = float(np.median(np.abs(np.array(rms_list) - bg_med))) if rms_list else 5e-5

    feats = extract_snap_features(buf, sr, event_center, bg_snap_rms=bg_med, bg_mad=bg_mad)
    return feats


def _relu(x):
    return np.maximum(0.0, x)


def _sigmoid(x):
    x = np.clip(x, -30.0, 30.0)
    return 1.0 / (1.0 + np.exp(-x))


def train_mlp(X_tr, y_tr, X_val, y_val, seed=123):
    """Train a 26 -> 48 -> 24 -> 1 MLP with Adam + L2 weight decay + dropout."""
    rng = np.random.default_rng(seed)
    n_in = X_tr.shape[1]
    h1, h2 = 48, 24

    W1 = (rng.standard_normal((n_in, h1)) * math.sqrt(2.0 / n_in)).astype(np.float32)
    b1 = np.zeros(h1, dtype=np.float32)
    W2 = (rng.standard_normal((h1, h2)) * math.sqrt(2.0 / h1)).astype(np.float32)
    b2 = np.zeros(h2, dtype=np.float32)
    W3 = (rng.standard_normal((h2, 1)) * math.sqrt(2.0 / h2)).astype(np.float32)
    b3 = np.zeros(1, dtype=np.float32)

    params = [W1, b1, W2, b2, W3, b3]
    m_adam = [np.zeros_like(p) for p in params]
    v_adam = [np.zeros_like(p) for p in params]

    lr0 = 0.004
    l2 = 1e-4
    batch = 256
    epochs = 45
    beta1, beta2, eps = 0.9, 0.999, 1e-8
    step_t = 0

    best_score = -1.0
    best_weights = [p.copy() for p in params]

    # Weight false positives 2.0x stronger to eliminate speech/murmur false triggers
    pos_w = 1.0
    neg_w = 2.0

    for ep in range(epochs):
        perm = rng.permutation(X_tr.shape[0])
        lr = lr0 * 0.5 * (1.0 + math.cos(math.pi * ep / epochs))
        for i in range(0, X_tr.shape[0], batch):
            idx = perm[i : i + batch]
            xb = X_tr[idx]
            yb = y_tr[idx, None]
            nb = xb.shape[0]

            # Forward with dropout on hidden layers
            z1 = xb @ params[0] + params[1]
            a1 = _relu(z1)
            mask1 = (rng.random(a1.shape) > 0.15).astype(np.float32) / 0.85
            a1_d = a1 * mask1

            z2 = a1_d @ params[2] + params[3]
            a2 = _relu(z2)
            mask2 = (rng.random(a2.shape) > 0.10).astype(np.float32) / 0.90
            a2_d = a2 * mask2

            logits = a2_d @ params[4] + params[5]
            prob = _sigmoid(logits)

            sw = np.where(yb > 0.5, pos_w, neg_w).astype(np.float32)
            dz3 = (prob - yb) * sw / nb

            gW3 = a2_d.T @ dz3 + l2 * params[4]
            gb3 = np.sum(dz3, axis=0)
            da2 = (dz3 @ params[4].T) * mask2
            dz2 = da2 * (z2 > 0)

            gW2 = a1_d.T @ dz2 + l2 * params[2]
            gb2 = np.sum(dz2, axis=0)
            da1 = (dz2 @ params[2].T) * mask1
            dz1 = da1 * (z1 > 0)

            gW1 = xb.T @ dz1 + l2 * params[0]
            gb1 = np.sum(dz1, axis=0)

            grads = [gW1, gb1, gW2, gb2, gW3, gb3]
            step_t += 1
            for pi in range(len(params)):
                m_adam[pi] = beta1 * m_adam[pi] + (1.0 - beta1) * grads[pi]
                v_adam[pi] = beta2 * v_adam[pi] + (1.0 - beta2) * (grads[pi] ** 2)
                m_hat = m_adam[pi] / (1.0 - beta1 ** step_t)
                v_hat = v_adam[pi] / (1.0 - beta2 ** step_t)
                params[pi] -= lr * m_hat / (np.sqrt(v_hat) + eps)

        # Validation check
        vp = infer_mlp(X_val, params)
        preds = (vp >= 0.72).astype(np.float32)
        tp = float(np.sum((preds == 1) & (y_val == 1)))
        fp = float(np.sum((preds == 1) & (y_val == 0)))
        fn = float(np.sum((preds == 0) & (y_val == 1)))
        tn = float(np.sum((preds == 0) & (y_val == 0)))
        recall = tp / max(1.0, tp + fn)
        fpr = fp / max(1.0, fp + tn)
        # Optimize F1 heavily penalizing FPR
        score = recall - 4.0 * fpr
        if score > best_score:
            best_score = score
            best_weights = [p.copy() for p in params]

    return best_weights


def infer_mlp(X, weights):
    z1 = X @ weights[0] + weights[1]
    a1 = np.maximum(0.0, z1)
    z2 = a1 @ weights[2] + weights[3]
    a2 = np.maximum(0.0, z2)
    logits = a2 @ weights[4] + weights[5]
    return _sigmoid(logits).reshape(-1)


def main():
    t0 = time.time()
    rng = np.random.default_rng(2026)

    n_pos = 3600
    n_neg = 8400
    X_list = []
    y_list = []

    print(f"Synthesizing {n_pos} snap + {n_neg} hard-negative acoustic samples...")
    for _ in range(n_pos):
        sr = int(rng.choice([44100, 48000]))
        X_list.append(generate_example(rng, sr, 1))
        y_list.append(1.0)
    for _ in range(n_neg):
        sr = int(rng.choice([44100, 48000]))
        X_list.append(generate_example(rng, sr, 0))
        y_list.append(0.0)

    X = np.vstack(X_list).astype(np.float32)
    y = np.array(y_list, dtype=np.float32)

    perm = rng.permutation(X.shape[0])
    X = X[perm]
    y = y[perm]

    split = int(0.82 * X.shape[0])
    X_tr_raw, y_tr = X[:split], y[:split]
    X_val_raw, y_val = X[split:], y[split:]

    feat_mean = np.mean(X_tr_raw, axis=0).astype(np.float32)
    feat_std = np.maximum(np.std(X_tr_raw, axis=0), 1e-4).astype(np.float32)

    X_tr = (X_tr_raw - feat_mean) / feat_std
    X_val = (X_val_raw - feat_mean) / feat_std

    print(f"Training MLP ({NUM_FEATURES} -> 48 -> 24 -> 1) in pure numpy...")
    weights = train_mlp(X_tr, y_tr, X_val, y_val)

    # Positive class standardized prototype for out-of-distribution guard
    X_pos = X_tr[y_tr > 0.5]
    proto_mean = np.mean(X_pos, axis=0).astype(np.float32)
    proto_std = np.maximum(np.std(X_pos, axis=0), 0.25).astype(np.float32)

    vp = infer_mlp(X_val, weights)
    for th in (0.64, 0.76, 0.86):
        pr = vp >= th
        tp = int(np.sum(pr & (y_val > 0.5)))
        fp = int(np.sum(pr & (y_val < 0.5)))
        fn = int(np.sum((~pr) & (y_val > 0.5)))
        tn = int(np.sum((~pr) & (y_val < 0.5)))
        rec = tp / max(1, tp + fn)
        fpr = fp / max(1, fp + tn)
        prec = tp / max(1, tp + fp)
        print(f"  val @ th={th:.2f}: recall={rec:.4f}, precision={prec:.4f}, fpr={fpr:.4f} (tp={tp}, fp={fp}, fn={fn}, tn={tn})")

    out_path = os.path.join(SCRIPT_DIR, "snap_ml_model.npz")
    np.savez(
        out_path,
        feat_mean=feat_mean,
        feat_std=feat_std,
        proto_mean=proto_mean,
        proto_std=proto_std,
        W1=weights[0],
        b1=weights[1],
        W2=weights[2],
        b2=weights[3],
        W3=weights[4],
        b3=weights[5],
        feature_names=np.array(FEATURE_NAMES),
    )
    print(f"Saved ML model -> {out_path} in {time.time() - t0:.2f}s")


if __name__ == "__main__":
    main()
