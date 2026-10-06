import Foundation

// MARK: - 逐拍时间戳的打包（**当前格式**）

/// 逐拍时间戳（相对整条序列起点的**毫秒偏移**）的打包 / 解包。
///
/// ## 为什么传时间戳，而不是手表算好的 RR 间期
/// 之前的做法是手表做"相邻时间戳相减"、把算好的 RR 传下来。看上去只差一次减法，
/// 实际代价是：**以后每加一个分析（PSD、pNN50、样本熵…）都要改手表代码，
/// 再走一轮 watchOS 发布 + 用户装到表上。**
///
/// 手表代码的迭代成本极高，手机随时能更新。所以：
/// **手表只做"取数 + 转发"，所有解释性计算都留在手机上。**
/// 这样以后任何新分析都只改手机，一行手表代码都不用碰。
///
/// ## 为什么用 UInt32
/// - `UInt16` **存不下**偏移：一条序列 500 拍 × 平均 800 ms = 40 万毫秒，早就溢出了。
///   之前能压到 2 字节是因为存的是**相邻差值**（几百毫秒），不是绝对偏移。
/// - 4 字节/拍的代价可以接受：一晚约 3600 拍 → 14 KB。
///   同一晚的心率样本（每 5 秒一条）是它的几十倍，心跳序列根本不是瓶颈。
///
/// 1 ms 精度对 RR 完全够：Apple 的逐拍时间戳本身就是毫秒级，
/// 而 HRV 指标的量级是几十毫秒。
enum BeatPacking {

    static func pack(_ offsetsMillis: [Int]) -> Data {
        var data = Data(capacity: offsetsMillis.count * 4)
        for value in offsetsMillis {
            // 负数在这里被钳成 0（`timeSinceStart` 理论上不会是负的）。
            // ⚠️ 钳位会造成"非单调"的偏移数组，消费方必须能容忍 ——
            //    见 `HeartbeatSeriesPayload.intervals(fromOffsets:)`。
            let clamped = UInt32(max(0, min(value, Int(UInt32.max))))
            data.append(UInt8(clamped & 0xFF))
            data.append(UInt8((clamped >> 8) & 0xFF))
            data.append(UInt8((clamped >> 16) & 0xFF))
            data.append(UInt8((clamped >> 24) & 0xFF))
        }
        return data
    }

    static func unpack(_ data: Data) -> [Int] {
        // ⚠️ 长度不是 4 的倍数说明数据被截断（写一半被系统杀掉 / 传输截断）。
        //    丢掉最后那个不完整的值，**不要崩** —— 丢一拍不影响任何结论，
        //    而崩掉会让整个图表页打不开。
        let count = data.count / 4
        guard count > 0 else { return [] }

        let bytes = [UInt8](data)
        var result: [Int] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let base = index * 4
            let value = UInt32(bytes[base])
                | (UInt32(bytes[base + 1]) << 8)
                | (UInt32(bytes[base + 2]) << 16)
                | (UInt32(bytes[base + 3]) << 24)
            result.append(Int(value))
        }
        return result
    }
}

// MARK: - 洞标记（`precededByGap`）的打包

/// `HKHeartbeatSeriesQuery` 回调里那个 `precededByGap` 的打包 / 解包（**每拍 1 bit**）。
///
/// ## 为什么必须把它传下来（这是一个真丢过的信号）
/// Apple 对它的定义（官方原文，读侧与写侧措辞一致）：
/// > "A Boolean value that indicates whether this heartbeat was **immediately preceded
/// > by a gap in the data**, indicating that **one or more heartbeats may be missing**."
///
/// 也就是说：**这一拍和前一拍之间的时间差，不是一个真实的心跳间隔** ——
/// 中间漏了一拍或多拍。而我们的 RR 间期正是"相邻时间戳相减"算出来的，
/// 所以跨洞算出来的那个值**必须丢掉**。
///
/// ## 不丢的后果（为什么这不是"优化"，是修错）
/// 漏 1 拍的话，800 ms 会变成 1600 ms —— 而 1600 ms **正好落在**
/// 手机端 300–2000 ms 的生理范围内（`PoincareBuilder.minRR/maxRR`），
/// 于是它会被当成一个真实的心跳间隔画进散点图，并把 SDNN 拉大。
/// 临床上这叫"早搏"，实际是"漏拍"，两者被混为一谈。
///
/// ⚠️ 没有这个字段时（v3.2 之前的手表发的老数据）我们**只能按"无洞"处理**，
/// 但那是一个**假设**而不是事实 —— 所以调用方会拿到 `hasGapInfo == false`，
/// 可以在界面上如实说明。见 `IntervalBreakdown`。
enum GapPacking {

