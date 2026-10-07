import SwiftUI
import Charts

// MARK: - 最新一条心跳序列 · HRV 分析
//
// 参照需求方给的那份报告（波形图 / 直方图 / 能量光谱密度 / 交感-副交感 / 自主神经平衡）。
//
// ## ⚠️ 和那份报告最重要的一处不同：**能不能出现的门槛**
// 那份报告的记录至少有 5 分钟（VLF 能量比 LF 还大，而 VLF 的下限周期就是 300 秒），
// 而**我们的序列约 50 拍 ≈ 40 秒**。所以这里：
//   · 算得出但**不成立**的指标，**根本不显示数值**，只在下面如实说明"还差多少"
//   · 每个指标的门槛写在 `HRVMetrics` 里，理由是实测出来的（`ci/hrv_check_windows.py`）
//
// 这一条是本项目的底线：**"表能填出来"不等于"这个结论成立"**。

/// 波形图上的一个点：第 i 个 **RR 间期**。
///
/// ## 纵轴为什么是 ms 而不是 BPM
/// 需求方给的参考报告里那张「心率变异波形图」纵轴是 BPM，所以第一版照抄了 BPM。
/// 但需求方随后明确纠正：**要画的是心跳序列本身，也就是 RR 间期**
/// （`HKHeartbeatSeriesSample` → 逐拍时间戳 → 相邻相减）。
///
/// BPM 是 `60000 ÷ RR` 的**换算结果**：换过去只多一层加工，
/// 而且会让人以为数据源是"心率样本"（`HKQuantityTypeIdentifierHeartRate`）——
/// 那是**另一套数据**，和心跳序列不是一回事。
///
/// 两者是倒数关系，所以纵轴换回 ms 不丢信息；
/// 而"心率"该出现的地方是指标表里的**平均心率**（它本来就在那儿）。
private struct BeatPoint: Identifiable {
    let id: Int
    let seconds: Double
    let rrMillis: Double
}

struct HeartbeatHRVCard: View {

    @ObservedObject private var status = LinkStatus.shared

