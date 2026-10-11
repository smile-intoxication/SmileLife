import SwiftUI
import WidgetKit

// MARK: - 这个文件现在只剩两样东西
//
// 1. `SnapshotEntry` —— timeline 的 entry 类型（**所有**指标小组件共用）
// 2. `SnapshotWidgetView` —— 按 widget family 渲染的视图（**所有**指标小组件共用）
//
// ## 为什么要改（需求方明确要求过）
// 这里原来是一个 **`AppIntentConfiguration` 的可配置小组件** ——
// 用户在表盘上添加它，再进配置界面**选一个**指标。
// 那个做法在 watchOS 26+ 上技术上是可行的，代码也更少（加指标不用动这个文件），
// 而且当时正是按这个理由选的它。
//
// **但需求方否掉了它，要求"每个指标独立一个小组件"。** 理由和图表页那条是同一个：
// 用户加小组件时的动作是"我要看心率"，而不是"我要加一个小组件然后配置它"；
// 而且**可配置**意味着小组件库里只有一个笼统的"健康指标"条目，
// 用户根本不知道能不能用它看 HRV —— **藏进配置界面的代价是用户不会去配置**。
//
// 所以现在：**每个指标一个 `StaticConfiguration` 小组件**，直接以指标自己的名字
// 出现在小组件库里。定义都在 `MetricWidgetDefinitions.swift`（含 `@main` bundle）。
//
// ⚠️ 这条推论和图表页的"平铺 vs 选择器"完全同构 —— 见 AGENTS.md 原则 6。

// MARK: - Timeline entry

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let item: LatestSnapshot.Item?
    let generatedAt: Date
}

// MARK: - 视图

/// 所有指标小组件共用的视图：**按 family 换布局，不换数据**。
///
/// 数据来自 `entry.item` —— 快照里已经带了标题/单位/图标/显示值，
/// 所以这个视图**不需要知道**有哪些指标，也就不需要 `MetricCatalog`。
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
