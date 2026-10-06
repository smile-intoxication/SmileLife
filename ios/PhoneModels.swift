import Foundation
import SwiftData

/// iPhone 端的一条样本。
///
/// ## 为什么和手表端的 `SampleRecord` 是两个模型（而不是共享一个）
/// 两者是**不同的数据**，只是字段碰巧相似：
/// - 手表端那份是"我采集到、7 天后就删"的缓冲；
/// - 手机这份是"长期档案"，保留 180 天原始样本 + **永久**保留汇总桶。
/// 硬凑成一个模型的话，两边任何一方加字段都会牵动另一方（而它们编译在不同的 target 里，
/// 甚至可能版本不同步）。字段对齐由 `shared/WatchWire.swift` 的 `UploadPayload` 保证。
@Model
final class PhoneSample {

    /// 索引：手机上的行数远多于手表（长期档案，最坏 50 万行/月）。
    /// - `[metricID, startDate]`：画图表时"取某指标某时间段"的查询全靠它。
    ///   没有这个索引，每次切时间范围都会**全表扫描**几百万行。
    /// - `[startDate]`：保留策略的按日期删除。
    /// - `[receivedAt]`："最后一次收到数据是什么时候"要按它取最新一条。
    ///   不加这个索引的话，状态页每次刷新都要对几百万行做一次排序
    ///   —— 表现是"打开状态页要等好几秒"，而数据本身完全正确。
    #Index<PhoneSample>([\.metricID, \.startDate], [\.startDate], [\.receivedAt])

    /// 主键 = HealthKit 的 `HKObject.uuid`。用 `.unique` 让**重复投递变成更新**。
    ///
    /// ⚠️ 这是整条链路能"至少一次投递"的前提：手表可能重发，
    /// 手机必须天然幂等，否则每次重发都会多出一条重复数据。
    @Attribute(.unique) var uuid: UUID

    var metricID: String
    var startDate: Date
    var endDate: Date

    var value: Double?
    var categoryValue: Int?
    var unitString: String?

    // ——— 来源追踪 ———
    var sourceBundleID: String?
    var sourceName: String?
    var deviceName: String?
    var deviceModel: String?
    var deviceManufacturer: String?

    /// 手表**落库**的时间（不是采样时间）
    var ingestedAt: Date

    /// **本机收到**的时间。
    ///
    /// 和 `ingestedAt` 的差就是「手表采集 → 手机可见」的端到端延迟。
    /// 这个字段只存在于手机端的手表里是刻意的：它是"传输链路"的观测点，
    /// 手表自己不需要知道。
    var receivedAt: Date

    init(payload: UploadPayload, receivedAt: Date = .now) {
        self.uuid = payload.uuid
        self.metricID = payload.metricID
        self.startDate = payload.startDate
        self.endDate = payload.endDate
        self.value = payload.value
        self.categoryValue = payload.categoryValue
        self.unitString = payload.unitString
        self.sourceBundleID = payload.sourceBundleID
        self.sourceName = payload.sourceName
        self.deviceName = payload.deviceName
        self.deviceModel = payload.deviceModel
        self.deviceManufacturer = payload.deviceManufacturer
        self.ingestedAt = payload.ingestedAt
        self.receivedAt = receivedAt
    }

    /// 重复投递时用新载荷覆盖旧值。
    ///
    /// 为什么允许覆盖而不是"已存在就跳过"：静息心率 / 步行心率会被系统**回填修正**，
    /// 值会变。已存在就跳过的话，手机上会永远停在第一次收到的那个值。
    func apply(_ payload: UploadPayload, receivedAt: Date) {
        self.startDate = payload.startDate
        self.endDate = payload.endDate
        self.value = payload.value
        self.categoryValue = payload.categoryValue
        self.unitString = payload.unitString
        self.sourceBundleID = payload.sourceBundleID
        self.sourceName = payload.sourceName
        self.deviceName = payload.deviceName
        self.deviceModel = payload.deviceModel
        self.deviceManufacturer = payload.deviceManufacturer
        self.ingestedAt = payload.ingestedAt
        self.receivedAt = receivedAt
    }
}

