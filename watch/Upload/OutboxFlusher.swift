import Foundation

/// 待上传队列里的一行**载荷**。
///
/// 队列里混着两种东西，用 `PendingUploadRecord.metricID` 上的标记区分
/// （见 `WatchWire.heartbeatSeriesMarker`）：
/// - 普通样本（一条 = 一个数值）
/// - 心跳序列（一条 = 几百个逐拍时间戳）
enum OutboxItem: Sendable {
    case sample(UploadPayload)
    case heartbeatSeries(HeartbeatSeriesPayload)
}

/// 待上传队列里的一行，已经解码成线上格式。
///
/// 刻意做成 `Sendable` 的值类型：`PendingUploadRecord` 是 SwiftData 的 `@Model`，
/// **不能跨 actor 传递**（和 `HealthStore` 里 `MetricSampleStats` 同样的理由）。
struct OutboxRow: Sendable {
    let id: UUID
    let item: OutboxItem
    /// 已编码负载的字节数，用于分批时估算大小
    let byteCount: Int
}

/// 待上传队列 → iPhone 的搬运工。
///
/// ## 送达语义：**至少一次（at-least-once）**，靠手机端幂等去重
///
/// `transferUserInfo` 的官方语义是"把字典加进系统队列，传输在后台继续，
/// **即使 app 被挂起或终止**"。也就是说系统会**持久化**它自己那份队列。
/// 所以本实现在 `transferUserInfo` 被系统收下之后，就立刻把手表这边的行删掉
/// —— 不做"等送达确认再删"的记账。
///
/// 为什么不做记账：那样要额外持久化 batchID ↔ 队列行的映射，而
/// `didFinish` 回调**可能在 app 被系统重启之后才到达**，那时内存里的映射已经没了。
/// 结果是一部分行永远等不到确认、永远重发，反而更难查。
/// 现在这套的最坏情况是"极端情况下丢一小段"——这符合已确认的
/// 「不追求数据完整性」，而且手表本地还有 7 天副本。
/// 手机端按 `uuid` upsert，所以**任何重复投递都无害**，这是能这么做的前提。
///
/// ## 背压
/// 系统队列压着太多未完成传输时**停止发送**，把手表这边的行留在队列里。
/// 理由见 `WatchWire.maxOutstandingTransfers` 的注释：
/// 我们宁可丢自己看得见、能记数的那一份，也不要把数据交给一个
/// 官方没有承诺过溢出行为的地方。
actor OutboxFlusher {

    /// 一轮发送的结果，给日志和诊断界面用。
    struct Report: Sendable {
        var batches = 0
        var samples = 0
        var heartbeatSeries = 0
        var deletions = 0
        /// 为什么停下来。`nil` 表示队列已经发空。
        var stopReason: String?
        /// 停下来是不是"正常情况"。
        /// ⚠️ 必须区分：`"系统队列未腾空"` 是**正常背压**，下一轮会继续；
        /// 而 `"WCSession 尚未激活"` 是**真的坏了**，界面上要能一眼看出来。
        var stopIsNormal = true

        var didSendAnything: Bool { batches > 0 }
    }

    /// 单次从库里取多少行。取多了没意义——分批上限会先起作用。
    private static let fetchLimit = 600

    private let store: HealthStore
    private let link: WatchLinkSession
    private let deletions: DeletionQueue

    /// 防重入：前台同步和后台唤醒可能同时走到这里。
    private var isRunning = false

    private(set) var lastFlushAt: Date?
    private(set) var lastReport: Report?

    init(store: HealthStore, link: WatchLinkSession, deletions: DeletionQueue) {
        self.store = store
        self.link = link
        self.deletions = deletions
    }

    /// 诊断界面读的一小份快照。
    func snapshot() -> (lastFlushAt: Date?, report: Report?) {
        (lastFlushAt, lastReport)
    }

    /// 把待上传队列尽量发出去。
    ///
    /// - Parameter budget: 本轮最多花多少秒。
    ///   后台唤醒总共只有"几秒"预算（见 `BackgroundCoordinator`），
    ///   所以这里必须能被硬性截断，不能"发完为止"。
    @discardableResult
    func flush(budget: TimeInterval) async -> Report {
        guard !isRunning else {
            var report = Report()
            report.stopReason = "上一轮还在发送"
            return report
        }
        isRunning = true
        defer { isRunning = false }

        var report = Report()

        // ——— 前置检查：这两种情况下发送是**真的发不出去**，不是"没数据" ———
        guard link.isSupported else {
            report.stopReason = "本设备不支持 WCSession"
            report.stopIsNormal = false
            return finish(report)
        }
        guard link.isActivated else {
            report.stopReason = "WCSession 尚未激活"
            report.stopIsNormal = false
            return finish(report)
        }

        let deadline = Date().addingTimeInterval(budget)
        var pendingDeletions = await deletions.drain()

        while true {
            if Date() >= deadline {
                report.stopReason = "本轮时间用完"
                break
            }
            if link.outstandingCount >= WatchWire.maxOutstandingTransfers {
                report.stopReason = "系统队列未腾空（\(link.outstandingCount)）"
                break
            }

            let rows = (try? await store.outboxBatch(limit: Self.fetchLimit)) ?? []
            if rows.isEmpty {
                // 队列空了，但可能还有删除没送出去 —— 删除与样本是**独立列表**，
                // 一条样本都没有的时候仍然要把删除送出去，否则手机上永远显示已删除的数据。
                if !pendingDeletions.isEmpty {
                    let batch = SampleBatch(samples: [], deletedUUIDs: pendingDeletions)
                    if link.enqueue(batch) {
                        report.batches += 1
                        report.deletions += pendingDeletions.count
                        pendingDeletions = []
                    } else {
                        report.stopReason = "系统未接收删除批次（会话未激活）"
                        report.stopIsNormal = false
                    }
                }
                break
            }

            for group in Self.group(rows) {
                if Date() >= deadline {
                    report.stopReason = "本轮时间用完"
                    break
                }
                if link.outstandingCount >= WatchWire.maxOutstandingTransfers {
                    report.stopReason = "系统队列未腾空（\(link.outstandingCount)）"
                    break
                }

                // 一个批次里可以**同时**有样本和心跳序列 —— `SampleBatch` 两个字段都带
                var payloads: [UploadPayload] = []
                var series: [HeartbeatSeriesPayload] = []
                for row in group {
                    switch row.item {
                    case .sample(let payload):       payloads.append(payload)
                    case .heartbeatSeries(let item): series.append(item)
                    }
                }
                let batch = SampleBatch(samples: payloads,
                                        deletedUUIDs: pendingDeletions,
                                        heartbeatSeries: series)

                guard link.enqueue(batch) else {
                    report.stopReason = "系统未接收（会话未激活）"
                    report.stopIsNormal = false
                    break
                }

                // ⚠️ **顺序不能反**：先确认系统收下，再删自己的队列。
                //    先删后发的话，`transferUserInfo` 那一刻抛错就真的丢了。
                try? await store.removeUploads(ids: group.map(\.id))

                pendingDeletions = []
                report.batches += 1
                report.samples += payloads.count
                report.heartbeatSeries += series.count
                report.deletions += batch.deletedUUIDs.count
            }

            if report.stopReason != nil { break }
        }

        // 没能送出去的删除必须放回去，否则它们只存在于内存里，本轮结束就没了
        if !pendingDeletions.isEmpty {
            await deletions.restore(pendingDeletions)
        }

        return finish(report)
    }

    private func finish(_ report: Report) -> Report {
        lastFlushAt = .now
        lastReport = report

        if let reason = report.stopReason, !report.stopIsNormal {
            print("[Outbox] ⚠️ 发送中止：\(reason)")
        } else if report.didSendAnything {
            print("[Outbox] 已交给系统：\(report.batches) 批 / "
                  + "\(report.samples) 条样本 / \(report.heartbeatSeries) 条心跳序列 / "
                  + "\(report.deletions) 条删除"
                  + (report.stopReason.map { "（\($0)）" } ?? ""))
        }
        return report
    }

    // MARK: - 分批

    /// 按"**条数** + **字节数**"两个上限切批。
    ///
    /// 两个上限都要：条数上限防"200 条超长文本撑爆单包"，
    /// 字节数上限防"20 条但每条都很大"。只守一个都会漏。
    static func group(_ rows: [OutboxRow]) -> [[OutboxRow]] {
        var result: [[OutboxRow]] = []
        var current: [OutboxRow] = []
        var bytes = 0

        for row in rows {
            let wouldExceed = !current.isEmpty
                && (current.count >= WatchWire.maxSamplesPerBatch
                    || bytes + row.byteCount > WatchWire.maxBytesPerBatch)
            if wouldExceed {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(row)
            bytes += row.byteCount
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
