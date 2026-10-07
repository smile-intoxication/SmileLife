import Foundation

// MARK: - HRV 指标注册表
//
// ## 为什么"最少间期数"要和指标定义写在一起
// 需求方给的参考报告里有 TP / VLF / LF / HF / LF-HF 一整套频域指标，
// 而**我们的序列只有约 50 拍（≈40 秒）**。照抄那套数字会得出
// "看起来很专业、实际毫无意义"的结论 —— 这正是本项目最想避免的一类错误
// （"表能填出来"被当成"这个结论成立"）。
//
// 所以每个指标都携带**它成立的前提**，界面据此决定显示还是隐藏。
// 门槛不是照抄教科书，而是 `ci/hrv_check_windows.py` **实测出来的**：
// 从同一段 1800 秒信号里反复抽窗口，看指标的散布随窗口长度怎么变。

/// 一个 HRV 指标：值 + **它成立的前提**。
struct HRVMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let unit: String
    /// 算出有意义的值**至少**需要多少个 RR 间期
    let minimumIntervals: Int
    /// 为什么是这个门槛 —— 会显示在界面上，让用户知道"差多少、为什么差"
    let rationale: String
}

enum HRVMetrics {

    /// 全部指标。**顺序 = 界面显示顺序**（先能算的，后不能算的）。
    static let all: [HRVMetric] = [
        // ——— 时域：短片也耐受 ———
        HRVMetric(id: "mean_hr", title: "平均心率", unit: "bpm",
                  minimumIntervals: 5,
                  rationale: "只是个均值，几个间期就够"),
        HRVMetric(id: "mean_rr", title: "平均 RR", unit: "ms",
                  minimumIntervals: 5,
                  rationale: "同上"),
        HRVMetric(id: "rmssd", title: "RMSSD", unit: "ms",
                  minimumIntervals: 20,
                  rationale: "差值类指标，短片也稳 —— 实测 40 秒的估计已经很接近长记录"),
        HRVMetric(id: "sd1", title: "SD1", unit: "ms",
                  minimumIntervals: 20,
                  rationale: "= RMSSD/√2，和 RMSSD 是同一份信息，所以门槛相同"),
        HRVMetric(id: "cv", title: "CV（变异系数）", unit: "",
                  minimumIntervals: 20,
                  rationale: "SDNN/平均RR，无量纲，跨人可比"),
        HRVMetric(id: "pnn20", title: "pNN20", unit: "%",
                  minimumIntervals: 30,
                  rationale: "阈值放宽到 20ms 后步进更细，短片比 pNN50 可靠"),
        HRVMetric(id: "pnn50", title: "pNN50", unit: "%",
                  minimumIntervals: 50,
                  rationale: "分母是差值个数：50 拍只有 49 个差值 → 结果只能按 2% 步进"),
        HRVMetric(id: "sdnn", title: "SDNN", unit: "ms",
                  minimumIntervals: 60,
                  rationale: "临床标准是 5 分钟；1 分钟以内只能看**本人趋势**，不能对标准值"),
        HRVMetric(id: "sd2", title: "SD2", unit: "ms",
                  minimumIntervals: 100,
                  rationale: "要估离散度，短片上噪声占比太大"),

        // ——— 频域：需要长记录 ———
        HRVMetric(id: "hf_power", title: "HF 功率", unit: "ms²",
                  minimumIntervals: 60,
                  rationale: "频率分辨率 Δf=1/T：40 秒只落在 HF 带内约 10 个频点，勉强"),
        HRVMetric(id: "lf_power", title: "LF 功率", unit: "ms²",
                  minimumIntervals: 120,
                  rationale: "LF 带宽只有 0.11Hz，40 秒时带内约 4 个频点，太粗"),
        HRVMetric(id: "lf_hf", title: "LF/HF", unit: "",
                  minimumIntervals: 120,
                  rationale: "实测：40 秒时同一段信号的 5%~95% 是 3.0~11.8（散布 152%），报一个数会误导"),
        HRVMetric(id: "lf_norm", title: "LF Norm", unit: "nU",
                  minimumIntervals: 120,
                  rationale: "归一化量，分母不稳它就不稳"),
        HRVMetric(id: "hf_norm", title: "HF Norm", unit: "nU",
                  minimumIntervals: 120,
                  rationale: "同上"),
        HRVMetric(id: "vlf_power", title: "VLF 功率", unit: "ms²",
                  minimumIntervals: 300,
                  rationale: "VLF 上限周期 300 秒，**装不进更短的窗口**。实测真值 450 时 40 秒只测出 55（差 8 倍）"),
        HRVMetric(id: "total_power", title: "TP 总功率", unit: "ms²",
                  minimumIntervals: 300,
                  rationale: "= VLF+LF+HF，VLF 不可用时 TP 也不可用"),

        // ——— 熵：长度偏差 ———
        HRVMetric(id: "apen", title: "ApEn 近似熵", unit: "",
                  minimumIntervals: 200,
                  rationale: "实测**长度偏差**：同一段信号截到 40/50/100/200/600 拍，ApEn 从 0.182 漂到 0.244"),

        // ——— 永远算不了 ———
        HRVMetric(id: "ulf_power", title: "ULF 功率", unit: "ms²",
                  minimumIntervals: 86_400,
                  rationale: "上限 0.0033Hz 意味着需要 24 小时连续记录 —— 我们**永远拿不到**"),
    ]

