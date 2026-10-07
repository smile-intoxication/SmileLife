"""短序列**按小时平均**之后，LF Norm 能不能用？—— 用实测回答，不靠推理。

## 为什么要问这个
需求方要"近 7 天的交感/副交感归一化河流图"。但每条序列只覆盖约 1 分钟，
而单条序列的 `lfNorm` 门槛我定在 120 个间期（理由见 `HRVMetrics`）——
**照那个门槛，河流图永远是空的**。

可"一小时里有好几条序列，把它们平均起来"是另一回事：
Welch 法的核心就是**平均多个周期图来降方差**。平均不改频率分辨率（那是窗口长度定的），
但**方差**能降。

所以这里量化三件事：
1. 单条 ~40 秒序列的 LF Norm 散布有多大；
2. 把 N 条这样序列的 LF Norm **平均**之后，散布降到多少；
3. 平均值离真值有多远（**偏差**）—— 这一条平均**修不掉**，必须单独看。

跑法：python hrv_check_hourly.py
"""

import math
import random

from hrv_check import interpolate, welch_like_psd, band_power

FS = 4.0
TRUE_VLF_AMP = 30.0
TRUE_LF_AMP = 40.0
TRUE_HF_AMP = 15.0
TRUE_LF_POWER = TRUE_LF_AMP ** 2 / 2      # 800
TRUE_HF_POWER = TRUE_HF_AMP ** 2 / 2      # 112.5
TRUE_LF_NORM = TRUE_LF_POWER / (TRUE_LF_POWER + TRUE_HF_POWER) * 100   # ≈87.7


def one_recording(rng, duration_s):
    """造一条"一次记录"的 RR 序列（时长约 duration_s）。"""
    times, rr = [], []
    t = 0.0
    while t < duration_s:
        rr.append(800.0
                  + TRUE_VLF_AMP * math.sin(2 * math.pi * 0.01 * t)
                  + TRUE_LF_AMP * math.sin(2 * math.pi * 0.10 * t)
                  + TRUE_HF_AMP * math.sin(2 * math.pi * 0.25 * t)
                  + rng.gauss(0, 15.0))
        times.append(t)
        t += rr[-1] / 1000.0
    return times, rr


def lf_norm_of(times, rr):
    grid, samples = interpolate(times, rr, FS)
    freqs, psd = welch_like_psd(samples, FS)
    lf = band_power(freqs, psd, 0.04, 0.15)
    hf = band_power(freqs, psd, 0.15, 0.40)
    if lf + hf <= 0:
        return None
    return lf / (lf + hf) * 100


def quantile(xs, q):
    s = sorted(xs)
    pos = q * (len(s) - 1)
    lo = int(math.floor(pos)); hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def main():
    print(__doc__)
    print("=" * 78)
    print(f"真实频谱：LF 幅值 {TRUE_LF_AMP} / HF 幅值 {TRUE_HF_AMP}  →  "
          f"真值 LF Norm ≈ {TRUE_LF_NORM:.1f} %")
    print("=" * 78)

    rng = random.Random(20261008)

    print("\n【1】单条约 40 秒序列的 LF Norm（1000 次独立抽取）")
    singles = []
    for _ in range(1000):
        times, rr = one_recording(rng, 40.0)
        v = lf_norm_of(times, rr)
        if v is not None:
            singles.append(v)
    print(f"    中位 {quantile(singles,0.5):6.1f}   "
          f"5%~95% = {quantile(singles,0.05):6.1f} ~ {quantile(singles,0.95):6.1f}   "
          f"散布 {(quantile(singles,0.95)-quantile(singles,0.05))/quantile(singles,0.5):.0%}")
    print(f"    ⚠️ 离真值 {TRUE_LF_NORM:.1f} 的**偏差** = "
          f"{quantile(singles,0.5)-TRUE_LF_NORM:+.1f} 个百分点")

    print("\n【2】把 N 条这样的序列**平均**之后（每组各 1000 次）")
    print(f"    {'N':>4}  {'中位':>7}  {'5%~95%':>18}  {'散布':>7}  {'偏差':>8}")
    print("    " + "-" * 52)
    for n in (1, 3, 5, 10, 20, 40):
        averages = []
        for _ in range(1000):
            vals = []
            for _ in range(n):
                times, rr = one_recording(rng, 40.0)
                v = lf_norm_of(times, rr)
                if v is not None:
                    vals.append(v)
            if vals:
                averages.append(sum(vals) / len(vals))
        med = quantile(averages, 0.5)
        lo, hi = quantile(averages, 0.05), quantile(averages, 0.95)
        print(f"    {n:>4}  {med:7.1f}  {lo:7.1f} ~ {hi:<7.1f}  "
              f"{(hi-lo)/med:6.0%}  {med-TRUE_LF_NORM:+7.1f}")

    print("\n【3】单条序列要**多长**才能和'平均 10 条 40 秒'一样稳")
    print(f"    {'时长':>6}  {'中位':>7}  {'5%~95%':>18}  {'散布':>7}  {'偏差':>8}")
    print("    " + "-" * 52)
    for duration in (40, 60, 120, 180, 300):
        vals = []
        for _ in range(1000):
            times, rr = one_recording(rng, duration)
            v = lf_norm_of(times, rr)
            if v is not None:
                vals.append(v)
        med = quantile(vals, 0.5)
        lo, hi = quantile(vals, 0.05), quantile(vals, 0.95)
        print(f"    {duration:5.0f}s  {med:7.1f}  {lo:7.1f} ~ {hi:<7.1f}  "
              f"{(hi-lo)/med:6.0%}  {med-TRUE_LF_NORM:+7.1f}")

    print("\n讀法：")
    print("  · 【2】看的是**平均能不能救短序列**：散布随 N 下降 = 能（Welch 的思路），")
    print("    但**偏差那一列几乎不动** —— 平均只降方差，不修系统偏差。")
    print("  · 【3】看的是'同样稳'需要多长的记录，用来和【2】做对比。")


if __name__ == "__main__":
    main()
