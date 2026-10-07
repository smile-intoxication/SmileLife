import Foundation
import SwiftData

/// 概览界面用的"每个指标一行"。
///
/// 刻意做成 `Sendable` 值类型：`PhoneSample` 是 SwiftData 的 `@Model`，
/// **不能跨 actor 传递**（和手表端 `HealthStore` 里 `MetricSampleStats` 同样的理由）。
struct PhoneMetricSummary: Sendable, Identifiable {
    var id: String { metricID }
    let metricID: String
    let count: Int
    let latestDate: Date?
    let latestValue: Double?
    let latestCategoryValue: Int?
    let earliestDate: Date?

    var hasData: Bool { count > 0 && latestDate != nil }
}

/// 画折线用的一行（已经合并到展示粒度）。
struct RollupPoint: Sendable, Identifiable {
    var id: Date { bucketStart }
    let bucketStart: Date
    let count: Int
    /// 桶内样本值之和。**可加**：合并两个桶时 sum 与 count 直接相加。
    let sum: Double
    let minValue: Double
    let maxValue: Double

    var average: Double { count > 0 ? sum / Double(count) : 0 }
}

/// 画睡眠图用的一段（枚举型样本）。
struct CategoryPoint: Sendable, Identifiable {
    var id: UUID { uuid }
    let uuid: UUID
    let startDate: Date
    let endDate: Date
    let categoryValue: Int

    var hours: Double { max(0, endDate.timeIntervalSince(startDate)) / 3600 }
}

/// 一次落库的结果，用来在状态界面/日志里如实说明"这一批到底做了什么"。
struct PhoneIngestResult: Sendable {
    var inserted = 0
    var updated = 0
    var deleted = 0
    var bucketsRebuilt = 0
    var pruned = 0
    /// 新增 / 更新的**心跳序列**条数（RR 间期的来源）
    var heartbeatInserted = 0
    var heartbeatUpdated = 0

    var summary: String {
        var text = "+\(inserted) 新 / \(updated) 更新 / \(deleted) 删除 / \(bucketsRebuilt) 桶"
        if heartbeatInserted + heartbeatUpdated > 0 {
            text += " / 心跳序列 +\(heartbeatInserted) 更新\(heartbeatUpdated)"
        }
        if pruned > 0 { text += " / 清理 \(pruned) 条过期" }
        return text
    }
}

