"""HRV 频域在短记录上到底有多不可信 —— **正确版的实验**。

## 为什么重写这一个

第一版我用"无噪声的双正弦"去测"记录变短会不会让频域变差"，
结论是**没变差**（300s/120s/60s/40s 的 LF/HF 都是 8.9）。
那个实验是错的：确定性的双音信号，就算只截 40 秒也能看出两个峰。

真正的问题**不是"看不看得见峰"，而是两件事**：
1. **估计量的方差** —— 频域估计的置信区间 ∝ 1/√(T·带宽)。
   短记录下同一段生理信号会给出**散布极大**的 LF/HF，而报告里只会印一个数。
2. **VLF 的周期装不进窗口** —— VLF 下限 0.0033 Hz 对应 **300 秒**周期。
   40 秒窗口**在物理上装不下一个 VLF 周期**，测出来的只能是趋势泄漏。

所以这一版做**蒙特卡洛**：从同一段长期信号里反复抽窗口，看 LF/HF 的散布。
"""

import math
import random

from hrv_check import interpolate, welch_like_psd, band_power

FS = 4.0
TRUE_VLF_AMP = 30.0     # 0.01 Hz，周期 100 秒
TRUE_LF_AMP = 40.0      # 0.10 Hz
TRUE_HF_AMP = 15.0      # 0.25 Hz
NOISE_SD = 15.0         # ms，模拟真实 RR 的宽带噪声


def build_series(duration_s, seed):
    """造一段**有噪声、有 VLF** 的 RR 序列（这是"真实感"的关键）。"""
    rng = random.Random(seed)
    times, rr = [], []
    t = 0.0
    while t < duration_s:
        value = (800.0
                 + TRUE_VLF_AMP * math.sin(2 * math.pi * 0.01 * t)
                 + TRUE_LF_AMP * math.sin(2 * math.pi * 0.10 * t)
                 + TRUE_HF_AMP * math.sin(2 * math.pi * 0.25 * t)
                 + rng.gauss(0, NOISE_SD))
        rr.append(value)
        times.append(t)
        t += value / 1000.0
    return times, rr


def analyse(times, rr):
    grid, samples = interpolate(times, rr, FS)
    freqs, psd = welch_like_psd(samples, FS)
    return (band_power(freqs, psd, 0.0033, 0.04),
            band_power(freqs, psd, 0.04, 0.15),
            band_power(freqs, psd, 0.15, 0.40))


def quantile(xs, q):
    s = sorted(xs)
    pos = q * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def main():
    print(__doc__)
    print("=" * 74)
    print(f"真实频谱：VLF 0.01Hz 幅值 {TRUE_VLF_AMP}  LF 0.10Hz 幅值 {TRUE_LF_AMP}"
          f"  HF 0.25Hz 幅值 {TRUE_HF_AMP}  白噪声 SD={NOISE_SD}ms")
    print(f"理论频带功率：VLF≈{TRUE_VLF_AMP**2/2:.0f}  LF≈{TRUE_LF_AMP**2/2:.0f}"
          f"  HF≈{TRUE_HF_AMP**2/2:.0f}  真值 LF/HF≈{(TRUE_LF_AMP/TRUE_HF_AMP)**2:.1f}")
    print("=" * 74)

    # 一段很长的"底稿"，从里面随机抽窗口 —— 生理信号本身不变，变的只是窗口长度
    long_times, long_rr = build_series(1800.0, seed=1)
    print(f"底稿：1800 秒，{len(long_rr)} 拍\n")
    print(f"{'窗口':>7} {'拍数':>5} {'Δf':>8}  "
          f"{'LF/HF 中位':>10} {'LF/HF 5%~95%':>18} {'相对散布':>9}  "
          f"{'VLF 中位':>9}{'真值100':>8}")
    print("-" * 74)

    rng = random.Random(99)
    for duration in (40, 60, 120, 300):
        trials = []
        while len(trials) < 200:
            start = rng.uniform(0, 1800.0 - duration)
            tw = [t for t in long_times if start <= t < start + duration]
            if len(tw) < 20:
                continue
            idx = long_times.index(tw[0])
            trials.append(analyse(tw, long_rr[idx:idx + len(tw)]))
        ratios = [lf / hf for _, lf, hf in trials if hf > 0]
        vlfs = [v for v, _, _ in trials]
        med = quantile(ratios, 0.5)
        lo, hi = quantile(ratios, 0.05), quantile(ratios, 0.95)
        spread = (hi - lo) / med if med else float("nan")
        beats = len([t for t in long_times if t < duration])
        df = FS / max(256, int(duration * FS) if duration * FS > 256 else 256)
        print(f"{duration:6.0f}s {beats:5d} {df:8.4f}  "
              f"{med:10.2f} {lo:8.2f}~{hi:<8.2f} {spread:8.0%}  "
              f"{quantile(vlfs, 0.5):9.1f}")

    print("-" * 74)
    print("读法：")
    print("  · 「相对散布」= (95分位 - 5分位) / 中位数。**同一段生理信号**、只换窗口长度，")
    print("    40 秒时 LF/HF 能差出好几倍 —— 而报告上只会印一个数。")
    print("  · 「VLF 中位」对真值 100：窗口越短，测出来的 VLF 越低（周期装不进去，")
    print("    能量被当成趋势/直流丢掉了）。这就是 VLF 在 40 秒上不可用的直接证据。")


if __name__ == "__main__":
    main()
