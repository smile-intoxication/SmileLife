import Foundation

/// App Group 共享容器：**主 app 与小组件之间唯一的通信通道**。
///
/// 为什么小组件不直接查 HealthKit？三个理由（都有官方依据）：
/// 1. 官方推荐的就是这个模式："your app can download data and store it in a database
///    in the shared container, and then a widget can access the database"；
/// 2. 设备锁定时 HealthKit store 被加密，小组件**可能读不到数据**，会直接白屏；
/// 3. 小组件渲染时间预算很紧，查 HealthKit 会拖慢 timeline 生成。
enum SharedContainer {

    /// ⚠️ 必须和 Xcode 里三个 target（Watch App / Watch App Extension / Widget Extension）
    /// 配置的 App Group 完全一致，否则小组件读不到数据。
    static let appGroupID = "group.com.smile.intoxication.applewatchhealth"

    /// 共享容器根目录
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 快照文件路径。小组件只读这一个文件。
    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("latest-snapshot.json")
    }

    /// 同步元信息（最后一次成功同步时间等），用于 UI 展示"数据更新于 …"
    static var syncStatusURL: URL? {
        containerURL?.appendingPathComponent("sync-status.json")
    }
}

/// 写进共享容器的快照。**保持字段少而稳定**——小组件与主 app 可能不同版本共存。
struct LatestSnapshot: Codable {

    struct Item: Codable, Identifiable {
        var id: String { metricID }
        var metricID: String
        var title: String
        var unitSuffix: String
        var symbolName: String
        /// 已经格式化好的展示字符串（小组件直接显示，不再做计算）
        var displayValue: String
        /// 原始数值，供图表使用
        var rawValue: Double?
        /// 采样时间（不是写入时间）
        var sampleDate: Date
    }

    var generatedAt: Date
    var items: [Item]

    static let empty = LatestSnapshot(generatedAt: .distantPast, items: [])
}

/// 同步状态，用于在手表 UI 上如实告诉用户"数据是什么时候的"。
///
/// 这一点很重要：HealthKit 的同步延迟**官方没有任何承诺**，
/// 所以 UI 上只能展示"最后同步时间"，**不能暗示"实时"**。
struct SyncStatus: Codable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var totalSamplesStored: Int

    static let unknown = SyncStatus(lastAttemptAt: nil,
                                    lastSuccessAt: nil,
                                    lastError: nil,
                                    totalSamplesStored: 0)
}

/// 共享容器的读写工具（JSON 文件方式）。
///
/// 为什么用 JSON 文件而不是在共享容器里放一个 SwiftData 库？
/// —— 多进程同时打开同一个 SQLite 有并发与版本迁移风险；
///    小组件是只读的展示层，给它一个原子写入的小 JSON 最稳。
enum SharedStore {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 原子写入：先写临时文件再 replace，避免小组件读到写了一半的文件。
    private static func write<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        do {
            let data = try encoder.encode(value)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // 共享容器写失败不应让同步流程崩溃——下次再来
            print("[SharedStore] write failed: \(error)")
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func writeSnapshot(_ snapshot: LatestSnapshot) {
        write(snapshot, to: SharedContainer.snapshotURL)
    }

    static func readSnapshot() -> LatestSnapshot {
        read(LatestSnapshot.self, from: SharedContainer.snapshotURL) ?? .empty
    }

    static func writeStatus(_ status: SyncStatus) {
        write(status, to: SharedContainer.syncStatusURL)
    }

    static func readStatus() -> SyncStatus {
        read(SyncStatus.self, from: SharedContainer.syncStatusURL) ?? .unknown
    }
}
