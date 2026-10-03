import Foundation
import HealthKit
import SwiftData
import WidgetKit

/// 快照服务——手表端功能 2 的实现。
///
/// 职责：把「每个指标的最新值」计算好、格式化成展示字符串，
/// 原子写入 App Group 共享容器，供小组件读取。
///
/// 为什么小组件不自己查 HealthKit（这是刻意的设计选择）：
/// 1. 官方推荐主 app 把数据写进共享容器、小组件只读（见调研 §4.5）；
/// 2. **设备锁定时 HealthKit store 被加密，小组件可能读不到数据**，会白屏；
/// 3. 小组件渲染时间预算紧，查 HealthKit 会拖慢 timeline 生成。
actor SnapshotService {

    private let store: HealthStore

    init(store: HealthStore) {
        self.store = store
    }

    /// 重建整份快照。同步跑完后调用一次即可。
    func rebuild() async {
        var items: [LatestSnapshot.Item] = []

        for metric in MetricCatalog.all {
            // 只收录**有数据**的指标：拿不到就整行不显示（符合"有的就有，没有就没有"）。
            if let latest = try? await store.latest(metricID: metric.id) {
                items.append(makeItem(from: latest, metric: metric))
            }
        }

        // 按固定顺序输出，保证小组件与主 app 的展示顺序稳定
        let order = Dictionary(uniqueKeysWithValues: MetricCatalog.all.enumerated().map { ($1.id, $0) })
        items.sort { (order[$0.metricID] ?? .max) < (order[$1.metricID] ?? .max) }

        // ⚠️ **内容没变就不写、也不要求刷新。**
        // 表盘 complication 每天只有几十次刷新预算（官方口径约 40~75 次），
        // 而后台每 15 分钟就会跑一轮同步 —— 无条件 reload 会在一天内要求近百次刷新，
        // 超出的部分会被系统直接丢弃，反而削弱了"主动刷新"的效果。
        // 注意不能拿 generatedAt 当判据（它每轮都变），只比 items。
        guard items != SharedStore.readSnapshot().items else {
            return
        }

        SharedStore.writeSnapshot(LatestSnapshot(generatedAt: .now, items: items))

        // 内容真的变了，才让表盘上的 complication 立刻刷新。
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func makeItem(from record: SampleRecord, metric: MetricDescriptor) -> LatestSnapshot.Item {
        LatestSnapshot.Item(
            metricID: metric.id,
            title: metric.title,
            unitSuffix: metric.unitSuffix,
            symbolName: metric.symbolName,
            displayValue: format(record: record, metric: metric),
            rawValue: record.value,
            sampleDate: record.startDate
        )
    }

    /// 格式化。
    ///
    /// ⚠️ 睡眠这类**区间型**指标，"最新一条"其实只是"最后一个睡眠阶段"，
    /// 并不是用户想看的"昨晚睡了多久"。
    /// 正确的做法是另加一个聚合器（按睡眠会话求和 asleep* 时长），
    /// 这里先如实展示阶段标签，等 UI 需求明确后再替换。
    private func format(record: SampleRecord, metric: MetricDescriptor) -> String {
        switch metric.shape {
        case .quantity(_, let decimals):
            guard let value = record.value else { return "—" }
            return String(format: "%.\(decimals)f", value)

        case .category(let label):
            guard let raw = record.categoryValue else { return "—" }
            return label(raw)
        }
    }
}
