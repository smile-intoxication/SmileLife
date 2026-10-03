import Foundation
import HealthKit

/// 增量同步引擎——手表端功能 1 的实现。
///
/// ## 核心机制
/// 每个指标一个持久化的 `HKQueryAnchor`：
/// - **首次**（anchor == nil）：限定回看窗口拉一批，建立基线；
/// - **之后**：`HKAnchoredObjectQuery` 只返回**新增 / 删除**的样本。
///
/// ## 为什么不用 HKObserverQuery
/// 官方明确：`HKAnchoredObjectQuery` **不能注册后台投递**，
/// 而 `HKObserverQuery` 的后台投递又依赖表盘上的 complication 且每小时约 4 次。
/// 对"定期把数据抄进自己库里"这个目标来说，**被唤醒后跑一次 anchored query 就够**，
/// 不需要常驻 observer——少一个长期存活的查询，也少一类 bug。
///
/// ## 重要现实约束（详见调研文档）
/// - 后台每小时约 4 次，且**前提是表盘上有本 app 的 complication**；
/// - 每次后台只有"几秒"，所以**超时必须能优雅放弃**，不能重试到被杀；
/// - 设备锁定时 HealthKit store 是加密的，**可能读不到**——这属于正常情况，不是错误。
actor HealthSyncEngine {

    enum Reason {
        case foreground   // 用户打开了 app，时间充足
        case background   // 后台唤醒，只有几秒，要快
    }

    private let healthStore = HKHealthStore()
    private let store: HealthStore
    private let snapshotService: SnapshotService

    /// 防止前台同步和后台唤醒撞在一起
    private var isRunning = false

    init(store: HealthStore, snapshotService: SnapshotService) {
        self.store = store
        self.snapshotService = snapshotService
    }

    // MARK: - 对外入口

    /// 跑一轮同步：拉增量 → 落库 → 重建快照 → （预留）入上传队列。
    @discardableResult
    func syncAll(reason: Reason) async -> SyncStatus {
        guard !isRunning else { return SharedStore.readStatus() }
        isRunning = true
        defer { isRunning = false }

        var status = SharedStore.readStatus()
        status.lastAttemptAt = .now

        // 后台唤醒时给整轮同步设一个上限，留出时间写快照和回调 completion。
        // 官方只说"几秒"，这里取 8 秒，宁可少同步几个指标也不要被系统杀掉。
        let deadline = Date().addingTimeInterval(reason == .background ? 8 : 60)

        for metric in MetricCatalog.all where isEnabled(metric) {
            if Date() > deadline {
                print("[Sync] 超时，剩余指标留到下次：\(metric.id)")
                break
            }
            do {
                try await syncOne(metric)
            } catch {
                // 单个指标失败不影响其它指标。锁屏读不到是最常见的原因。
                print("[Sync] \(metric.id) 失败：\(error.localizedDescription)")
                status.lastError = "\(metric.id): \(error.localizedDescription)"
            }
        }

        // 重建快照（小组件的数据源）
        await snapshotService.rebuild()

        // ——— 保留策略：只留最近 7 天 ———
        // 有 #Index 撑着，这条删除不会全表扫描。
        if let removed = try? await store.enforceRetention(), removed > 0 {
            print("[Retention] 清理了 \(removed) 条超过 \(StoragePolicy.retentionDays) 天的样本")
        }
        // 上传队列也设上限：按"不追求完整性"原则，满了丢最老的即可
        _ = try? await store.trimUploadQueue()

        status.lastSuccessAt = .now
        status.totalSamplesStored = (try? await store.totalCount()) ?? 0
        SharedStore.writeStatus(status)
        return status
    }

    // MARK: - 单个指标

    /// 单页拉取上限。
    ///
    /// 官方建议：给 `HKAnchoredObjectQuery` 一个 limit，然后**从它返回的 anchor 继续**，
    /// 而不是按日期翻页。这样在心率密度暴涨时也不会一次把上万条样本拉进内存。
    private static let pageSize = 2_000

    private func syncOne(_ metric: MetricDescriptor) async throws {
        var anchor = try await store.anchor(for: metric.id)

        // 首次同步（anchor 为空）限定回看窗口；有 anchor 时交给 HealthKit 做增量。
        let predicate: NSPredicate?
        if anchor == nil {
            let from = Calendar.current.date(byAdding: .day,
                                             value: -metric.initialLookbackDays,
                                             to: .now) ?? .distantPast
            predicate = HKQuery.predicateForSamples(withStart: from, end: nil, options: .strictStartDate)
        } else {
            predicate = nil
        }

        var totalNew = 0
        var shouldContinue = true

        while shouldContinue {
            let result = try await fetchIncremental(type: metric.sampleType,
                                                    predicate: predicate,
                                                    anchor: anchor,
                                                    limit: Self.pageSize)

            let records = result.samples.compactMap { makeRecord($0, metric: metric) }
            try await store.upsert(records)
            try await store.delete(uuids: result.deleted.map(\.uuid))
            totalNew += records.count

            // 保存游标 —— 即使后面还有页，也要先落盘，
            // 这样万一被系统杀掉，下次不会从头再来
            if let newAnchor = result.newAnchor {
                try await store.saveAnchor(newAnchor, for: metric.id)
                anchor = newAnchor
            }

            // ——— 功能 3 的预留接点：把新样本放进待上传队列 ———
            // 这一版只入队不发送。等确认走手机还是走服务器，接一个 UploadTransport 即可。
            if !records.isEmpty {
                let pending = records.map { record in
                    PendingUploadRecord(
                        sampleUUID: record.uuid,
                        metricID: record.metricID,
                        payload: UploadPayload(record: record).encoded()
                    )
                }
                try await store.enqueue(pending)
            }

            // 只有"拉满了"才说明后面可能还有，否则本轮结束。
            // 翻页沿用同一个 predicate 与最新 anchor，退出条件交给 HealthKit 的返回数量。
            shouldContinue = result.samples.count >= Self.pageSize
        }

        if totalNew > 0 {
            print("[Sync] \(metric.id)：新增 \(totalNew) 条")
        }
    }

    // MARK: - Anchored query 的 async 包装

    private struct FetchResult {
        let samples: [HKSample]
        let deleted: [HKDeletedObject]
        let newAnchor: HKQueryAnchor?
    }

    /// 用**一次性**的 `HKAnchoredObjectQuery`（不带 updateHandler）。
    /// 带 updateHandler 的版本会持续投递，不适合这种"跑一轮就结束"的场景。
    ///
    /// `limit` 是必须的：官方建议给它一个上限，然后**从返回的 anchor 继续**，
    /// 而不是按日期翻页。心率密度暴涨时这能避免一次把上万条样本读进内存。
    private func fetchIncremental(type: HKSampleType,
                                  predicate: NSPredicate?,
                                  anchor: HKQueryAnchor?,
                                  limit: Int) async throws -> FetchResult {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: FetchResult(
                    samples: samples ?? [],
                    deleted: deleted ?? [],
                    newAnchor: newAnchor
                ))
            }
            healthStore.execute(query)
        }
    }

    // MARK: - HKSample → SampleRecord

    private func makeRecord(_ sample: HKSample, metric: MetricDescriptor) -> SampleRecord? {
        let record = SampleRecord(
            uuid: sample.uuid,
            metricID: metric.id,
            startDate: sample.startDate,
            endDate: sample.endDate
        )

        switch metric.shape {
        case .quantity(let unit, _):
            guard let q = sample as? HKQuantitySample else { return nil }
            record.value = q.quantity.doubleValue(for: unit)
            record.unitString = unit.unitString

        case .category:
            guard let c = sample as? HKCategorySample else { return nil }
            record.categoryValue = c.value
        }

        // ——— 来源追踪 ———
        // 官方推荐用 HKSourceRevision + HKDevice 判断来源，
        // 不要用已废弃的 HKMetadataKeyDeviceManufacturerName 字符串。
        let source = sample.sourceRevision.source
        record.sourceBundleID = source.bundleIdentifier
        record.sourceName = source.name
        let device = sample.device
        record.deviceName = device?.name
        record.deviceModel = device?.model
        record.deviceManufacturer = device?.manufacturer

        return record
    }

    // MARK: - 开关

    /// 用户可以在设置里关掉某些指标。默认从 UserDefaults 读，
    /// 未设置过就按 `enabledByDefault`。
    private func isEnabled(_ metric: MetricDescriptor) -> Bool {
        let key = "metric.enabled.\(metric.id)"
        if UserDefaults.standard.object(forKey: key) == nil {
            return metric.enabledByDefault
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}
