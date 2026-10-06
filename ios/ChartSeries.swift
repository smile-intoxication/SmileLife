import Foundation

/// 图表的时间范围。
///
/// 每一档同时定义两件事：**查多久的数据** 和 **画多少个点**。
/// 两者必须一起定：只定范围的话，"最近 30 天"会查出 2880 个 15 分钟桶，
/// 直接画成折线在手机屏幕上是锯齿状的噪声，看不出趋势。
enum ChartRange: String, CaseIterable, Identifiable {

    case day, week, month, quarter, halfYear, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:      return "24 小时"
        case .week:     return "7 天"
        case .month:    return "30 天"
        case .quarter:  return "90 天"
        case .halfYear: return "180 天"
        case .all:      return "全部"
        }
    }

    /// 查多久。`nil` = 不设下限（有多少画多少）。
    var seconds: TimeInterval? {
        switch self {
        case .day:      return 24 * 3600
        case .week:     return 7 * 24 * 3600
        case .month:    return 30 * 24 * 3600
        case .quarter:  return 90 * 24 * 3600
        case .halfYear: return 180 * 24 * 3600
        case .all:      return nil
        }
    }

    /// 展示粒度：把 15 分钟的汇总桶**再合并**到这个粒度。
    ///
    /// 目标都是"一百多个点" —— 少于 50 个点看不出形状，
    /// 多于 400 个点在手机宽度上每个点不到 1 像素，纯噪声。
    var displayBucket: TimeInterval {
        switch self {
        case .day:      return 15 * 60          // 96 点
        case .week:     return 3600             // 168 点
        case .month:    return 3 * 3600         // 240 点
        case .quarter:  return 12 * 3600        // 180 点
        case .halfYear: return 24 * 3600        // 180 点
        case .all:      return 24 * 3600
        }
    }

    /// **柱状图**的聚合粒度。和上面的折线粒度是两回事，不能共用：
    /// 折线看的是"这段时间的值大约是多少"，柱状看的是"这段时间**累计**了多少"。
    /// 后者必须按自然时间段切 —— 否则"一天的活动能量"会被拆成 96 根 15 分钟的柱子，
    /// 日总量根本看不出来（而活动能量 / 锻炼时间的全部意义就是日总量）。
    var barBucket: TimeInterval {
        switch self {
        case .day:  return 3600        // 24 根，看一天之内的分布
        default:    return 24 * 3600   // 每天一根，看日总量
        }
    }

    /// 查询窗口。
    func window(now: Date = .now) -> (from: Date, to: Date) {
        // 上界往后挪一点：样本的 startDate 可能刚好等于"现在"，
        // 用严格小于会把最新一条排除掉，表现是"刚同步完但图表最后一段是空的"。
        let to = now.addingTimeInterval(60)
        guard let seconds else {
            // 「全部」用 epoch 起点而不是 distantPast：后者是公元 1 年，
            // 拿它去做桶对齐要处理一个巨大的负数时间戳，没必要。
            return (Date(timeIntervalSince1970: 0), to)
        }
        return (now.addingTimeInterval(-seconds), to)
    }
}

/// 折线上的一个点（已合并到展示粒度）。
struct ChartPoint: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    /// 桶内所有样本的**平均值**。心率这类指标看平均值才有意义，
    /// 看某一个瞬时值只会看到噪声。
    let average: Double
    let minValue: Double
    let maxValue: Double
    /// 这个点由多少条原始样本算出来。用于在界面上如实说明"这条线有多可信"。
    let count: Int
}

/// 一段睡眠（枚举型样本）。
struct SleepDayBar: Identifiable {
    var id: Date { day }
    /// 这一天的起点（按**结束时间**归属，见 `sleepDays`）
    let day: Date
    /// 阶段原始值 → 小时数
    let hoursByStage: [Int: Double]
    /// 真正"睡着"的时长（不含卧床与清醒）
    let totalSleepHours: Double
}

/// 睡眠图表里的**一段**（已经拍平成 `Chart` 能直接吃的形式）。
///
/// ## 为什么要先拍平，而不是在 `Chart { }` 里现算
/// 原来直接在 Chart 里写「`ForEach` 套 `ForEach` + `if let` + 字符串插值」，
/// 结果 **SwiftUI 的类型推导超时**，CI 报：
///
///     ios/ChartView.swift:129:41: error: the compiler is unable to type-check
///     this expression in reasonable time; try breaking up the expression
///     into distinct sub-expressions
///
/// 这类错误在 Windows 上完全看不出来（没有编译器），只能靠 CI 暴露。
/// 把数据先算成 `[SleepChartSegment]`（字段类型全部写死），
/// `Chart` 的 body 就只剩**一层 `ForEach` + 一个 `BarMark`**，类型推导瞬间结束。
///
/// 顺带的好处：视图层不再需要知道"哪些阶段要跳过"这种业务规则。
struct SleepChartSegment: Identifiable {
    let id: String
    /// 这一天（按**起床时间**归属，见 `ChartSeriesBuilder.sleepDays`）
    let day: Date
    /// 已经翻译好的阶段名（`Chart` 直接用，不再在视图里调函数）
    let stageLabel: String
    let hours: Double
}

