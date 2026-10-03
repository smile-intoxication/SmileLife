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
@ModelActor
actor HealthStore {

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
