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

    /// RR 间期（毫秒）—— **由时间戳相邻相减得到，计算发生在手机上**。
    var rrMillis: [Int] { Self.intervals(fromOffsets: beatOffsetsMillis) }

    /// 相邻时间戳之差 = RR 间期。
    ///
    /// ⚠️ 只保留**正的**间隔：`HKHeartbeatSeriesQuery` 收尾那次回调
    /// **不保证带有效时间戳**（可能是 0 或重复值），那会算出 0 或负数。
    /// 丢掉它们，别让脏数据进分析。
    ///
    /// 📌 这条规则原来在手表上（那时是边算边过滤）。位置挪到了手机上，**语义没变** ——
    /// 之所以能挪，正是因为手表现在只转发原始时间戳、不做任何判断。
    static func intervals(fromOffsets offsets: [Int]) -> [Int] {
        guard offsets.count >= 2 else { return [] }
        var result: [Int] = []
        result.reserveCapacity(offsets.count - 1)
        for index in 1..<offsets.count {
            let delta = offsets[index] - offsets[index - 1]
            if delta > 0 { result.append(delta) }
        }
        return result
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