    /// bit i = 第 i 拍的 `precededByGap`；字节内**低位在前**（bit 0 是该字节最低位）。
    static func pack(_ flags: [Bool]) -> Data {
        guard !flags.isEmpty else { return Data() }
        var data = Data(count: (flags.count + 7) / 8)
        for (index, flag) in flags.enumerated() where flag {
            data[index / 8] |= UInt8(1 << (index % 8))
        }
        return data
    }

    /// 解出 `count` 个标记。**长度对不上就返回 `nil`（= "没有洞信息"），绝不猜。**
    ///
    /// 为什么宁可返回 nil 也不补零：补零等于宣称"这些拍都没跨洞"，
    /// 而那正是我们想避免的错误结论。猜错的代价是图上多出假的远端散点，
    /// 而且它长得和真数据一模一样。
    static func unpack(_ data: Data, count: Int) -> [Bool]? {
        guard count > 0, data.count == (count + 7) / 8 else { return nil }
        let bytes = [UInt8](data)
        var result: [Bool] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(bytes[index / 8] & UInt8(1 << (index % 8)) != 0)
        }
        return result
    }
}

// MARK: - 按洞切段

/// 一条序列里**连续**的一段间期。
///
/// 洞把一条序列切成若干段，而**配对必须在段内做** —— 跨段的两个间期
/// 中间隔着一段没记录的时间，配出来的点是纯噪声。
struct IntervalRun: Sendable, Equatable {

    /// 这一段里的 RR 间期（毫秒）。**每个值都保证没有跨洞。**
    let intervals: [Int]

    /// 这一段第一个间期的**起点拍序号**（0 基）。
    ///
    /// 只用于给散点图的点生成**稳定且不撞车**的 id
    /// （`"序列序号-起点拍号-段内序号"`）。不参与任何计算。
    let startBeatIndex: Int
}

/// 一条序列的间期拆解结果 —— 把"切段"和"丢了多少"一起带出来。
///
/// ⚠️ **丢弃必须回报**（本项目坑 #33）：静默丢掉跨洞间隔，
/// 用户会以为"数据就这么多"，之后任何"图看着不对"的排查都从错误方向开始。
struct IntervalBreakdown: Sendable {

    let runs: [IntervalRun]

    /// 因为**跨洞**而丢掉的间隔数（Apple 明确说过这里漏了拍）。
    let gapCrossedDropped: Int

    /// 因为**非正**而丢掉的（收尾那一次回调不保证带有效时间戳，可能是 0 或重复值）。
    let nonPositiveDropped: Int

    /// 这条序列到底**有没有**洞信息可用。
    ///
    /// `false` 只代表"发数据的手表版本太老/字段缺失"，**不代表没有洞** ——
    /// 此时我们按"整条一个段"处理，并在界面上说明这是假设。
    let hasGapInfo: Bool

    /// 全部连续段拍平成一个数组（给 SDNN / 平均心率用）。
    ///
    /// ⚠️ 拍平在这里是**安全的**：跨洞的那个间隔已经在切段时丢掉了，
    /// 剩下的都是真实间隔，求标准差不需要知道段边界。
    /// 但**配对不对**（`PoincareBuilder`）必须逐段做 —— 两件事的区别就在这。
    var allIntervals: [Int] { runs.flatMap(\.intervals) }
}

// MARK: - 旧格式（RR 间期）的打包 —— **只为读历史数据保留**

/// RR 间期（相邻两次心跳的间隔，毫秒）的打包 / 解包。
///
/// ⚠️ **新代码不再用它写**（手表已经不传 RR 了，见 `BeatPacking` 的说明）。
/// 留着是因为手机上已经存了一批用这个格式写的序列，读取时要能解出来。
/// 等那批数据自然过期（`PhoneStoragePolicy.rawRetentionDays`）之后就可以删掉。
enum RRPacking {

    static let maxMillis = 65_535

    static func pack(_ millis: [Int]) -> Data {
        var data = Data(capacity: millis.count * 2)
        for value in millis {
            let clamped = UInt16(max(0, min(value, maxMillis)))
            data.append(UInt8(clamped & 0xFF))
            data.append(UInt8((clamped >> 8) & 0xFF))
        }
        return data
    }

    static func unpack(_ data: Data) -> [Int] {
        let count = data.count / 2
        guard count > 0 else { return [] }

        let bytes = [UInt8](data)
        var result: [Int] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1])
            result.append(Int(low | (high << 8)))
        }
        return result
    }
}

// MARK: - 心跳序列的线上格式

