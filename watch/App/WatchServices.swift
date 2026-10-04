import Foundation
import SwiftData

/// 依赖装配。手表端所有模块都从这里取。
///
/// 说明：这里刻意用最小实现（不用 DI 框架）。编译时按 **Swift 5 语言模式**最省事，
/// Swift 6 严格并发检查下需要给这个类加 `@unchecked Sendable`。
final class WatchServices {

    static let shared = WatchServices()

    let container: ModelContainer
    let store: HealthStore
    let snapshotService: SnapshotService
    let syncEngine: HealthSyncEngine

    /// 预留：等确认上传目标后换成真实实现
    let uploadTransport: UploadTransport = NoopUploadTransport()

    /// 本地库落盘位置（诊断界面展示用）
    var storeURL: URL? { container.configurations.first?.url }

    /// 本地库占用的磁盘字节数（含 SQLite 的 -wal / -shm 边车文件）
    var storeBytes: Int64 {
        guard let path = storeURL?.path else { return 0 }
        return LocalFile.sqliteSize(basePath: path)
    }

    private init() {
        let schema = Schema([
            SampleRecord.self,
            SyncAnchorRecord.self,
            PendingUploadRecord.self
        ])

        // ⚠️ 关键：`isStoredInMemoryOnly` 必须是 `false` —— 数据要落在**手表的硬盘**上，
        // 不是运行内存。默认值本来就是 false，这里显式写出来，
        // 避免以后有人误改成 true，导致"app 一重启数据全没"。
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // ⚠️ 刻意**不用 fatalError**。
            // 本地库是文件型且随 app 版本演进（加模型 / 加字段 / 加减 #Index 都可能让
            // 轻量迁移失败），一旦失败就是「每次冷启动都崩」，用户只能重装才能恢复。
            // 而这里的数据本来就是 7 天可丢的（StoragePolicy.retentionDays = 7），
            // 按已确认的「不追求完整性」原则，没有任何理由为它把整个 app 拖死。
            print("[Store] ⚠️ ModelContainer 创建失败，尝试自愈：\(error)")
            container = Self.recoverContainer(schema: schema, configuration: configuration)
        }

        // 把实际落盘位置打出来：真机上可以直接在 Console 里确认
        // "确实写在硬盘上"，排查持久化问题时非常有用。
        if let url = container.configurations.first?.url {
            print("[Store] SwiftData 落盘位置：\(url.path)")
        }

        store = HealthStore(modelContainer: container)
        snapshotService = SnapshotService(store: store)
        syncEngine = HealthSyncEngine(store: store, snapshotService: snapshotService)
    }

    /// 本地库自愈：删掉旧 store 重建一次；仍然失败就退化成**内存库**。
    ///
    /// 取舍：内存库不持久化，但 app 仍然可用（数据每次从 HealthKit 重新拉），
    /// 比"每次启动都崩、用户只能重装"好得多。
    private static func recoverContainer(schema: Schema,
                                         configuration: ModelConfiguration) -> ModelContainer {
        // 1) 删掉可能损坏/迁移失败的旧文件（含 SQLite 的 -shm / -wal 边车文件）
        let basePath = configuration.url.path
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: basePath + suffix)
        }
        if let fresh = try? ModelContainer(for: schema, configurations: [configuration]) {
            print("[Store] 自愈成功：已用全新的本地库（旧数据已丢弃，HealthKit 里还有原件）")
            return fresh
        }

        // 2) 兜底：内存库
        let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let memory = try? ModelContainer(for: schema, configurations: [memoryConfiguration]) {
            print("[Store] ⚠️ 退化为内存库：本次运行数据不落盘，重启即丢")
            return memory
        }

        // 3) 连内存库都建不起来，说明 Schema 本身有硬错误——这时崩掉才能暴露问题
        fatalError("ModelContainer 彻底无法创建（内存库也失败），Schema 定义可能有误")
    }
}

/// 本地文件小工具。
enum LocalFile {

    /// 文件字节数；取不到就返回 0。
    ///
    /// ⚠️ 刻意用 `FileHandle.seekToEnd()`，**不用** `FileManager.attributesOfItem(atPath:)`：
    /// 后者属于 Apple 的 **required-reason API（FileTimestamp 类别）**，
    /// 一旦使用就必须在隐私清单里额外声明一类 API，否则 App Store Connect 会拦。
    /// 而我们对文件时间戳毫无兴趣，只是想知道"这个文件多大"——
    /// `seekToEnd` 不是 required-reason API，语义也更直接（不用把文件读进内存）。
    static func size(at url: URL) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        return Int64((try? handle.seekToEnd()) ?? 0)
    }

    /// SQLite 主文件 + `-wal` / `-shm` 边车文件的总大小。
    /// 只算主文件会明显低估（WAL 里可能压着大量还没 checkpoint 的数据）。
    static func sqliteSize(basePath: String) -> Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            total + size(at: URL(fileURLWithPath: basePath + suffix))
        }
    }
}
