import Foundation
import SwiftData

/// 一条健康样本。以 HealthKit 的 `HKObject.uuid` 作为主键，天然幂等去重。
///
/// 为什么要自己存一份？因为 **Apple Watch 上的 HealthKit store 会被系统定期清理旧数据**
/// （官方原文："old data is periodically purged from Apple Watch"）。
/// 只有存进 app 自己的沙盒，才有可能给用户连续的长期记录。
@Model
final class SampleRecord {

    /// 索引：本地最多会有十几万行（S12 心率最坏 17,280 条/天 × 7 天 ≈ 12.1 万），
    /// 没有索引的话"取某指标最新一条""按日期范围删旧数据"都会全表扫描。
    /// `#Index` 需要 watchOS 11+，本项目基线是 watchOS 27，可以放心用。
    #Index<SampleRecord>([\.metricID, \.startDate], [\.startDate])

    /// 主键 = HKObject.uuid。用 `.unique` 让重复写入变成更新而不是插入。
    @Attribute(.unique) var uuid: UUID

    /// 对应 `MetricDescriptor.id`。故意用 String 而不是枚举，
    /// 这样以后指标下线了也不会导致旧数据无法解码。
    var metricID: String

    var startDate: Date
    var endDate: Date

    /// 数值型样本的值（已按指标单位换算）
    var value: Double?
    /// 数值型样本的单位字符串，仅用于调试与导出
    var unitString: String?
    /// 枚举型样本的原始值（如睡眠阶段）
    var categoryValue: Int?

    // ——— 来源追踪：用来回答"这条是不是手表产生的" ———
    var sourceBundleID: String?
    var sourceName: String?
    var deviceName: String?
    var deviceModel: String?
    var deviceManufacturer: String?

    /// 落库时间（不是采样时间）。用于排查同步延迟。
    var ingestedAt: Date

    init(uuid: UUID,
         metricID: String,
         startDate: Date,
         endDate: Date,
         value: Double? = nil,
         unitString: String? = nil,
         categoryValue: Int? = nil,
         sourceBundleID: String? = nil,
         sourceName: String? = nil,
         deviceName: String? = nil,
         deviceModel: String? = nil,
         deviceManufacturer: String? = nil,
         ingestedAt: Date = .now) {
        self.uuid = uuid
        self.metricID = metricID
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unitString = unitString
        self.categoryValue = categoryValue
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.deviceManufacturer = deviceManufacturer
        self.ingestedAt = ingestedAt
    }
}

/// 每个指标一个增量游标（HKQueryAnchor）。
///
/// **必须持久化**：`HKAnchoredObjectQuery` 靠它只返回新增/删除的样本。
/// 放在内存里会在 app 被杀之后丢失，导致下次全量重拉。
@Model
final class SyncAnchorRecord {

    @Attribute(.unique) var metricID: String
    /// `HKQueryAnchor` 是 NSSecureCoding 的，这里存归档后的 Data
    var anchorData: Data
    var lastSyncAt: Date

    init(metricID: String, anchorData: Data, lastSyncAt: Date = .now) {
        self.metricID = metricID
        self.anchorData = anchorData
        self.lastSyncAt = lastSyncAt
    }
}

/// 待上传队列。**这一版只写入不发送**，等确认了是走手机还是走服务器再接上传输层。
///
/// 设计要点：队列与传输解耦。无论最终选 WatchConnectivity 还是 URLSession，
/// 这张表都不用改，只需要提供一个 `UploadTransport` 实现。
@Model
final class PendingUploadRecord {

    @Attribute(.unique) var id: UUID
    /// 关联的样本 UUID，方便上传成功后就地删除
    var sampleUUID: UUID
    var metricID: String
    /// 已经序列化好的上传载荷（JSON）
    var payload: Data
    var createdAt: Date
    var attemptCount: Int
    var lastError: String?

    init(id: UUID = UUID(),
         sampleUUID: UUID,
         metricID: String,
         payload: Data,
         createdAt: Date = .now,
         attemptCount: Int = 0,
         lastError: String? = nil) {
        self.id = id
        self.sampleUUID = sampleUUID
        self.metricID = metricID
        self.payload = payload
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}
