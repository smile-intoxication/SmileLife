import Foundation

/// RR 间期散点图（Poincaré）在图表选择器里的展示信息。
///
/// ## ⚠️ 刻意**不**放进 `MetricDisplay.all`
/// 那张表会被自检脚本第 12 节与 `MetricCatalog` 的指标 id 做**双向**一致性比对。
/// 而 RR 间期根本不是 HealthKit 的指标类型 —— 它是从心跳序列
/// （`HKSeriesType`）的逐拍时间戳**派生**出来的。
/// 混进那张表会让那个不变量失效，而它正是用来防"两边漂移"的东西。
enum RRPoincare {
    static let metricID = "__rr_poincare__"
    static let title = "RR 间期（Poincaré）"
    static let symbolName = "circle.grid.cross"
    static let unitSuffix = "ms"
}

/// 一条序列的**逐拍时间戳**（相对序列起点的毫秒偏移）。
///
/// ## 为什么存时间戳而不是 RR 间期
/// RR 只是时间戳的一阶差分 —— 存时间戳能算出 RR，反过来不行。
/// 以后要加的分析（频谱 PSD 需要按真实时间重采样、样本熵需要原始序列）
/// 都要求拿到时间戳，所以**原始形式**才是该存的那个。
///
/// 这不是"多存一点"，而是**分层**：手表只负责搬运原始数据，
/// **所有解释性计算（RR、Poincaré、SDNN、以后可能加的 PSD）都在手机上**。
/// 手表代码的迭代成本极高，手机随时能更新。
struct RRSeriesData: Sendable {
    let seriesUUID: UUID
    let startDate: Date
    let beatOffsetsMillis: [Int]

    /// 每一拍的 `precededByGap`。`nil` = 这条记录**没有洞信息**（v3.2 之前的老数据）。
    let gapFlags: [Bool]?

    /// 按洞切段 + 如实报出丢了多少 —— 散点图和 SDNN 都从这里取数。
    ///
    /// ⚠️ **配对必须用 `runs` 逐段做**，不能直接拍平：
    /// 拍平之后段边界就消失了，`rr[n]` 和 `rr[n+1]` 可能来自两段互不相连的记录，
    /// 配出来的点是纯噪声 —— 而它在图上**看起来完全正常**，没法从图上看出来。
    /// （和"跨序列配对"是同一类错误，那个已经用分组结构挡住了。）
    var intervalBreakdown: IntervalBreakdown {
        HeartbeatSeriesPayload.breakdown(fromOffsets: beatOffsetsMillis, gapFlags: gapFlags)
    }

    /// RR 间期（毫秒）—— 相邻时间戳之差，**在手机上算**。已排除跨洞的间隔。
    var rrMillis: [Int] { intervalBreakdown.allIntervals }
}

/// 一次 RR 序列查询的结果。
///
/// ## 为什么要把 `isTruncated` 显式带出来
/// 查询有**条数上限**（见 `PhoneStore.rrSeries` 的说明）。如果只是安安静静地
/// 截断，用户看到的就是"数据就这么多"—— 而实际上是"我们没全读"。
/// 这两件事必须能区分，否则任何"图看着不对"的排查都会从错误的方向开始。
struct RRSeriesFetch: Sendable {
    let series: [RRSeriesData]
    /// 是否因为条数上限被截断
    let isTruncated: Bool
}

/// 散点图上的一个点：横轴 RRₙ、纵轴 RRₙ₊₁。
struct PoincarePoint: Identifiable {
    /// 「序列序号-序列内位置」：跨序列也不会撞 id
    let id: String
    let rrN: Double
    let rrNext: Double
}

/// 构造 Poincaré 图的结果。
struct PoincareResult {
    var points: [PoincarePoint] = []

    var seriesCount = 0
    /// 参与计算的间期总数（原始，未过滤）
    var rawIntervals = 0
    /// 落在生理范围外、被丢掉的间期数
    var outOfRange = 0
    /// 相邻变化过大的**对**数（早搏／伪影的典型特征）
    var ectopicPairs = 0
    /// 因为超过点数上限而抽稀过
    var isDownsampled = false

    // MARK: - 跨洞过滤的账（**必须回报，不能静默丢**）

