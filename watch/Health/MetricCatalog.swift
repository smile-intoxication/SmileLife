import Foundation
import HealthKit

/// 指标注册表：**一个指标 = 一条声明**。
///
/// 设计意图：同步引擎、本地库、快照、小组件全部只认 `MetricDescriptor`，
/// 所以新增一个指标只需要在 `MetricCatalog.all` 里加一行，全链路自动生效。
/// 不要为每个指标单独写逻辑——全量方案下那样会失控。
///
/// ## ⚠️ 展示字段（标题 / 单位 / SF Symbol / 小数位）**不在这个文件里**
/// 它们全部来自 `MetricDisplay`（`shared/MetricDisplay.swift`），那是
/// **跨设备共享的唯一定义处**：iPhone 也要用同一份，因为它收到的只有 `metricID`。
/// 如果在这里再写一遍，新增指标时漏改一处**不会编译报错**，
/// 表现是"手机上显示的指标名和手表上不一样"——这类漂移极难发现。
/// `ci/verify-project.sh` 会断言两边的 id 集合一致。
struct MetricDescriptor: Identifiable {

    /// 数值形态：决定怎么从 HKSample 里取值和单位。
    ///
    /// 注意这里**不带**小数位与中文标签——它们在 `MetricDisplay` 里，
    /// 避免"同一个指标的小数位在两处不一致"。
    enum ValueShape {
        /// 数值型，例如心率、血氧、HRV。带一个单位用于换算。
        case quantity(HKUnit)
        /// 枚举型，例如睡眠阶段。标签翻译见 `MetricDisplay.categoryLabel`。
        case category
    }

    /// 稳定标识。**会被写进本地库、anchor 记录、线协议和快照文件，一旦上线不要改。**
    let id: String
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
    ///
    /// ⚠️ 必须是 `var` 而不是 `let`：`let` 带初值会被排除在成员初始化器之外，
    /// 那样 `initialLookbackDays:` 就传不进来了（心率需要的正是这个）。
    var initialLookbackDays: Int = 7

    // ——— 展示字段：全部转发到 MetricDisplay，这里不存副本 ———

    var info: MetricDisplay.Info { MetricDisplay.infoOrFallback(id: id) }
    var title: String { info.title }
    var unitSuffix: String { info.unitSuffix }
    var symbolName: String { info.symbolName }
    /// 展示保留几位小数
    var decimals: Int { info.decimals }
}

