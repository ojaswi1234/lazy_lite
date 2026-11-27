# -*- coding: utf-8 -*-
"""Shared acoustic feature extraction & speech-context analysis for finger-snap ML.

All features are scale-invariant (normalized against local energy / noise baseline)
so both close-range (0.3 m) and far-field (3-4 m) finger snaps map to consistent
regions of feature space while rejecting:
- Solo human speech (voiced vowels, plosives 't/k/p/ch + vowel', coughs, sibilants)
- Noisy environments (fan/AC hum, cafe babble, keyboard typing, mouse clicks, claps)

Pure numpy implementation (zero librosa/scipy dependency).
"""

import functools
import math
import numpy as np


@functools.lru_cache(maxsize=64)
def _cached_freqs(n, sr):
    return np.fft.rfftfreq(n, d=1.0 / sr)


@functools.lru_cache(maxsize=64)
def _cached_hann(n):
    return np.hanning(n).astype(np.float32)


@functools.lru_cache(maxsize=64)
def _cached_hp_mask(n, sr, cutoff_hz):
    freqs = _cached_freqs(n, sr)
    return np.clip((freqs - cutoff_hz * 0.85) / max(cutoff_hz * 0.30, 1.0), 0.0, 1.0).astype(np.float32)

FEATURE_NAMES = [
    "b0_60_250",
    "b1_250_700",
    "b2_700_1400",
    "b3_1400_2200",
    "b4_2200_3500",
    "b5_3500_5200",
    "b6_5200_8500",
    "b7_8500_16000",
    "centroid_norm",
    "bandwidth_norm",
    "rolloff_norm",
    "spectral_flatness",
    "peak_prominence_log",
    "snap_vs_low_log",
    "snap_vs_ultra_log",
    "fwhm_ms_norm",
    "rise_ms_norm",
    "decay_25_ratio",
    "decay_55_ratio",
    "secondary_peak_ratio",
    "hp_crest_norm",
    "hp_kurtosis_log",
    "post_voiced_acf",
    "pre_voiced_acf",
    "post_low_spill_log",
    "robust_snr_log",
]

NUM_FEATURES = len(FEATURE_NAMES)

BAND_EDGES = [
    (60.0, 250.0),
    (250.0, 700.0),
    (700.0, 1400.0),
    (1400.0, 2200.0),
    (2200.0, 3500.0),
    (3500.0, 5200.0),
    (5200.0, 8500.0),
    (8500.0, 16000.0),
]


def _highpass_fft(wave, sr, cutoff_hz=1100.0):
    """Zero-phase FFT high-pass filter above cutoff_hz."""
    n = wave.shape[0]
    if n < 16:
        return wave
    spec = np.fft.rfft(wave - np.mean(wave))
    mask = _cached_hp_mask(n, sr, float(cutoff_hz))
    return np.fft.irfft(spec * mask, n=n).astype(np.float32)


def _bandpass_fft(wave, sr, low_hz=75.0, high_hz=1100.0):
    """Zero-phase FFT band-pass filter for speech periodicity estimation."""
    n = wave.shape[0]
    if n < 32:
        return wave
    freqs = _cached_freqs(n, sr)
    spec = np.fft.rfft(wave - np.mean(wave))
    mask = ((freqs >= low_hz) & (freqs <= high_hz)).astype(np.float32)
    return np.fft.irfft(spec * mask, n=n).astype(np.float32)


