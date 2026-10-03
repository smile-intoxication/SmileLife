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
            // 本地库建不起来说明 Schema 迁移出了问题，属于开发期错误，直接暴露
            fatalError("无法创建 ModelContainer: \(error)")
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
}