/// 一条心跳序列（`HKHeartbeatSeriesSample`）的线上格式。
///
/// ## 为什么它不是 `UploadPayload`
/// `UploadPayload` 是"**一条样本 = 一个数值**"的形状
/// （`value` / `categoryValue` 二选一）。而一条心跳序列里是**几百个时间戳**，
/// 硬塞进那个形状只能靠"一条序列拆成几百条样本"，那会让行数和传输批次都爆炸。
///
/// 所以它是独立的一类载荷，`SampleBatch` 里也占独立的一个字段。
/// 这也正是它进不了 `MetricCatalog` 的原因 —— 那张表是按
/// `HKQuantityType` / `HKCategoryType` 设计的，而心跳序列是 `HKSeriesType`。
struct HeartbeatSeriesPayload: Codable, Equatable, Sendable {

    var uuid: UUID
    var startDate: Date
    var endDate: Date

    /// 逐拍时间戳（相对序列起点的毫秒偏移），已按 `BeatPacking` 打包。
    ///
    /// **这是当前格式。** Optional 是为了容忍老版本手表发来的载荷
    /// （它只有 `rrPacked`）—— 见 `WatchWire` 里"新字段必须是 Optional"的说明。
    var beatOffsetsPacked: Data?

    /// 每一拍的 `precededByGap` 标记，已按 `GapPacking` 打包（**每拍 1 bit**）。
    ///
    /// ## ⚠️ 必须写成 `Optional`
    /// 本协议与 payload 都遵守「**只增不改**」：老手表发来的载荷里没有这个键，
    /// 而 Swift 合成的 `Decodable` 对**非可选**属性用 `decode` 而不是 `decodeIfPresent`
    /// —— 写成 `var x: Data = Data()` 这种"给个默认值"的写法**不能**容忍缺失的键，
    /// 老版本一解码就抛错、**整批心跳序列全丢**（而不是忽略这个字段）。
    /// 自检脚本第 13 节守着这一类。
    ///
    /// 没有它时的语义是「**没有洞信息**」，不是「没有洞」—— 见 `IntervalBreakdown.hasGapInfo`。
    var gapFlagsPacked: Data?

    /// **旧格式**：手表算好的逐拍间隔。只为兼容还在跑 v2.1 的手表而保留。
    ///
    /// ⚠️ 这个字段是从 `Data`（非可选）改成 `Data?` 的。
    /// 对 Codable 来说是安全的：`Data?` 走 `decodeIfPresent`，
    /// 缺键解成 nil、有键照样解出来，两个方向都兼容。
    var rrPacked: Data?

    /// HealthKit 给出的**拍数**（原始，不是间期数）。
    ///
    /// 冗余存一份是为了**校验**：解出来的时间戳个数应该**正好等于**拍数。
    /// 对不上说明数据坏了，渲染层可以据此跳过这条序列，
    /// 而不是画出一堆凭空捏造的间期。
    var beatCount: Int

    var ingestedAt: Date

    // ——— 来源追踪（和 UploadPayload 保持同一套字段名）———
    var sourceBundleID: String?
    var sourceName: String?
    var deviceName: String?
    var deviceModel: String?

    init(uuid: UUID,
         startDate: Date,
         endDate: Date,
         beatOffsetsPacked: Data? = nil,
         gapFlagsPacked: Data? = nil,
         rrPacked: Data? = nil,
         beatCount: Int,
         ingestedAt: Date,
         sourceBundleID: String? = nil,
         sourceName: String? = nil,
         deviceName: String? = nil,
         deviceModel: String? = nil) {
        self.uuid = uuid
        self.startDate = startDate
        self.endDate = endDate
        self.beatOffsetsPacked = beatOffsetsPacked
        self.gapFlagsPacked = gapFlagsPacked
        self.rrPacked = rrPacked
        self.beatCount = beatCount
        self.ingestedAt = ingestedAt
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }

    /// 逐拍时间戳（毫秒偏移）。
    ///
    /// 新格式直接用；老格式把间期**累加**回偏移 —— 这样上游只需要一套分析代码，
    /// 不用每处都写"如果是老格式就…"。
    var beatOffsetsMillis: [Int] {
        if let packed = beatOffsetsPacked, !packed.isEmpty {
            return BeatPacking.unpack(packed)
        }
        var offsets: [Int] = [0]
        var running = 0
        for interval in RRPacking.unpack(rrPacked ?? Data()) {
            running += interval
            offsets.append(running)
        }
        return offsets
    }

    /// 每一拍的 `precededByGap` 标记。`nil` = **这条载荷没有洞信息**（老手表）。
    ///
    /// ⚠️ 用 `beatOffsetsMillis.count` 而不是 `beatCount` 去定长度：
    /// 间期是从**时间戳**推出来的，所以"有没有洞"必须和时间戳一一对应。
    /// 长度对不上时 `GapPacking.unpack` 返回 `nil`，我们宁可当成"没有洞信息"。
    var gapFlags: [Bool]? {
        guard let packed = gapFlagsPacked else { return nil }
        return GapPacking.unpack(packed, count: beatOffsetsMillis.count)
    }

