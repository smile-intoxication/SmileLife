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
    @State private var sleepDays: [SleepDayBar] = []
    /// 拍平后的睡眠片段（`Chart` 直接吃这个，不现算 —— 见 `SleepChartSegment` 的注释）
    @State private var sleepSegments: [SleepChartSegment] = []
    @State private var stats: ChartStats?
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var loadError: String?

    private var info: MetricDisplay.Info { MetricDisplay.infoOrFallback(id: metricID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    selectors

                    if info.kind == .category {
                        sleepContent
                    } else {
                        quantityContent
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
            Image(systemName: info.symbolName)
            Text(info.title).font(.headline)
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
                ForEach(MetricDisplay.all) { item in
                    Button {
                        metricID = item.id
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
        if points.isEmpty {
            if isLoading || !hasLoadedOnce {
                loadingPlaceholder
            } else {
                emptyPlaceholder
            }
        } else {
            Chart(points) { point in
                // 先画"最低~最高"的浅色带，再画平均值折线。
                // 只有平均值的话，一次剧烈波动会被平均掉、完全看不见。
                AreaMark(x: .value("时间", point.date),
                         yStart: .value("最低", point.minValue),
                         yEnd: .value("最高", point.maxValue))
                    .foregroundStyle(Color.pink.opacity(0.15))

                LineMark(x: .value("时间", point.date),
                         y: .value("平均", point.average))
                    .foregroundStyle(Color.pink)
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: ChartSeriesBuilder.yDomain(from: points,
                                                            fromZero: info.chartFromZero))
            .frame(height: 260)

            if let stats {
                statisticsRow(stats)
            }
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

    private var provenanceNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if info.kind == .quantity, !points.isEmpty {
                Text("折线是每 \(bucketDescription)一格的平均值；浅色带是该格内的最低~最高值。")
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

        do {
            if info.kind == .category {
                let samples = try await store.categorySamples(metricID: metricID,
                                                              from: window.from,
                                                              to: window.to)
                let days = ChartSeriesBuilder.sleepDays(from: samples)
                sleepDays = days
                // 拍平放到这里做，视图里就只剩渲染
                sleepSegments = ChartSeriesBuilder.sleepSegments(from: days)
                points = []
                stats = nil
            } else {
                let rollups = try await store.rollups(metricID: metricID,
                                                      from: window.from,
                                                      to: window.to)
                let built = ChartSeriesBuilder.points(from: rollups,
                                                      displayBucket: range.displayBucket)
                points = built
                stats = ChartSeriesBuilder.stats(from: built)
                sleepDays = []
                sleepSegments = []
            }
            loadError = nil
        } catch {
            loadError = "查询失败：\(error.localizedDescription)"
        }
    }
}
