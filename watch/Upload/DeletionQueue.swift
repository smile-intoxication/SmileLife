import Foundation

/// 待转发给 iPhone 的**删除**列表。
///
/// ## 为什么需要它
/// 用户在健康 App 里删掉一条数据后，HealthKit 会通过 `HKDeletedObject` 通知我们。
/// 手表本地删了、手机不删，手机上就会一直显示**用户已经删掉的数据** ——
/// 这属于**正确性**问题，不是被砍掉的"数据完整性"（见设计方案 §0）。
///
/// ## 为什么不塞进 `PendingUploadRecord`
/// 那张表的 `payload` 字段语义是"一条样本"。删除是**另一个列表**
/// （线协议 `SampleBatch.deletedUUIDs` 也是独立的），混在一起会让
/// "这条读不出来"到底是坏了还是类型不对，变得说不清。
///
/// ## 为什么用 UserDefaults 而不是再开一张 SwiftData 表
/// - 数据量极小（只有 uuid 字符串），且**丢了也不致命**：
///   手机上最多多显示一条用户已经删掉的记录，下次同步时……
///   ——不，其实不会自动纠正，所以这里仍然要尽量持久。
/// - `UserDefaults` 已经在隐私清单里声明过（CA92.1），不再引入新的
///   required-reason API，也不引入新的 `@Model`（加模型就有迁移风险）。
///
/// 做成 **actor** 而不是一组静态函数：调用方一个是同步引擎（actor）、
/// 一个是发送器（actor），读-改-写需要串行化，否则 `restore` 会覆盖掉
/// 并发 `append` 进来的新删除。
actor DeletionQueue {

    /// 上限。满了丢**最老的** —— 与上传队列同一策略（设计方案 §4 决策 3）。
    private static let maxCount = 500

    private let defaults: UserDefaults
    private let key = "watch.pendingDeletedSampleUUIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func append(_ uuids: [UUID]) {
        guard !uuids.isEmpty else { return }
        var current = read()
        current.append(contentsOf: uuids)
        trim(&current)
        write(current)
    }

    /// 取出全部并清空。取走后如果发送失败，调用方必须 `restore` 放回去。
    func drain() -> [UUID] {
        let current = read()
        write([])
        return current
    }

    /// 放回**队首**：这些删除比队列里现有的更早发生，顺序不能反。
    func restore(_ uuids: [UUID]) {
        guard !uuids.isEmpty else { return }
        var current = read()
        current.insert(contentsOf: uuids, at: 0)
        trim(&current)
        write(current)
    }

    func pendingCount() -> Int { read().count }

    // MARK: - 内部

    private func trim(_ list: inout [UUID]) {
        if list.count > Self.maxCount {
            list.removeFirst(list.count - Self.maxCount)
        }
    }

    private func read() -> [UUID] {
        guard let strings = defaults.stringArray(forKey: key) else { return [] }
        // 解析不出 UUID 的条目直接丢掉：它们是坏数据，留着只会让队列头部一直卡住
        return strings.compactMap { UUID(uuidString: $0) }
    }

    private func write(_ uuids: [UUID]) {
        if uuids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(uuids.map(\.uuidString), forKey: key)
        }
    }
}