struct ChartStats {
    let average: Double
    let minValue: Double
    let maxValue: Double
    let sampleCount: Int
}

/// 柱状图的一根柱子：某个时间块内的**累计值**。
///
/// 刻意叫 `total` 而不是平均值 —— 活动能量、锻炼时间的含义就是"一共多少"，
/// 用平均值画柱状图会得到一个和活动圆环完全对不上的数字。
struct BarPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let total: Double
    /// 这根柱子里有多少条原始样本。用于区分"这段时间真的没活动"和"没同步上"
    let sampleCount: Int
}

/// 柱状图的统计量。
struct BarStats {
    let total: Double
    let peak: Double
    /// 每根柱子的平均量（日粒度下就是"日均"）
    let perBar: Double
    let barCount: Int
}

enum ChartSeriesBuilder {

    /// 把 15 分钟的汇总桶合并到展示粒度。
    ///
    /// ⚠️ 合并必须用 **sum 与 count 相加**，不能对平均值再求平均：
    /// 每个桶里的样本数不一样（夜间静息时桶里可能只有 1 条，
    /// 运动时可能有 20 条），对平均值求平均会被稀疏的桶带偏。
    /// 这也是 `PhoneRollup` 存 `sum` 而不是只存 `average` 的原因。
    static func points(from rollups: [RollupPoint], displayBucket: TimeInterval) -> [ChartPoint] {
        guard !rollups.isEmpty else { return [] }

        var buckets: [Date: (sum: Double, count: Int, min: Double, max: Double)] = [:]
        for rollup in rollups {
            let key = BucketMath.floor(rollup.bucketStart, seconds: displayBucket)
            if var existing = buckets[key] {
                existing.sum += rollup.sum
                existing.count += rollup.count
                existing.min = Swift.min(existing.min, rollup.minValue)
                existing.max = Swift.max(existing.max, rollup.maxValue)
                buckets[key] = existing
            } else {
                buckets[key] = (sum: rollup.sum,
                                count: rollup.count,
                                min: rollup.minValue,
                                max: rollup.maxValue)
            }
        }

        return buckets.keys.sorted().map { key in
            // 显式写出标签：`??` 的右侧如果写成裸的 `(0, 0, 0, 0)`，
            // 就要依赖元组标签推断，没必要在这里省这几个字符。
            let entry = buckets[key] ?? (sum: 0, count: 0, min: 0, max: 0)
            return ChartPoint(date: key,
                              average: entry.count > 0 ? entry.sum / Double(entry.count) : 0,
                              minValue: entry.min,
                              maxValue: entry.max,
                              count: entry.count)
        }
    }

    /// 把 15 分钟汇总桶按**自然时间段**聚合成柱子（取和，不是取平均）。
    ///
    /// ⚠️ **"天"必须用 `Calendar.startOfDay` 对齐，不能用 epoch 取模**：
    /// epoch 对齐出来的"天"是 **UTC 午夜**，在东八区就是早上 8 点 ——
    /// 那样"一天的活动能量"实际统计的是 08:00–08:00，
    /// 和用户理解的"一天"（以及活动圆环的日界线）对不上，**而且完全是静默的**。
    /// 小时可以用 epoch 取模：所有真实时区的偏移都是 15 分钟的整数倍。
    static func bars(from rollups: [RollupPoint],
                     bucket: TimeInterval,
                     calendar: Calendar = .current) -> [BarPoint] {
        guard !rollups.isEmpty else { return [] }

        var totals: [Date: (total: Double, count: Int)] = [:]
        for rollup in rollups {
            let key = barKey(rollup.bucketStart, bucket: bucket, calendar: calendar)
            if var existing = totals[key] {
                existing.total += rollup.sum
                existing.count += rollup.count
                totals[key] = existing
            } else {
                totals[key] = (total: rollup.sum, count: rollup.count)
            }
        }

        return totals.keys.sorted().map { key in
            // 显式写标签，不依赖元组标签推断
            let entry = totals[key] ?? (total: 0, count: 0)
            return BarPoint(date: key, total: entry.total, sampleCount: entry.count)
        }
    }

    /// 柱子对齐：天走日历、小时走 epoch 取模（理由见 `bars` 的注释）。
    static func barKey(_ date: Date, bucket: TimeInterval, calendar: Calendar) -> Date {
        if bucket >= 24 * 3600 - 1 {
            return calendar.startOfDay(for: date)
        }
        return BucketMath.floor(date, seconds: bucket)
    }