    static func metric(id: String) -> HRVMetric? {
        all.first { $0.id == id }
    }

    /// 按"当前这条序列能不能算"分组。界面直接用它决定显示什么。
    static func partition(intervalCount: Int) -> (available: [HRVMetric], unavailable: [HRVMetric]) {
        var yes: [HRVMetric] = [], no: [HRVMetric] = []
        for metric in all {
            if intervalCount >= metric.minimumIntervals { yes.append(metric) } else { no.append(metric) }
        }
        return (yes, no)
    }
}

// MARK: - FFT

/// 原地 radix-2 FFT（长度必须是 2 的幂）。
///
/// ## 为什么手写而不用 Accelerate
/// 一是 `vDSP` 的 API 在这台机器上我**没法编译验证**（没有 Mac）；
/// 二是这段算法很短，可以**在 Windows 上用 Python 逐行复现、和朴素 DFT 对照** ——
/// 实测最大偏差 5e-13（见 `ci/hrv_check.py`），比"应该没问题"可靠得多。
enum Radix2FFT {

    static func forward(real: inout [Double], imaginary: inout [Double]) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0, imaginary.count == n else { return }

        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }

        var length = 2
        while length <= n {
            let angle = -2.0 * Double.pi / Double(length)
            let wReal = cos(angle)
            let wImag = sin(angle)
            var i = 0
            while i < n {
                var curReal = 1.0
                var curImag = 0.0
                for k in 0..<(length / 2) {
                    let a = i + k
                    let b = i + k + length / 2
                    let tReal = curReal * real[b] - curImag * imaginary[b]
                    let tImag = curReal * imaginary[b] + curImag * real[b]
                    real[b] = real[a] - tReal
                    imaginary[b] = imaginary[a] - tImag
                    real[a] += tReal
                    imaginary[a] += tImag
                    let nextReal = curReal * wReal - curImag * wImag
                    curImag = curReal * wImag + curImag * wReal
                    curReal = nextReal
                }
                i += length
            }
            length <<= 1
        }
    }
}

// MARK: - 结果类型

/// 功率谱上的一个点（画图用）。
struct PSDPoint: Identifiable, Sendable {
    var id: Double { frequency }
    let frequency: Double
    let power: Double
}

/// RR 直方图的一根柱子。
struct RRHistogramBin: Identifiable, Sendable {
    var id: Double { lowerBound }
    let lowerBound: Double
    let upperBound: Double
    let count: Int
}

/// 一条序列的 HRV 分析结果。
///
/// 全是**值类型**（跨 `@ModelActor` 边界，不能带 `@Model` 出来）。
struct HRVResult: Sendable {
    /// 逐拍时间（毫秒偏移）—— 波形图的横轴
    let beatOffsetsMillis: [Int]
    /// 归一化后的 NN 间期（毫秒）
    let nnMillis: [Double]
    /// NN 间期**对应的时间**（毫秒偏移，和 `nnMillis` 一一对应）—— 波形图的横轴
    var nnTimesMillis: [Int] = []
    /// 被丢掉的间期数（超出 300–2000 或相邻变化 >20%）
    let artifactsDropped: Int
    /// **跨洞**丢掉的间期数（`precededByGap`，见 v3.2）—— 这些差值不是真实心跳间隔
    let gapDropped: Int

