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

    /// 手表 → iPhone 的通道（WatchConnectivity）
    let link = WatchLinkSession.shared

    /// 待转发给 iPhone 的删除（用户在健康 App 里删掉的样本）
    let deletions: DeletionQueue

    /// 待上传队列的搬运工：把队列里的样本交给 iPhone
    let outboxFlusher: OutboxFlusher

    /// **服务端**直传路径，尚未接入。
    ///
    /// 保留 `UploadTransport` 这个协议是为了以后要把数据也送一份到自己的服务器时，
    /// 实现一个 `HTTPTransport` 即可，**线上格式（`UploadPayload`）不用改**。
    /// 「手表 → iPhone」那条路不走这个协议，它实现在 `OutboxFlusher` 里
    /// （`transferUserInfo` 是"交给系统排队"的语义，和这里"给你一批、
    /// 你给我一个 throw"的同步语义并不吻合）。
    let serverUploadTransport: UploadTransport = NoopUploadTransport()

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
            PendingUploadRecord.self,
            // 心跳序列（RR 间期的来源）。独立一张表：一条序列 = 一行
            // （RR 数组打包在里面），见 Models.swift 的说明。
            HeartbeatSeriesRecord.self
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
        deletions = DeletionQueue()
        outboxFlusher = OutboxFlusher(store: store,
                                      link: WatchLinkSession.shared,
                                      deletions: deletions)
        syncEngine = HealthSyncEngine(store: store,
                                      snapshotService: snapshotService,
                                      flusher: outboxFlusher,
                                      deletions: deletions)
    }

    /// 启动「手表 → iPhone」通道。**必须在 app 启动最早的时候调用**
    /// （`applicationDidFinishLaunching` 里）。
    ///
    /// 为什么不能等用户点开某个界面再调用：`WCSession` 未激活时
    /// `transferUserInfo` 会**静默失败**，表现是"手机上一直接收不到数据"，
    /// 而手表这边看不出任何异常。
    ///
    /// 这里同时挂上两个回调：
    /// - `onTransferSettled`：一次传输送达后，说明系统队列腾出了位置，
    ///   顺势把剩下的继续发出去（这就是背压的"解锁"时机）。
    /// - `onActivationChanged`：会话刚激活时，把之前因为未激活而发不出去的补上。
    func startLink() {
        // 先取到局部 `let`，再在捕获列表里 weak 它。
        // ⚠️ 不用 `[weak outboxFlusher]` 直接捕获属性：捕获列表里读实例属性
        //    会牵扯到"闭包内是否必须显式 self"的规则，而这里完全没有必要去赌它。
        //
        // 为什么是 weak：`WatchLinkSession.shared` 会持有这两个闭包，
        // 而 flusher 又持有 `WatchLinkSession.shared` —— 强引用会成环。
        // 这里虽然是"活到进程结束"的单例、成环不会泄漏出问题，
        // 但成环会让"谁持有谁"彻底说不清，以后想改生命周期时会踩到。
        let flusher = outboxFlusher

        WatchLinkSession.shared.onTransferSettled = { [weak flusher] _, error in
            // 失败不重试：`transferUserInfo` 的失败几乎都是"对端 app 没装"这类
            // 不会因为立刻重试而改变的原因。重试只会空转，把后台预算烧光。
            guard error == nil, let flusher else { return }
            Task { await flusher.flush(budget: 5) }
        }

        WatchLinkSession.shared.onActivationChanged = { [weak flusher] in
            guard let flusher else { return }
            Task { await flusher.flush(budget: 5) }
        }

        WatchLinkSession.shared.activate()
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
