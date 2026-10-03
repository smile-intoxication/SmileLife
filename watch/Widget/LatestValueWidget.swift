import SwiftUI
import WidgetKit
import AppIntents

// MARK: - 可选的指标（AppEntity）

/// 用 `AppEntity` + `EntityQuery` 而不是 `AppEnum`，是为了让"可选指标"**从快照动态生成**：
/// 手表端采到新指标后，小组件的配置界面里会自动多一个选项，不用改这个文件。
struct MetricEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "健康指标"
    static var defaultQuery = MetricEntityQuery()

    var id: String
    var title: String
    var symbolName: String

    var displayRepresentation: DisplayRepresentation {
        // 官方签名是 init(systemName:isTemplate:)，两个参数都要给。
        // （没有 systemName(_:) 这种静态方法，写错会在下一轮 CI 才暴露。）
        DisplayRepresentation(
            title: "\(title)",
            image: DisplayRepresentation.Image(systemName: symbolName, isTemplate: nil)
        )
    }
}

/// 候选指标**从快照里取**，而不是从 `MetricCatalog` 取。
///
/// 为什么：小组件是**独立 target**，`MetricCatalog` 属于手表 app target，
/// 而且它依赖 HealthKit——小组件既不该也不需要 HealthKit 权限。
/// 快照里已经带了每个指标的 id / 标题 / 图标，直接用就够了。
struct MetricEntityQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [MetricEntity] {
        let items = SharedStore.readSnapshot().items
        return identifiers.map { id in
            if let item = items.first(where: { $0.metricID == id }) {
                return MetricEntity(item)
            }
            // 快照里暂时没有这个指标（还没采到数据）时，退化成只显示 id
            return MetricEntity(id: id, title: id, symbolName: "heart.fill")
        }
    }

    /// 配置界面里默认展示的候选：当前快照里**有数据**的指标
    func suggestedEntities() async throws -> [MetricEntity] {
        SharedStore.readSnapshot().items.map(MetricEntity.init)
    }

    func defaultResult() async -> MetricEntity? {
        let items = SharedStore.readSnapshot().items
        if let heartRate = items.first(where: { $0.metricID == "heart_rate" }) {
            return MetricEntity(heartRate)
        }
        return items.first.map(MetricEntity.init)
    }
}

private extension MetricEntity {
    init(_ item: LatestSnapshot.Item) {
        self.init(id: item.metricID, title: item.title, symbolName: item.symbolName)
    }
}

// MARK: - 配置意图

struct SelectMetricIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource = "选择指标"
    static var description = IntentDescription("选择这个小组件要显示哪个健康指标。")

    @Parameter(title: "指标")
    var metric: MetricEntity?
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let item: LatestSnapshot.Item?
    let generatedAt: Date
}

/// 小组件 provider。
///
/// **刻意不查 HealthKit**，只读 App Group 里的快照文件。原因（见调研 §4.5）：
/// - 设备锁定时 HealthKit store 被加密，小组件可能读不到数据 → 会白屏；
/// - 小组件渲染时间预算紧，查 HealthKit 会拖慢 timeline 生成；
/// - 这也是 Apple 官方推荐的模式（主 app 写共享容器，扩展只读）。
struct MetricTimelineProvider: AppIntentTimelineProvider {

    typealias Entry = SnapshotEntry
    typealias Intent = SelectMetricIntent

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(
            date: .now,
            item: .init(metricID: "heart_rate",
                        title: "心率",
                        unitSuffix: "bpm",
                        symbolName: "heart.fill",
                        displayValue: "72",
                        rawValue: 72,
                        sampleDate: .now),
            generatedAt: .now
        )
    }

    func snapshot(for configuration: SelectMetricIntent, in context: Context) async -> SnapshotEntry {
        makeEntry(for: configuration)
    }

    func timeline(for configuration: SelectMetricIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        // ⚠️ 间隔要和表盘刷新预算对齐：官方口径 complication 每天最多约 40~75 次刷新。
        //    15 分钟一轮 = 96 次/天，**已经超预算**，超出的会被系统丢弃，
        //    反而让"多久更新一次"的预期落空。所以取 30 分钟（48 次/天），
        //    真正需要即时更新时由主 app 在快照内容变化后调用
        //    WidgetCenter.reloadAllTimelines() 主动触发。
        let next = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [makeEntry(for: configuration)], policy: .after(next))
    }

    /// 在"添加小组件"的列表里预先给出几个常用指标，
    /// 用户不必先添加再进配置界面。
    /// 同样从快照取（见上面 MetricEntityQuery 的说明）。
    func recommendations() -> [AppIntentRecommendation<SelectMetricIntent>] {
        SharedStore.readSnapshot().items
            .prefix(6)
            .map { item in
                let intent = SelectMetricIntent()
                intent.metric = MetricEntity(item)
                return AppIntentRecommendation(intent: intent, description: "\(item.title)")
            }
    }

    private func makeEntry(for configuration: SelectMetricIntent) -> SnapshotEntry {
        let snapshot = SharedStore.readSnapshot()
        let metricID = configuration.metric?.id ?? "heart_rate"
        let item = snapshot.items.first { $0.metricID == metricID }
        return SnapshotEntry(date: .now, item: item, generatedAt: snapshot.generatedAt)
    }
}

// MARK: - 视图

struct SnapshotWidgetView: View {

    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        content
            // watchOS 10+ 必须提供 containerBackground，否则不被渲染
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {

        case .accessoryCircular:
            Gauge(value: 0) {
                Image(systemName: entry.item?.symbolName ?? "heart.fill")
            } currentValueLabel: {
                Text(entry.item?.displayValue ?? "--")
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .gaugeStyle(.accessoryCircular)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.item?.symbolName ?? "heart.fill")
                        .font(.caption2)
                    Text(entry.item?.title ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(entry.item?.displayValue ?? "--")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text(entry.item?.unitSuffix ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

        case .accessoryInline:
            // 官方没有给 inline 的字符数上限，不同表盘可用空间不同，
            // 所以内容要尽量短。
            Text("\(entry.item?.title ?? "") \(entry.item?.displayValue ?? "--")\(entry.item?.unitSuffix ?? "")")

        case .accessoryCorner:
            Text(entry.item?.displayValue ?? "--")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .widgetLabel {
                    Text(entry.item?.title ?? "")
                }

        default:
            Text(entry.item?.displayValue ?? "--")
        }
    }

    private var timeText: String {
        guard let date = entry.item?.sampleDate else { return "无数据" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Widget 定义

/// 因为本项目只支持 **watchOS 27+**，而 watchOS 26 起系统已经支持
/// **用户自己配置 watchOS 小组件**（`AppIntentConfiguration`），
/// 所以这里用"**一个可配置小组件**"代替了早期那种"每个指标一个固定 widget"的做法：
///
/// - 用户在表盘/智能叠放里添加后，自己选要显示哪个指标；
/// - 加新指标**不需要动这个文件**；
/// - 也就不存在"WidgetBundle 里堆十几个 widget"的问题。
///
/// （作为对比：watchOS 11 及更早**没有配置界面**，那时才必须用 `WidgetBundle` 预定义一组。）
struct MetricComplicationWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "com.applewatchhealth.metric",
            intent: SelectMetricIntent.self,
            provider: MetricTimelineProvider()
        ) { entry in
            SnapshotWidgetView(entry: entry)
        }
        .configurationDisplayName("健康指标")
        .description("在表盘上显示任意一个健康指标的最新值")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}

@main
struct AppleWatchHealthWidgets: WidgetBundle {
    var body: some Widget {
        MetricComplicationWidget()
    }
}
