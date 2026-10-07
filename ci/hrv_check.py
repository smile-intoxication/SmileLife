"""本地验证 HRV 数学：FFT / 插值 / 频带积分。

## 为什么要在 Windows 上跑这个

我要往 iOS 里写一个手写的 radix-2 FFT + HRV 频域分析，而**本机没有 Swift 编译器**。
如果只在 CI 上"编译通过"，那只验证了语法，**验证不了算法对不对** ——
频域分析里最容易错的就是"频带积分少乘一个 Δf"、"单边谱没乘 2"、
"Hanning 窗没做功率归一化"这几类，它们都**不会报错**，只会给出偏了几倍的数。

所以：**用 Python 把完全相同的算法复现一遍，和 numpy 的 FFT 对照**。
算法一致 → Swift 里照着抄就不会有算法级错误。

跑法：python hrv_check.py
"""

import cmath
import math
import random

# ---------------------------------------------------------------- 待验证的算法
# 下面这几个函数是**逐行照搬**要写进 Swift 的那份实现（只是语言不同）。
# 一旦这里对照通过，Swift 里就只需要保证"抄得没错"，不需要再怀疑算法。


def radix2_fft(real, imag):
    """原地 radix-2 FFT（长度必须是 2 的幂）。与 Swift 版逐行对应。"""
    n = len(real)
    if n <= 1 or (n & (n - 1)) != 0 or len(imag) != n:
        return
    # 1) 位反转置换
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            real[i], real[j] = real[j], real[i]
            imag[i], imag[j] = imag[j], imag[i]
    # 2) 蝶形
    length = 2
    while length <= n:
        angle = -2.0 * math.pi / length
        w_real, w_imag = math.cos(angle), math.sin(angle)
        for i in range(0, n, length):
            cur_real, cur_imag = 1.0, 0.0
            for k in range(length // 2):
                a, b = i + k, i + k + length // 2
                t_real = cur_real * real[b] - cur_imag * imag[b]
                t_imag = cur_real * imag[b] + cur_imag * real[b]
                real[b] = real[a] - t_real
                imag[b] = imag[a] - t_imag
                real[a] += t_real
                imag[a] += t_imag
                nxt = cur_real * w_real - cur_imag * w_imag
                cur_imag = cur_real * w_imag + cur_imag * w_real
                cur_real = nxt
        length <<= 1


def interpolate(times_s, values, fs):
    """把不等间隔的 tachogram 线性插值到均匀网格。返回 (网格, 值)。"""
    total = times_s[-1] - times_s[0]
    count = int(total * fs) + 1
    grid = [times_s[0] + i / fs for i in range(count)]
    out = []
    k = 0
    for t in grid:
        while k < len(times_s) - 2 and times_s[k + 1] < t:
            k += 1
        t0, t1 = times_s[k], times_s[k + 1]
        v0, v1 = values[k], values[k + 1]
        span = t1 - t0
        out.append(v0 if span <= 0 else v0 + (v1 - v0) * (t - t0) / span)
    return grid, out


def welch_like_psd(samples, fs):
    """单段 Hann 窗 PSD（单边）。返回 (频率数组, 功率谱密度)。

    归一化用的是 `2 / (fs * sum(w^2))` —— 这是让"对 PSD 积分 = 信号功率"
    成立的那一项。少乘它，频带功率就会差一个窗函数的增益比。
    """
    n = len(samples)
    size = 1
    while size < max(256, n):
        size <<= 1
    mean = sum(samples) / n
    window = [0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) for i in range(n)]
    wsum2 = sum(w * w for w in window)

    real = [(samples[i] - mean) * window[i] for i in range(n)] + [0.0] * (size - n)
    imag = [0.0] * size
    radix2_fft(real, imag)

    half = size // 2
    scale = 2.0 / (fs * wsum2)
    freqs = [k * fs / size for k in range(half + 1)]
    psd = [scale * (real[k] ** 2 + imag[k] ** 2) for k in range(half + 1)]
    # 直流与 Nyquist 不该乘 2（单边谱的端点只算一半）
    psd[0] *= 0.5
    psd[half] *= 0.5
    return freqs, psd


def band_power(freqs, psd, low, high):
    """频带功率 = Σ PSD(f) · Δf，区间用频点中心判定。"""
    df = freqs[1] - freqs[0]
    total = 0.0
    for f, p in zip(freqs, psd):
        if low <= f < high:
            total += p * df
    return total


