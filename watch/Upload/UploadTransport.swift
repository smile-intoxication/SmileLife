import Foundation

/// 上传载荷——**协议中立**的序列化格式。
///
/// 关键设计：载荷格式与传输方式解耦。
/// 无论最后选 WatchConnectivity 传给手机，还是用 URLSession 直传服务器，
/// 这个结构都不用改（对应调研文档 §5.8 的结论）。
struct UploadPayload: Codable {

    var uuid: UUID
    var metricID: String
    var startDate: Date
    var endDate: Date
    var value: Double?
    var categoryValue: Int?
    var unitString: String?

    // 来源追踪：服务端可以据此判断数据是不是手表产生的
    var sourceBundleID: String?
    var deviceName: String?
    var deviceModel: String?
    var deviceManufacturer: String?

    /// 落库时间，用于排查"手表采集 → 服务端可见"的端到端延迟
    var ingestedAt: Date

    init(record: SampleRecord) {
        self.uuid = record.uuid
        self.metricID = record.metricID
        self.startDate = record.startDate
        self.endDate = record.endDate
        self.value = record.value
        self.categoryValue = record.categoryValue
        self.unitString = record.unitString
        self.sourceBundleID = record.sourceBundleID
        self.deviceName = record.deviceName
        self.deviceModel = record.deviceModel
        self.deviceManufacturer = record.deviceManufacturer
        self.ingestedAt = record.ingestedAt
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }
}

/// 传输层的抽象。
///
/// **这一版不接任何实现**（用户明确说上传功能先预留）。
/// 等确认了走手机还是走服务器，实现下面任意一个即可：
///
/// - `WatchConnectivityTransport`：用 `transferUserInfo` 传给手机 app。
///   注意官方语义：它只保证**进入队列**，不保证送达；且必须在
///   `activationState == .activated` 时调用；模拟器不支持，必须真机测。
///
/// - `HTTPTransport`：直接传自己的服务器。**必须用 `URLSessionConfiguration.background`**，
///   因为后台传输跑在独立进程，app 挂起/终止后仍会继续；
///   普通的 async upload 会在 app 挂起时中断。
///   注意手表后台传输的调度上限：有 complication 时每小时最多 4 次，
///   官方建议 `earliestBeginDate` 间隔 **≥ 15 分钟**。
protocol UploadTransport {
    /// 批量上传。实现方负责幂等——服务端应该按 `uuid` 做 upsert。
    func upload(_ batches: [UploadPayload]) async throws
}

/// 占位实现：只记录不发送，让整条链路可以跑通而不产生副作用。
struct NoopUploadTransport: UploadTransport {
    func upload(_ batches: [UploadPayload]) async throws {
        guard !batches.isEmpty else { return }
        print("[Upload] 预留阶段：本次本应上传 \(batches.count) 条，已跳过")
    }
}