    static func barStats(from bars: [BarPoint]) -> BarStats? {
        guard !bars.isEmpty else { return nil }
        let total = bars.reduce(0.0) { $0 + $1.total }
        let peak = bars.map(\.total).max() ?? 0
        return BarStats(total: total,
                        peak: peak,
                        perBar: total / Double(bars.count),
                        barCount: bars.count)
    }

    static func stats(from points: [ChartPoint]) -> ChartStats? {        guard !points.isEmpty else { return nil }
        var sum = 0.0
        var count = 0
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        for point in points {
            sum += point.average * Double(point.count)
            count += point.count
            low = Swift.min(low, point.minValue)
            high = Swift.max(high, point.maxValue)
        }
        guard count > 0 else { return nil }
        return ChartStats(average: sum / Double(count),
                          minValue: low,
                          maxValue: high,
                          sampleCount: count)
    }

    /// Y 轴范围。
    ///
    /// `fromZero` 由 `MetricDisplay` 的 `chartFromZero` 决定，不是这里猜的：
    /// 心率从 0 开始会把 60 上下的小波动压成一条直线，而活动能量不从 0 开始
    /// 会把柱状图变得没法比较。这件事只有指标的语义知道。
    static func yDomain(from points: [ChartPoint], fromZero: Bool) -> ClosedRange<Double> {
        guard !points.isEmpty else { return 0...1 }

        var low = points.map(\.minValue).min() ?? 0
        var high = points.map(\.maxValue).max() ?? 1
        if high <= low { high = low + 1 }

        let padding = (high - low) * 0.1
        if fromZero {
            low = 0
            high += padding
        } else {
            low -= padding
            high += padding
        }
        return low...high
    }

    /// 把睡眠样本按天聚合成"各阶段时长"。
    ///
    /// ## 为什么归属到**结束时间**那一天
    /// 一段睡眠通常横跨午夜（23:30 → 07:00）。按开始时间归属的话，
    /// 这一晚的记录会被算到"昨晚"那一栏里，而用户看"昨天的睡眠"时
    /// 会觉得数字对不上。按**起床时间**归属才符合直觉：
    /// "我今早起床的这次睡眠"。
    static func sleepDays(from samples: [CategoryPoint],
                          calendar: Calendar = .current) -> [SleepDayBar] {
        var byDay: [Date: [Int: Double]] = [:]

        for sample in samples {
            let day = calendar.startOfDay(for: sample.endDate)
            var stages = byDay[day] ?? [:]
            stages[sample.categoryValue, default: 0] += sample.hours
            byDay[day] = stages
        }

        return byDay.keys.sorted().map { day in
            let stages = byDay[day] ?? [:]
            var asleep = 0.0
            for (stage, hours) in stages where Self.isAsleep(stage) {
                asleep += hours
            }
            return SleepDayBar(day: day, hoursByStage: stages, totalSleepHours: asleep)
        }
    }

    /// 把"每天各阶段时长"拍平成 Chart 直接可用的片段。
    ///
    /// 顺手丢掉小于 `0.01` 小时（36 秒）的碎片：
    /// 手表上睡眠阶段一段只有几十秒时很常见，画出来是**看不见的一条线**，
    /// 却会让点数翻好几倍 —— 图看起来更慢、更乱，信息量却一点没多。
    static func sleepSegments(from days: [SleepDayBar]) -> [SleepChartSegment] {
        var result: [SleepChartSegment] = []
        for day in days {
            for stage in MetricDisplay.sleepStageOrder {
                guard let hours = day.hoursByStage[stage], hours > 0.01 else { continue }
                result.append(SleepChartSegment(
                    id: "\(Int(day.day.timeIntervalSince1970))-\(stage)",
                    day: day.day,
                    stageLabel: MetricDisplay.categoryLabel(metricID: "sleep_analysis", raw: stage),
                    hours: hours
                ))
            }
        }
        return result
    }

    /// "睡着"的阶段。
    ///
    /// 刻意把**卧床**和**清醒**排除在外：用户问"昨晚睡了多久"时，
    /// 答案是睡着的时间，不是躺在床上的时间。
    /// 两者相差往往有一个多小时，混在一起会让人以为睡眠质量比实际好。
    static func isAsleep(_ stage: Int) -> Bool {
        switch stage {
        case MetricDisplay.sleepCore,
             MetricDisplay.sleepDeep,
             MetricDisplay.sleepREM,
             MetricDisplay.sleepUnspecified,
             MetricDisplay.sleepAsleepDeprecated:
            return true
        default:
            return false
        }
    }
}