    /// 分析时长（秒）。频域分辨率就是它的倒数。
    let durationSeconds: Double
    /// 频率分辨率 Δf = fs / FFT 长度。
    ///
    /// ⚠️ 必须是 `var`：它要等功率谱算完才知道，所以在构造之后才赋值。
    /// 写成 `let` 会报 `cannot assign to property: ... is a 'let' constant` ——
    /// **这类错误本机完全看不出来，只有 CI 能发现**（实测在 run #52 踩到）。
    var frequencyResolution: Double
    /// 采样率（插值用）
    let samplingRate: Double

    // 时域
    var meanRR: Double?
    var meanHR: Double?
    var sdnn: Double?
    var rmssd: Double?
    var pnn50: Double?
    var pnn20: Double?
    var sd1: Double?
    var sd2: Double?
    var cv: Double?
    var apen: Double?

    // 频域
    var ulfPower: Double?
    var vlfPower: Double?
    var lfPower: Double?
    var hfPower: Double?
    var totalPower: Double?
    var lfNorm: Double?
    var hfNorm: Double?
    var lfHfRatio: Double?

    // 画图用
    var spectrum: [PSDPoint] = []
    var histogram: [RRHistogramBin] = []

    /// 按指标 id 取值 —— 界面只走这一个入口，保证"算不出来的就是 nil"
    func value(for metricID: String) -> Double? {
        switch metricID {
        case "mean_hr":     return meanHR
        case "mean_rr":     return meanRR
        case "sdnn":        return sdnn
        case "rmssd":       return rmssd
        case "pnn50":       return pnn50
        case "pnn20":       return pnn20
        case "sd1":         return sd1
        case "sd2":         return sd2
        case "cv":          return cv
        case "apen":        return apen
        case "ulf_power":   return ulfPower
        case "vlf_power":   return vlfPower
        case "lf_power":    return lfPower
        case "hf_power":    return hfPower
        case "total_power": return totalPower
        case "lf_norm":     return lfNorm
        case "hf_norm":     return hfNorm
        case "lf_hf":       return lfHfRatio
        default:            return nil
        }
    }

    /// 判断指标是否可用（**同时**看门槛和值是否存在）
    func isAvailable(_ metric: HRVMetric) -> Bool {
        nnMillis.count >= metric.minimumIntervals && value(for: metric.id) != nil
    }
}

// MARK: - 分析器

enum HRVAnalyzer {

    /// 频带定义（Task Force 1996 的标准频带）
    static let ulfBand = 0.0..<0.0033
    static let vlfBand = 0.0033..<0.04
    static let lfBand = 0.04..<0.15
    static let hfBand = 0.15..<0.4
    /// 插值采样率。4 Hz 是 HRV 频域分析的惯例（RR 本身的"采样率"约 1 Hz）
    static let samplingRate = 4.0

    static let minRR = 300.0
    static let maxRR = 2000.0
    static let maxDeltaRatio = 0.2

