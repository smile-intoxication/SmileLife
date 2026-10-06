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
    private let flusher: OutboxFlusher
    private let deletions: DeletionQueue

    /// 防止前台同步和后台唤醒撞在一起
    private var isRunning = false

    init(store: HealthStore,
         snapshotService: SnapshotService,
         flusher: OutboxFlusher,
         deletions: DeletionQueue) {
        self.store = store
        self.snapshotService = snapshotService
        self.flusher = flusher
        self.deletions = deletions
    }

    // MARK: - 对外入口

    /// 跑一轮同步：拉增量 → 落库 → 重建快照 → 清理 → 把数据交给 iPhone。
    @discardableResult
    func syncAll(reason: Reason) async -> SyncStatus {
        guard !isRunning else { return SharedStore.readStatus() }
        isRunning = true
        defer { isRunning = false }

        var status = SharedStore.readStatus()
        status.lastAttemptAt = .now
        // 先把上一轮的错误清掉：否则一条早已自愈的旧错误会永远留在界面上常驻显示
        status.lastError = nil
        var roundErrors: [String] = []
        var succeededMetrics = 0

        // 后台唤醒时给整轮同步设一个上限，留出时间写快照和回调 completion。
        // 官方只说"几秒"，这里取 8 秒，宁可少同步几个指标也不要被系统杀掉。
        let deadline = Date().addingTimeInterval(reason == .background ? 8 : 60)

        for metric in MetricCatalog.all where isEnabled(metric) {
            if Date() > deadline {
                print("[Sync] 超时，剩余指标留到下次：\(metric.id)")
                break
            }
            do {
                // ⚠️ 删除也要转发给 iPhone：手表本地删了、手机不删，
                //    手机上就会一直显示用户已经删掉的数据（正确性问题）。
                let deleted = try await syncOne(metric, deadline: deadline)
                if !deleted.isEmpty {
                    await deletions.append(deleted)
                }
                succeededMetrics += 1
            } catch {
                // 单个指标失败不影响其它指标。锁屏读不到是最常见的原因。
                print("[Sync] \(metric.id) 失败：\(error.localizedDescription)")
                roundErrors.append("\(metric.id): \(error.localizedDescription)")
            }
        }

        // 重建快照（小组件的数据源）
        await snapshotService.rebuild()

        // ——— 保留策略：只留最近 7 天 ———
        // 有 #Index 撑着，这条删除不会全表扫描。
        //
        // ⚠️ 这里删掉的样本**刻意不转发给 iPhone**。
        //    两者是不同的东西：
        //      · `HKDeletedObject`（上面的 deletions）= 用户主动删掉了数据 → 手机必须跟着删
        //      · 这里的保留清理 = 手表磁盘放不下 → 手机是长期档案，本来就该留着
        //    把保留清理也转发出去，会变成"手机上永远只有 7 天数据"，
        //    那正是做手机端图表要解决的问题。
        if let removed = try? await store.enforceRetention(), removed > 0 {
            print("[Retention] 清理了 \(removed) 条超过 \(StoragePolicy.retentionDays) 天的样本（手机端档案不受影响）")
        }
        // 上传队列也设上限：按"不追求完整性"原则，满了丢最老的即可。
        // ⚠️ 现在队列**真的会被消费**了（由 OutboxFlusher 发往 iPhone），
        //    所以只在 iPhone 长期不可达时才会触发这个丢弃，丢的条数会被记进日志。
        if let dropped = try? await store.trimUploadQueue(), dropped > 0 {
            print("[Upload] 队列满，丢弃最老 \(dropped) 条")
        }

        // ——— 把手表采到的数据交给 iPhone ———
        // 刻意放在**最后**：同步的重点是"先把数据落到自己的库里"（落库即安全），
        // 发送只花剩余预算，发不完的留在队列里等下一轮，或者等 didFinish 腾出位置。
        let flushReport = await flusher.flush(budget: reason == .background ? 3 : 20)
        if let stop = flushReport.stopReason, !flushReport.stopIsNormal {
            // 只有"真的坏了"才写进错误展示；"系统队列未腾空"是正常背压，不该变红。
            roundErrors.append("发送到手机：\(stop)")
        }

        // ⚠️ 只有真的成功跑完至少一个指标才更新 lastSuccessAt。
        // 否则「所有指标都因为锁屏而失败」时界面会显示"更新于 1 秒前"，
        // 而这个字段的语义是"最后一次成功同步"——那会直接误导真机排查。
        if succeededMetrics > 0 {
            status.lastSuccessAt = .now
        }
        status.lastError = roundErrors.isEmpty ? nil : roundErrors.joined(separator: "; ")
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

    /// 单个指标一轮最多翻多少页（防死循环 + 防一次吃光后台预算）。
    /// 30 页 x 2000 条 = 单轮最多 6 万条，足够覆盖首次同步，也不会无限跑。
    private static let maxPagesPerMetric = 30

    /// 同步单个指标。
    ///
    /// - Returns: 本轮被 HealthKit 通知**删除**的样本 uuid。
    ///   调用方要把它们转发给 iPhone —— 手表本地删了、手机不删，
    ///   手机上就会一直显示用户已经删掉的数据。
    @discardableResult
    private func syncOne(_ metric: MetricDescriptor, deadline: Date) async throws -> [UUID] {
        // ⚠️ 游标损坏时不要让它把这个指标永久卡死：清掉坏游标、按首次同步重来。
        //    （锚点是 NSSecureCoding 存档，跨版本/损坏时会解档失败；
        //      不处理的话每一轮都在第一行以同样方式失败，而且 lastError 只有单字段，
        //      会被后面指标的报错覆盖掉，等于静默停摆。）
        var anchor: HKQueryAnchor?
        do {
            anchor = try await store.anchor(for: metric.id)
        } catch {
            print("[Sync] \(metric.id) 游标损坏，清除后按首次同步重来：\(error.localizedDescription)")
            try? await store.clearAnchor(for: metric.id)
            anchor = nil
        }

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
        var deletedUUIDs: [UUID] = []
        var shouldContinue = true
        var page = 0

        while shouldContinue {
            // ⚠️ 循环**内部**也要检查超时：只在指标之间检查的话，
            //    首次同步心率（1 天最坏 17,280 条 ≈ 9 页）会把后台那几秒预算一次吃光，
            //    被系统 SIGKILL 之后连 setTaskCompleted 都来不及回调，
            //    系统随后会按退避算法收紧这个 app 的后台额度。
            if Date() > deadline || Task.isCancelled {
                print("[Sync] \(metric.id) 本轮时间用完，剩余页留到下次")
                break
            }

            let result = try await fetchIncremental(type: metric.sampleType,
                                                    predicate: predicate,
                                                    anchor: anchor,
                                                    limit: Self.pageSize)

            let records = result.samples.compactMap { makeRecord($0, metric: metric) }
            try await store.upsert(records)
            // 收集删除 uuid：本地删掉的同时也要转发给 iPhone（正确性，不是完整性）
            let deleted = result.deleted.map(\.uuid)
            try await store.delete(uuids: deleted)
            deletedUUIDs.append(contentsOf: deleted)
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

            // ⚠️ 防御：满页但**没有新游标**时，下一轮查询会和这一轮完全一样，
            //    会无限重拉同一批 2000 行（每轮都 upsert + 入队，前后台都会卡死）。
            //    Apple 文档保证正常路径上游标一定前进，但代码不该把"正常"当唯一可能。
            if result.samples.count >= Self.pageSize && result.newAnchor == nil {
                print("[Sync] \(metric.id) 满页但游标未前进，停止分页（防死循环）")
                break
            }

            page += 1
            if page >= Self.maxPagesPerMetric {
                print("[Sync] \(metric.id) 达到单轮页数上限 \(Self.maxPagesPerMetric)，余下留到下次")
                break
            }

            // 只有"拉满了"才说明后面可能还有，否则本轮结束。
            // 翻页沿用同一个 predicate 与最新 anchor，退出条件交给 HealthKit 的返回数量。
            shouldContinue = result.samples.count >= Self.pageSize
        }

        if totalNew > 0 {
            print("[Sync] \(metric.id)：新增 \(totalNew) 条")
        }
        return deletedUUIDs
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
        case .quantity(let unit):
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