def compute_acoustic_signature(pcm_window, sr, peak_idx, bg_snap_rms=1e-4, bg_speech_rms=1e-4):
    """Compute DRR, core crest, murmur/speech-band RMS, and transient isolation ratio.

    Detects unvoiced murmuring, whispering, and soft mouth pops that evade pitch ACF.
    """
    a0 = max(0, peak_idx - int(round(sr * 0.130)))
    a1 = min(pcm_window.size, peak_idx + int(round(sr * 0.080)))
    if a1 - a0 < int(sr * 0.040):
        return {
            "drr": 1.0, "core_rms": 0.0, "core_peak": 0.0, "core_crest": 0.0,
            "speech_pre": 0.0, "speech_post": 0.0, "isolation": 1.0,
        }

    seg = pcm_window[a0:a1].astype(np.float32, copy=False)
    c = peak_idx - a0

    hp = _highpass_fft(seg, sr, cutoff_hz=1200.0)
    sp_bp = _bandpass_fft(seg, sr, low_hz=220.0, high_hz=1150.0)

    c0 = max(0, c - int(round(sr * 0.002)))
    c1 = min(hp.size, c + int(round(sr * 0.012)))
    r0 = min(hp.size, c + int(round(sr * 0.018)))
    r1 = min(hp.size, c + int(round(sr * 0.058)))

    core = hp[c0:c1]
    rev = hp[r0:r1]
    core_rms = float(np.sqrt(np.mean(core * core) + 1e-14)) if core.size else 0.0
    core_peak = float(np.max(np.abs(core))) if core.size else 0.0
    core_crest = core_peak / max(core_rms, 1e-9)
    rev_rms = float(np.sqrt(np.mean(rev * rev) + 1e-14)) if rev.size else bg_snap_rms
    excess_rev = max(rev_rms - 0.85 * bg_snap_rms, bg_snap_rms * 0.25, 1e-6)
    drr = core_rms / excess_rev

    # Unvoiced murmur/speech envelope in 160-1150 Hz before (-125..-18 ms) and after (+16..+75 ms)
    p0 = max(0, c - int(round(sr * 0.125)))
    p1 = max(p0 + 16, c - int(round(sr * 0.018)))
    q0 = min(sp_bp.size, c + int(round(sr * 0.016)))
    q1 = min(sp_bp.size, c + int(round(sr * 0.075)))
    pre_sp = sp_bp[p0:p1]
    post_sp = sp_bp[q0:q1]
    speech_pre = float(np.sqrt(np.mean(pre_sp * pre_sp) + 1e-14)) if pre_sp.size else 0.0
    speech_post = float(np.sqrt(np.mean(post_sp * post_sp) + 1e-14)) if post_sp.size else 0.0

    # Isolation ratio: how cleanly high-band core (10 ms) spikes above surrounding high-band audio
    sur_pre = hp[p0:p1]
    sur_post = hp[min(hp.size, c + int(round(sr * 0.025))) : min(hp.size, c + int(round(sr * 0.075)))]
    sur_pre_rms = float(np.sqrt(np.mean(sur_pre * sur_pre) + 1e-14)) if sur_pre.size else bg_snap_rms
    sur_post_rms = float(np.sqrt(np.mean(sur_post * sur_post) + 1e-14)) if sur_post.size else bg_snap_rms
    isolation = core_rms / max(0.5 * (sur_pre_rms + sur_post_rms), bg_snap_rms, 1e-6)

    return {
        "drr": float(min(200.0, drr)),
        "core_rms": core_rms,
        "core_peak": core_peak,
        "core_crest": float(core_crest),
        "speech_pre": speech_pre,
        "speech_post": speech_post,
        "isolation": float(min(200.0, isolation)),
    }