/// iPhone 端本地库的**唯一入口**。所有读写都走这里，视图不直接碰 ModelContext。
///
/// 用 `@ModelActor` 的原因和手表端一样：SwiftData 的 ModelContext 不是线程安全的，
/// 而 WCSession 的接收回调在**后台队列**上。收敛到一个 actor 里最省心，
/// 也天然保证多批数据不会并发写同一个 ModelContext。
///
/// 📌 **落盘位置**：文件型库（`isStoredInMemoryOnly: false`），
/// 存在 app 沙盒里。app 重启、被系统杀掉都不会丢。
@ModelActor
actor PhoneStore {

    /// 上一次执行保留清理的时间。
    ///
    /// 为什么要节流：每收到一批（最多 200 条）就跑一次"统计总数 + 按日期删除"
    /// 在首次全量同步时会做几百次毫无意义的全表统计。
    /// 保留清理一天做一次就够，这里按小时节流。
    private var lastPruneAt: Date?

    // MARK: - 落库

    /// 处理一个批次：删除 → 幂等写入 → 重建受影响的汇总桶 → 保留清理。
    ///
    /// **整体是幂等的**：同一批重发一次，结果完全一样。
    /// 这是"至少一次投递"能成立的前提。
    func ingest(_ batch: SampleBatch) throws -> PhoneIngestResult {
        var result = PhoneIngestResult()
        let now = Date()

        // 受影响的汇总桶。用 Set 去重：一批 200 条通常只落在 1~2 个桶里。
        var touched = Set<String>()
        var touchedMetric = Set<String>()

        // ——— 1. 先处理删除 ———
        // ⚠️ 必须在删除**之前**把它属于哪个桶记下来：
        //    行删掉之后就再也反查不出"哪个桶被影响了"，
        //    那个桶就会永远停在一个偏大的旧值上。
        if !batch.deletedUUIDs.isEmpty {
            let ids = batch.deletedUUIDs
            let doomed = try modelContext.fetch(
                FetchDescriptor<PhoneSample>(predicate: #Predicate { ids.contains($0.uuid) })
            )
            for sample in doomed where sample.value != nil {
                touched.insert(BucketMath.bucket(metricID: sample.metricID,
                                                 date: sample.startDate).key)
            }
            if !doomed.isEmpty {
                try modelContext.delete(model: PhoneSample.self,
                                        where: #Predicate { ids.contains($0.uuid) })
                result.deleted = doomed.count
            }
        }

        // ——— 2. 幂等写入 ———
        if !batch.samples.isEmpty {
            let ids = batch.samples.map(\.uuid)
            let existing = try modelContext.fetch(
                FetchDescriptor<PhoneSample>(predicate: #Predicate { ids.contains($0.uuid) })
            )
            var byUUID: [UUID: PhoneSample] = [:]
            for sample in existing { byUUID[sample.uuid] = sample }

            for payload in batch.samples {
                if let sample = byUUID[payload.uuid] {
                    // 已存在 → 覆盖。静息/步行心率会被系统回填修正，跳过更新会让手机停在旧值。
                    sample.apply(payload, receivedAt: now)
                    result.updated += 1
                } else {
                    let sample = PhoneSample(payload: payload, receivedAt: now)
                    modelContext.insert(sample)
                    byUUID[payload.uuid] = sample
                    result.inserted += 1
                }
                // 只有**数值型**才进汇总桶。枚举型（睡眠）样本量本来就小，
                // 而且"阶段时长求和"这种聚合方式与 min/max/avg 完全不同，
                // 硬塞进同一张表只会让含义变模糊 —— 睡眠图表直接读原始样本。
                if payload.value != nil {
                    let bucket = BucketMath.bucket(metricID: payload.metricID, date: payload.startDate)
                    touched.insert(bucket.key)
                    touchedMetric.insert(payload.metricID)
                }
            }
        }

        // ——— 2.5 心跳序列（RR 间期的来源）———
        // ⚠️ 它**不进汇总桶**：一条序列里是几百个间期，而 Poincaré 图要的是
        //    "逐间配对"，不是某个时间格里的 min/max/avg。
        //    硬塞进汇总表只会让那张表的含义变糊。
        if let incoming = batch.heartbeatSeries, !incoming.isEmpty {
            let ids = incoming.map(\.uuid)
            let existing = try modelContext.fetch(
                FetchDescriptor<PhoneHeartbeatSeries>(predicate: #Predicate { ids.contains($0.uuid) })
            )
            var byUUID: [UUID: PhoneHeartbeatSeries] = [:]
            for record in existing { byUUID[record.uuid] = record }

            for payload in incoming {
                if let record = byUUID[payload.uuid] {
                    record.apply(payload, receivedAt: now)
                    result.heartbeatUpdated += 1
                } else {
                    let record = PhoneHeartbeatSeries(payload: payload, receivedAt: now)
                    modelContext.insert(record)
                    byUUID[payload.uuid] = record
                    result.heartbeatInserted += 1
                }
            }
        }

        try modelContext.save()

        // ——— 3. 重建受影响的汇总桶 ———
        // 刻意**不设数量上限**：一个批次最多 200 条样本，
        // 能影响的桶数天然有界（最坏 200 个桶，实际通常只有 1~2 个）。
        // 设一个上限反而会静默漏掉一部分桶，让图表数据长期偏小。
        for key in touched {
            try rebuildBucket(key: key)
            result.bucketsRebuilt += 1
        }
        if result.bucketsRebuilt > 0 {
            try modelContext.save()
        }

        // ——— 4. 保留清理（节流） ———
        if shouldPrune(now: now) {
            result.pruned = try pruneRawSamples()
            if result.pruned > 0 { try modelContext.save() }
            lastPruneAt = now
        }

        // touchedMetric 目前只用于日志，让"哪些指标真的在动"可以远程看出来
        if !touchedMetric.isEmpty {
            print("[PhoneStore] 本批涉及指标：\(touchedMetric.sorted().joined(separator: ","))")
        }

        return result
    }

    /// 重建一个汇总桶：**从原始样本重算**，而不是增量加减。
    ///
    /// 为什么重算而不是增量更新：增量更新要求我们知道"这条是新增还是覆盖、
    /// 覆盖前的旧值是多少"，而这些状态一旦在传输中丢失（重发、乱序、app 被杀），
    /// 桶就会**永久偏移**，而且没有任何办法发现。
    /// 重算的代价只是多一次按索引的范围查询，换来的是"怎么重发都不会错"。
    private func rebuildBucket(key: String) throws {
        guard let parsed = Self.parse(key: key) else {
            // 键的格式由 BucketMath 唯一决定，解析不出来说明是坏数据。
            // 记一句日志然后跳过：一个坏键不该让整批落库失败。
            print("[PhoneStore] ⚠️ 汇总桶键无法解析，跳过：\(key)")
            return
        }
        try recompute(key: key, metricID: parsed.metricID, bucketStart: parsed.bucketStart)
    }

    private func recompute(key: String, metricID: String, bucketStart: Date) throws {
        let end = bucketStart.addingTimeInterval(PhoneStoragePolicy.bucketSeconds)
        let samples = try modelContext.fetch(
            FetchDescriptor<PhoneSample>(
                predicate: #Predicate {
                    $0.metricID == metricID && $0.startDate >= bucketStart && $0.startDate < end
                }
            )
        )
        let values = samples.compactMap(\.value)

        let existing = try modelContext.fetch(
            FetchDescriptor<PhoneRollup>(predicate: #Predicate { $0.key == key })
        ).first

        // 桶里一条都不剩（样本被用户删了 / 被保留策略清了）→ 桶本身也该消失，
        // 否则图表上会留下一个"有数据但其实是空的"的假点。
        guard !values.isEmpty else {
            if let existing { modelContext.delete(existing) }
            return
        }

        let sum = values.reduce(0, +)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0

        if let existing {
            existing.count = values.count
            existing.sum = sum
            existing.minValue = minValue
            existing.maxValue = maxValue
            existing.computedAt = .now
        } else {
            modelContext.insert(PhoneRollup(key: key,
                                            metricID: metricID,
                                            bucketStart: bucketStart,
                                            count: values.count,
                                            sum: sum,
                                            minValue: minValue,
                                            maxValue: maxValue))
        }
    }

    /// 从 `"<metricID>@<epoch>"` 解析。解析不出来返回 nil（坏键直接跳过，不让整批失败）。
    static func parse(key: String) -> (metricID: String, bucketStart: Date)? {
        guard let separator = key.lastIndex(of: "@") else { return nil }
        let metricID = String(key[key.startIndex..<separator])
        let epochPart = String(key[key.index(after: separator)...])
        guard !metricID.isEmpty, let epoch = TimeInterval(epochPart) else { return nil }
        return (metricID, Date(timeIntervalSince1970: epoch))
    }

    private func shouldPrune(now: Date) -> Bool {
        guard let last = lastPruneAt else { return true }
        return now.timeIntervalSince(last) > 3600
    }

    /// 删掉超过 `rawRetentionDays` 的**原始样本**。
    ///
    /// ⚠️ 刻意**不删汇总桶**：那是长期趋势的唯一来源，
    /// 而且一年也只有几万行。删了原始样本之后，那些老桶就"冻结"了
    /// —— 这个语义是对的，因为手表不可能再补发 180 天前的数据给它。
    @discardableResult
    private func pruneRawSamples() throws -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day,
                                                 value: -PhoneStoragePolicy.rawRetentionDays,
                                                 to: .now) else { return 0 }
        let before = try modelContext.fetchCount(FetchDescriptor<PhoneSample>())
        try modelContext.delete(model: PhoneSample.self, where: #Predicate { $0.startDate < cutoff })
        let after = try modelContext.fetchCount(FetchDescriptor<PhoneSample>())

        // 心跳序列同样按原始保留期清理。它的**派生结果**（Poincaré 图）
        // 不是我们要长期留的东西 —— 那张图看的是"最近一晚/几晚"的形态，
        // 而不是半年趋势（半年趋势用 15 分钟汇总桶看就够了）。
        let seriesBefore = try modelContext.fetchCount(FetchDescriptor<PhoneHeartbeatSeries>())
        try modelContext.delete(model: PhoneHeartbeatSeries.self,
                                where: #Predicate { $0.startDate < cutoff })
        let seriesAfter = try modelContext.fetchCount(FetchDescriptor<PhoneHeartbeatSeries>())

        return max(0, before - after) + max(0, seriesBefore - seriesAfter)
    }

    // MARK: - 读取：图表

    /// 取某指标某时间段的汇总桶（**图表的数据源**）。
    func rollups(metricID: String, from: Date, to: Date) throws -> [RollupPoint] {
        let descriptor = FetchDescriptor<PhoneRollup>(
            predicate: #Predicate {
                $0.metricID == metricID && $0.bucketStart >= from && $0.bucketStart < to
            },
            sortBy: [SortDescriptor(\.bucketStart, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map {
            RollupPoint(bucketStart: $0.bucketStart,
                        count: $0.count,
                        sum: $0.sum,
                        minValue: $0.minValue,
                        maxValue: $0.maxValue)
        }
    }

    /// 取某枚举型指标某时间段的原始样本（睡眠图表的数据源）。
    ///
    /// 睡眠样本一天只有几十条（一晚大约 10~30 段），一年也就一万条，
    /// 直接读原始样本完全没问题 —— 不需要为它再做一层汇总。
    func categorySamples(metricID: String, from: Date, to: Date) throws -> [CategoryPoint] {
        let descriptor = FetchDescriptor<PhoneSample>(
            predicate: #Predicate {
                $0.metricID == metricID && $0.startDate >= from && $0.startDate < to
            },
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try modelContext.fetch(descriptor).compactMap { sample in
            guard let raw = sample.categoryValue else { return nil }
            return CategoryPoint(uuid: sample.uuid,
                                 startDate: sample.startDate,
                                 endDate: sample.endDate,
                                 categoryValue: raw)
        }
    }

    /// 某指标某时间段内的原始样本条数（用于在图表下方如实说明"点是多少条算出来的"）。
    func sampleCount(metricID: String, from: Date, to: Date) throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<PhoneSample>(
                predicate: #Predicate {
                    $0.metricID == metricID && $0.startDate >= from && $0.startDate < to
                }
            )
        )
    }

    // MARK: - 读取：RR 间期（Poincaré）

    /// 心跳序列条数。图表页靠它决定"要不要显示 RR 间期那个入口"。
    ///
    /// 刻意的设计：**没有数据就不显示入口**，而不是留一个永远为空的死项。
    /// 这条链路依赖手表真的产生心跳序列（很可能需要房颤历史），
    /// 对这种"可能永远没有"的功能，留一个空入口比没有入口更糟。
    func heartbeatSeriesCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PhoneHeartbeatSeries>())
    }

    func latestHeartbeatSeriesDate() throws -> Date? {
        var descriptor = FetchDescriptor<PhoneHeartbeatSeries>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.startDate
    }

    /// 取时间范围内的 RR 间期，**按序列分组**返回。
    ///
    /// ## ⚠️ 为什么返回分组而不是一个大数组
    /// Poincaré 配对只能在**同一条序列内**做。跨序列配对等于把相隔几分钟的
    /// 两次测量连成一个点 —— 纯噪声。如果这里返回扁平数组，
    /// 调用方迟早会写出跨序列配对的 bug，而且是**静默的**（图还是会画出来）。
    /// 把"分组"做成返回类型的性质，这个错误就不可能犯。
    ///
    /// - Parameter seriesLimit: 最多取多少条序列。**必须有限制**：
    ///   一晚约 120 条，90 天就是 1 万多条、上百万个间期，
    ///   全读进内存只是为了画一张最多 3000 个点的图。
    ///   ⚠️ 被截断时**如实回报**（`isTruncated`），绝不静默丢数据。
    func rrSeries(from: Date, to: Date, seriesLimit: Int = 3_000) throws -> RRSeriesFetch {
        var descriptor = FetchDescriptor<PhoneHeartbeatSeries>(
            predicate: #Predicate { $0.startDate >= from && $0.startDate < to },
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        descriptor.fetchLimit = seriesLimit

        let records = try modelContext.fetch(descriptor)

        let series = records.compactMap { record -> RRSeriesData? in
            // ⚠️ 跳过**不自洽**的序列（时间戳个数与拍数对不上）。
            //    画出来会是一堆凭空捏造的间期，比不画更糟。
            guard record.isSelfConsistent else { return nil }
            // 只把**原始时间戳 + 洞标记**交出去，RR 间期由 `RRSeriesData` 自己算 ——
            // 这样"在哪里算 RR"这件事只有一个答案（手机），不会两边各算一份。
            // 洞标记一起带上：跨洞的差值不是一个真实的心跳间隔，必须能过滤掉。
            return RRSeriesData(seriesUUID: record.uuid,
                                startDate: record.startDate,
                                beatOffsetsMillis: record.beatOffsetsMillis,
                                gapFlags: record.gapFlags)
        }

        return RRSeriesFetch(series: series, isTruncated: records.count >= seriesLimit)
    }

    /// 取**最新一条**序列（波形图 + 单序列 HRV 分析用）。
    ///
    /// ⚠️ 刻意不复用 `rrSeries`：那个是"时间范围内**最早**的前 N 条"，
    /// 而这里要的是"**最近**那一条" —— 两者在范围边界上的语义不同。
    ///
    /// 往前多取几条是为了**跳过不自洽的记录**（拍数与时间戳个数对不上），
    /// 而不是"取最新那条、如果它是坏的就算了" —— 那会让图表莫名其妙地空掉，
    /// 而"空"会被读成"没有数据"。
    func latestRRSeries() throws -> RRSeriesData? {
        var descriptor = FetchDescriptor<PhoneHeartbeatSeries>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 8

        for record in try modelContext.fetch(descriptor) {
            guard record.isSelfConsistent else { continue }
            return RRSeriesData(seriesUUID: record.uuid,
                                startDate: record.startDate,
                                beatOffsetsMillis: record.beatOffsetsMillis,
                                gapFlags: record.gapFlags)
        }
        return nil
    }

    // MARK: - 读取：概览与状态

    /// 每个指标的最新值 / 总条数 / 时间范围。
    ///
    /// 刻意按 `MetricDisplay.all` 的**注册顺序**遍历，
    /// 而且**没有数据的指标也会返回**（count = 0）：
    /// 否则用户看到的是"少了几个指标"，而不是"这几个指标没数据"——
    /// 前者看起来像 bug，后者才是事实。
    func metricSummaries() throws -> [PhoneMetricSummary] {
        MetricDisplay.all.map { info in
            let id = info.id
            let count = (try? modelContext.fetchCount(
                FetchDescriptor<PhoneSample>(predicate: #Predicate { $0.metricID == id })
            )) ?? 0

            var latest: PhoneSample?
            if count > 0 {
                var descriptor = FetchDescriptor<PhoneSample>(
                    predicate: #Predicate { $0.metricID == id },
                    sortBy: [SortDescriptor(\.startDate, order: .reverse)]
                )
                descriptor.fetchLimit = 1
                latest = (try? modelContext.fetch(descriptor))?.first
            }

            var earliest: Date?
            if count > 0 {
                var descriptor = FetchDescriptor<PhoneSample>(
                    predicate: #Predicate { $0.metricID == id },
                    sortBy: [SortDescriptor(\.startDate, order: .forward)]
                )
                descriptor.fetchLimit = 1
                earliest = (try? modelContext.fetch(descriptor))?.first?.startDate
            }

            return PhoneMetricSummary(metricID: id,
                                      count: count,
                                      latestDate: latest?.startDate,
                                      latestValue: latest?.value,
                                      latestCategoryValue: latest?.categoryValue,
                                      earliestDate: earliest)
        }
    }

    func totalSampleCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PhoneSample>())
    }

    func rollupCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PhoneRollup>())
    }

    func oldestSampleDate() throws -> Date? {
        var descriptor = FetchDescriptor<PhoneSample>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.startDate
    }

    func newestSampleDate() throws -> Date? {
        var descriptor = FetchDescriptor<PhoneSample>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.startDate
    }

    /// 本机最后一次收到数据的时间。用 `receivedAt` 而不是 `startDate`：
    /// 后者是采样时间，无法回答"传输链路还活着吗"。
    func lastReceivedAt() throws -> Date? {
        var descriptor = FetchDescriptor<PhoneSample>(sortBy: [SortDescriptor(\.receivedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.receivedAt
    }
}
