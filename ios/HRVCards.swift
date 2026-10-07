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

        // 🔴 「交感 / 副交感」这一对**必须用归一化值（nU）**，不能用绝对功率（ms²）。
        // 需求方指出过这一点，而且是对的：绝对功率的单位是 ms²，
        // 两者相除才是"平衡"，直接比高度等于在比两个不同量纲的数。
        // 详见 `LFHFBarChart` 的说明。
        if let lfNorm = result.lfNorm, let hfNorm = result.hfNorm {
            sectionTitle("交感 / 副交感（LF / HF 归一化功率，nU）")
            LFHFBarChart(lfNorm: lfNorm, hfNorm: hfNorm)
        } else {
            sectionTitle("交感 / 副交感")
            Text("归一化值需要 ≥\(normalizedMinimumIntervals) 个 NN 间期"
                 + "（现有 \(result.nnMillis.count)）—— **绝对功率不能当交感/副交感之比看**，"
                 + "所以这里不画。下面是谱和平衡散点，那两张不依赖归一化。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        sectionTitle("自主神经平衡（横轴 LF、纵轴 HF，取自然对数）")
        BalanceScatterChart(lfLn: ln(result.lfPower), hfLn: ln(result.hfPower))
    }

    private func ln(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return log(value)
    }

    /// 归一化值的门槛**从 `HRVMetrics` 取**，不在这里写死。
    ///
    /// 写死的话"界面文案里说的门槛"和"实际用来判断的门槛"会各说一套 ——
    /// 而这两者一旦不一致，用户会看到"说是需要 2 分钟、可我有 2 分钟了还是没出来"。
    private var normalizedMinimumIntervals: Int {
        HRVMetrics.metric(id: "lf_norm")?.minimumIntervals ?? 120
    }

    // MARK: 说明

    @ViewBuilder
    private func notes(_ result: HRVResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // ⚠️ 必须是**单个字符串字面量**：`Text("a" + "b")` 会退化成 `String`，
            // SwiftUI 就不再按 markdown 解析，`**粗体**` 会**原样显示成星号**。
            Text("纵轴是 **RR 间期（ms）**，红线是平均值 —— 画的就是拿到的心跳序列本身。参考报告那张「心率变异波形图」用的是它的倒数（BPM = 60000 ÷ RR），同一份信息；这里用 ms，因为那是逐拍时间戳**直接**给出的量。「平均心率」在下面的指标表里。")
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

    /// 条数轴的**固定上限**（需求方指定）。
    ///
    /// 刻意**不按数据自适应**：自适应的纵轴会让"50 拍的一条序列"和"300 拍的一条序列"
    /// 看起来一样高 —— 而这张图的用途正是**跨序列比较分布形状**。
    /// ⚠️ 代价：条数超过 20 的柱子会被**截平**。这是有意的取舍
    /// （上限固定才可比），真出现那种情况应当看下面的"能算的指标"而不是这张图。
    private let countLimit: Double = 20

    var body: some View {
        Chart(bins) { bin in
            BarMark(x: .value("RR", bin.lowerBound),
                    y: .value("条数", bin.count),
                    width: .fixed(18))
                .foregroundStyle(Color.blue.gradient)
        }
        .chartYScale(domain: 0...countLimit)
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
///
/// ## 🔴 为什么必须用**归一化值（nU）**，不能用绝对功率（ms²）
/// 需求方指出过这一点，而且是对的。参考报告那张图的表里就写着
/// **`LF Norm 65.403 nU` / `HF Norm 34.597 nU`** —— 两根柱子画的正是这两个数。
///
/// 理由是**量纲**：绝对功率的单位是 ms²，而 LF 和 HF 的绝对值受
/// 总功率、呼吸深度、体位等一堆因素影响，两个数直接比高度，
/// 等于在比"两个不同量纲的数谁大"。归一化之后它们**加起来恒等于 100**，
/// 于是两根柱子表示的才是"**平衡**"—— 那才是"交感 / 副交感"这张图要说的东西。
///
/// ⚠️ 归一化值的门槛比绝对功率更高（≥2 分钟），达不到时上层**不画这张图**，
/// 而不是退回绝对功率 —— 因为那会把结论讲错。
private struct LFHFBarChart: View {
    let lfNorm: Double
    let hfNorm: Double

    private struct Bar: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let tint: Color
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("频带", bar.label),
                    y: .value("归一化功率", bar.value))
                .foregroundStyle(bar.tint)
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("nU")
        .frame(height: 150)
    }

    private var bars: [Bar] {
        [Bar(label: "LF（交感）", value: lfNorm, tint: .red.opacity(0.7)),
         Bar(label: "HF（副交感）", value: hfNorm, tint: .blue.opacity(0.7))]
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

// MARK: - 近 7 天：交感 / 副交感归一化「河流图」

/// 近 7 天的交感 / 副交感归一化「河流图」。
///
/// ## 画法
/// 每小时一根**堆叠柱**：HF（副交感，蓝）从 0 堆起，LF（交感，红）叠在上面。
/// 两者之和恒为 100，所以整条带子的**高度恒定**，看起来就是一条河。
/// （真正的 stream graph 基线会上下摆动，但那只是为了好看 —— 只有两个分量、
/// 且和恒为 100 时，直堆叠信息量一样而更好读。）
///
/// ## ⚠️ 两件必须说清楚的事（都写在界面上）
/// 1. **没有数据的整点不画柱子** —— 不补 0、不插值。序列之间隔着几十分钟到几小时，
///    连起来等于**伪造连续性**。「断口」本身就是信息：它说明那段时间没有记录。
/// 2. **每个点是那一小时的平均**，而均值也有不确定度：实测单条约 40 秒散布 22%、
///    平均 5 条 10%、平均 10 条 7%。所以界面上要能看到条数。
struct HRVTrendCard: View {

    @ObservedObject private var status = LinkStatus.shared

    @State private var buckets: [HRVTrendBucket] = []
    @State private var isLoading = true

    /// 画几天。**刻意固定 7 天、不跟页面上那个范围控件联动** ——
    /// 它是"长期累计"视角，和"单个体征的时间范围"是两件事。
    private let days = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if buckets.count >= 2 {
                chart
                legend
                footnote
            } else if isLoading {
                Text("正在读取近 \(days) 天的心跳序列…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("近 \(days) 天还没有够画这张图的序列（至少需要 2 个有数据的整点）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .task(id: status.dataVersion) { await load() }
    }

    private func load() async {
        let store = PhoneServices.shared.store
        buckets = (try? await store.hrvNormTrend(days: days)) ?? []
        isLoading = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "water.waves")
                    .foregroundStyle(.purple)
                Text("近 \(days) 天自主神经平衡（河流图）")
                    .font(.headline)
            }
            Text("每小时一根柱子，是那一小时里所有序列的**平均**归一化功率。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(x: .value("时间", bucket.hourStart, unit: .hour),
                        y: .value("HF 归一化", bucket.hfNorm),
                        width: .ratio(0.85))
                    .foregroundStyle(Color.blue.opacity(0.75))
                BarMark(x: .value("时间", bucket.hourStart, unit: .hour),
                        y: .value("LF 归一化", bucket.lfNorm),
                        width: .ratio(0.85))
                    .foregroundStyle(Color.red.opacity(0.75))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("nU")
        .frame(height: 180)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .red.opacity(0.75), text: "交感 LF")
            legendItem(color: .blue.opacity(0.75), text: "副交感 HF")
            Spacer(minLength: 6)
            Text("共 \(buckets.count) 个整点")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text).font(.caption2)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("**断口是真实的**：没有数据的整点不画柱子 —— 不补 0、也不连线。序列之间隔着几十分钟到几小时，连起来会伪造成「一直在测」。")
            Text("**每个点是一小时的平均**，条数少时均值本身不稳（实测：单条约 40 秒散布 22%、平均 5 条 10%、平均 10 条 7%）。最多的一小时有 \(maxSeriesCount) 条。")
            Text("**看趋势有效，绝对值不能当临床数字**：我们的 LF Norm 系统性偏低约 3 个百分点，而且各种长度下都一样 —— 所以横向比较有意义，具体数值没意义。")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var maxSeriesCount: Int {
        buckets.map(\.seriesCount).max() ?? 0
    }
}
