import Foundation
import SwiftData

/// iPhone 端的依赖装配。**所有模块都从这里取**。
///
/// 和手表端的 `WatchServices` 是同一套结构，刻意保持对称 ——
/// 两个平台上的"从哪拿库、从哪拿状态"应该是同一个形状，
/// 否则以后加功能时每次都要重新想一遍。
final class PhoneServices {

    static let shared = PhoneServices()

    let container: ModelContainer
    let store: PhoneStore

    /// 本地库落盘位置（状态界面展示用）
    var storeURL: URL? { container.configurations.first?.url }

    /// 本地库占用的磁盘字节数（含 SQLite 的 -wal / -shm 边车文件）
    var storeBytes: Int64 {
        guard let path = storeURL?.path else { return 0 }
        return PhoneLocalFile.sqliteSize(basePath: path)
    }

    private init() {
        let schema = Schema([
            PhoneSample.self,
            PhoneRollup.self
        ])

        // ⚠️ 关键：`isStoredInMemoryOnly` 必须是 `false`。
        // 手机端是**长期档案**，落在内存里等于每次冷启动都从零开始，
        // 那这个 app 就完全没有存在意义了。
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            print("[PhoneStore] ⚠️ ModelContainer 创建失败，尝试自愈：\(error)")
            container = Self.recover(schema: schema, configuration: configuration)
        }

        if let url = container.configurations.first?.url {
            print("[PhoneStore] SwiftData 落盘位置：\(url.path)")
        }

        store = PhoneStore(modelContainer: container)
    }

    /// 启动「手表 → iPhone」通道。**必须在 `didFinishLaunchingWithOptions` 里调用**。
    func startLink() {
        WatchLink.shared.activate(store: store)
    }

    /// 本地库自愈。
    ///
    /// ## 和手表端不同的取舍
    /// 手表端直接删库重建是安全的（数据是 7 天可丢的缓冲，HealthKit 里还有原件）。
    /// 手机端是**长期档案**，直接删更可惜 —— 但也不能让它变成"每次冷启动必崩"：
    /// - 先把旧文件**改名备份**而不是删除，用户/我们还有机会捞回来；
    /// - 再建全新的库；
    /// - 仍然失败就退化成内存库（app 可用，只是这次不落盘）。
    ///
    /// 而且有一个重要的兜底事实：**这些数据在 iPhone 自己的健康 App 里也有一份**
    /// （手表数据会通过 iCloud 同步到手机 HealthKit）。所以最坏情况不是"数据没了"，
    /// 而是"这个 app 的档案没了"。
    private static func recover(schema: Schema,
                                configuration: ModelConfiguration) -> ModelContainer {
        let basePath = configuration.url.path
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-shm", "-wal"] {
            let source = basePath + suffix
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let backup = source + ".broken-\(stamp)"
            try? FileManager.default.moveItem(atPath: source, toPath: backup)
        }

        if let fresh = try? ModelContainer(for: schema, configurations: [configuration]) {
            print("[PhoneStore] 自愈成功：已用全新的本地库（旧文件已改名备份为 *.broken-\(stamp)）")
            return fresh
        }

        let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let memory = try? ModelContainer(for: schema, configurations: [memoryConfiguration]) {
            print("[PhoneStore] ⚠️ 退化为内存库：本次运行数据不落盘")
            return memory
        }

        // 连内存库都建不起来说明 Schema 本身有硬错误 —— 这时崩掉才能暴露问题
        fatalError("PhoneStore 的 ModelContainer 彻底无法创建（内存库也失败）")
    }
}

/// 本地文件小工具（iPhone 端）。
enum PhoneLocalFile {

    /// 文件字节数；取不到就返回 0。
    ///
    /// ⚠️ 和手表端一样，刻意用 `FileHandle.seekToEnd()`，
    /// **不用** `FileManager.attributesOfItem(atPath:)`：后者是 Apple 的
    /// required-reason API（FileTimestamp 类别），一旦使用就必须在隐私清单里
    /// 额外声明一类 API，否则 App Store Connect 会拦。
    /// （`ci/verify-project.sh` 第 6 节会守住这条。）
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
