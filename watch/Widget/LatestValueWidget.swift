import SwiftUI
import WidgetKit
import AppIntents

// MARK: - 可选的指标（AppEntity）

/// 用 `AppEntity` + `EntityQuery` 而不是 `AppEnum`，是为了让"可选指标"**从注册表动态生成**：
/// 以后在 `MetricCatalog` 里加一个指标，小组件的配置界面里就自动多一个选项，不用改这个文件。
struct MetricEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "健康指标"
    static var defaultQuery = MetricEntityQuery()

    var id: String
    var title: String
    var symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: symbolName))
    }
}

struct MetricEntityQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [MetricEntity] {
        identifiers.compactMap { id in
            MetricCatalog.all.first { $0.id == id }.map(MetricEntity.init)
        }
    }

    /// 配置界面里默认展示的候选（只列默认开启的，避免列表过长）
    func suggestedEntities() async throws -> [MetricEntity] {
        MetricCatalog.all.filter(\.enabledByDefault).map(MetricEntity.init)
    }

    func defaultResult() async -> MetricEntity? {
        MetricCatalog.all.first(where: { $0.id == "heart_rate" }).map(MetricEntity.init)
    }
}

private extension MetricEntity {
    init(_ descriptor: MetricDescriptor) {
        self.init(id: descriptor.id, title: descriptor.title, symbolName: descriptor.symbolName)
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
        // 官方建议：timeline 条目间隔**至少约 5 分钟**；
        // 表盘上的 complication 每天最多约 75 次刷新。
        // 真正的即时更新靠主 app 主动调 `WidgetCenter.reloadAllTimelines()` 触发。
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [makeEntry(for: configuration)], policy: .after(next))
    }

    /// 在"添加小组件"的列表里预先给出几个常用指标，
    /// 用户不必先添加再进配置界面。
    func recommendations() -> [AppIntentRecommendation<SelectMetricIntent>] {
        MetricCatalog.all
            .filter(\.enabledByDefault)
            .prefix(6)
            .map { descriptor in
                let intent = SelectMetricIntent()
                intent.metric = MetricEntity(descriptor)
                return AppIntentRecommendation(intent: intent, description: descriptor.title)
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
