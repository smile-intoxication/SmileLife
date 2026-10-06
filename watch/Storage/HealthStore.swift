import Foundation
import HealthKit
import SwiftData

/// 本地库的**唯一入口**。所有读写都走这里，其它模块不直接碰 ModelContext。
///
/// 用 `@ModelActor` 让所有数据库操作跑在独立 actor 上：
/// - 后台任务里不会被主线程阻塞；
/// - SwiftData 的 ModelContext 不是线程安全的，收敛到 actor 里最省心。
///
/// 📌 **落盘位置**：SwiftData 用的是文件型库（`isStoredInMemoryOnly: false`），
/// 存在 app 沙盒的 Application Support 目录，**不是运行内存**。
/// app 重启、被系统杀掉、手表重启都不会丢数据。
/// 单个指标在本地的采集情况，供诊断界面展示。
///
/// 刻意做成独立的 `Sendable` 值类型：诊断界面在别的 actor/主线程上，
/// 而 `@Model` 实例（SampleRecord）**不能跨 actor 传递**。
struct MetricSampleStats: Sendable {
    let metricID: String
    let count: Int
    let latest: Date?
}

@ModelActor
actor HealthStore {

    // MARK: - 诊断

    /// 每个指标在本地的样本数与最新样本时间。
    ///
    /// ⚠️ 参数刻意是 `[String]`（指标 id）而不是 `[MetricDescriptor]`：
    /// MetricDescriptor 里带一个闭包（睡眠标签翻译），**不是 Sendable**，
    /// 跨 actor 传会在 Swift 6 下直接报错。传纯值最省心。
    func stats(for metricIDs: [String]) throws -> [MetricSampleStats] {
        metricIDs.map { id in
            let predicate = #Predicate<SampleRecord> { $0.metricID == id }
            let count = (try? modelContext.fetchCount(FetchDescriptor<SampleRecord>(predicate: predicate))) ?? 0

            var latest: Date?
            if count > 0 {
                var descriptor = FetchDescriptor<SampleRecord>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.startDate, order: .reverse)]
                )
                descriptor.fetchLimit = 1
                latest = (try? modelContext.fetch(descriptor))?.first?.startDate
            }
            return MetricSampleStats(metricID: id, count: count, latest: latest)
        }
    }

    // MARK: - 写入

    /// 幂等写入。以 `uuid` 为主键，已存在就更新，不存在就插入。
    /// 增量同步可能重复投递同一条样本，所以幂等是必须的。
    func upsert(_ records: [SampleRecord]) throws {
        guard !records.isEmpty else { return }

        let ids = records.map(\.uuid)
        let existing = try modelContext.fetch(
            FetchDescriptor<SampleRecord>(predicate: #Predicate { ids.contains($0.uuid) })
        )
        var byUUID = Dictionary(uniqueKeysWithValues: existing.map { ($0.uuid, $0) })

        for record in records {
            if let old = byUUID[record.uuid] {
                // HealthKit 的样本是不可变的，正常情况下不会变；
                // 但静息/步行心率会被系统覆盖，所以允许更新。
                old.startDate = record.startDate
                old.endDate = record.endDate
                old.value = record.value
                old.categoryValue = record.categoryValue
                old.unitString = record.unitString
                old.ingestedAt = record.ingestedAt
            } else {
                modelContext.insert(record)
                byUUID[record.uuid] = record
            }
        }
        try modelContext.save()
    }

    /// 处理 `HKDeletedObject`。**这一步不能省**：
    /// 用户在健康 App 里删掉一条数据后，如果你不删本地副本，就会显示用户已经删掉的数据。
    /// （这属于**正确性**，不属于被砍掉的"数据完整性"，见设计方案 §0。）
    func delete(uuids: [UUID]) throws {
        guard !uuids.isEmpty else { return }
        try modelContext.delete(model: SampleRecord.self, where: #Predicate { uuids.contains($0.uuid) })
        try modelContext.save()
    }

    // MARK: - 增量游标

    func anchor(for metricID: String) throws -> HKQueryAnchor? {
        let record = try modelContext.fetch(
            FetchDescriptor<SyncAnchorRecord>(predicate: #Predicate { $0.metricID == metricID })
        ).first
        guard let data = record?.anchorData else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// 清掉某个指标的游标。
    ///
    /// 用途：`anchorData` 解档失败时（存档损坏 / 跨版本不兼容），如果不做处理，
    /// 这个指标**每一轮同步都会在第一行以同样的方式失败**，等于永久静默停摆。
    /// 清掉游标后退化成"首次同步"，代价只是重拉一次回看窗口内的数据 ——
    /// 完全符合「不追求完整性」的原则。
    func clearAnchor(for metricID: String) throws {
        try modelContext.delete(model: SyncAnchorRecord.self,
                                where: #Predicate { $0.metricID == metricID })
        try modelContext.save()
    }

    func saveAnchor(_ anchor: HKQueryAnchor, for metricID: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        let existing = try modelContext.fetch(
            FetchDescriptor<SyncAnchorRecord>(predicate: #Predicate { $0.metricID == metricID })
        ).first
        if let existing {
            existing.anchorData = data
            existing.lastSyncAt = .now
        } else {
            modelContext.insert(SyncAnchorRecord(metricID: metricID, anchorData: data))
        }
        try modelContext.save()
    }

    // MARK: - 读取

    func latest(metricID: String) throws -> SampleRecord? {
        var d = FetchDescriptor<SampleRecord>(
            predicate: #Predicate { $0.metricID == metricID },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    func recentSamples(metricID: String, limit: Int = 200) throws -> [SampleRecord] {
        var d = FetchDescriptor<SampleRecord>(
            predicate: #Predicate { $0.metricID == metricID },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        d.fetchLimit = limit
        return try modelContext.fetch(d)
    }

    func totalCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<SampleRecord>())
    }

    func count(metricID: String) throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<SampleRecord>(predicate: #Predicate { $0.metricID == metricID })
        )
    }

    /// 数据最早到什么时候——用来在 UI 上如实展示"本地已存范围"
    /// （最多就是 `StoragePolicy.retentionDays` 天）。
    func earliestDate() throws -> Date? {
        var d = FetchDescriptor<SampleRecord>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        d.fetchLimit = 1
        return try modelContext.fetch(d).first?.startDate
    }

    // MARK: - 保留策略

    /// 只保留最近 `StoragePolicy.retentionDays`（**7 天**）的样本。
    ///
    /// - 删的只是**你自己的副本**，HealthKit 里的数据不受影响；
    ///   长期档案本来就在 iPhone 上（官方："old data is periodically purged from Apple Watch"）。
    /// - 有 `#Index<SampleRecord>([\.startDate])` 撑着，这条删除不会全表扫描。
    /// - 返回实际删掉的行数，方便日志里观察效果。
    @discardableResult
    func enforceRetention() throws -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day,
                                                 value: -StoragePolicy.retentionDays,
                                                 to: .now) else { return 0 }
        let before = try modelContext.fetchCount(FetchDescriptor<SampleRecord>())
        try modelContext.delete(model: SampleRecord.self,
                                where: #Predicate { $0.startDate < cutoff })
        try modelContext.save()
        let after = try modelContext.fetchCount(FetchDescriptor<SampleRecord>())
        return max(0, before - after)
    }

    // MARK: - 待上传队列

    func enqueue(_ items: [PendingUploadRecord]) throws {
        guard !items.isEmpty else { return }
        for item in items { modelContext.insert(item) }
        try modelContext.save()
    }

    func pendingUploads(limit: Int = 200) throws -> [PendingUploadRecord] {
        var d = FetchDescriptor<PendingUploadRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        d.fetchLimit = limit
        return try modelContext.fetch(d)
    }

    func pendingUploadCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PendingUploadRecord>())
    }

    /// 取最老的一批待发送行，**解码成线上格式**后返回。
    ///
    /// ⚠️ 解码失败的行会被**就地删掉**，这一点很重要：
    /// 它们在队首，每轮都会被取出来、每轮都解不开、如果只是跳过就永远删不掉，
    /// 于是整个上传队列被几行坏数据**永久堵死**，而且没有任何报错。
    /// 按「不追求完整性」的原则，直接丢弃并打日志才是对的。
    func outboxBatch(limit: Int = 200) throws -> [OutboxRow] {
        var descriptor = FetchDescriptor<PendingUploadRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty else { return [] }

        var rows: [OutboxRow] = []
        var broken: [UUID] = []
        for record in records {
            if let payload = UploadPayload.decode(record.payload) {
                rows.append(OutboxRow(id: record.id,
                                      payload: payload,
                                      byteCount: record.payload.count))
            } else {
                broken.append(record.id)
            }
        }

        if !broken.isEmpty {
            // 刻意先拷成 `let` 再进 `#Predicate`：
            // 谓词表达式会被编译器重写成逃逸闭包，捕获 `var` 是不必要的风险。
            let brokenIDs = broken
            print("[Outbox] ⚠️ 丢弃 \(brokenIDs.count) 行无法解码的队列条目（否则会永久堵住队列）")
            try modelContext.delete(model: PendingUploadRecord.self,
                                    where: #Predicate { brokenIDs.contains($0.id) })
            try modelContext.save()
        }

        return rows
    }

    func removeUploads(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try modelContext.delete(model: PendingUploadRecord.self, where: #Predicate { ids.contains($0.id) })
        try modelContext.save()
    }

    func markUploadFailed(id: UUID, error: String) throws {
        let record = try modelContext.fetch(
            FetchDescriptor<PendingUploadRecord>(predicate: #Predicate { $0.id == id })
        ).first
        record?.attemptCount += 1
        record?.lastError = error
        try modelContext.save()
    }

    /// 队列容量上限：按"不追求完整性"原则，**满了就丢最老的**，
    /// 不需要"保证送达"那套机制（见设计方案 §4 决策 3）。
    @discardableResult
    func trimUploadQueue(maxCount: Int = 5_000) throws -> Int {
        let total = try pendingUploadCount()
        guard total > maxCount else { return 0 }
        let overflow = total - maxCount
        var d = FetchDescriptor<PendingUploadRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        d.fetchLimit = overflow
        let doomed = try modelContext.fetch(d)
        for item in doomed { modelContext.delete(item) }
        try modelContext.save()
        return doomed.count
    }
}
