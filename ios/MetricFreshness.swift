import Foundation
import SwiftData

/// 一个指标的「采集节奏」—— 回答"它**多久**来一条数据、最近还来不来"。
///
/// ## 🔴 为什么必须用中位数，不能用平均值
/// 一次"手表没戴"的长间隔（几小时、甚至过夜）就能把平均值拉到毫无意义的量级
/// —— 平均值会告诉你"平均 40 分钟一条"，而真相是"绝大多数几十秒一条，
/// 只是中间断了两小时"。**中位数才是"典型节奏"。**
/// 最小/最大间隔一起给出来，是为了让"中位数有没有掩盖极端值"这件事一眼可见。
struct MetricFreshness: Identifiable, Sendable {

    var id: String { metricID }

    let metricID: String
    let title: String

    /// 最近有数据的时间（`nil` = 一条都没有）
    let latest: Date?
    /// 最早一条的时间
    let earliest: Date?

    /// 用 `fetchCount` 拿的三个计数（都走索引，很便宜）
    let countLastHour: Int
    let countLastDay: Int
    let countTotal: Int

    /// 相邻样本时间差的**中位数**（秒）—— **这就是"多久更新一次"**
    let medianInterval: TimeInterval?
    let minInterval: TimeInterval?
    let maxInterval: TimeInterval?

    /// 参与算间隔的样本数
    let intervalSampleCount: Int
    /// 因为撞到抓取上限而**没有**参与统计 —— 必须如实回报
    /// （坑 #33：静默截断比报错更糟，用户会以为"数据就这么多"）
    let intervalTruncated: Bool

    /// 距今多久（给界面用；`nil` = 没有数据）
    func age(now: Date) -> TimeInterval? {
        latest.map { now.timeIntervalSince($0) }
    }
}

// MARK: - 抓取预算

extension PhoneStore {

    /// 算「中位间隔」时往回看多久。
    ///
    /// 6 小时是刻意的折中：**够长**（心率 5 秒一条能拿到几千个间隔，中位数很稳），
    /// **又够短**（不用把 7 天的对象全取出来 —— 心率 7 天最坏十几万条）。
    static let freshnessIntervalWindowHours = 6

    /// 参与算间隔的样本数上限。撞到了会**如实标记**，不静默丢。
    static let freshnessIntervalSampleCap = 4000

    /// 每个指标的采集节奏。
    ///
    /// ## 三次查询各管什么
    /// | 要的 | 怎么拿 | 成本 |
    /// |---|---|---|
    /// | 最新 / 最早 | 带 `fetchLimit: 1` 的排序查询 | 走索引，很便宜 |
    /// | 1 小时 / 24 小时 / 总条数 | `fetchCount` | 走索引，很便宜 |
    /// | **中位间隔** | 把**最近 6 小时**的时间戳取出来排序 | 唯一较贵的一步，所以有窗口 + 上限 |
    func metricFreshness(now: Date = Date()) throws -> [MetricFreshness] {
        var rows = MetricDisplay.all.map { info in
            try freshness(metricID: info.id, title: info.title, now: now)
        }
        // 心跳序列是**另一张表**（系统产生，不是我们采的指标），
        // 但它同样要回答"系统多久产生一条" —— 复用同一套算法。
        rows.append(try seriesFreshness(now: now))
        return rows
    }

    // MARK: 普通指标（PhoneSample）

