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

        // ⚠️ 授权还没被用户决定时，**不推进任何同步游标**。
        //    原因见 `HealthAuthorizer.isAuthorizationPending()`：未授权时
        //    HealthKit 返回"空结果 + 有效的新游标"，推进之后就永远补不回
        //    授权前那段历史，而且一点报错都没有。
        //    这一条对 v1.8 尤其关键 —— 心跳序列是**新增的**读权限，
        //    后台刷新完全可能在用户点授权之前先跑一轮。
        // 括号是必要的：`await !foo()` 的写法把 `!` 和 `await` 混在一起，
        // 不写成 `!(await foo())` 就是在赌解析顺序 —— 没必要赌。
        let authorizationPending = await HealthAuthorizer.shared.isAuthorizationPending()
        let canAdvanceAnchor = !authorizationPending

        for metric in MetricCatalog.all where isEnabled(metric) {
            if Date() > deadline {
                print("[Sync] 超时，剩余指标留到下次：\(metric.id)")
                break
            }
            do {
                // ⚠️ 删除也要转发给 iPhone：手表本地删了、手机不删，
                //    手机上就会一直显示用户已经删掉的数据（正确性问题）。
                let deleted = try await syncOne(metric,
                                                deadline: deadline,
                                                canAdvanceAnchor: canAdvanceAnchor)
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

        // ——— 心跳序列（RR 间期）：**独立通道** ———
        // 为什么不放进上面那个循环：它是 `HKSeriesType` 而不是 quantity/category，
        // 进不了 `MetricCatalog`；而且要"两步查询 + 逐拍展开"，
        // 成本和普通样本不是一个量级，必须单独限量。见 `syncHeartbeatSeries`。
        do {
            let seriesInserted = try await syncHeartbeatSeries(deadline: deadline,
                                                              canAdvanceAnchor: canAdvanceAnchor)
            if seriesInserted > 0 {
                print("[Sync] 心跳序列新增 \(seriesInserted) 条")
            }
        } catch {
            // 单独 catch：心跳序列这条路断了，不该影响心率、血氧那些已经同步好的指标
            print("[Sync] 心跳序列失败：\(error.localizedDescription)")
            roundErrors.append("heartbeat: \(error.localizedDescription)")
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
    private func syncOne(_ metric: MetricDescriptor,
                         deadline: Date,
                         canAdvanceAnchor: Bool) async throws -> [UUID] {
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
            // 这样万一被系统杀掉，下次不会从头再来。
            // ⚠️ 但**授权未决时只前进内存里的游标、不落盘**：
            //    落盘会让"之后才授权"永远补不回授权前的历史（见 syncAll 的说明）；
            //    而不前进内存游标又会让**同一轮的分页反复拉同一页**（死循环）。
            //    两者都要满足，所以拆成"内存游标始终前进 / 落盘看授权"。
            if let newAnchor = result.newAnchor {
                if canAdvanceAnchor {
                    try await store.saveAnchor(newAnchor, for: metric.id)
                }
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

    // MARK: - 心跳序列（RR 间期的唯一自动来源）

    /// anchor 用的键。**不是指标 id** —— 心跳序列是 `HKSeriesType`，
    /// 进不了 `MetricCatalog`（那张表是按 quantity/category 设计的：
    /// 一条样本一个数值，而一条序列里有几百个时间戳）。
    private static let heartbeatAnchorKey = "heartbeat_series"

    /// 首次同步回看几天
    private static let heartbeatLookbackDays = 7

    /// 单轮最多**展开**多少条序列的逐拍数据。
    ///
    /// 为什么必须限量：展开走 `HKHeartbeatSeriesQuery`，它是**逐拍回调**的
    /// （一条序列几百次回调）。而手表后台总共只有"几秒"。
    /// 普通样本是一次回调返回一批，两者成本不是一个量级。
    private static let maxSeriesToExpandPerRound = 6

    /// 单轮最多取回多少条序列的**元信息**（不展开，只是看看有哪些）
    private static let heartbeatPageSize = 20

    /// 同步心跳序列。返回本轮**新存入**的条数。
    ///
    /// ## 两步查询
    /// ① `HKAnchoredObjectQuery`（type = `HKSeriesType.heartbeat()`）拿到"有哪些序列"；
    /// ② 对每一条**还没存过**的跑 `HKHeartbeatSeriesQuery` 取逐拍时间戳。
    ///
    /// ## 游标只在"这一页全都处理完"时才前进
    /// 如果因为时间不够、或超过了展开上限而留下没处理的序列，就**不保存新 anchor**
    /// —— 下一轮会重新拿到同一页，但已经存过的会被 `storedHeartbeatSeriesUUIDs` 跳过，
    /// 所以一定能推进。
    /// 反过来如果无条件保存 anchor，被跳过的那几条就**永远不会再被看到**了。
    @discardableResult
    private func syncHeartbeatSeries(deadline: Date, canAdvanceAnchor: Bool) async throws -> Int {
        var anchor: HKQueryAnchor?
        do {
            anchor = try await store.anchor(for: Self.heartbeatAnchorKey)
        } catch {
            print("[Heartbeat] 游标损坏，清除后按首次同步重来：\(error.localizedDescription)")
            try? await store.clearAnchor(for: Self.heartbeatAnchorKey)
            anchor = nil
        }

        let predicate: NSPredicate?
        if anchor == nil {
            let from = Calendar.current.date(byAdding: .day,
                                             value: -Self.heartbeatLookbackDays,
                                             to: .now) ?? .distantPast
            predicate = HKQuery.predicateForSamples(withStart: from, end: nil, options: .strictStartDate)
        } else {
            predicate = nil
        }

        let result = try await fetchIncremental(type: MetricCatalog.heartbeatSeriesType,
                                                predicate: predicate,
                                                anchor: anchor,
                                                limit: Self.heartbeatPageSize)

        // ⚠️ 防御：满页但**没有新游标**时，下一轮查询会和这一轮完全一样。
        //    正常路径上游标一定前进，但代码不该把"正常"当唯一可能。
        if result.samples.count >= Self.heartbeatPageSize && result.newAnchor == nil {
            print("[Heartbeat] 满页但游标未前进，本轮不再推进（防死循环）")
        }

        let series = result.samples.compactMap { $0 as? HKHeartbeatSeriesSample }
        guard !series.isEmpty else {
            // ⚠️ 一条都没有时**只有授权已决**才落盘游标。
            //    否则"还没授权 → 空结果 + 有效新游标 → 推进"
            //    会让用户之后授权成功时**永久丢掉授权前的历史**（零报错）。
            //    不落盘的代价只是每轮重查一次 7 天窗口，很便宜。
            if let newAnchor = result.newAnchor, canAdvanceAnchor {
                try await store.saveAnchor(newAnchor, for: Self.heartbeatAnchorKey)
            }
            return 0
        }

        let stored = (try? await store.storedHeartbeatSeriesUUIDs(among: series.map(\.uuid))) ?? []
        let toProcess = series.filter { !stored.contains($0.uuid) }

        var inserted = 0
        var expandFailures = 0
        var deferred = 0

        for (index, sample) in toProcess.enumerated() {
            if Date() > deadline || inserted >= Self.maxSeriesToExpandPerRound {
                deferred = toProcess.count - index
                break
            }
            do {
                let record = try await expandHeartbeatSeries(sample)
                inserted += try await store.upsertHeartbeatSeries([record])
                try await store.enqueue([PendingUploadRecord(
                    sampleUUID: record.uuid,
                    metricID: WatchWire.heartbeatSeriesMarker,
                    payload: record.payload.encoded()
                )])
            } catch {
                // ⚠️ 刻意**跳过而不是死等重试**：失败几乎都是"这条序列的数据已经不可读"
                //    （而不是暂时性故障 —— anchored query 刚刚才成功返回了它）。
                //    若在这里留着不前进，游标会被这一条**永久卡住**，
                //    同一页里后面的新序列也全都同步不到。
                //    按「不追求完整性」原则：丢一条（约 100 拍）好过卡死整条通道。
                expandFailures += 1
                print("[Heartbeat] ⚠️ 展开失败，跳过 \(sample.uuid)：\(error.localizedDescription)")
            }
        }

        if deferred == 0, let newAnchor = result.newAnchor, canAdvanceAnchor {
            try await store.saveAnchor(newAnchor, for: Self.heartbeatAnchorKey)
        }

        if inserted > 0 || expandFailures > 0 || deferred > 0 {
            print("[Heartbeat] 本页 \(series.count) 条：新增 \(inserted)"
                  + "，已存跳过 \(series.count - toProcess.count)"
                  + "，展开失败 \(expandFailures)"
                  + (deferred > 0 ? "，留到下轮 \(deferred)" : ""))
        }
        return inserted
    }

    /// 把一条心跳序列展开成可落库的记录。
    ///
    /// ## ⚠️ 手表在这里**不做任何解释性计算**
    /// 只把 HealthKit 给的逐拍时间戳（相对序列起点的秒数）转成毫秒偏移就落库。
    /// RR 间期、Poincaré、SDNN、以后可能加的 PSD —— **全部在手机上算**。
    ///
    /// 为什么这条边界值得守：手表代码的迭代成本极高（改一次要走 watchOS 发布
    /// + 用户装到表上），而手机随时能更新。手表越"哑"，以后加新分析的代价越小。
    /// 自检脚本第 16 节会断言手表侧不出现 `RRPacking.pack`。
    ///
    /// 📌 注意这里**不过滤**非正的时间戳（收尾那次回调可能带 0 或重复值）。
    /// 过滤搬到手机的 `HeartbeatSeriesPayload.intervals(fromOffsets:)` 里做 ——
    /// 语义没变，只是"谁来判断"变了。
    private func expandHeartbeatSeries(_ sample: HKHeartbeatSeriesSample) async throws -> HeartbeatSeriesRecord {
        let stamps = try await fetchHeartbeats(of: sample)

        // 秒 → 毫秒。负数（理论上不会有）由 `BeatPacking.pack` 钳成 0。
        let offsets = stamps.map { Int(($0 * 1000).rounded()) }

        let source = sample.sourceRevision.source
        let device = sample.device

        return HeartbeatSeriesRecord(uuid: sample.uuid,
                                     startDate: sample.startDate,
                                     endDate: sample.endDate,
                                     offsetsPacked: BeatPacking.pack(offsets),
                                     beatCount: stamps.count,
                                     ingestedAt: .now,
                                     sourceBundleID: source.bundleIdentifier,
                                     sourceName: source.name,
                                     deviceName: device?.name,
                                     deviceModel: device?.model)
    }

    /// 读出一条心跳序列里的**逐拍时间戳**（相对序列起点的秒数）。
    ///
    /// ⚠️ `dataHandler` 是**逐拍回调**的，`done` 为 true 时才是最后一次。
    /// continuation 必须**恰好 resume 一次**，所以用 `finished` 守住；
    /// 并且 `error != nil` 时也要 resume —— 否则会永久挂住，把后台预算烧光
    /// （然后被系统按退避算法收紧额度）。
    private func fetchHeartbeats(of sample: HKHeartbeatSeriesSample) async throws -> [TimeInterval] {
        try await withCheckedThrowingContinuation { continuation in
            var stamps: [TimeInterval] = []
            var finished = false

            let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceStart, _, done, error in
                if let error {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                // ⚠️ 无论 done 与否都收下这个时间戳：Apple **没有文档说明**
                //    "收尾那一次回调带不带有效时间戳"。
                //    多收一个无意义的值，会在算 RR 时被 `delta > 0` 过滤掉；
                //    少收一个则是**真的丢一拍**（少一个间期）。两害相权取其轻。
                stamps.append(timeSinceStart)

                if done && !finished {
                    finished = true
                    continuation.resume(returning: stamps)
                }
            }
            healthStore.execute(query)
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
