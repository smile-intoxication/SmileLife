import Foundation

/// 指标的**展示元数据**——跨设备（手表 / iPhone / 小组件）共享的**唯一定义处**。
///
/// ## 为什么必须单独抽出来
/// 手表把样本传给 iPhone 时，线上只传 `metricID` 这个稳定字符串
/// （加上 uuid、数值、时间）。**不传标题 / 单位 / SF Symbol**：
/// 那些是展示层的事，跟着数据走会让线协议变脏，而且改一次文案就得迁移历史数据。
///
/// 于是 iPhone 必须自己有一份 `metricID -> 展示信息` 的表。如果这份表和
/// `MetricCatalog` 各写一遍，**新增指标时漏改一处不会编译报错**，
/// 结果就是手机上看到一个 id 却没有名字（或名字是旧的）。
/// 所以：这里定义一次，`MetricCatalog` 从这里取展示字段，
/// `ci/verify-project.sh` 再断言两边的 id 集合完全一致。
///
/// ## ⚠️ 依赖约束
/// 本文件会被编进 **iOS app / watch app / widget** 三个 target，
/// 所以**只能依赖 Foundation**：
/// - 不能 `import HealthKit`（iOS app 刻意不申请健康权限）
/// - 不能 `import SwiftData`（只有落库的 target 才需要）
/// - 不能 `import WatchConnectivity`（同上）
///
/// `ci/verify-project.sh` 第 11 节会把这条约束当不变量来守。
enum MetricDisplay {

    /// 取值形态。**决定了能画什么图**：
    /// `quantity` 有数值 → 折线；`category` 是枚举（睡眠阶段）→ 只能按标签堆叠。
    enum Kind: String, Codable, Sendable {
        case quantity
        case category
    }

    struct Info: Identifiable, Equatable, Sendable {
        /// 稳定标识。**会被写进线协议与历史数据，一旦上线不要改。**
        let id: String
        let title: String
        /// 单位后缀，仅用于展示（"bpm"、"ms"、"%")
        let unitSuffix: String
        /// SF Symbol 名，手表列表与小组件用
        let symbolName: String
        let kind: Kind
        /// 数值型展示保留几位小数。**唯一来源**——
        /// `MetricCatalog` 不再自带 decimals，避免两处漂移。
        let decimals: Int
        /// 图表 Y 轴是否从 0 开始。
        ///
        /// ⚠️ 心率**不能**从 0 开始：静息心率 60 上下浮动时，
        /// 0~120 的坐标轴会把曲线压成一条直线，什么都看不出来。
        /// 而"活动能量 / 锻炼时间"这类累积量从 0 开始才符合直觉。
        let chartFromZero: Bool

        /// `metricID` 在对方版本里不存在时的兜底。
        ///
        /// 刻意**显示原始 id 而不是编造一个名字**：用户看到 `heart_rate` 就知道
        /// 是版本不同步；看到一个错的中文名只会以为是数据错了。
        static func fallback(id: String) -> Info {
            Info(id: id,
                 title: id,
                 unitSuffix: "",
                 symbolName: "questionmark.circle",
                 kind: .quantity,
                 decimals: 0,
                 chartFromZero: false)
        }
    }

    // MARK: - 指标清单

    /// ⚠️ **顺序就是 UI 里的展示顺序**（手表主界面列表、iPhone 概览、图表选择器）。
    /// 新增指标请加在语义相近的位置，不要随手追加到末尾。
    static let all: [Info] = [
        // ——— 心率族（全部由 Apple Watch 产生）———
        Info(id: "heart_rate",
             title: "心率",
             unitSuffix: "bpm",
             symbolName: "heart.fill",
             kind: .quantity,
             decimals: 0,
             chartFromZero: false),
        Info(id: "resting_heart_rate",
             title: "静息心率",
             unitSuffix: "bpm",
             symbolName: "heart.text.square.fill",
             kind: .quantity,
             decimals: 0,
             chartFromZero: false),
        Info(id: "walking_heart_rate_average",
             title: "步行心率",
             unitSuffix: "bpm",
             symbolName: "figure.walk",
             kind: .quantity,
             decimals: 0,
             chartFromZero: false),
        Info(id: "hrv_sdnn",
             title: "HRV (SDNN)",
             unitSuffix: "ms",
             symbolName: "waveform.path.ecg",
             kind: .quantity,
             decimals: 0,
             chartFromZero: true),
        Info(id: "hrv_rmssd",
             title: "HRV (RMSSD)",
             unitSuffix: "ms",
             symbolName: "waveform.path.ecg.rectangle",
             kind: .quantity,
             decimals: 0,
             chartFromZero: true),

        // ——— 呼吸 / 血氧 / 腕温 ———
        Info(id: "respiratory_rate",
             title: "呼吸频率",
             unitSuffix: "次/分",
             symbolName: "lungs.fill",
             kind: .quantity,
             decimals: 1,
             chartFromZero: false),
        Info(id: "oxygen_saturation",
             title: "血氧",
             unitSuffix: "%",
             symbolName: "drop.fill",
             kind: .quantity,
             decimals: 0,
             chartFromZero: false),
        Info(id: "sleeping_wrist_temperature",
             title: "睡眠腕温",
             unitSuffix: "°C",
             symbolName: "thermometer.medium",
             kind: .quantity,
             decimals: 2,
             chartFromZero: false),

        // ——— 睡眠（枚举型）———
        Info(id: "sleep_analysis",
             title: "睡眠",
             unitSuffix: "",
             symbolName: "bed.double.fill",
             kind: .category,
             decimals: 0,
             chartFromZero: false),

        // ——— 可选：默认关闭，用户可在设置里打开 ———
        Info(id: "active_energy",
             title: "活动能量",
             unitSuffix: "kcal",
             symbolName: "flame.fill",
             kind: .quantity,
             decimals: 1,
             chartFromZero: true),
        Info(id: "exercise_time",
             title: "锻炼时间",
             unitSuffix: "分钟",
             symbolName: "figure.run",
             kind: .quantity,
             decimals: 0,
             chartFromZero: true),
        Info(id: "vo2_max",
             title: "最大摄氧量",
             unitSuffix: "mL/kg·min",
             symbolName: "chart.line.uptrend.xyaxis",
             kind: .quantity,
             decimals: 1,
             chartFromZero: false)
    ]