    /// 因为**跨洞**而丢掉的间隔数。
    ///
    /// Apple 明确说过 `precededByGap` 意味着"漏了一拍或多拍"，
    /// 所以这些差值不是真实的心跳间隔。丢掉是对的 ——
    /// 但**必须让用户看见丢了多少**（静默丢弃比报错更糟：用户会以为"数据就这么多"）。
    var gapCrossedDropped = 0
    /// 因为非正而丢掉的（收尾回调可能带 0 或重复时间戳）
    var nonPositiveDropped = 0
    /// 有洞信息的序列数
    var seriesWithGapInfo = 0
    /// **没有**洞信息的序列数（老数据）—— 这些是按"无洞"假设处理的
    var seriesWithoutGapInfo = 0
    /// 被洞切出来的连续段总数。
    ///
    /// 它比"序列数"更能说明数据的**碎片化程度**：
    /// 120 条序列切成 180 段，说明平均每条内部就有洞。
    var runCount = 0

    /// 平均 RR（毫秒）—— 和散点图用同一批（已过范围过滤的）间期，保证数字和图对得上
    var meanRR: Double?
    /// 全部 NN 间期的标准差（SDNN，毫秒）。这是标准 HRV 指标之一。
    var sdnn: Double?

    /// 平均心率（bpm），由平均 RR 换算
    var meanHeartRate: Double? {
        guard let meanRR, meanRR > 0 else { return nil }
        return 60_000 / meanRR
    }

    var isEmpty: Bool { points.isEmpty }
}

/// Poincaré 散点图的构造。
///
/// ## 为什么单独抽出来，不在 `ChartView` 里算
/// 两个理由，都不是"为了整洁"：
/// 1. **SwiftUI 的类型推导会超时**（本项目已经踩过一次 —— 睡眠图表就是
///    因为把嵌套 `ForEach` + `if let` + 字符串插值写进 `Chart { }` 而编译失败）。
///    数据先在类型明确的地方算好，视图里只留一层 `PointMark`，最稳。
/// 2. 过滤规则是**业务规则**（生理范围、早搏判定），不该散落在视图里。
enum PoincareBuilder {

    /// 生理范围（毫秒）：300 ms = 200 bpm，2000 ms = 30 bpm。
    ///
    /// 超出这个范围的间期**不可能是真的心动周期** —— 要么是早搏后的代偿间歇，
    /// 要么是运动/佩戴不良导致的漏检。它们会把散点图从"一团云"变成
    /// "几条打到边界的线"，把真正想看的东西压没。
    static let minRR = 300.0
    static let maxRR = 2000.0

    /// 相邻两个间期的最大相对变化。超过就按早搏／伪影处理。
    static let maxDeltaRatio = 0.2

    /// 一张散点图最多画多少个点。
    ///
    /// ## 量级按**用户真机实测**校准过（2026-10，v1.8 读数）
    /// | 量 | 实测 |
    /// |---|---|
    /// | 单条序列 | **约 50 拍** → 约 49 个间期 |
    /// | 间隔 | **约 4 分钟一条**（房颤历史开启） |
    /// | 一夜 8 小时 | 约 **120 条**序列 → 约 **5900** 个间期 |
    ///
    /// 所以一晚上的点数在 5000 上下，**会真的触发抽稀**（不是防御性代码）。
    /// 而手机上超过 3000 个点在视觉上已经是一团实心色块
    /// （**不再增加信息量**），却明显拖慢渲染。所以超过就均匀抽稀，并在界面上说明。
    ///
    /// ⚠️ 这里以前写的是"每条序列约 100 拍"—— 比实测大了约一倍，已按上面的数字改。
    /// 条数（约 120 条/夜）那半是对的。
    static let maxPoints = 3000

