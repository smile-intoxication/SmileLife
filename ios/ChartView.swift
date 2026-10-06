import SwiftUI
import Charts

/// 图表：某个指标在这段时间里怎么变化的。
///
/// ## 数据来自汇总桶，不是原始样本
/// 最坏情况是心率每 5 秒一条（`52 万条/月`）。直接拿原始样本画图，
/// 光是查询就会卡住，而且屏幕上根本画不出 50 万个点。
/// 所以：**折线读 `PhoneRollup`（15 分钟汇总桶），睡眠读原始样本**
/// （睡眠一天只有几十段，量小，而且"阶段时长求和"这种聚合方式与
/// min/max/avg 完全不同，硬塞进汇总表只会让含义变模糊）。
struct ChartView: View {

    @ObservedObject private var status = LinkStatus.shared

    @State private var metricID = "heart_rate"
    @State private var range: ChartRange = .week

    @State private var points: [ChartPoint] = []
    /// 柱状图的数据（日累计量用）。和 `points` 是**互斥**的两套：
    /// 同一个指标要么是"值随时间变化"，要么是"每段时间累计多少"，不会两者都是。
    @State private var bars: [BarPoint] = []
    @State private var barStats: BarStats?
    @State private var sleepDays: [SleepDayBar] = []
    /// 拍平后的睡眠片段（`Chart` 直接吃这个，不现算 —— 见 `SleepChartSegment` 的注释）
    @State private var sleepSegments: [SleepChartSegment] = []
    @State private var stats: ChartStats?
    /// RR 间期散点图的数据。**在类型明确的地方算好**，视图只负责渲染
    /// —— 这是 `sleepContent` 那次类型推导超时留下的教训。
    @State private var poincare: PoincareResult?
    /// 是否剔除早搏／伪影。做成开关：关掉时看到的**原始**早搏分布本身也有分析价值。
    @State private var filterEctopic = true
    /// 本机有没有收到过心跳序列 —— 决定选择器里要不要出现 RR 那一项
    @State private var hasRRSeries = false
    /// RR 序列查询是否因为条数上限被截断（要在界面上如实说明）
    @State private var rrTruncated = false
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var loadError: String?

    private var info: MetricDisplay.Info { MetricDisplay.infoOrFallback(id: metricID) }

    /// 当前画的是哪一类图。
    ///
    /// 用枚举而不是直接读 `info.kind`：RR 间期**不是 HealthKit 指标**
    /// （见 `RRPoincare` 的说明），它在 `MetricDisplay` 里查不到，
    /// 硬套那个类型只能拿到一个 fallback —— 判断就变成"靠兜底值碰巧对"。
    private enum ChartKind { case quantity, category, rrPoincare }

    private var kind: ChartKind {
        if metricID == RRPoincare.metricID { return .rrPoincare }
        return info.kind == .category ? .category : .quantity
    }

    /// 选择器里的一项。
    private struct ChartPickerItem: Identifiable {
        let id: String
        let title: String
        let symbolName: String
    }

    /// 选择器的内容。
    ///
    /// RR 间期那一项**只在真的收到过心跳序列时才出现**：这条链路依赖手表
    /// 产生 `HKHeartbeatSeriesSample`（很可能需要开房颤历史），
    /// 对一个"可能永远没有"的功能，留一个永远为空的入口比没有入口更糟。
    private var pickerItems: [ChartPickerItem] {
        var items = MetricDisplay.all.map {
            ChartPickerItem(id: $0.id, title: $0.title, symbolName: $0.symbolName)
        }
        if hasRRSeries {
            items.append(ChartPickerItem(id: RRPoincare.metricID,
                                         title: RRPoincare.title,
                                         symbolName: RRPoincare.symbolName))
        }
        return items
    }

    private var selectedItem: ChartPickerItem {
        pickerItems.first { $0.id == metricID }
            ?? ChartPickerItem(id: metricID, title: metricID, symbolName: "questionmark.circle")
    }

