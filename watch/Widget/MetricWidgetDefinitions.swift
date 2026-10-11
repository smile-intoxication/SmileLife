import SwiftUI
import WidgetKit

// MARK: - 每个指标一个小组件
//
// ## 为什么是"一个指标一个"，而不是"一个可配置的"
// 需求方明确要求过。理由和图表页那条原则同构（AGENTS.md 原则 6）：
// 用户加小组件时的动作是"我要看心率"，不是"我要加一个小组件然后配置它"。
// 而且**可配置**意味着小组件库里只有一个笼统的"健康指标"条目 ——
// 用户根本不知道能不能用它看 HRV。**藏进配置界面的代价是用户不会去配置。**
//
// 代价要说清楚：**加一个新指标要动这个文件**（多一个 struct + 在 bundle 里加一行）。
// 所以自检第 21 节会机械断言"`MetricDisplay` 里每个指标都有对应的小组件" ——
// 漏了不会报错，只会让那个指标在小组件库里**凭空消失**。
//
// ## ⚠️ 显示名是**写死的字面量**，这一点必须知道为什么
// `shared/MetricDisplay.swift` **不在 widget target 的 sources 里**
// （小组件刻意只依赖 Foundation，见 AGENTS.md「两个 shared 是不同的东西」）。
// 所以这里拿不到 `MetricDisplay` 的标题，只能抄一份。
// **抄了就会漂移** —— 自检第 21 节同时校验"这里的字面量和 MetricDisplay 一致"。

// MARK: - Provider

/// **普通过（非 AppIntent）**的 provider：指标由类型自己固定，用户没有配置项。
///
/// ⚠️ 名字刻意不叫 `MetricTimelineProvider` —— 那是原来那个可配置小组件用的
/// `AppIntentTimelineProvider`。两者协议不同，重名会直接编译失败。
struct FixedMetricTimelineProvider: TimelineProvider {

    typealias Entry = SnapshotEntry

    let metricID: String
    let displayName: String

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(
            date: .now,
            item: .init(metricID: metricID,
                        title: displayName,
                        unitSuffix: "",
                        symbolName: "heart.fill",
                        displayValue: "--",
                        rawValue: nil,
                        sampleDate: .now),
            generatedAt: .now
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .after(nextRefresh)))
    }

    /// 下一个**兜底**刷新时间。
    ///
    /// ## 🔴 这里有个反直觉的事实，别把它当成 bug
    /// **刷新间隔不是小组件能设的，是 WidgetKit 按预算给的。**
    /// 官方口径：表盘 complication 每天大约只有 **40~75 次**刷新额度。
    ///
    /// 所以：
    /// - **30 分钟**（48 次/天）是诚实的兜底值。写 15 分钟（96 次/天）就**超预算**了，
    ///   超出的会被系统丢弃 —— 反而让"多久更新一次"的预期落空。
    /// - **真正让表盘及时更新的是另一条路**：手表 app 在快照内容变化后调用
    ///   `WidgetCenter.shared.reloadAllTimelines()`（`SnapshotService` 里已经在做）。
    ///   那条路才是"数据一到就刷新"，而 policy 只是"没有新数据时的兜底"。
    /// - ⚠️ **不要为了"更新更快"把这个值调小** —— 请求超量会被系统降频，
    ///   结果比 30 分钟更慢。
    private var nextRefresh: Date {
        Date().addingTimeInterval(30 * 60)
    }

    private func currentEntry() -> SnapshotEntry {
        let snapshot = SharedStore.readSnapshot()
        let item = snapshot.items.first { $0.metricID == metricID }
        return SnapshotEntry(date: .now, item: item, generatedAt: snapshot.generatedAt)
    }
}

// MARK: - 共用的配置构造器