    /// 分析一条序列。
    ///
    /// - Parameter gapsBeforeBeat: 每拍**前面是不是一个洞**（v3.2 的 `precededByGap`）。
    ///   有洞的那一拍和前一拍的差**不是真实心跳间隔**，必须丢掉 ——
    ///   漏 1 拍会把 800ms 变成 1600ms，而 1600 **正好落在**生理范围内，
    ///   会被当成真实间期，把 SDNN 和 LF 一起拉大。
    static func analyze(beatOffsetsMillis: [Int],
                        gapsBeforeBeat: [Bool]? = nil) -> HRVResult? {
        guard beatOffsetsMillis.count >= 3 else { return nil }

        var nn: [Double] = []
        var nnTimes: [Double] = []
        var nnTimesMillis: [Int] = []
        var dropped = 0
        var gapDropped = 0

        for index in 1..<beatOffsetsMillis.count {
            let delta = Double(beatOffsetsMillis[index] - beatOffsetsMillis[index - 1])
            let isGap = gapsBeforeBeat.map { index < $0.count ? $0[index] : false } ?? false
            if isGap {
                gapDropped += 1
                continue
            }
            // 范围过滤
            guard delta >= minRR, delta <= maxRR else {
                dropped += 1
                continue
            }
            // 相邻变化过滤（早搏/漏拍）
            if let previous = nn.last, previous > 0 {
                if abs(delta - previous) / previous > maxDeltaRatio {
                    dropped += 1
                    continue
                }
            }
            nn.append(delta)
            nnTimes.append(Double(beatOffsetsMillis[index]) / 1000.0)
            nnTimesMillis.append(beatOffsetsMillis[index])
        }

        guard nn.count >= 5 else {
            return HRVResult(beatOffsetsMillis: beatOffsetsMillis,
                             nnMillis: nn,
                             artifactsDropped: dropped,
                             gapDropped: gapDropped,
                             durationSeconds: 0,
                             frequencyResolution: 0,
                             samplingRate: samplingRate)
        }

        let duration = (nnTimes.last ?? 0) - (nnTimes.first ?? 0)
        var result = HRVResult(beatOffsetsMillis: beatOffsetsMillis,
                               nnMillis: nn,
                               artifactsDropped: dropped,
                               gapDropped: gapDropped,
                               durationSeconds: duration,
                               frequencyResolution: 0,
                               samplingRate: samplingRate)
        result.nnTimesMillis = nnTimesMillis

        // ——— 时域 ———
        let n = Double(nn.count)
        let mean = nn.reduce(0, +) / n
        result.meanRR = mean
        result.meanHR = mean > 0 ? 60_000.0 / mean : nil

        if nn.count >= 2 {
            let variance = nn.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
            let sd = variance.squareRoot()
            result.sdnn = sd
            result.cv = mean > 0 ? sd / mean : nil

            var squaredDiff = 0.0
            var over50 = 0, over20 = 0
            for index in 1..<nn.count {
                let diff = nn[index] - nn[index - 1]
                squaredDiff += diff * diff
                if abs(diff) > 50 { over50 += 1 }
                if abs(diff) > 20 { over20 += 1 }
            }
            let pairCount = Double(nn.count - 1)
            let rmssd = (squaredDiff / pairCount).squareRoot()
            result.rmssd = rmssd
            result.pnn50 = Double(over50) / pairCount * 100
            result.pnn20 = Double(over20) / pairCount * 100
            result.sd1 = rmssd / 2.0.squareRoot()
            // SD2² = 2·SDNN² − SD1²  （Poincaré 的关系式）
            let sd2Squared = 2 * sd * sd - result.sd1! * result.sd1!
            result.sd2 = sd2Squared > 0 ? sd2Squared.squareRoot() : nil
        }

        result.apen = approximateEntropy(nn)

        // ——— 频域 ———
        let (spectrum, resolution) = powerSpectrum(times: nnTimes, values: nn)
        result.spectrum = spectrum
        result.frequencyResolution = resolution
        if !spectrum.isEmpty {
            result.ulfPower = bandPower(spectrum, ulfBand)
            result.vlfPower = bandPower(spectrum, vlfBand)
            result.lfPower = bandPower(spectrum, lfBand)
            result.hfPower = bandPower(spectrum, hfBand)
            let lf = result.lfPower ?? 0, hf = result.hfPower ?? 0
            let total = lf + hf + (result.vlfPower ?? 0)
            result.totalPower = total
            if total > 0 {
                result.lfNorm = lf / (lf + hf) * 100
                result.hfNorm = hf / (lf + hf) * 100
            }
            result.lfHfRatio = hf > 0 ? lf / hf : nil
        }

        result.histogram = histogram(nn)
        return result
    }

    // MARK: 直方图

    static func histogram(_ nn: [Double], binWidth: Double = 25) -> [RRHistogramBin] {
        guard let low = nn.min(), let high = nn.max(), high > low else { return [] }
        let start = (low / binWidth).rounded(.down) * binWidth
        let binCount = max(1, Int(((high - start) / binWidth).rounded(.up)))
        var counts = [Int](repeating: 0, count: binCount)
        for value in nn {
            let index = min(binCount - 1, max(0, Int((value - start) / binWidth)))
            counts[index] += 1
        }
        return counts.enumerated().map { offset, count in
            RRHistogramBin(lowerBound: start + Double(offset) * binWidth,
                           upperBound: start + Double(offset + 1) * binWidth,
                           count: count)
        }
    }

    // MARK: 功率谱