    /// y = x 参考线的两个端点。
    ///
    /// 单独建一个类型（配 `ForEach`）而不是直接写两条裸 `LineMark`：
    /// 后者要靠 Swift Charts 的隐式"同一序列"推导才会连成线，
    /// 显式给数据不依赖这个推导。
    private struct DiagonalPoint: Identifiable {
        let id: Int
        let value: Double
    }

    private let diagonalPoints = [DiagonalPoint(id: 0, value: 0),
                                  DiagonalPoint(id: 1, value: 2000)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    selectors

                    switch kind {
                    case .category:   sleepContent
                    case .rrPoincare: poincareContent
                    case .quantity:   quantityContent
                    }

                    if let loadError {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    provenanceNote
                }
                .padding()
            }
            .navigationTitle("图表")
            .refreshable { await load() }
        }
        .task { await load() }
        .onChange(of: metricID) { _, _ in Task { await load() } }
        .onChange(of: range) { _, _ in Task { await load() } }
        .onChange(of: status.dataVersion) { _, _ in Task { await load() } }
    }

    // MARK: - 选择器

    /// 指标选择器的标签。
    ///
    /// 单独拆出来不是为了复用，而是为了**压平类型推导**：
    /// `Menu { ... } label: { 一长串带修饰符的 HStack }` 这种嵌套很容易让
    /// SwiftUI 的类型推导变慢甚至超时（同一个文件里的 `sleepContent` 就超时过）。
    private var metricMenuLabel: some View {
        HStack {
            Image(systemName: selectedItem.symbolName)
            Text(selectedItem.title).font(.headline)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                ForEach(pickerItems) { item in
                    Button {
                        metricID = item.id
                        // 心跳序列是被动采样、主要在睡眠中出现，一天可能只有几条 ——
                        // 24 小时窗口经常是空的。切到这一项时自动放宽到 7 天。
                        if item.id == RRPoincare.metricID { range = .week }
                    } label: {
                        Label(item.title, systemImage: item.symbolName)
                    }
                }
            } label: {
                metricMenuLabel
            }

            Picker("时间范围", selection: $range) {
                ForEach(ChartRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 数值型：折线

    @ViewBuilder
    private var quantityContent: some View {
        if points.isEmpty && bars.isEmpty {
            if isLoading || !hasLoadedOnce {
                loadingPlaceholder
            } else {
                emptyPlaceholder
            }
        } else {
            chartForStyle

            // 统计量也要跟着形态走：累计量看的是"一共多少 / 日均多少"，
            // 用平均值那一套会给出一个和活动圆环完全对不上的数字。
            if info.chartStyle == .bars {
                if let barStats { barStatisticsRow(barStats) }
            } else if let stats {
                statisticsRow(stats)
            }
        }
    }

    /// **按体征选图**。判断依据是数据是"怎么产生的"，见 `MetricDisplay.ChartStyle`。
    @ViewBuilder
    private var chartForStyle: some View {
        switch info.chartStyle {
        case .bars:
            CumulativeBarChart(bars: bars,
                               unit: range.barBucket >= 24 * 3600 - 1 ? .day : .hour,
                               tint: tintColor)
        case .points:
            ScatterPointChart(points: points, domain: yDomain, tint: tintColor)
        case .lineWithRange:
            RangeBandChart(points: points, domain: yDomain)
        case .line:
            TrendLineChart(points: points, domain: yDomain, tint: tintColor)
        case .stackedBars:
            // 枚举型走 `sleepContent`，不会到这里。留着分支是为了让 switch 完整 —— 
            // 真走到了说明 `kind` 判断和 `chartStyle` 打架了，画个趋势线兜底总比崩好。
            TrendLineChart(points: points, domain: yDomain, tint: tintColor)
        }
    }

    private var yDomain: ClosedRange<Double> {
        ChartSeriesBuilder.yDomain(from: points, fromZero: info.chartFromZero)
    }

    /// 图线颜色按**图表形态**分，不按指标分。
    /// 好处是同一个颜色的图读法一样（点图就是点测、柱图就是累计），
    /// 换指标时不用重新理解这张图。
    private var tintColor: Color {
        switch info.chartStyle {
        case .lineWithRange: return .pink
        case .line:          return .orange
        case .points:        return .teal
        case .bars:          return .green
        case .stackedBars:   return .indigo
        }
    }

    private var barAverageLabel: String {
        range.barBucket >= 24 * 3600 - 1 ? "日均" : "时均"
    }

    private var barBucketDescription: String {
        range.barBucket >= 24 * 3600 - 1 ? "一天" : "一小时"
    }

    private func barStatisticsRow(_ stats: BarStats) -> some View {
        HStack(spacing: 10) {
            statistic("合计", value: stats.total)
            statistic(barAverageLabel, value: stats.perBar)
            statistic("最高", value: stats.peak)
        }
    }

    // MARK: - 枚举型：睡眠堆叠柱

    @ViewBuilder
    private var sleepContent: some View {
        if sleepSegments.isEmpty {
            if isLoading || !hasLoadedOnce {
                loadingPlaceholder
            } else {
                emptyPlaceholder
            }
        } else {
            // ⚠️ 这里刻意只有**一层 ForEach + 一个 BarMark**。
            //    原来写成"ForEach 套 ForEach + if let + 字符串插值"，
            //    直接让 SwiftUI 的类型推导超时（CI 报
            //    "the compiler is unable to type-check this expression in reasonable time"）。
            //    数据已经在 `ChartSeriesBuilder.sleepSegments` 里拍平好了。
            Chart(sleepSegments) { segment in
                BarMark(x: .value("日期", segment.day, unit: .day),
                        y: .value("小时", segment.hours))
                    .foregroundStyle(by: .value("阶段", segment.stageLabel))
            }
            .chartForegroundStyleScale([
                "深睡": Color.indigo,
                "核心睡眠": Color.blue,
                "快速眼动": Color.cyan,
                "睡眠": Color.teal,
                "清醒": Color.orange,
                "卧床": Color.gray
            ])
            .frame(height: 260)

            sleepSummary
        }
    }

    private var sleepSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每日睡眠时长").font(.subheadline.weight(.semibold))
            // 只列最近 7 天，避免列表过长把图表挤下去
            ForEach(sleepDays.suffix(7).reversed()) { day in
                HStack {
                    Text(PhoneFormat.day(day.day))
                        .font(.footnote)
                    Spacer()
                    Text(PhoneFormat.hours(day.totalSleepHours))
                        .font(.footnote.weight(.medium))
                }
            }
            Text("只统计真正睡着的阶段，不含卧床与清醒。上一晚的记录归到「起床那天」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - RR 间期：Poincaré 散点图

    /// RR 间期散点图（Poincaré）。
    ///
    /// 横轴 = 第 n 个间期，纵轴 = 第 n+1 个间期，**两轴都是 0–2000 ms**（需求方指定）。
    /// 这是看 HRV 形态最直观的一张图：
    /// - 点贴着 y=x 对角线 → 相邻两个间期几乎一样 → 心率很稳
    /// - 垂直于对角线散开 → 相邻间期差得越多 → 变异越大
    /// - 偏离对角线的孤立点 → 早搏 / 运动伪影
    @ViewBuilder
    private var poincareContent: some View {
        if let result = poincare, !result.isEmpty {
            // 参考线和散点必须画在**同一个坐标系**里，所以用 `Chart { }` 而不是
            // `Chart(result.points) { ... }` 那个便利初始化器。
            Chart {
                ForEach(diagonalPoints) { point in
                    LineMark(x: .value("RRₙ", point.value),
                             y: .value("RRₙ₊₁", point.value))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                ForEach(result.points) { point in
                    PointMark(x: .value("RRₙ", point.rrN),
                              y: .value("RRₙ₊₁", point.rrNext))
                        .symbolSize(6)
                        .foregroundStyle(Color.teal.opacity(0.45))
                }
            }
            // ⚠️ 必须写 `0.0...2000.0`：只写 `0...2000` 会被推断成 `ClosedRange<Int>`，
            //    和 Double 的数据点对不上（这类错只有编译器能发现）。
            .chartXScale(domain: 0.0...2000.0)
            .chartYScale(domain: 0.0...2000.0)
            .chartXAxisLabel("RRₙ (ms)")
            .chartYAxisLabel("RRₙ₊₁ (ms)")
            .frame(height: 320)

            rrStats(result)
            rrFilterToggle
        } else if isLoading || !hasLoadedOnce {
            loadingPlaceholder
        } else {
            rrEmptyPlaceholder
        }
    }

    private func rrStats(_ result: PoincareResult) -> some View {
        HStack(spacing: 10) {
            rrStatBox("平均心率",
                      value: result.meanHeartRate.map { String(format: "%.0f", $0) } ?? "—",
                      unit: "bpm")
            rrStatBox("SDNN",
                      value: result.sdnn.map { String(format: "%.0f", $0) } ?? "—",
                      unit: "ms")
            rrStatBox("点数", value: "\(result.points.count)", unit: "个")
        }
    }

    private func rrStatBox(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded, weight: .semibold))
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var rrFilterToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("剔除早搏 / 伪影（相邻变化超过 20%）", isOn: $filterEctopic)
                .font(.footnote)
                .onChange(of: filterEctopic) { _, _ in Task { await load() } }
            Text(rrFilterSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 如实说明"这批数据发生了什么"。
    ///
    /// 这一段不是装饰：散点图好不好看，可能是**数据本身**（早搏很多），
    /// 也可能是**我们的过滤**。不把剔除数量写出来，两件事就分不清，
    /// 而"图不对"的排查会从这一步开始走弯路。
    private var rrFilterSummary: String {
        guard let result = poincare else { return "" }
        var parts: [String] = []
        parts.append("\(result.seriesCount) 条序列 / \(result.rawIntervals) 个间期")
        if rrTruncated {
            // 静默截断比报错更糟：用户会以为"数据就这么多"
            parts.append("⚠️ 序列条数达到上限，只画了范围内最早的一部分，缩小范围更准")
        }
        if result.outOfRange > 0 {
            parts.append("超出 \(Int(PoincareBuilder.minRR))–\(Int(PoincareBuilder.maxRR)) ms 剔除 \(result.outOfRange) 个")
        }
        if result.ectopicPairs > 0 {
            parts.append(filterEctopic
                         ? "按早搏剔除 \(result.ectopicPairs) 对"
                         : "检出相邻变化超过 20% 的 \(result.ectopicPairs) 对（当前未剔除）")
        }
        if result.isDownsampled {
            parts.append("点数超过 \(PoincareBuilder.maxPoints)，已均匀抽稀")
        }
        return parts.joined(separator: "；")
    }

    private var rrEmptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这个时间段里没有心跳序列", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text("心跳序列是被动采样，Apple 只在特定条件下才写（很可能需要开启「房颤历史」），"
                 + "而且通常集中在睡眠中 —— 一天可能只有很少几条。换个更长的时间范围试试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    // MARK: - 小块

    private func statisticsRow(_ stats: ChartStats) -> some View {
        HStack(spacing: 10) {
            statistic("平均", value: stats.average)
            statistic("最低", value: stats.minValue)
            statistic("最高", value: stats.maxValue)
        }
    }

    private func statistic(_ title: String, value: Double) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(MetricDisplay.formatted(metricID: metricID, value: value))
                .font(.system(.body, design: .rounded, weight: .semibold))
            if !info.unitSuffix.isEmpty {
                Text(info.unitSuffix)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("读取中…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这段时间没有数据", systemImage: "chart.xyaxis.line")
                .font(.headline)
            Text("换个更长的时间范围试试；如果所有范围都是空的，"
                 + "说明这个指标还没从手表传过来 —— 去「状态」页签看链路。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    /// 展示粒度的中文说明（"15 分钟" / "1 小时"）。
    private var bucketDescription: String {
        range.displayBucket >= 3600
            ? "\(Int(range.displayBucket / 3600)) 小时"
            : "\(Int(range.displayBucket / 60)) 分钟"
    }

    /// 一句话解释"这张图是怎么画出来的"。
    ///
    /// 这不是装饰：不同形态的图**读法完全不同**（点图为什么不连线、柱图是累计不是平均），
    /// 不写清楚，用户会拿折线的直觉去读柱状图，然后得出错误结论。
    private var chartNote: String {
        switch info.chartStyle {
        case .lineWithRange:
            return "折线是每 \(bucketDescription)一格的平均值，浅色带是该格内的最低~最高值。"
        case .line:
            return "每 \(bucketDescription)一个点并连成线：这类指标的相邻测量之间有真实的生理连续性。"
        case .points:
            return "只画点、不连线：这是离散点测（一天测几次），中间没测的时段不能画成平滑过渡。每点是一格内的实测值。"
        case .bars:
            return "柱高是每\(barBucketDescription)的累计值，不是平均值 —— 这个指标看的是一共多少。"
        case .stackedBars:
            return ""
        }
    }

    private var provenanceNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 用 `kind` 而不是 `info.kind`：RR 间期在 MetricDisplay 里查不到
            // （它不是 HealthKit 指标），读 info 只会拿到 fallback。
            if kind == .quantity, !points.isEmpty || !bars.isEmpty {
                Text(chartNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("数据由 Apple Watch 采集，经 WatchConnectivity 传到本机。传输是「至少一次」，重复的会按样本 id 去重。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 装配

    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        let store = PhoneServices.shared.store
        let window = range.window()

        // 先更新"本机有没有心跳序列"：它决定选择器里那一项在不在。
        // 放最前面是因为下面可能要靠它把选中项回退掉。
        hasRRSeries = ((try? await store.heartbeatSeriesCount()) ?? 0) > 0

        // 数据被保留策略清掉、或者还没同步过来时，选中的那一项可能已经不在列表里了
        // —— 那样菜单标题会退化成原始 id（`__rr_poincare__`），很难看。
        // 回退到心率，并由 `onChange(of: metricID)` 再触发一次加载。
        if metricID == RRPoincare.metricID && !hasRRSeries {
            metricID = "heart_rate"
            return
        }

        do {
            switch kind {
            case .rrPoincare:
                let fetch = try await store.rrSeries(from: window.from, to: window.to)
                poincare = PoincareBuilder.build(from: fetch.series, filterEctopic: filterEctopic)
                rrTruncated = fetch.isTruncated
                points = []
                bars = []
                barStats = nil
                sleepDays = []
                sleepSegments = []
                stats = nil

            case .category:
                let samples = try await store.categorySamples(metricID: metricID,
                                                              from: window.from,
                                                              to: window.to)
                let days = ChartSeriesBuilder.sleepDays(from: samples)
                sleepDays = days
                // 拍平放到这里做，视图里就只剩渲染
                sleepSegments = ChartSeriesBuilder.sleepSegments(from: days)
                points = []
                bars = []
                barStats = nil
                stats = nil
                poincare = nil

            case .quantity:
                let rollups = try await store.rollups(metricID: metricID,
                                                      from: window.from,
                                                      to: window.to)
                if info.chartStyle == .bars {
                    // 累计量：按**自然时间段求和**，粒度是 `barBucket`，
                    // 和折线那个 `displayBucket` 不是一回事（见 ChartRange 的说明）。
                    let built = ChartSeriesBuilder.bars(from: rollups, bucket: range.barBucket)
                    bars = built
                    barStats = ChartSeriesBuilder.barStats(from: built)
                    points = []
                    stats = nil
                } else {
                    let built = ChartSeriesBuilder.points(from: rollups,
                                                          displayBucket: range.displayBucket)
                    points = built
                    stats = ChartSeriesBuilder.stats(from: built)
                    bars = []
                    barStats = nil
                }
                sleepDays = []
                sleepSegments = []
                poincare = nil
            }
            loadError = nil
        } catch {
            loadError = "查询失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 各种图表形态
//
// 刻意各自独立成一个小 struct，而不是在 `ChartView` 里用一堆 `@ViewBuilder` 计算属性：
// 一个视图里塞四种图，SwiftUI 的类型推导很容易超时
// （本项目已经踩过一次，见 `sleepContent` 那段注释）。
// 每个 struct 只做一件事，每个 body 只有一层 `ForEach` + 一两个 Mark，推导瞬间结束。

/// **高频连续量**：平均值折线 + 最低~最高波动带。
///
/// 为什么要有波动带：只有平均值的话，一次剧烈波动会被平均掉、完全看不见
/// —— 而"运动时心率冲上去了"恰恰是用户最想看到的。
private struct RangeBandChart: View {
    let points: [ChartPoint]
    let domain: ClosedRange<Double>

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("时间", point.date),
                     yStart: .value("最低", point.minValue),
                     yEnd: .value("最高", point.maxValue))
                .foregroundStyle(Color.pink.opacity(0.15))

            LineMark(x: .value("时间", point.date),
                     y: .value("平均", point.average))
                .foregroundStyle(Color.pink)
                .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: domain)
        .frame(height: 260)
    }
}

/// **稀疏趋势量**：点 + 折线。
///
/// 这类指标的相邻测量之间确实存在生理上的连续变化（静息心率不会从 55 跳到 90），
/// 所以连线是有信息的、不是伪造的。
private struct TrendLineChart: View {
    let points: [ChartPoint]
    let domain: ClosedRange<Double>
    let tint: Color

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("时间", point.date),
                     y: .value("值", point.average))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)

            PointMark(x: .value("时间", point.date),
                      y: .value("值", point.average))
                .symbolSize(20)
                .foregroundStyle(tint)
        }
        .chartYScale(domain: domain)
        .frame(height: 260)
    }
}

/// **离散点测量**：只画点，**不连线**。
///
/// ⚠️ 不连线是刻意的，也是这张图存在的全部理由：
/// 血氧 / 呼吸频率 / 睡眠腕温都是"一天测几次"的点测，**中间那些小时根本没测**。
/// 连成折线等于把"没测"伪装成"连续变化的平滑过渡" —— 图会**说谎**，
/// 而且是那种没人会怀疑的说谎（曲线看着很合理）。
private struct ScatterPointChart: View {
    let points: [ChartPoint]
    let domain: ClosedRange<Double>
    let tint: Color

    var body: some View {
        Chart(points) { point in
            PointMark(x: .value("时间", point.date),
                      y: .value("值", point.average))
                .symbolSize(30)
                .foregroundStyle(tint.opacity(0.8))
        }
        .chartYScale(domain: domain)
        .frame(height: 260)
    }
}

/// **日累计量**：柱状。
///
/// `unit` 由调用方按时间范围给（一天的范围用小时、更长的用天）——
/// 因为"一共多少"必须落在用户能理解的自然时间段上，
/// 拆成 96 根 15 分钟的柱子等于把日总量藏起来。
private struct CumulativeBarChart: View {
    let bars: [BarPoint]
    let unit: Calendar.Component
    let tint: Color

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("时间", bar.date, unit: unit),
                    y: .value("累计", bar.total))
                .foregroundStyle(tint.opacity(0.85))
        }
        .frame(height: 260)
    }
}