    /// ⚠️ 刻意**不用** `Dictionary(uniqueKeysWithValues:)`：
    /// 它在遇到重复 id 时会**直接 trap**，而这是静态属性 → 一崩就是"启动即崩"，
    /// 且崩在用户设备上、看不出原因。用循环覆盖，重复 id 只是后者胜出。
    /// 重复 id 由 `ci/verify-project.sh` 在校验阶段拦下，不需要靠运行时崩。
    private static let index: [String: Info] = {
        var result: [String: Info] = [:]
        for item in all { result[item.id] = item }
        return result
    }()

    static func info(id: String) -> Info? { index[id] }

    /// 取展示信息，取不到就兜底。UI 层统一用这个，不要到处写 `??`。
    static func infoOrFallback(id: String) -> Info { index[id] ?? .fallback(id: id) }

    /// 只要数值型指标（图表选择器、折线图）
    static var quantityMetrics: [Info] { all.filter { $0.kind == .quantity } }

    /// 只要枚举型指标（睡眠）
    static var categoryMetrics: [Info] { all.filter { $0.kind == .category } }

    // MARK: - 睡眠阶段

    /// 睡眠阶段的原始值。
    ///
    /// ⚠️ 这里刻意用**整数**而不是 `HKCategoryValueSleepAnalysis`：
    /// 本文件要编进 iOS app，而 iOS app **不引入 HealthKit**（不需要那个权限）。
    ///
    /// 数值取自 HealthKit 的 `HKCategoryValueSleepAnalysis`：
    /// - 0 = inBed
    /// - 1 = asleep（**已被 Apple 废弃**，新数据不会再写这个值，但要能显示旧数据）
    /// - 2 = awake
    /// - 3 = asleepCore
    /// - 4 = asleepDeep
    /// - 5 = asleepREM
    /// - 6 = asleepUnspecified
    ///
    /// 手表端的 `MetricCatalog.sleepLabel` 直接转调这里，保证两边文案一致。
    static let sleepInBed = 0
    static let sleepAsleepDeprecated = 1
    static let sleepAwake = 2
    static let sleepCore = 3
    static let sleepDeep = 4
    static let sleepREM = 5
    static let sleepUnspecified = 6

    /// 睡眠在图表里的堆叠顺序：**从深到浅，最后才是清醒与卧床**。
    /// 这样一眼就能看出"深睡够不够"，而不是被卧床时长占满整条。
    static let sleepStageOrder: [Int] = [
        sleepDeep, sleepCore, sleepREM, sleepUnspecified, sleepAwake, sleepInBed
    ]

    /// 枚举型指标的取值翻译。`metricID` 不匹配就如实回显原始值，
    /// 不要假装知道它是什么意思。
    static func categoryLabel(metricID: String, raw: Int) -> String {
        guard metricID == "sleep_analysis" else { return "\(raw)" }
        switch raw {
        case sleepInBed:            return "卧床"
        case sleepAsleepDeprecated: return "睡眠"
        case sleepAwake:            return "清醒"
        case sleepCore:             return "核心睡眠"
        case sleepDeep:             return "深睡"
        case sleepREM:              return "快速眼动"
        case sleepUnspecified:      return "睡眠"
        default:                    return "未知"
        }
    }

    /// 数值的展示字符串。**手表列表、iPhone 概览、图表标注全部走这一个函数**，
    /// 避免"手表显示 62、手机显示 62.0"这类不一致。
    static func formatted(metricID: String, value: Double) -> String {
        let info = infoOrFallback(id: metricID)
        return String(format: "%.\(info.decimals)f", value)
    }
}