/// 存储策略：**手表本地只保留最近 7 天**（已确认）。
///
/// ## 为什么 7 天是安全的
/// 最坏情况（S12 全天每 5 秒一条心率）：
/// `17,280 条/天 × 7 天 ≈ **12.1 万行**`，SwiftData 落盘大约几十 MB，
/// Apple Watch 完全放得下。而且**增量同步只拉新增样本**，
/// 不会因为本地行数多而变慢——所以"行数多"本身不是问题。
///
/// ## 长期档案在哪
/// **在 iPhone 上**。手表是"采集器 + 7 天缓冲"，手机是"长期档案 + 图表"。
/// 这正是手机端要有 15 分钟汇总桶的原因（原始样本会有几百万行，图表读不动）。
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

    private static let perMinute = HKUnit.count().unitDivided(by: .minute())

    // MARK: - 睡眠标签

    /// 睡眠阶段的中文标签。
    ///
    /// 实现**转调 `MetricDisplay`**，不自己写一份：iPhone 端渲染睡眠图表时
    /// 需要同样的标签，而它拿不到 `HKCategoryValueSleepAnalysis`
    /// （iOS app 不引入 HealthKit）。两处各写一份必然会漂移。
    static func sleepLabel(_ raw: Int) -> String {
        MetricDisplay.categoryLabel(metricID: "sleep_analysis", raw: raw)
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
                sampleType: rmssd,
                shape: .quantity(HKUnit.secondUnit(with: .milli)),
                enabledByDefault: true
            )
        ]
    }

    /// v1 只收「Apple Watch 独有产生」的指标 —— 这些才是手表端真正该负责的数据。
    /// 注意：走路稳定性 / 步态不对称 / 步速 等**是 iPhone 产生的**，不放进手表端。
    ///
    /// 结构是 `[心率族] + [watchOS 27 专属] + [其余]`，
    /// 拆成三段是因为 watchOS 27 专属那段需要**运行时**判断类型是否存在，
    /// 不能直接写在数组字面量里。
    static let all: [MetricDescriptor] =
        [
        // ——— 心率族（全部 ★Watch 独有）———
        MetricDescriptor(
            id: "heart_rate",
            sampleType: q(.heartRate)!,
            shape: .quantity(perMinute),
            enabledByDefault: true,
            initialLookbackDays: 1   // 高频数据，首次只回看 1 天（不追求完整性）
        ),
        MetricDescriptor(
            id: "resting_heart_rate",
            sampleType: q(.restingHeartRate)!,
            shape: .quantity(perMinute),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "walking_heart_rate_average",
            sampleType: q(.walkingHeartRateAverage)!,
            shape: .quantity(perMinute),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "hrv_sdnn",
            sampleType: q(.heartRateVariabilitySDNN)!,
            shape: .quantity(HKUnit.secondUnit(with: .milli)),
            enabledByDefault: true
        )
        ]
        + watchOS27Metrics
        + [
        // ——— 呼吸 / 血氧 / 腕温 ———
        MetricDescriptor(
            id: "respiratory_rate",
            sampleType: q(.respiratoryRate)!,
            shape: .quantity(perMinute),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "oxygen_saturation",
            sampleType: q(.oxygenSaturation)!,
            shape: .quantity(HKUnit.percent()),
            enabledByDefault: true
        ),
        MetricDescriptor(
            id: "sleeping_wrist_temperature",
            sampleType: q(.appleSleepingWristTemperature)!,
            shape: .quantity(HKUnit.degreeCelsius()),
            enabledByDefault: true
        ),

        // ——— 睡眠（枚举型）———
        MetricDescriptor(
            id: "sleep_analysis",
            sampleType: c(.sleepAnalysis)!,
            shape: .category,
            enabledByDefault: true
        ),

        // ——— 可选：默认关闭，用户可在设置里打开 ———
        MetricDescriptor(
            id: "active_energy",
            sampleType: q(.activeEnergyBurned)!,
            shape: .quantity(HKUnit.kilocalorie()),
            enabledByDefault: false
        ),
        MetricDescriptor(
            id: "exercise_time",
            sampleType: q(.appleExerciseTime)!,
            shape: .quantity(HKUnit.minute()),
            enabledByDefault: false
        ),
        MetricDescriptor(
            id: "vo2_max",
            sampleType: q(.vo2Max)!,
            shape: .quantity(vo2MaxUnit),
            enabledByDefault: false
        )
    ]

    /// 心跳序列（逐拍时间戳）的**读授权类型**。
    ///
    /// ## ⚠️ 为什么它必须单独列出来（这是一个真踩过的坑）
    /// 它**不是** `HKQuantityType`，而是 `HKSeriesType` —— 所以它进不了下面那张
    /// `all` 指标表（那张表是按 quantity/category 设计的），必须**单独**塞进 `readTypes`。
    ///
    /// 不加的后果极其隐蔽，因为 HealthKit 对**没授权的类型返回空数组、不报错**：
    /// 「0 条」看起来就像"这台设备不产生这个数据"，其实只是**我们从来没申请过读权限**。
    ///
    /// 实测踩到过：v1.7 的诊断界面报「近 7 天 0 条序列」，
    /// 差点据此得出「房颤历史关闭时 Apple Watch 不写逐拍数据」的结论 ——
    /// 而那个 0 完全不可信（当时根本没申请过这个权限）。
    /// 自检脚本第 15 节守着"探针查的类型必须在读授权集合里"。
    static let heartbeatSeriesType: HKSeriesType = HKSeriesType.heartbeat()

    /// 只读授权需要请求的类型集合
    static var readTypes: Set<HKObjectType> {
        var types = Set(all.map { $0.sampleType as HKObjectType })
        // 心跳序列不在上面的指标表里（它是 HKSeriesType，不是 HKQuantityType）
        types.insert(heartbeatSeriesType)
        return types
    }

    static func descriptor(id: String) -> MetricDescriptor? {
        all.first { $0.id == id }
    }
}