/// 一个指标一个小组件，但**构造逻辑只有这一份**。
///
/// `kind` 必须每个指标唯一（系统靠它区分时间线）。
private func metricWidgetConfiguration(metricID: String,
                                       displayName: String) -> some WidgetConfiguration {
    StaticConfiguration(kind: "com.applewatchhealth.metric.\(metricID)",
                        provider: FixedMetricTimelineProvider(metricID: metricID,
                                                              displayName: displayName)) { entry in
        SnapshotWidgetView(entry: entry)
    }
    .configurationDisplayName(Text(verbatim: displayName))
    .description(Text(verbatim: "在表盘上显示「\(displayName)」的最新值"))
    .supportedFamilies([
        .accessoryCircular,
        .accessoryRectangular,
        .accessoryInline,
        .accessoryCorner
    ])
}

// MARK: - 心率族

struct HeartRateWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "heart_rate", displayName: "心率")
    }
}

struct RestingHeartRateWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "resting_heart_rate", displayName: "静息心率")
    }
}

struct WalkingHeartRateWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "walking_heart_rate_average", displayName: "步行心率")
    }
}

/// HRV（SDNN）—— **HealthKit 原值**。
///
/// ⚠️ 这是**系统按心跳间期算好的离散样本**（`HKQuantityTypeIdentifierHeartRateVariabilitySDNN`），
/// **不是**我们自己算的 RMSSD。这条是需求方定的（AGENTS.md 原则 9）：
/// 手表 → 手机是单向的，我们自己算的值都在手机上，要上表盘得新加反向通路；
/// 而用系统原值就没这个问题，也避开了"同一个名字两个来源、数值不一样"。
struct HRVSDNNWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "hrv_sdnn", displayName: "HRV (SDNN)")
    }
}

/// HRV（RMSSD）—— 同样是 HealthKit 原值（类型标识符用原始字符串构造，见坑 #18）。
struct HRVRMSSDWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "hrv_rmssd", displayName: "HRV (RMSSD)")
    }
}

struct RespiratoryRateWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "respiratory_rate", displayName: "呼吸频率")
    }
}

struct OxygenSaturationWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "oxygen_saturation", displayName: "血氧")
    }
}

// MARK: - 其余指标

struct WristTemperatureWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "sleeping_wrist_temperature", displayName: "睡眠腕温")
    }
}

struct SleepWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "sleep_analysis", displayName: "睡眠")
    }
}

struct ActiveEnergyWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "active_energy", displayName: "活动能量")
    }
}

struct ExerciseTimeWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "exercise_time", displayName: "锻炼时间")
    }
}

struct VO2MaxWidget: Widget {
    var body: some WidgetConfiguration {
        metricWidgetConfiguration(metricID: "vo2_max", displayName: "最大摄氧量")
    }
}

// MARK: - Bundle
//
// ## 🔴 这里有个我赌错过的假设，记下来
// 我原以为可以像 `ViewBuilder` 那样**嵌套 bundle** 来绕开孩子数上限，
// 于是写了 `HeartMetricsWidgets`(7) + `OtherMetricsWidgets`(5) 套在 `@main` 里。
// **`WidgetBundle` 不 conform 到 `Widget`**，子 bundle 不能当孩子用，CI 报：
// ```
// error: no exact matches in call to static method 'buildExpression'
// ```
// 所以现在**平铺**：12 个指标小组件直接列在 `@main` bundle 里。
// ⚠️ 这也意味着"能不能超过 10 个"完全取决于 `WidgetBundleBuilder` 自己的
// `buildBlock` 重载 —— **实测 CI 说了算**，不要凭 `ViewBuilder` 的经验推。

@main
struct AppleWatchHealthWidgets: WidgetBundle {
    var body: some Widget {
        HeartRateWidget()
        RestingHeartRateWidget()
        WalkingHeartRateWidget()
        HRVSDNNWidget()
        HRVRMSSDWidget()
        RespiratoryRateWidget()
        OxygenSaturationWidget()
        WristTemperatureWidget()
        SleepWidget()
        ActiveEnergyWidget()
        ExerciseTimeWidget()
        VO2MaxWidget()
    }
}