    /// 把不等间隔的 RR 序列插值到均匀网格，加 Hann 窗，做 FFT，得到单边 PSD。
    ///
    /// 归一化用 `2 / (fs · Σw²)` —— 这是让"对 PSD 积分 = 信号功率"成立的那一项。
    /// 少乘它，频带功率就会差一个窗函数的增益比（**不会报错，只会偏**）。
    static func powerSpectrum(times: [Double], values: [Double]) -> (points: [PSDPoint], resolution: Double) {
        guard times.count >= 4, times.count == values.count else { return ([], 0) }
        let fs = samplingRate
        let span = (times.last ?? 0) - (times.first ?? 0)
        guard span > 1 else { return ([], 0) }

        let count = Int(span * fs) + 1
        guard count >= 4 else { return ([], 0) }

        // 线性插值到均匀网格
        var samples = [Double](repeating: 0, count: count)
        var cursor = 0
        for index in 0..<count {
            let t = times[0] + Double(index) / fs
            while cursor < times.count - 2 && times[cursor + 1] < t { cursor += 1 }
            let t0 = times[cursor], t1 = times[cursor + 1]
            let v0 = values[cursor], v1 = values[cursor + 1]
            let width = t1 - t0
            samples[index] = width <= 0 ? v0 : v0 + (v1 - v0) * (t - t0) / width
        }

        // 去均值 + Hann 窗
        let mean = samples.reduce(0, +) / Double(count)
        var windowSumSquares = 0.0
        var window = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let w = count > 1 ? 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1)) : 1
            window[index] = w
            windowSumSquares += w * w
        }
        guard windowSumSquares > 0 else { return ([], 0) }

        // 补零到 2 的幂（至少 256，否则低频频点太稀）
        var size = 256
        while size < count { size <<= 1 }
        var real = (0..<size).map { $0 < count ? (samples[$0] - mean) * window[$0] : 0 }
        var imaginary = [Double](repeating: 0, count: size)
        Radix2FFT.forward(real: &real, imaginary: &imaginary)

        let half = size / 2
        let scale = 2.0 / (fs * windowSumSquares)
        var points: [PSDPoint] = []
        points.reserveCapacity(half + 1)
        for k in 0...half {
            var power = scale * (real[k] * real[k] + imaginary[k] * imaginary[k])
            // 直流与 Nyquist 是单边谱的端点，只算一半
            if k == 0 || k == half { power *= 0.5 }
            points.append(PSDPoint(frequency: Double(k) * fs / Double(size), power: power))
        }
        return (points, fs / Double(size))
    }

    static func bandPower(_ spectrum: [PSDPoint], _ band: Range<Double>) -> Double {
        guard spectrum.count >= 2 else { return 0 }
        let df = spectrum[1].frequency - spectrum[0].frequency
        var total = 0.0
        for point in spectrum where band.contains(point.frequency) {
            total += point.power * df
        }
        return total
    }

    // MARK: 近似熵

    /// ApEn(m=2, r=0.2·SD)，与参考报告一致。
    ///
    /// ⚠️ **它有长度偏差**（实测：同一段信号截到 40/50/100/200/600 拍，
    /// ApEn 从 0.182 漂到 0.244）。所以 `HRVMetrics` 把门槛设在 200 间期，
    /// 达不到时界面**不显示这个数** —— 而不是显示一个不能跨序列比较的值。
    static func approximateEntropy(_ values: [Double], dimension: Int = 2, ratio: Double = 0.2) -> Double? {
        let n = values.count
        guard n >= dimension + 2 else { return nil }
        let mean = values.reduce(0, +) / Double(n)
        let sd = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)).squareRoot()
        let r = ratio * sd
        guard r > 0 else { return nil }

        func phi(_ m: Int) -> Double? {
            let limit = n - m + 1
            guard limit > 1 else { return nil }
            var count = 0
            for i in 0..<limit {
                for j in 0..<limit {
                    var matched = true
                    for k in 0..<m where abs(values[i + k] - values[j + k]) > r {
                        matched = false
                        break
                    }
                    if matched { count += 1 }
                }
            }
            let probability = Double(count) / Double(limit * limit)
            return probability > 0 ? log(probability) : nil
        }

        guard let p1 = phi(dimension), let p2 = phi(dimension + 1) else { return nil }
        return p1 - p2
    }
}
