import Foundation
import HealthKit

/// 指标注册表：**一个指标 = 一条声明**。
///
/// 设计意图：同步引擎、本地库、快照、小组件全部只认 `MetricDescriptor`，
/// 所以新增一个指标只需要在 `MetricCatalog.v1` 里加一行，全链路自动生效。
/// 不要为每个指标单独写逻辑——全量方案下那样会失控。
struct MetricDescriptor: Identifiable {

    /// 数值形态：决定怎么从 HKSample 里取值和单位
    enum ValueShape {
        /// 数值型，例如心率、血氧、HRV。带一个单位用于换算与展示。
        case quantity(HKUnit, decimals: Int)
        /// 枚举型，例如睡眠阶段。附带把枚举值翻译成中文标签的方法。
        case category(label: (Int) -> String)
    }

    /// 稳定标识。**会被写进本地库、anchor 记录和快照文件，一旦上线不要改。**
    let id: String
    /// 展示名
    let title: String
    /// 单位后缀，用于 UI 展示（如 "bpm"、"ms"、"%"）
    let unitSuffix: String
    /// SF Symbol 名，小组件用
    let symbolName: String
    /// HealthKit 样本类型
    let sampleType: HKSampleType
    /// 取值形态
    let shape: ValueShape
    /// v1 是否默认开启。关掉的指标仍然会出现在设置的候选列表里。
    let enabledByDefault: Bool

    /// **首次同步**（anchor 为空）时往回拉多少天。
    ///
    /// 为什么需要这个：`HKAnchoredObjectQuery` 在 anchor 为 nil 时会返回
    /// store 里**全部**匹配样本。心率最坏情况是每 5 秒一条 = 17,280 条/天，
    /// 手表后台只有"几秒"执行时间，必然超时被系统杀掉。
    ///
    /// 📌 已确认的设计原则是「**不追求数据完整性**」——有的就收集，没有就算了。
    /// 所以这里的窗口**刻意取小**，不需要为了"尽量多拿历史"而放大它。
    /// 默认 7 天正好铺满本地保留窗口；心率因为密度高，单独设成 1 天。
    var initialLookbackDays: Int = 7
}

/// 存储策略：**本地只保留最近 7 天**（已确认）。
///
/// ## 为什么 7 天是安全的
/// 最坏情况（S12 全天每 5 秒一条心率）：
/// `17,280 条/天 × 7 天 ≈ **12.1 万行**`，SwiftData 落盘大约几十 MB，
/// Apple Watch 完全放得下。而且**增量同步只拉新增样本**，
/// 不会因为本地行数多而变慢——所以"行数多"本身不是问题。
///
/// ## 为什么聚合层被删掉了
/// 之前设计过"原始 24 小时 + 小时聚合 365 天"的分层，是为了**长期保留同时压缩体积**。
/// 现在既然只留 7 天、不留长期，聚合就只剩额外复杂度（水位线、聚合顺序、
/// 快照兜底），**收益为零**，所以整个拿掉。
///
/// ## 落到磁盘，不是内存
/// SwiftData 库是**文件型**的（`isStoredInMemoryOnly: false`），
/// 存在 app 沙盒的 Application Support 目录，app 重启或被系统杀掉都不会丢。
enum StoragePolicy {
    /// 本地保留天数。超过这个天数的样本会被删除。
    static let retentionDays = 7
}

enum MetricCatalog {

    // MARK: - 工具

