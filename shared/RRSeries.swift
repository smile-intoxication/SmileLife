import Foundation

// MARK: - RR 间期的打包

/// RR 间期（相邻两次心跳的间隔，毫秒）的打包 / 解包。
///
/// ## 为什么打包，而不是存 `[Double]` 或 JSON 数组
/// 一条心跳序列有几十到几百拍。存成 JSON 数组，一条序列就是几 KB；
/// 打包成 `UInt16` 只要 **2 字节/间期**。手表要落盘、还要经系统队列传出去，
/// 这个差别是数量级的。
///
/// ## 为什么用 UInt16
/// RR 间期的生理范围是 **300–2000 ms**（对应 200–30 bpm），
/// 1 ms 精度完全够（Apple 给的时间戳本身也只有毫秒级精度）。
/// UInt16 上限 65535 ms 相当于 0.9 bpm —— 生理上不可能出现。
///
/// 超出范围的**钳到边界，而不是丢弃**：丢一个会让"间期数 + 1 ≠ 拍数"，
/// 而这两个数字是后面用来做一致性校验的。真正的异常值过滤放在渲染层
/// （见 `PoincareBuilder`），那里可以开关、可以统计剔除了多少条。
enum RRPacking {

    static let maxMillis = 65_535

    static func pack(_ millis: [Int]) -> Data {
        var data = Data(capacity: millis.count * 2)
        for value in millis {
            let clamped = UInt16(max(0, min(value, maxMillis)))
            // 小端：和 Apple 平台一致，也方便以后用别的语言读
            data.append(UInt8(clamped & 0xFF))
            data.append(UInt8((clamped >> 8) & 0xFF))
        }
        return data
    }

    static func unpack(_ data: Data) -> [Int] {
        // ⚠️ 奇数长度说明数据被截断（写一半就被系统杀掉 / 传输截断）。
        //    丢掉最后一个不完整的值，**不要崩** —— 丢一条间期不影响任何结论，
        //    而崩掉会让整个图表页打不开。
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

    /// 逐拍间隔（毫秒），已按 `RRPacking` 打包
    var rrPacked: Data
    /// HealthKit 给出的**拍数**（原始，不是间期数）。
    ///
    /// 冗余存一份是为了**校验**：正常情况 `rrPacked` 解出来应该是 `beatCount`
    /// 或 `beatCount - 1` 条。对不上说明数据坏了，渲染层可以据此跳过这条序列，
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
         rrPacked: Data,
         beatCount: Int,
         ingestedAt: Date,
         sourceBundleID: String? = nil,
         sourceName: String? = nil,
         deviceName: String? = nil,
         deviceModel: String? = nil) {
        self.uuid = uuid
        self.startDate = startDate
        self.endDate = endDate
        self.rrPacked = rrPacked
        self.beatCount = beatCount
        self.ingestedAt = ingestedAt
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }

    /// 解包出来的逐拍间隔（毫秒）
    var rrMillis: [Int] { RRPacking.unpack(rrPacked) }

    /// 拍数与间期数是否自洽。不自洽的序列**不该被画进图里**。
    var isSelfConsistent: Bool {
        let rrCount = rrPacked.count / 2
        return rrCount >= 1 && (rrCount == beatCount || rrCount == beatCount - 1)
    }

    func encoded() -> Data { WireCodec.encode(self) }

    static func decode(_ data: Data) -> HeartbeatSeriesPayload? {
        WireCodec.decode(HeartbeatSeriesPayload.self, from: data)
    }
}