    /// 按洞切段 + 如实报出丢了多少。**这是所有下游分析的唯一入口。**
    var intervalBreakdown: IntervalBreakdown {
        Self.breakdown(fromOffsets: beatOffsetsMillis, gapFlags: gapFlags)
    }

    /// 连续的间期段。配对（Poincaré）必须逐段做。
    var intervalRuns: [IntervalRun] { intervalBreakdown.runs }

    /// RR 间期（毫秒）—— **由时间戳相邻相减得到，计算发生在手机上**。
    ///
    /// 已排除跨洞的间隔（见 `breakdown`）。拍平给 SDNN / 平均心率用是安全的。
    var rrMillis: [Int] { intervalBreakdown.allIntervals }

    /// 相邻时间戳之差 = RR 间期（**不做按洞切分**，只过滤非正值）。
    ///
    /// ⚠️ 只保留**正的**间隔：`HKHeartbeatSeriesQuery` 收尾那次回调
    /// **不保证带有效时间戳**（可能是 0 或重复值），那会算出 0 或负数。
    /// 丢掉它们，别让脏数据进分析。
    ///
    /// 📌 这条规则原来在手表上（那时是边算边过滤）。位置挪到了手机上，**语义没变** ——
    /// 之所以能挪，正是因为手表现在只转发原始时间戳、不做任何判断。
    ///
    /// 📌 需要**配对**的场合（散点图）请改用 `breakdown`：这个函数不知道洞的存在。
    static func intervals(fromOffsets offsets: [Int]) -> [Int] {
        breakdown(fromOffsets: offsets, gapFlags: nil).allIntervals
    }

    /// 把逐拍时间戳 + 洞标记拆成连续段，并数清丢了多少。
    ///
    /// ## 两个过滤条件语义完全不同，**不要合并**
    /// | 条件 | 含义 | 计数 |
    /// |---|---|---|
    /// | `delta <= 0` | 收尾回调带的脏时间戳（0 或重复） | `nonPositiveDropped` |
    /// | `gapFlags[i] == true` | **Apple 说这一拍前面有洞、漏了拍** → 相邻相减不是真实间隔 | `gapCrossedDropped` |
    ///
    /// 第二个之前**从来没被检查过** —— 那是这个项目里一个真实的静默错误：
    /// 漏 1 拍会把 800 ms 变成 1600 ms，而 1600 ms 落在生理范围内，
    /// 于是它会伪装成一个真实的心跳间隔进图、并拉大 SDNN。
    static func breakdown(fromOffsets offsets: [Int], gapFlags: [Bool]?) -> IntervalBreakdown {
        guard offsets.count >= 2 else {
            return IntervalBreakdown(runs: [], gapCrossedDropped: 0,
                                     nonPositiveDropped: 0, hasGapInfo: gapFlags != nil)
        }

        var runs: [IntervalRun] = []
        var current: [Int] = []
        var currentStart = 0
        var gapCrossed = 0
        var nonPositive = 0

        for index in 1..<offsets.count {
            let delta = offsets[index] - offsets[index - 1]
            // 洞信息缺失时按"无洞"处理 —— 这是**假设**，由 hasGapInfo 如实带出去。
            let crossedGap = gapFlags.map { index < $0.count && $0[index] } ?? false

            if crossedGap {
                gapCrossed += 1
            } else if delta <= 0 {
                nonPositive += 1
            }

            if delta > 0 && !crossedGap {
                if current.isEmpty { currentStart = index - 1 }
                current.append(delta)
            } else {
                if !current.isEmpty {
                    runs.append(IntervalRun(intervals: current, startBeatIndex: currentStart))
                }
                current = []
            }
        }
        if !current.isEmpty {
            runs.append(IntervalRun(intervals: current, startBeatIndex: currentStart))
        }

        return IntervalBreakdown(runs: runs,
                                 gapCrossedDropped: gapCrossed,
                                 nonPositiveDropped: nonPositive,
                                 hasGapInfo: gapFlags != nil)
    }

    /// 时间戳个数与拍数是否自洽。不自洽的序列**不该被画进图里**。
    var isSelfConsistent: Bool {
        if let packed = beatOffsetsPacked, !packed.isEmpty {
            // 新格式：时间戳是**逐拍**记录的，必须**正好**等于拍数
            return beatCount >= 2 && packed.count / 4 == beatCount
        }
        // 老格式：间期数比拍数少 1（而且当时过滤过非正值，所以可能再少几个）
        let rrCount = (rrPacked?.count ?? 0) / 2
        return rrCount >= 1 && (rrCount == beatCount || rrCount == beatCount - 1)
    }

    func encoded() -> Data { WireCodec.encode(self) }

    static func decode(_ data: Data) -> HeartbeatSeriesPayload? {
        WireCodec.decode(HeartbeatSeriesPayload.self, from: data)
    }
}