/// 15 分钟粒度的汇总桶。**图表读的是这张表，不是原始样本。**
///
/// ## 为什么必须有这一层
/// 最坏情况（S12 全天每 5 秒一条心率）是 `17,280 条/天 ≈ 52 万条/月`。
/// 直接拿原始样本画"最近 30 天"的折线：
/// ① 要一次查出 50 万行，手机上会明显卡顿甚至被系统杀掉；
/// ② 就算查出来了，屏幕上也画不出 50 万个点，最终还是要聚合。
/// 所以聚合**在落库时就做掉**，图表只读这张小表
/// （30 天 = 2880 行，90 天 = 8640 行）。
///
/// ## 为什么这不违反「不追求完整性」
/// 那条原则说的是**采集**：有的就收集、没有就算了，不回填、不重试。
/// 这里说的是**存储与展示**：手机是长期档案，原始样本要留，
/// 但图表得有能读懂的那一层。汇总桶是**派生数据**，
/// 随时可以从原始样本重算 —— 它不承载任何"只有它才有"的信息。
///
/// ## 保留策略上的分工
/// - 原始样本：`PhoneStoragePolicy.rawRetentionDays`（180 天）
/// - 汇总桶：**不删**（一年也才 3.5 万行/指标），这是真正的"长期趋势"
@Model
final class PhoneRollup {

    #Index<PhoneRollup>([\.metricID, \.bucketStart])

    /// `"<metricID>@<epoch 秒>"`。
    ///
    /// 为什么用合成字符串而不是 (metricID, bucketStart) 两个字段：
    /// SwiftData 的 `@Attribute(.unique)` 只支持**单个**属性，
    /// 没有复合唯一约束。用合成键才能让"同一指标的同一时间桶"天然只有一行。
    @Attribute(.unique) var key: String

    var metricID: String
    /// 桶的起点（已按 `bucketMinutes` 对齐）
    var bucketStart: Date
    var count: Int
    /// 桶内所有样本值之和。存 sum 而不是存 average，
    /// 因为**合并两个桶**时（把 15 分钟桶合成 1 小时桶）只有 sum 和 count 是可加的。
    var sum: Double
    var minValue: Double
    var maxValue: Double
    var computedAt: Date

    init(key: String,
         metricID: String,
         bucketStart: Date,
         count: Int,
         sum: Double,
         minValue: Double,
         maxValue: Double,
         computedAt: Date = .now) {
        self.key = key
        self.metricID = metricID
        self.bucketStart = bucketStart
        self.count = count
        self.sum = sum
        self.minValue = minValue
        self.maxValue = maxValue
        self.computedAt = computedAt
    }
}

/// 手机端的存储策略。
///
/// ⚠️ 和手表端的 `StoragePolicy`（7 天）是**两个不同的数字**，不要合并：
/// 手表是"磁盘紧张的采集器"，手机是"长期档案"。手机端刻意留得长，
/// 因为"看长期趋势"正是做手机端图表的目的。
enum PhoneStoragePolicy {

    /// 原始样本保留天数。
    ///
    /// 180 天是个取舍：再长的话，一年 600 万行对手机来说太重
    /// （而且 Apple Health 里本来就有原件）。
    /// **汇总桶不受这个限制**，所以"半年以上的趋势"仍然看得到。
    static let rawRetentionDays = 180

    /// 汇总桶粒度。15 分钟是"够细到能看出一次运动、够粗到行数可控"的折中。
    static let bucketMinutes = 15

    static var bucketSeconds: TimeInterval { TimeInterval(bucketMinutes * 60) }
}

// MARK: - 桶对齐

/// 时间桶的对齐与键构造。
enum BucketMath {

    /// 把时间向下对齐到 `seconds` 的整数倍。
    ///
    /// 刻意用 **Unix epoch 取模**，不用 `Calendar`：
    /// `Calendar` 的 `dateInterval(of: .minute...)` 会受时区、夏令时、
    /// 以及用户改过时间的影响，而汇总桶的键**一旦算出来就写进数据库**了，
    /// 用日历算会让历史桶和新桶对不齐（同一段时间出现两个桶）。
    /// epoch 取模在所有真实时区（偏移都是 15 分钟的整数倍）下都对齐到整刻。
    static func floor(_ date: Date, seconds: TimeInterval) -> Date {
        guard seconds > 0 else { return date }
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / seconds).rounded(.down) * seconds)
    }

    static func key(metricID: String, bucketStart: Date) -> String {
        "\(metricID)@\(Int(bucketStart.timeIntervalSince1970))"
    }

    /// 一个 (指标, 时间) 落在哪个桶里。数值型才需要汇总桶。
    static func bucket(metricID: String, date: Date) -> (key: String, start: Date) {
        let start = floor(date, seconds: PhoneStoragePolicy.bucketSeconds)
        // 显式写成带标签的元组：裸的 `(x, y)` 依赖标签推断，
        // 没必要在返回值这里省这几个字符（CI 上抓不到，只能靠人看）。
        let storageKey = key(metricID: metricID, bucketStart: start)
        return (key: storageKey, start: start)
    }
}