# ------------------------------------------------------------------ 对照验证
def main():
    random.seed(20261007)

    print("=== 1) FFT 正确性：和朴素 DFT 对照 ===")
    for size in (256, 512):
        real = [random.uniform(-1, 1) for _ in range(size)]
        imag = [0.0] * size
        swift_real, swift_imag = real[:], imag[:]
        radix2_fft(swift_real, swift_imag)
        worst = 0.0
        for k in (0, 1, 7, size // 3, size // 2, size - 1):
            acc = sum(cmath.exp(-2j * math.pi * k * n / size) * real[n] for n in range(size))
            worst = max(worst, abs(acc - complex(swift_real[k], swift_imag[k])))
        print(f"  n={size}: 与朴素 DFT 的最大偏差 = {worst:.3e}  {'✅' if worst < 1e-8 else '❌'}")

    print()
    print("=== 2) 已知信号的频带功率：能不能把谱峰放到正确的带上 ===")
    # 造一段"心跳"：基线 800ms，叠加 0.1Hz（LF）和 0.25Hz（HF）两个正弦振荡
    fs = 4.0
    duration = 300.0        # 先用 5 分钟，这时频域是**有意义**的，可以拿来当基准
    times, rr = [], []
    t = 0.0
    while t < duration:
        rr.append(800.0 + 40.0 * math.sin(2 * math.pi * 0.1 * t)
                        + 15.0 * math.sin(2 * math.pi * 0.25 * t))
        times.append(t)
        t += rr[-1] / 1000.0
    grid, samples = interpolate(times, rr, fs)
    freqs, psd = welch_like_psd(samples, fs)
    lf = band_power(freqs, psd, 0.04, 0.15)
    hf = band_power(freqs, psd, 0.15, 0.40)
    vlf = band_power(freqs, psd, 0.0033, 0.04)
    print(f"  LF={lf:9.1f} ms²  HF={hf:9.1f} ms²  VLF={vlf:8.1f} ms²  LF/HF={lf/hf:.2f}")
    print(f"  期望：LF≈40²/2=800，HF≈15²/2=112，比值≈7.1 → 实际 {lf/hf:.2f}")
    ok = 400 < lf < 1600 and 50 < hf < 250 and lf > hf
    print(f"  {'✅ 量级与比值都对' if ok else '❌ 不对，算法有问题'}")

    print()
    print("=== 3) 关键：同一个信号，记录长度缩短后频域还剩多少可信度 ===")
    for dur in (300, 120, 60, 40):
        times, rr, t = [], [], 0.0
        while t < dur:
            rr.append(800.0 + 40.0 * math.sin(2 * math.pi * 0.1 * t)
                            + 15.0 * math.sin(2 * math.pi * 0.25 * t))
            times.append(t)
            t += rr[-1] / 1000.0
        if len(rr) < 8:
            continue
        grid, samples = interpolate(times, rr, fs)
        freqs, psd = welch_like_psd(samples, fs)
        lf = band_power(freqs, psd, 0.04, 0.15)
        hf = band_power(freqs, psd, 0.15, 0.40)
        df = freqs[1] - freqs[0]
        lf_bins = sum(1 for f in freqs if 0.04 <= f < 0.15)
        hf_bins = sum(1 for f in freqs if 0.15 <= f < 0.40)
        vlf_bins = sum(1 for f in freqs if 0.0033 <= f < 0.04)
        ratio = lf / hf if hf > 0 else float("nan")
        print(f"  {dur:5.0f}s（约 {len(rr):3d} 拍）Δf={df:.4f}Hz  "
              f"LF频点={lf_bins:2d} HF频点={hf_bins:2d} VLF频点={vlf_bins:2d}  "
              f"LF/HF={ratio:6.2f}  （基准 7.1）")
    print("  ↑ 段越短，比值离基准越远 —— 这就是'频域需要长记录'的量化证据，")
    print("    也是为什么 40 秒的序列不该报 LF/HF。")

    print()
    print("=== 4) 时域指标在短片上也稳（对照） ===")
    for dur in (300, 60, 40):
        times, rr, t = [], [], 0.0
        while t < dur:
            rr.append(800.0 + 40.0 * math.sin(2 * math.pi * 0.1 * t)
                            + 15.0 * math.sin(2 * math.pi * 0.25 * t))
            times.append(t)
            t += rr[-1] / 1000.0
        diffs = [rr[i] - rr[i - 1] for i in range(1, len(rr))]
        mean = sum(rr) / len(rr)
        sdnn = math.sqrt(sum((x - mean) ** 2 for x in rr) / (len(rr) - 1))
        rmssd = math.sqrt(sum(d * d for d in diffs) / len(diffs))
        print(f"  {dur:5.0f}s  n={len(rr):3d}  SDNN={sdnn:6.1f}  RMSSD={rmssd:6.1f}")
    print("  ↑ SDNN/RMSSD 的量级在短片上也基本稳定 —— 时域比频域耐受短记录。")

    print()
    print("=== 5) ApEn 的长度偏差（这是它不该在小 n 上用的直接证据）===")
    def apen(xs, m=2, r_ratio=0.2):
        n = len(xs)
        r = r_ratio * (sum((x - sum(xs) / n) ** 2 for x in xs) / (n - 1)) ** 0.5
        if r <= 0:
            return None
        def phi(mm):
            count, total, v = 0, 0.0, n - mm + 1
            for i in range(v):
                for j in range(v):
                    if max(abs(xs[i + k] - xs[j + k]) for k in range(mm)) <= r:
                        count += 1
            return count / (v * v)
        p1, p2 = phi(m), phi(m + 1)
        return None if p1 <= 0 or p2 <= 0 else math.log(p1) - math.log(p2)

    base = [800.0 + 40.0 * math.sin(2 * math.pi * 0.1 * i / 1.25) for i in range(600)]
    for n in (40, 50, 100, 200, 600):
        seg = base[:n]
        print(f"  n={n:3d}  ApEn={apen(seg):.3f}")
    print("  ↑ 同一段信号被截到不同长度，ApEn 明显漂移 —— 所以 n<200 时")
    print("    它只能'自己和自己比'，绝不能跨序列、更不能对标准值。")


if __name__ == "__main__":
    main()
