import Foundation
import HealthKit

// MARK: - 探针结果类型

/// 采样密度探针：最近 N 小时里**到底有多少条、间隔多密**。
///
/// 这是回答「S12 宣称的全天每 5 秒一次心率，到底有没有进 HealthKit」的唯一办法
/// —— 只有直接问 HealthKit，不能看我们自己的库（我们库里本来就只有同步过的）。
struct CadenceProbe: Sendable {
    let hours: Int
    let sampleCount: Int
    /// 相邻样本时间戳差值的中位数（秒）。5 秒采样的话这里应该接近 5。
    let medianGap: TimeInterval?
    let minGap: TimeInterval?
    let maxGap: TimeInterval?
    let latest: Date?
}

/// HRV (RMSSD) 探针。
///
/// ⚠️ 关键的未知数：Apple **从未确认** Apple Watch 会往 `heartRateVariabilityRMSSD` 写数据。
/// 这个类型是 iOS/watchOS 27 新加的，文档只有符号声明、没有 Discussion。
/// `typeAvailable == true && sampleCount == 0` 的含义是「类型在、但设备没写」。
struct RmssdProbe: Sendable {
    let typeAvailable: Bool
    let sampleCount: Int
    let latest: Date?
}

/// 某一天的序列条数。
struct DailySeriesCount: Sendable {
    let day: Date
    let count: Int
}

/// 心跳序列（RR 间期）探针。
///
/// ⚠️ 预期结果是 **seriesCount == 0**：`HKHeartbeatSeriesSample` 的用途是让
/// **第三方 app 自己写入**（配合 `HKHeartbeatSeriesBuilder`，需要 workout session），
/// Apple 官方文档从未说过手表会自动产生它。Apple 的传感器内部确实算逐拍间隔，
/// 但只把算好的 HRV 值暴露出来。这里做成可验证的，而不是靠推断下结论。
struct HeartbeatSeriesProbe: Sendable {
    let days: Int
    let seriesCount: Int
    let latestSampleDate: Date?
    /// **最早**一条序列的时间。
    ///
    /// 这个字段是为了回答一个具体的因果问题：「现在能看到数据了，
    /// 是因为补了读权限，还是因为打开了房颤历史？」
    ///
    /// 判据：**读权限只影响"我们能不能看见"，不影响手表写不写。**
    /// 所以只要最早那条**早于**用户打开房颤历史的时间，就说明手表一直在写，
    /// 之前看不到纯粹是没权限。
    let earliestSampleDate: Date?
    /// 近 N 天**每天**的序列条数（旧 → 新，没有数据的日子补 0）。
    ///
    /// 为什么不只给"最早/最新"：只给两端的话，看不出中间是"一直是 0 然后某天突然开始"，
    /// 还是"稀稀拉拉一直有"。**这个分布才是判定的直接证据** ——
    /// 数据只从某天开始有 = 那天开了某个开关。
    let dailyCounts: [DailySeriesCount]
    /// 最新一条序列里的拍数
    let beatsInLatestSeries: Int?
    /// 相邻拍时间戳差值的中位数，换算成毫秒 —— 这就是 RR 间期
    let medianRRms: Double?
}

/// HealthKit 侧的全部探针结果
struct HealthKitProbeReport: Sendable {
    let catalogMetricCount: Int
    let heartRate: CadenceProbe?
    let rmssd: RmssdProbe
    let heartbeat: HeartbeatSeriesProbe
    /// 单个探针失败时记下来，不影响其它探针（不追求完整性原则）
    let errors: [String]
}

// MARK: - 探针本体