def estimate_voiced_acf(segment, sr, min_hz=75.0, max_hz=360.0):
    """Normalized autocorrelation peak in human vocal F0 range (0.0 .. 1.0).

    Requires vocal formant energy in 260..1400 Hz so steady 60-220 Hz fan/AC hum
    never registers as human voiced speech.
    """
    if segment.size < int(sr * 0.025):
        return 0.0
    n = segment.size
    freqs = _cached_freqs(n, sr)
    spec = np.fft.rfft(segment - np.mean(segment))
    pow_spec = spec.real * spec.real + spec.imag * spec.imag

    # Vocal band energy & formant check (suppress pure 60-185 Hz electrical/fan hums & ultra-quiet floor)
    e_total_low = float(np.sum(pow_spec[(freqs >= 65.0) & (freqs <= 1400.0)]))
    e_formant = float(np.sum(pow_spec[(freqs >= 260.0) & (freqs <= 1400.0)]))
    e_hum = float(np.sum(pow_spec[(freqs >= 65.0) & (freqs <= 185.0)]))
    if e_total_low < 1e-8 or (e_formant / max(e_total_low, 1e-12)) < 0.22 or e_formant < 0.35 * e_hum:
        return 0.0

    mask = ((freqs >= min_hz) & (freqs <= max_hz * 2.5)).astype(np.float32)
    bp = np.fft.irfft(spec * mask, n=n).astype(np.float32)
    energy = float(np.dot(bp, bp))
    bp_rms = math.sqrt(energy / max(1, n))
    if energy < 1e-10 or bp_rms < 0.0022:
        return 0.0
    fft_n = 1 << int(math.ceil(math.log2(2 * n - 1)))
    f = np.fft.rfft(bp, n=fft_n)
    acf = np.fft.irfft(f * np.conj(f), n=fft_n)[:n]
    acf0 = max(float(acf[0]), 1e-12)
    lag_min = max(1, int(round(sr / max_hz)))
    lag_max = min(n // 2, int(round(sr / min_hz)))
    if lag_max <= lag_min:
        return 0.0
    peak_acf = float(np.max(acf[lag_min : lag_max + 1])) / acf0
    return float(max(0.0, min(1.0, peak_acf)))


def extract_snap_features(
    pcm_window,
    sr,
    peak_idx,
    bg_snap_rms=1e-4,
    bg_mad=5e-5,
    bg_spectrum=None,
):
    """Extract 26 scale-invariant ML features centered around sample `peak_idx`.

    Expected window coverage: at least 120 ms before `peak_idx` and 75 ms after.
    Shorter boundaries are zero-padded cleanly.
    Returns np.ndarray of shape (NUM_FEATURES,), dtype float32.
    """
    pre_len = int(round(sr * 0.140))
    post_len = int(round(sr * 0.080))
    start = peak_idx - pre_len
    end = peak_idx + post_len

    # Extract fixed [pre_len + post_len] slice with edge zero padding
    pad_l = max(0, -start)
    pad_r = max(0, end - pcm_window.size)
    s0 = max(0, start)
    s1 = min(pcm_window.size, end)
    core_slice = pcm_window[s0:s1].astype(np.float32, copy=False)
    if pad_l or pad_r:
        seg = np.pad(core_slice, (pad_l, pad_r), mode="constant")
    else:
        seg = core_slice

    c = pre_len  # exact peak center inside `seg`

    # --- 1. Noise-subtracted Core Spectrum (-4 ms .. +16 ms = 20 ms Hann) ---
    sp_a = max(0, c - int(round(sr * 0.004)))
    sp_b = min(seg.size, c + int(round(sr * 0.016)))
    win_wav = seg[sp_a:sp_b]
    n_sp = win_wav.size
    win_hann = _cached_hann(n_sp)
    spec = np.fft.rfft((win_wav - np.mean(win_wav)) * win_hann)
    power = (spec.real * spec.real + spec.imag * spec.imag) / max(1, n_sp)
    freqs = _cached_freqs(n_sp, sr)

    # Subtract pre-onset ambient spectrum using length-matched `n_sp` Hann windows so a recent
    # 1st snap (100-140 ms ago) never raises the floor AND 60/120 Hz sidelobes cancel cleanly.
    if bg_spectrum is not None and bg_spectrum.shape == power.shape:
        amb_pow = bg_spectrum
    else:
        def _win_pow_matched(end_offset_sec):
            wb = max(n_sp, c - int(round(sr * end_offset_sec)))
            wa = max(0, wb - n_sp)
            sl = seg[wa:wb]
            if sl.size == n_sp:
                sp = np.fft.rfft((sl - np.mean(sl)) * win_hann)
                return (sp.real * sp.real + sp.imag * sp.imag) / max(1, n_sp)
            hw = _cached_hann(sl.size)
            sp = np.fft.rfft((sl - np.mean(sl)) * hw)
            pw = (sp.real * sp.real + sp.imag * sp.imag) / max(1, sl.size)
            return np.interp(freqs, _cached_freqs(sl.size, sr), pw)

        # 5 matched-length 20ms frames across -140..-30 ms: median avoids both double-snap bleed
        # (ignores up to 2 spike frames) and chi^2 min downward bias on fan turbulence.
        stack = np.stack([
            _win_pow_matched(0.120),
            _win_pow_matched(0.098),
            _win_pow_matched(0.076),
            _win_pow_matched(0.054),
            _win_pow_matched(0.032),
        ], axis=0)
        amb_pow = np.median(stack, axis=0)

    # Subtract pre-onset stationary ambient spectrum so steady room/ceiling-fan noise
    # does not drown out finger snaps; transient vowels/murmurs above floor still keep 150-1400 Hz energy.
    clean_pow = np.maximum(0.0, power - 1.25 * amb_pow)

    tot_mask = (freqs >= 60.0) & (freqs <= min(16000.0, sr * 0.48))
    tot_energy = float(np.sum(clean_pow[tot_mask])) + 1e-12

    band_fracs = []
    for f_lo, f_hi in BAND_EDGES:
        hi_cap = min(f_hi, sr * 0.48)
        if f_lo >= hi_cap:
            band_fracs.append(0.0)
        else:
            bm = (freqs >= f_lo) & (freqs < hi_cap)
            band_fracs.append(float(np.sum(clean_pow[bm])) / tot_energy)

    # Spectral shape metrics over 1.2 kHz .. 12 kHz
    hi_mask = (freqs >= 1200.0) & (freqs <= min(12000.0, sr * 0.48))
    hi_f = freqs[hi_mask]
    hi_p = clean_pow[hi_mask]
    hi_sum = float(np.sum(hi_p)) + 1e-12
    centroid = float(np.sum(hi_f * hi_p) / hi_sum) if hi_f.size else 3000.0
    centroid_norm = (centroid - 1200.0) / 10800.0
    bw = float(np.sqrt(np.sum(((hi_f - centroid) ** 2) * hi_p) / hi_sum)) if hi_f.size else 1500.0
    bandwidth_norm = bw / 5000.0

    cum_p = np.cumsum(hi_p) / hi_sum if hi_p.size else np.array([1.0])
    ro_idx = int(np.searchsorted(cum_p, 0.85))
    ro_freq = float(hi_f[min(ro_idx, max(0, hi_f.size - 1))]) if hi_f.size else 6000.0
    rolloff_norm = (ro_freq - 1200.0) / 10800.0

    # Spectral flatness (Wiener entropy) & resonant peak prominence in 1.6..7.5 kHz
    sf_mask = (freqs >= 1600.0) & (freqs <= min(7500.0, sr * 0.48))
    sf_p = np.maximum(clean_pow[sf_mask], 1e-15)
    if sf_p.size >= 4:
        geo = math.exp(float(np.mean(np.log(sf_p))))
        arith = float(np.mean(sf_p)) + 1e-15
        spectral_flatness = min(1.0, geo / arith)
    else:
        spectral_flatness = 0.5

    mod_mask = (freqs >= 1800.0) & (freqs <= min(5500.0, sr * 0.48))
    mod_p = clean_pow[mod_mask]
    if mod_p.size >= 3:
        med_p = float(np.median(mod_p)) + 1e-12
        peak_prom_log = math.log1p(min(200.0, float(np.max(mod_p)) / med_p)) / math.log(201.0)
    else:
        peak_prom_log = 0.0

    e_snap = float(np.sum(clean_pow[(freqs >= 1700.0) & (freqs <= 5500.0)]))
    e_low = float(np.sum(clean_pow[(freqs >= 160.0) & (freqs <= 1250.0)]))
    e_ultra = float(np.sum(clean_pow[(freqs >= 6500.0) & (freqs <= min(16000.0, sr * 0.48))]))

    snap_vs_low_log = math.log1p(min(250.0, e_snap / max(e_low, tot_energy * 0.002))) / math.log(251.0)
    snap_vs_ultra_log = math.log1p(min(150.0, e_snap / max(e_ultra, tot_energy * 0.002))) / math.log(151.0)

    # --- 2. High-Passed Sub-Millisecond Temporal Envelope (-10 ms .. +75 ms) ---
    hp_a = max(0, c - int(round(sr * 0.012)))
    hp_b = min(seg.size, c + int(round(sr * 0.076)))
    hp_wave = _highpass_fft(seg[hp_a:hp_b], sr, cutoff_hz=1200.0)
    hp_c = c - hp_a

    # 1 ms sliding RMS envelope in 1 ms steps (-10 ms .. +72 ms)
    bin_n = max(16, int(round(sr * 0.001)))
    env = []
    # Align bins so peak region sits around index 10
    start_samp = max(0, hp_c - 10 * bin_n)
    for k in range(82):
        b0 = start_samp + k * bin_n
        b1 = b0 + bin_n
        if b1 > hp_wave.size:
            break
        sl = hp_wave[b0:b1]
        env.append(float(np.sqrt(np.mean(sl * sl) + 1e-16)))
    env_arr = np.array(env, dtype=np.float32) if env else np.zeros(20, dtype=np.float32)

    # Peak within +/- 5 ms of trigger center
    search_lo = min(max(0, 5), env_arr.size - 1)
    search_hi = min(env_arr.size, 18)
    pk_bin = int(search_lo + np.argmax(env_arr[search_lo:search_hi])) if search_hi > search_lo else 10
    pk_rms = max(float(env_arr[pk_bin]), 1e-9)

    # FWHM (ms): count contiguous bins around pk_bin above 0.5 * pk_rms
    half_lvl = 0.5 * pk_rms
    l_idx = pk_bin
    while l_idx > 0 and env_arr[l_idx - 1] >= half_lvl:
        l_idx -= 1
    r_idx = pk_bin
    while r_idx + 1 < env_arr.size and env_arr[r_idx + 1] >= half_lvl:
        r_idx += 1
    fwhm_ms = float(r_idx - l_idx + 1)
    fwhm_ms_norm = min(1.0, fwhm_ms / 35.0)

    # Rise time (ms): distance from last bin < 0.18 * pk_rms before pk_bin
    r_start = pk_bin
    while r_start > 0 and env_arr[r_start - 1] >= 0.18 * pk_rms:
        r_start -= 1
    rise_ms = float(pk_bin - r_start)
    rise_ms_norm = min(1.0, rise_ms / 12.0)

    # Decay tail ratios (+20..+40 ms and +45..+70 ms)
    t25_a, t25_b = min(env_arr.size, pk_bin + 20), min(env_arr.size, pk_bin + 40)
    decay_25 = float(np.mean(env_arr[t25_a:t25_b])) / pk_rms if t25_b > t25_a else 1.0
    decay_25 = min(1.5, decay_25)

    t55_a, t55_b = min(env_arr.size, pk_bin + 42), min(env_arr.size, pk_bin + 68)
    decay_55 = float(np.mean(env_arr[t55_a:t55_b])) / pk_rms if t55_b > t55_a else 1.0
    decay_55 = min(1.5, decay_55)

    # Secondary peak in +12..+45 ms (catches keyboard switch bounce / clatter / speech re-onset)
    sec_a, sec_b = min(env_arr.size, pk_bin + 12), min(env_arr.size, pk_bin + 45)
    secondary_peak_ratio = float(np.max(env_arr[sec_a:sec_b])) / pk_rms if sec_b > sec_a else 0.0
    secondary_peak_ratio = min(1.5, secondary_peak_ratio)

    # Core window crest factor and kurtosis (-3 ms .. +20 ms)
    k_a = max(0, hp_c - int(round(sr * 0.003)))
    k_b = min(hp_wave.size, hp_c + int(round(sr * 0.022)))
    core_hp = hp_wave[k_a:k_b]
    if core_hp.size >= 32:
        c_rms = float(np.sqrt(np.mean(core_hp * core_hp) + 1e-16))
        c_pk = float(np.max(np.abs(core_hp)))
        hp_crest_norm = min(1.0, (c_pk / max(c_rms, 1e-9)) / 12.0)
        z = (core_hp - float(np.mean(core_hp))) / max(c_rms, 1e-9)
        kurt = float(np.mean(z ** 4))
        hp_kurtosis_log = min(1.0, math.log1p(max(0.0, kurt)) / math.log(120.0))
    else:
        hp_crest_norm = 0.2
        hp_kurtosis_log = 0.2

    # --- 3. Solo Speaker / Voiced Context Features ---
    # Post-onset (+14 ms .. +78 ms) -> catches "t-aa", "k-ee", "p-oo" vowel voicing!
    pv_a = min(seg.size, c + int(round(sr * 0.014)))
    pv_b = min(seg.size, c + int(round(sr * 0.078)))
    post_voiced_acf = estimate_voiced_acf(seg[pv_a:pv_b], sr)

    # Pre-onset (-115 ms .. -18 ms) -> speaker talking immediately before burst
    prv_a = max(0, c - int(round(sr * 0.115)))
    prv_b = max(prv_a, c - int(round(sr * 0.018)))
    pre_voiced_acf = estimate_voiced_acf(seg[prv_a:prv_b], sr)

    # Low-frequency speech spillover after onset vs pre-onset low-band RMS
    low_seg = _bandpass_fft(seg, sr, low_hz=110.0, high_hz=850.0)
    pre_low = low_seg[prv_a:prv_b]
    post_low = low_seg[pv_a:pv_b]
    pre_low_rms = float(np.sqrt(np.mean(pre_low * pre_low) + 1e-14)) if pre_low.size else 1e-7
    post_low_rms = float(np.sqrt(np.mean(post_low * post_low) + 1e-14)) if post_low.size else 1e-7
    # Normalize against core snap peak level so pure snap in silence doesn't amplify tiny noise ratio
    post_low_rel = post_low_rms / max(pre_low_rms + 0.05 * pk_rms, 1e-6)
    post_low_spill_log = min(1.0, math.log1p(post_low_rel) / math.log(16.0))

    # --- 4. Robust Noise Floor Z-score ---
    # Measure 10 ms high-band RMS centered at peak vs rolling median + MAD
    c10_a = max(0, hp_c - int(round(sr * 0.005)))
    c10_b = min(hp_wave.size, hp_c + int(round(sr * 0.005)))
    snap10_rms = float(np.sqrt(np.mean(hp_wave[c10_a:c10_b] ** 2) + 1e-16)) if c10_b > c10_a else pk_rms
    z_snr = max(0.0, snap10_rms - bg_snap_rms) / max(bg_mad, bg_snap_rms * 0.25, 1e-6)
    robust_snr_log = min(1.0, math.log1p(min(200.0, z_snr)) / math.log(201.0))

    feats = np.array(
        band_fracs
        + [
            centroid_norm,
            bandwidth_norm,
            rolloff_norm,
            spectral_flatness,
            peak_prom_log,
            snap_vs_low_log,
            snap_vs_ultra_log,
            fwhm_ms_norm,
            rise_ms_norm,
            decay_25,
            decay_55,
            secondary_peak_ratio,
            hp_crest_norm,
            hp_kurtosis_log,
            post_voiced_acf,
            pre_voiced_acf,
            post_low_spill_log,
            robust_snr_log,
        ],
        dtype=np.float32,
    )
    return np.nan_to_num(feats, nan=0.0, posinf=1.0, neginf=0.0)