    private func freshness(metricID id: String, title: String, now: Date) throws -> MetricFreshness {
        let hourAgo = now.addingTimeInterval(-3600)
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        let windowStart = now.addingTimeInterval(-Double(Self.freshnessIntervalWindowHours) * 3600)

        let total = (try? modelContext.fetchCount(
            FetchDescriptor<PhoneSample>(predicate: #Predicate { $0.metricID == id })
        )) ?? 0
        let lastHour = (try? modelContext.fetchCount(
            FetchDescriptor<PhoneSample>(
                predicate: #Predicate { $0.metricID == id && $0.startDate >= hourAgo }
            )
        )) ?? 0
        let lastDay = (try? modelContext.fetchCount(
            FetchDescriptor<PhoneSample>(
                predicate: #Predicate { $0.metricID == id && $0.startDate >= dayAgo }
            )
        )) ?? 0

        var latestDescriptor = FetchDescriptor<PhoneSample>(
            predicate: #Predicate { $0.metricID == id },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        let latest = (try? modelContext.fetch(latestDescriptor))?.first?.startDate

        var earliestDescriptor = FetchDescriptor<PhoneSample>(
            predicate: #Predicate { $0.metricID == id },
            sortBy: [SortDescriptor(\.startDate)]
        )
        earliestDescriptor.fetchLimit = 1
        let earliest = (try? modelContext.fetch(earliestDescriptor))?.first?.startDate

        // 中位间隔：升序取窗口内的样本 —— 升序 + 上限意味着**丢的是窗口尾部**，
        // 而相邻差全是真实的（不会因为截断凭空多出一个假间隔）。
        var windowDescriptor = FetchDescriptor<PhoneSample>(
            predicate: #Predicate { $0.metricID == id && $0.startDate >= windowStart },
            sortBy: [SortDescriptor(\.startDate)]
        )
        windowDescriptor.fetchLimit = Self.freshnessIntervalSampleCap
        let dates = ((try? modelContext.fetch(windowDescriptor)) ?? []).map(\.startDate)

        return MetricFreshness(metricID: id,
                               title: title,
                               latest: latest,
                               earliest: earliest,
                               countLastHour: lastHour,
                               countLastDay: lastDay,
                               countTotal: total,
                               medianInterval: Self.medianInterval(of: dates),
                               minInterval: Self.intervalStats(dates).min,
                               maxInterval: Self.intervalStats(dates).max,
                               intervalSampleCount: dates.count,
                               intervalTruncated: dates.count >= Self.freshnessIntervalSampleCap)
    }

    // MARK: 心跳序列（PhoneHeartbeatSeries）

    /// "系统多久产生一条心跳序列"。
    ///
    /// 窗口刻意用**7 天**而不是 6 小时：系统一天可能只产生几条序列，
    /// 6 小时里往往一条都没有 —— 那样中位间隔永远是空的。
    /// ⚠️ 这也意味着这一行的窗口和别的行**不一样**，界面上要标出来。
    private func seriesFreshness(now: Date) throws -> MetricFreshness {
        let hourAgo = now.addingTimeInterval(-3600)
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        let windowStart = now.addingTimeInterval(-7 * 24 * 3600)

        let total = (try? modelContext.fetchCount(FetchDescriptor<PhoneHeartbeatSeries>())) ?? 0
        let lastHour = (try? modelContext.fetchCount(
            FetchDescriptor<PhoneHeartbeatSeries>(predicate: #Predicate { $0.startDate >= hourAgo })
        )) ?? 0
        let lastDay = (try? modelContext.fetchCount(
            FetchDescriptor<PhoneHeartbeatSeries>(predicate: #Predicate { $0.startDate >= dayAgo })
        )) ?? 0

        var latestDescriptor = FetchDescriptor<PhoneHeartbeatSeries>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        let latest = (try? modelContext.fetch(latestDescriptor))?.first?.startDate

        var earliestDescriptor = FetchDescriptor<PhoneHeartbeatSeries>(
            sortBy: [SortDescriptor(\.startDate)]
        )
        earliestDescriptor.fetchLimit = 1
        let earliest = (try? modelContext.fetch(earliestDescriptor))?.first?.startDate

        let dates = ((try? modelContext.fetch(
            FetchDescriptor<PhoneHeartbeatSeries>(
                predicate: #Predicate { $0.startDate >= windowStart },
                sortBy: [SortDescriptor(\.startDate)]
            )
        )) ?? []).map(\.startDate)
        let stats = Self.intervalStats(dates)

        return MetricFreshness(metricID: "heartbeat_series",
                               title: "心跳序列（系统产生）",
                               latest: latest,
                               earliest: earliest,
                               countLastHour: lastHour,
                               countLastDay: lastDay,
                               countTotal: total,
                               medianInterval: Self.medianInterval(of: dates),
                               minInterval: stats.min,
                               maxInterval: stats.max,
                               intervalSampleCount: dates.count,
                               intervalTruncated: false)
    }

    // MARK: 间隔统计

    /// 相邻样本的时间差（秒）。样本少于 2 个时返回空 —— **没有间隔可算**，
    /// 而不是"间隔是 0"（0 会被当成一个真实测量值）。
    static func intervals(of dates: [Date]) -> [TimeInterval] {
        guard dates.count >= 2 else { return [] }
        var result: [TimeInterval] = []
        result.reserveCapacity(dates.count - 1)
        for index in 1..<dates.count {
            result.append(dates[index].timeIntervalSince(dates[index - 1]))
        }
        return result
    }

    static func medianInterval(of dates: [Date]) -> TimeInterval? { median(intervals(of: dates)) }

    static func intervalStats(_ dates: [Date]) -> (min: TimeInterval?, max: TimeInterval?) {
        let values = intervals(of: dates)
        return (values.min(), values.max())
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

// MARK: - 可复制的文本

extension MetricFreshness {

    /// 把整张表导成**可复制的文本**。
    ///
    /// 需求方要"能看到"，而**贴文本比截图有用**：拿到这几列之后就能直接判断
    /// "哪个指标根本没在更新""哪个是几分钟一条"，据此调门槛。
    static func textReport(_ rows: [MetricFreshness], now: Date) -> String {
        var lines: [String] = []
        lines.append("长明护心 · 各指标采集节奏")
        lines.append("导出时间：\(Self.stamp(now))")
        lines.append("中位间隔 = 相邻两条的典型时间差（窗口 6 小时；心跳序列为 7 天）")
        lines.append("")
        lines.append("指标\t最新一条\t距今\t中位间隔\t最小\t最大\t近1h\t近24h\t总条数\t样本数\t截断")
        for row in rows {
            let values: [String] = [
                row.title,
                row.latest.map(Self.stamp) ?? "—",
                row.age(now: now).map { Self.duration($0) } ?? "—",
                row.medianInterval.map(Self.duration) ?? "—",
                row.minInterval.map(Self.duration) ?? "—",
                row.maxInterval.map(Self.duration) ?? "—",
                "\(row.countLastHour)",
                "\(row.countLastDay)",
                "\(row.countTotal)",
                "\(row.intervalSampleCount)",
                row.intervalTruncated ? "是" : "否",
            ]
            lines.append(values.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 秒 → "3 分 20 秒" 这种。刻意**不给小数**：这是节奏，不是测量值。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 3600 {
            let minutes = total / 60, rest = total % 60
            return rest == 0 ? "\(minutes) 分" : "\(minutes) 分 \(rest) 秒"
        }
        if total < 86_400 {
            let hours = total / 3600, minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
        }
        let days = total / 86_400, hours = (total % 86_400) / 3600
        return hours == 0 ? "\(days) 天" : "\(days) 天 \(hours) 小时"
    }
}