    /// 构造散点图。
    ///
    /// - Parameter filterEctopic: 是否剔除"相邻变化 >20%"的点对。
    ///   做成开关而不是写死：关掉时能看到**原始的**早搏散点分布本身，
    ///   那在某些分析里恰恰是要看的东西。
    static func build(from series: [RRSeriesData], filterEctopic: Bool) -> PoincareResult {
        var result = PoincareResult()
        result.seriesCount = series.count

        var candidates: [PoincarePoint] = []
        var nnIntervals: [Double] = []

        for (seriesIndex, item) in series.enumerated() {
            let breakdown = item.intervalBreakdown

            // ——— 先记账：跨洞丢了多少（**要显示出来**）———
            result.gapCrossedDropped += breakdown.gapCrossedDropped
            result.nonPositiveDropped += breakdown.nonPositiveDropped
            if breakdown.hasGapInfo {
                result.seriesWithGapInfo += 1
            } else {
                result.seriesWithoutGapInfo += 1
            }

            // ⚠️ 逐段处理。两层的"不许跨越"叠在一起：
            //    · 不许跨**序列**（每次测量之间隔着几分钟）
            //    · 不许跨**洞**（同一条序列内部漏了拍 —— Apple 用 precededByGap 标出来了）
            //    两者的后果一样：配出来的点来自两段互不相连的记录，是纯噪声，
            //    而且**在图上完全看不出来**。
            for run in breakdown.runs {
                let rr = run.intervals.map(Double.init)
                guard !rr.isEmpty else { continue }
                result.runCount += 1
                result.rawIntervals += rr.count

                // ——— NN 间期：给 SDNN / 平均心率用 ———
                // ⚠️ 这里必须算 **NN（normal-to-normal）** 而不是原始间期。
                //    SDNN 的定义就是"NN 间期的标准差"，而早搏会把 SDNN 显著**拉大**
                //    （这是 SDNN 虚高最常见的原因）。用原始间期算，数字看着漂亮但没意义。
                //    顺带：开关切到"剔除"时，图变了 SDNN 也必须跟着变，
                //    否则同一屏上两个数字互相矛盾。
                // ⚠️ 早搏是"和前一个间期比"，所以那个"前一个"必须在**同一段**里 ——
                //    跨段的比较等于拿隔着空洞的两个数作比较。
                for index in 0..<rr.count {
                    let value = rr[index]
                    guard value >= minRR, value <= maxRR else {
                        result.outOfRange += 1
                        continue
                    }
                    // 段内第一个间期没有"前一个"，直接算合格。
                    if index > 0, filterEctopic,
                       abs(value - rr[index - 1]) > maxDeltaRatio * rr[index - 1] {
                        continue
                    }
                    nnIntervals.append(value)
                }

                guard rr.count >= 2 else { continue }

                for index in 0..<(rr.count - 1) {
                    let previous = rr[index]
                    let next = rr[index + 1]

                    // 两个值都必须落在生理范围内才配对
                    guard previous >= minRR, previous <= maxRR,
                          next >= minRR, next <= maxRR else { continue }

                    // 早搏判定**总是统计**（界面上要如实说明剔除了多少），
                    // 但只有开关打开时才真的丢弃。
                    let isEctopic = abs(next - previous) > maxDeltaRatio * previous
                    if isEctopic {
                        result.ectopicPairs += 1
                        if filterEctopic { continue }
                    }

                    // id 里带上**段起点的拍序号**：段内序号只在段内有意义，
                    // 只用 "序列-段内序号" 会让不同段的点撞 id（List/ForEach 会出问题）。
                    candidates.append(PoincarePoint(id: "\(seriesIndex)-\(run.startBeatIndex)-\(index)",
                                                    rrN: previous,
                                                    rrNext: next))
                }
            }
        }

        // 统计量用 NN 间期（和上面同一套过滤规则），保证"图"和"数字"说的是同一件事。
        if nnIntervals.count >= 2 {
            let mean = nnIntervals.reduce(0, +) / Double(nnIntervals.count)
            result.meanRR = mean
            let variance = nnIntervals.reduce(0.0) { partial, value in
                partial + (value - mean) * (value - mean)
            } / Double(nnIntervals.count - 1)
            result.sdnn = variance.squareRoot()
        } else if let only = nnIntervals.first {
            result.meanRR = only
        }

        // 显式分两步：`result.points = downsample(..., marking: &result)`
        // 在同一个语句里既读又写 `result`，虽然 Swift 的独占性检查允许，
        // 但没必要在可读性上冒险。
        let picked = downsample(candidates, marking: &result)
        result.points = picked
        return result
    }

    /// 均匀抽稀。**均匀**很重要：按前 N 个截断会让图只看得到最早那一小段。
    private static func downsample(_ points: [PoincarePoint],
                                   marking result: inout PoincareResult) -> [PoincarePoint] {
        guard points.count > maxPoints else { return points }
        result.isDownsampled = true

        let step = Double(points.count) / Double(maxPoints)
        var picked: [PoincarePoint] = []
        picked.reserveCapacity(maxPoints)
        var cursor = 0.0
        while picked.count < maxPoints {
            let index = Int(cursor)
            if index >= points.count { break }
            picked.append(points[index])
            cursor += step
        }
        return picked
    }
}
