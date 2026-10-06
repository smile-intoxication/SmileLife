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

struct ChartStats {
    let average: Double
    let minValue: Double
    let maxValue: Double
    let sampleCount: Int
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

    static func stats(from points: [ChartPoint]) -> ChartStats? {
        guard !points.isEmpty else { return nil }
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
