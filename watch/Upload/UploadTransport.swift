import Foundation

/// 从本地库的 `SampleRecord` 构造线上格式。
///
/// ⚠️ 这个扩展刻意放在 **watch 侧**而不是 `shared/`：
/// `SampleRecord` 是 SwiftData 的 `@Model`，而 `shared/` 里的文件
/// 会被编进 iOS app（iOS app 用不着 SwiftData 的那套模型）。
/// `shared/WatchWire.swift` 里只有纯值类型的 `UploadPayload` 本身。
extension UploadPayload {
    init(record: SampleRecord) {
        self.init(uuid: record.uuid,
                  metricID: record.metricID,
                  startDate: record.startDate,
                  endDate: record.endDate,
                  value: record.value,
                  categoryValue: record.categoryValue,
                  unitString: record.unitString,
                  sourceBundleID: record.sourceBundleID,
                  sourceName: record.sourceName,
                  deviceName: record.deviceName,
                  deviceModel: record.deviceModel,
                  deviceManufacturer: record.deviceManufacturer,
                  ingestedAt: record.ingestedAt)
    }
}

/// 传输层的抽象。
///
/// ## 现状（重要）
/// 「手表 → iPhone」这条路**已经实现**，但它不走这个协议：
/// `transferUserInfo` 的语义是"交给系统排队、系统负责送"，
/// 与这里"我给你一批、你给我一个 throw"的同步语义并不吻合，
/// 所以它单独实现在 `watch/Upload/OutboxFlusher.swift`。
///
/// 这个协议保留给**另一条路**：将来要把数据也送一份到自己的服务器时，
/// 实现一个 `HTTPTransport` 即可（`UploadPayload` 的线上格式不用改）。
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

/// 占位实现：只记录不发送。服务端那条路还没接。
struct NoopUploadTransport: UploadTransport {
    func upload(_ batches: [UploadPayload]) async throws {
        guard !batches.isEmpty else { return }
        print("[Upload] 服务端路径未接入：本次本应上传 \(batches.count) 条，已跳过")
    }
}