/// 直接向 HealthKit 提问的探针集合。
///
/// 与 `HealthSyncEngine` 的区别：同步引擎关心「把增量搬进本地库」，
/// 探针关心「**HealthKit 里究竟有什么**」。两者不能互相替代 ——
/// 本地库里是 0，可能是没授权、可能是同步没跑、也可能是设备根本没这个数据，
/// 只有直接问 HealthKit 才能把「类型不存在」和「类型存在但没数据」区分开。
actor HealthProbe {

    static let shared = HealthProbe()

    private let store = HKHealthStore()

    // MARK: 对外入口

    /// 跑齐所有探针。任何一个失败都不影响其它（符合「不追求完整性」原则）。
    func runAll(heartRateHours: Int, days: Int) async -> HealthKitProbeReport {
        var errors: [String] = []

        let heartRate = await heartRateCadence(hours: heartRateHours)
        if heartRate == nil { errors.append("心率密度探针失败（类型拿不到）") }

        let rmssd = await rmssdProbe(days: days)

        let heartbeat = await heartbeatSeries(days: days)

        return HealthKitProbeReport(
            catalogMetricCount: MetricCatalog.all.count,
            heartRate: heartRate,
            rmssd: rmssd,
            heartbeat: heartbeat,
            errors: errors
        )
    }

    // MARK: 心率密度

    /// 最近 N 小时的心率样本数与间隔分布。
    ///
    /// 取回样本再自己算间隔，而不是用统计查询 —— 因为我们要的恰恰是
    /// **间隔的分布**（中位数），这只能从原始时间戳算。
    /// 6 小时最坏 4320 条，一次性查询在手表上可以接受（这是手动触发的诊断，不是后台任务）。
    func heartRateCadence(hours: Int) async -> CadenceProbe? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let from = Date().addingTimeInterval(-Double(hours) * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: nil, options: .strictStartDate)
        let samples = await fetch(type: type, predicate: predicate, limit: 20_000, ascending: true)

        let sorted = samples.map(\.startDate).sorted()
        var gaps: [TimeInterval] = []
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                gaps.append(sorted[i].timeIntervalSince(sorted[i - 1]))
            }
        }
        return CadenceProbe(hours: hours,
                            sampleCount: sorted.count,
                            medianGap: Self.median(gaps),
                            minGap: gaps.min(),
                            maxGap: gaps.max(),
                            latest: sorted.last)
    }

    // MARK: RMSSD

    func rmssdProbe(days: Int) async -> RmssdProbe {
        // 用 MetricCatalog 里那个「原始字符串构造」的标识符 —— 这是全 app 唯一的来源，
        // 避免两处字符串写得不一致。
        guard let type = HKQuantityType.quantityType(forIdentifier: MetricCatalog.rmssdIdentifier) else {
            return RmssdProbe(typeAvailable: false, sampleCount: 0, latest: nil)
        }
        let from = Date().addingTimeInterval(-Double(days) * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: nil, options: .strictStartDate)
        let samples = await fetch(type: type, predicate: predicate, limit: HKObjectQueryNoLimit, ascending: false)
        return RmssdProbe(typeAvailable: true,
                          sampleCount: samples.count,
                          latest: samples.first?.startDate)
    }

    // MARK: 心跳序列（RR 间期）

    func heartbeatSeries(days: Int) async -> HeartbeatSeriesProbe {
        // ⚠️ 用 `MetricCatalog.heartbeatSeriesType` 而不是就地 `HKSeriesType.heartbeat()`：
        //    这个类型**同时**是"读授权的类型"和"要查的类型"，
        //    两处各写一遍就可能出现「申请了 A、查的是 B」——而那种情况下查询返回空数组，
        //    表现成"设备没数据"，完全看不出来。
        let type = MetricCatalog.heartbeatSeriesType
        let from = Date().addingTimeInterval(-Double(days) * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: nil, options: .strictStartDate)
        let samples = await fetch(type: type, predicate: predicate, limit: HKObjectQueryNoLimit, ascending: false)

        // 「现在能看到数据，是补了读权限还是开了房颤历史」靠这两个数回答，见结构体注释
        let earliest = samples.map(\.startDate).min()
        let daily = Self.dailyCounts(dates: samples.map(\.startDate), days: days)

        guard let latest = samples.first as? HKHeartbeatSeriesSample else {
            return HeartbeatSeriesProbe(days: days,
                                        seriesCount: samples.count,
                                        latestSampleDate: samples.first?.startDate,
                                        earliestSampleDate: earliest,
                                        dailyCounts: daily,
                                        beatsInLatestSeries: nil,
                                        medianRRms: nil)
        }

        let beats = await beatTimestamps(of: latest)
        var rr: [Double] = []
        if beats.count >= 2 {
            for i in 1..<beats.count {
                rr.append((beats[i] - beats[i - 1]) * 1000)   // 秒 → 毫秒
            }
        }
        return HeartbeatSeriesProbe(days: days,
                                    seriesCount: samples.count,
                                    latestSampleDate: latest.startDate,
                                    earliestSampleDate: earliest,
                                    dailyCounts: daily,
                                    beatsInLatestSeries: beats.count,
                                    medianRRms: Self.median(rr))
    }

    /// 按**本地自然日**分桶，没有数据的日子**补 0**。
    ///
    /// ⚠️ 补 0 是关键：只列"有数据的那几天"会跳过"哪几天是空的"，
    /// 而那恰恰是判断"某天打开了某个开关"的依据。
    /// 用 `Calendar.startOfDay` 而不是 epoch 取模 —— 后者算出来的是 UTC 午夜，
    /// 在东八区就成了早上 8 点（同一个坑在图表侧也踩过）。
    private static func dailyCounts(dates: [Date], days: Int) -> [DailySeriesCount] {
        let calendar = Calendar.current
        var buckets: [Date: Int] = [:]
        for date in dates {
            buckets[calendar.startOfDay(for: date), default: 0] += 1
        }

        let today = calendar.startOfDay(for: .now)
        var result: [DailySeriesCount] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            result.append(DailySeriesCount(day: day, count: buckets[day] ?? 0))
        }
        return result
    }

    // MARK: 底层查询

    /// 一次性 `HKSampleQuery` 的 async 包装。
    private func fetch(type: HKSampleType,
                       predicate: NSPredicate?,
                       limit: Int,
                       ascending: Bool) async -> [HKSample] {
        await withCheckedContinuation { cont in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)]
            let query = HKSampleQuery(sampleType: type,
                                      predicate: predicate,
                                      limit: limit,
                                      sortDescriptors: sort) { _, samples, _ in
                // 没授权时这里返回的是空数组而不是错误 —— 所以「0 条」同时意味着
                // 「没数据」或「没授权」，界面上必须如实说明这一点。
                cont.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }

    /// 读出一条心跳序列里的**逐拍时间戳**（相对序列起点的秒数）。
    ///
    /// ⚠️ dataHandler 是**逐拍回调**的，`done` 为 true 时才是最后一次。
    /// continuation 必须**恰好 resume 一次**，所以用 `finished` 守住，
    /// 并且 `error != nil` 时也要 resume（否则会永久挂住）。
    private func beatTimestamps(of sample: HKHeartbeatSeriesSample) async -> [TimeInterval] {
        await withCheckedContinuation { cont in
            var stamps: [TimeInterval] = []
            var finished = false

            let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceStart, _, done, error in
                if error == nil {
                    stamps.append(timeSinceStart)
                }
                if (done || error != nil) && !finished {
                    finished = true
                    cont.resume(returning: stamps)
                }
            }
            store.execute(query)
        }
    }

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