    @State private var result: HRVResult?
    @State private var startDate: Date?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let result, !result.nnMillis.isEmpty {
                sectionTitle("逐拍 RR 间期（心跳序列本身）")
                BeatWaveformChart(points: beatPoints(result), meanRR: result.meanRR)
                metricsSection(result)
                if result.histogram.count >= 2 {
                    sectionTitle("RR 间期直方图")
                    RRHistogramChart(bins: result.histogram)
                }
                if result.spectrum.count > 4 {
                    frequencySection(result)
                }
                notes(result)
            } else if isLoading {
                Text("正在读取最新一条心跳序列…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("还没有收到心跳序列。这一块需要手表那边产生过逐拍数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .task(id: status.dataVersion) { await load() }
    }

    // MARK: 取数

    private func load() async {
        let store = PhoneServices.shared.store
        guard let series = try? await store.latestRRSeries() else {
            result = nil
            isLoading = false
            return
        }
        // 洞标记一起传进去：跨洞的差值不是真实心跳间隔
        result = HRVAnalyzer.analyze(beatOffsetsMillis: series.beatOffsetsMillis,
                                     gapsBeforeBeat: series.gapFlags)
        startDate = series.startDate
        isLoading = false
    }

    // MARK: 小部件

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.purple)
                Text("最新一条心跳序列（HRV）")
                    .font(.headline)
            }
            if let startDate {
                Text("采集于 \(startDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.top, 2)
    }

    private func beatPoints(_ result: HRVResult) -> [BeatPoint] {
        let base = result.nnTimesMillis.first ?? 0
        return zip(result.nnTimesMillis, result.nnMillis).enumerated().compactMap { index, pair in
            guard pair.1 > 0 else { return nil }
            return BeatPoint(id: index,
                             seconds: Double(pair.0 - base) / 1000.0,
                             rrMillis: pair.1)
        }
    }

    // MARK: 指标

    /// 能算的指标 + **不能算的**（后者只说明还差多少，不给数值）。
    @ViewBuilder
    private func metricsSection(_ result: HRVResult) -> some View {
        let split = HRVMetrics.partition(intervalCount: result.nnMillis.count)

        sectionTitle("能算的指标（\(result.nnMillis.count) 个 NN 间期）")
        VStack(spacing: 4) {
            ForEach(split.available) { metric in
                HRVMetricRow(metric: metric, value: result.value(for: metric.id))
            }
        }

        if !split.unavailable.isEmpty {
            sectionTitle("这些还不够算")
            Text(shortfallText(split.unavailable, have: result.nnMillis.count))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func shortfallText(_ metrics: [HRVMetric], have: Int) -> String {
        metrics.map { "\($0.title)（需 ≥\($0.minimumIntervals)，现有 \(have)）" }
            .joined(separator: "、")
    }

    // MARK: 频域

    @ViewBuilder
    private func frequencySection(_ result: HRVResult) -> some View {
        sectionTitle("功率谱密度（Δf = \(format(result.frequencyResolution, 4)) Hz）")
        SpectrumChart(points: result.spectrum)

        sectionTitle("交感 / 副交感（LF / HF 功率）")
        LFHFBarChart(lf: result.lfPower ?? 0, hf: result.hfPower ?? 0)

        sectionTitle("自主神经平衡（横轴 LF、纵轴 HF，取自然对数）")
        BalanceScatterChart(lfLn: ln(result.lfPower), hfLn: ln(result.hfPower))
    }

    private func ln(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return log(value)
    }

    // MARK: 说明

    @ViewBuilder
    private func notes(_ result: HRVResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("纵轴是 **RR 间期（ms）**，红线是平均值 —— 画的就是拿到的心跳序列本身。"
                 + "参考报告那张「心率变异波形图」用的是它的倒数（BPM = 60000 ÷ RR），"
                 + "同一份信息；这里用 ms，因为那是逐拍时间戳**直接**给出的量。"
                 + "「平均心率」在下面的指标表里。")
            Text("短记录的频域指标**波动极大**：同一段生理信号，40 秒窗口的 LF/HF "
                 + "有 90% 的把握落在 3.0~11.8 之间（300 秒窗口才是 4.6~6.9）。"
                 + "所以这里对不够长的序列只画谱、不报数。")
            if result.gapDropped > 0 {
                Text("跨洞丢弃 \(result.gapDropped) 个间隔（Apple 标为「漏拍」，"
                     + "那个差值是假的，会把 SDNN 拉大）。")
            }
            if result.artifactsDropped > 0 {
                Text("范围/突变过滤丢弃 \(result.artifactsDropped) 个间期。")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func format(_ value: Double, _ decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }
}

// MARK: - 一行指标

/// 一行指标。
///
/// ⚠️ `value == nil` 时显示「—」而**不是 0**：0 是一个可能被当成真实测量结果的数字。
private struct HRVMetricRow: View {
    let metric: HRVMetric
    let value: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(metric.title)
                .font(.caption)
            Spacer(minLength: 8)
            Text(display)
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == nil ? .tertiary : .primary)
            if !metric.unit.isEmpty {
                Text(metric.unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var display: String {
        guard let value else { return "—" }
        let decimals = abs(value) >= 100 ? 1 : (abs(value) >= 1 ? 2 : 3)
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }
}

// MARK: - 波形图

/// 逐拍 RR 间期波形图（心跳序列本身）。
///
/// 纵轴是 **RR 间期（ms）**，红线是平均 RR。
/// 参考报告那张「心率变异波形图」纵轴用的是 BPM —— 那是本图的倒数视角，
/// 同一份信息；这里画 ms，因为那才是心跳序列**直接**给出的量。
private struct BeatWaveformChart: View {
    let points: [BeatPoint]
    let meanRR: Double?

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("时间", point.seconds),
                         y: .value("RR 间期", point.rrMillis))
                    .foregroundStyle(Color.purple)
                    .interpolationMethod(.linear)
            }
            if let meanRR {
                RuleMark(y: .value("平均 RR", meanRR))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxisLabel("秒")
        .chartYAxisLabel("RR 间期 (ms)")
        .frame(height: 200)
    }
}

// MARK: - 直方图

private struct RRHistogramChart: View {
    let bins: [RRHistogramBin]

    var body: some View {
        Chart(bins) { bin in
            BarMark(x: .value("RR", bin.lowerBound),
                    y: .value("条数", bin.count),
                    width: .fixed(18))
                .foregroundStyle(Color.blue.gradient)
        }
        .chartXAxisLabel("RR 间期（ms）")
        .frame(height: 150)
    }
}

// MARK: - 功率谱

/// 能量光谱密度图。**频带边界画出来**，让人一眼看出"HF 带里有多少频点"。
private struct SpectrumChart: View {
    let points: [PSDPoint]

    private let bandEdges: [Double] = [0.04, 0.15, 0.4]

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("频率", point.frequency),
                         y: .value("功率谱密度", point.power))
                    .foregroundStyle(Color.indigo)
            }
            ForEach(bandEdges, id: \.self) { edge in
                RuleMark(x: .value("频带边界", edge))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: 0...0.5)
        .chartXAxisLabel("Hz")
        .frame(height: 160)
    }
}

// MARK: - 交感 / 副交感

/// 参考报告里那两根柱子（LF 红、HF 蓝）。
private struct LFHFBarChart: View {
    let lf: Double
    let hf: Double

    private struct Bar: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let tint: Color
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("频带", bar.label),
                    y: .value("功率", bar.value))
                .foregroundStyle(bar.tint)
        }
        .frame(height: 150)
    }

    private var bars: [Bar] {
        [Bar(label: "LF（交感）", value: lf, tint: .red.opacity(0.7)),
         Bar(label: "HF（副交感）", value: hf, tint: .blue.opacity(0.7))]
    }
}

// MARK: - 自主神经平衡

/// 横轴 LF(ln)、纵轴 HF(ln) 的散点 —— 参考报告右下那张"自主神经平衡图"。
///
/// 现在是**单条序列的一个点**。把最近 7 天所有序列叠上来就是"长数据累计"那一版
/// （见待办）。这里先把单序列的做出来。
private struct BalanceScatterChart: View {
    let lfLn: Double?
    let hfLn: Double?

    var body: some View {
        Chart {
            if let lfLn, let hfLn {
                PointMark(x: .value("LF(ln)", lfLn),
                          y: .value("HF(ln)", hfLn))
                    .symbolSize(120)
                    .foregroundStyle(Color.yellow)
            }
        }
        .chartXScale(domain: 0...12)
        .chartYScale(domain: 0...12)
        .chartXAxisLabel("LF (ln)")
        .chartYAxisLabel("HF (ln)")
        .frame(height: 180)
    }
}