    private static func q(_ id: HKQuantityTypeIdentifier) -> HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: id)
    }

    private static func c(_ id: HKCategoryTypeIdentifier) -> HKCategoryType? {
        HKCategoryType.categoryType(forIdentifier: id)
    }

    /// VO₂ max 的单位是 mL/(kg·min)。
    /// ⚠️ 刻意**不用** `HKUnit(from: "ml/kg*min")`——字符串解析失败会直接抛异常崩溃，
    /// 而 `MetricCatalog.all` 是静态属性，一崩就是启动即崩。用组合单位最稳。
    private static let vo2MaxUnit = HKUnit
        .literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))

    /// 睡眠阶段的中文标签。注意 `.asleep` 已被 Apple 废弃，不要用。
    static func sleepLabel(_ raw: Int) -> String {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: raw) else { return "未知" }
        switch v {
        case .inBed:               return "卧床"
        case .awake:               return "清醒"
        case .asleepCore:          return "核心睡眠"
        case .asleepDeep:          return "深睡"
        case .asleepREM:           return "快速眼动"
        case .asleepUnspecified:   return "睡眠"
        @unknown default:          return "未知"
        }
    }

    // MARK: - v1 指标清单

    /// watchOS 27 才有的类型 —— **用原始字符串构造，不引用 Swift 符号**。
    ///
    /// ⚠️ 为什么必须这样（这是一个真踩过的坑）：
    /// `HKQuantityTypeIdentifier.heartRateVariabilityRMSSD` 这个**符号只存在于 watchOS 27 SDK**，
    /// 而 CI runner 目前只有 watchOS 26.2 SDK。直接写符号就编译不过，
    /// 于是之前只能在 `#if HAS_WATCHOS_27_SDK` 里门控 ——
    /// 而那个条件**在 CI 上从未成立**，结果就是 **RMSSD 从来就没被编译进去过**。
    ///
    /// `HKQuantityTypeIdentifier` 是 ObjC 的 `NS_TYPED_ENUM`，Swift 里就是一个
    /// `RawRepresentable` 结构体，`rawValue` 就是 ObjC 常量名。所以用原始字符串构造：
    /// 在**老 SDK 上照样能编译**，在 watchOS 27 设备上**运行时能拿到真类型**。
    ///
    /// 代价：字符串写错**不会编译报错**，只会让 `quantityType(forIdentifier:)` 返回 nil。
    /// 所以下面**绝不强制解包**，拿不到就跳过该指标（诊断界面会把它标成「不可用」）。
    static let rmssdIdentifier = HKQuantityTypeIdentifier(
        rawValue: "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"
    )

    private static var watchOS27Metrics: [MetricDescriptor] {
        // 拿不到类型就静默跳过：不崩、不影响其它指标。
        // 这同时也是一个**运行时探针**——watchOS 27 设备上它应该能拿到。
        guard let rmssd = HKQuantityType.quantityType(forIdentifier: rmssdIdentifier) else {
            return []
        }
        return [
            MetricDescriptor(
                id: "hrv_rmssd",
                title: "HRV (RMSSD)",
                unitSuffix: "ms",
                symbolName: "waveform.path.ecg.rectangle",
                sampleType: rmssd,
                shape: .quantity(HKUnit.secondUnit(with: .milli), decimals: 0),
                enabledByDefault: true
            )
        ]
    }

    /// v1 只收「Apple Watch 独有产生」的指标 —— 这些才是手表端真正该负责的数据。
    /// 注意：走路稳定性 / 步态不对称 / 步速 等**是 iPhone 产生的**，不放进手表端。
    ///
    /// 结构是 `[心率族] + [watchOS 27 专属] + [其余]`，
    /// 拆成三段就是因为 `#if` 不能写在数组字面量里（见 `watchOS27Metrics`）。
    static let all: [MetricDescriptor] =
        [
        // ——— 心率族（全部 ★Watch 独有）———
        MetricDescriptor(
            id: "heart_rate",
            title: "心率",
            unitSuffix: "bpm",
            symbolName: "heart.fill",
            sampleType: q(.heartRate)!,
            shape: .quantity(HKUnit.count().unitDivided(by: .minute()), decimals: 0),
            enabledByDefault: true,
            initialLookbackDays: 1   // 高频数据，首次只回看 1 天（不追求完整性）
        ),
        MetricDescriptor(
            id: "resting_heart_rate",
            title: "静息心率",
            unitSuffix: "bpm",
            symbolName: "heart.text.square.fill",
            sampleType: q(.restingHeartRate)!,
            shape: .quantity(HKUnit.count().unitDivided(by: .minute()), decimals: 0),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "walking_heart_rate_average",
            title: "步行心率",
            unitSuffix: "bpm",
            symbolName: "figure.walk",
            sampleType: q(.walkingHeartRateAverage)!,
            shape: .quantity(HKUnit.count().unitDivided(by: .minute()), decimals: 0),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "hrv_sdnn",
            title: "HRV (SDNN)",
            unitSuffix: "ms",
            symbolName: "waveform.path.ecg",
            sampleType: q(.heartRateVariabilitySDNN)!,
            shape: .quantity(HKUnit.secondUnit(with: .milli), decimals: 0),
            enabledByDefault: true
        )
        ]
        + watchOS27Metrics
        + [
        // ——— 呼吸 / 血氧 / 腕温 ———
        MetricDescriptor(
            id: "respiratory_rate",
            title: "呼吸频率",
            unitSuffix: "次/分",
            symbolName: "lungs.fill",
            sampleType: q(.respiratoryRate)!,
            shape: .quantity(HKUnit.count().unitDivided(by: .minute()), decimals: 1),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "oxygen_saturation",
            title: "血氧",
            unitSuffix: "%",
            symbolName: "drop.fill",
            sampleType: q(.oxygenSaturation)!,
            shape: .quantity(HKUnit.percent(), decimals: 0),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "sleeping_wrist_temperature",
            title: "睡眠腕温",
            unitSuffix: "°C",
            symbolName: "thermometer.medium",
            sampleType: q(.appleSleepingWristTemperature)!,
            shape: .quantity(HKUnit.degreeCelsius(), decimals: 2),
            enabledByDefault: true
        ),

        // ——— 睡眠（枚举型）———
        MetricDescriptor(
            id: "sleep_analysis",
            title: "睡眠",
            unitSuffix: "",
            symbolName: "bed.double.fill",
            sampleType: c(.sleepAnalysis)!,
            shape: .category(label: sleepLabel),
            enabledByDefault: true
        ),

        // ——— 可选：默认关闭，用户可在设置里打开 ———
        MetricDescriptor(
            id: "active_energy",
            title: "活动能量",
            unitSuffix: "kcal",
            symbolName: "flame.fill",
            sampleType: q(.activeEnergyBurned)!,
            shape: .quantity(HKUnit.kilocalorie(), decimals: 1),
            enabledByDefault: false
        ),
        MetricDescriptor(
            id: "exercise_time",
            title: "锻炼时间",
            unitSuffix: "分钟",
            symbolName: "figure.run",
            sampleType: q(.appleExerciseTime)!,
            shape: .quantity(HKUnit.minute(), decimals: 0),
            enabledByDefault: false
        ),
        MetricDescriptor(
            id: "vo2_max",
            title: "最大摄氧量",
            unitSuffix: "mL/kg·min",
            symbolName: "chart.line.uptrend.xyaxis",
            sampleType: q(.vo2Max)!,
            shape: .quantity(vo2MaxUnit, decimals: 1),
            enabledByDefault: false
        )
    ]

    /// 只读授权需要请求的类型集合
    static var readTypes: Set<HKObjectType> {
        Set(all.map { $0.sampleType as HKObjectType })
    }

    static func descriptor(id: String) -> MetricDescriptor? {
        all.first { $0.id == id }
    }
}
