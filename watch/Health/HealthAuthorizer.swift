import Foundation
import HealthKit

/// HealthKit 授权。
///
/// 三个必须做对的点（都有官方依据）：
/// 1. Info.plist 必须设置 `NSHealthShareUsageDescription`；如果要写入还需要
///    `NSHealthUpdateUsageDescription`。**建议两个都配齐**，缺键会在请求授权时崩溃。
/// 2. watchOS 6+ 授权弹窗**直接出现在手表上**，所以 Info.plist 的键
///    **必须加到 Watch App Extension**（不只是主 target）。
/// 3. 用户**可以只授权一部分类型**，或者只授权"部分历史数据"。
///    **必须把"部分授权"当成正常情况处理**，每个指标都要有独立空态。
actor HealthAuthorizer {

    static let shared = HealthAuthorizer()

    private let healthStore = HKHealthStore()

    /// 请求读授权。只读，不请求任何写权限——这个 app 不往 HealthKit 写数据。
    func requestReadAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthAuthError.notAvailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: MetricCatalog.readTypes)
    }

    /// 是否已经问过用户了。首次启动可以据此决定要不要弹引导页。
    func hasRequestedBefore() async -> Bool {
        await withCheckedContinuation { cont in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: MetricCatalog.readTypes) { status, _ in
                switch status {
                case .unnecessary:
                    cont.resume(returning: true)
                case .shouldRequest:
                    cont.resume(returning: false)
                default:
                    // ⚠️ `.unknown` 也当成「还没问过」。
                    // 这是全 app **唯一**会弹授权窗的入口：如果这里把 .unknown 当成
                    // 「已问过」而跳过，用户就永远看不到授权弹窗、也永远拿不到数据，
                    // 而且界面上没有任何补救路径。
                    // 反过来误判的代价很小：后台调用时 requestAuthorization 会静默失败，
                    // 我们在 catch 里吞掉即可（后台本来就弹不出窗）。
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// 只在"还没问过"时才弹授权。后台任务里调用是安全的：
    /// 已经授权过就立即返回，不会在后台弹窗（后台也弹不出来）。
    func requestReadAuthorizationIfNeeded() async throws {
        guard await !hasRequestedBefore() else { return }
        try await requestReadAuthorization()
    }

    /// 用户**还没对读权限做出决定**。
    ///
    /// ## ⚠️ 这个判断是给同步引擎用的，用来决定"能不能推进游标"
    /// HealthKit 对**没授权的类型返回空数组、而不是错误**，而且同时给出一个
    /// **有效的新 `HKQueryAnchor`**。于是会出现这条极隐蔽的路径：
    ///
    /// 1. 后台刷新先跑了一轮（用户还没打开过 app、还没点授权）；
    /// 2. 每个类型都"成功"返回 0 条 + 新游标 → 游标被推进；
    /// 3. 用户之后授权成功 → 从那个游标往后查**只会拿到新数据**；
    /// 4. 授权之前那段历史**永远补不回来**，而且**没有任何报错**。
    ///
    /// 所以授权未决时**不推进游标**，代价只是"每轮重新查一次有限的回看窗口"
    /// —— 而这段时间很短（到用户第一次打开 app 为止）。
    func isAuthorizationPending() async -> Bool {
        await !hasRequestedBefore()
    }

    // MARK: - ⚠️ 关于「判断读授权」的一个陷阱
    //
    // **不要**用 `HKHealthStore.authorizationStatus(for:)` 判断"读权限有没有拿到"。
    //
    // Apple 的设计是：**读权限是不可查询的** —— 出于隐私，app 无法知道用户是否拒绝了读。
    // `authorizationStatus(for:)` 返回的是**写入（sharing）**授权状态，
    // 而本 app 的 `toShare` 恒为空集，所以它对每个类型都会返回 `.sharingDenied` 之类，
    // 与"用户是否允许读"毫无关系。
    //
    // 曾经的实现 `unauthorizedMetrics()` 正是踩了这个坑：
    // 结果是主界面**永远**显示"部分指标未授权"，而且这个提示永远不会消失。
    // 已删除。正确做法是**用查询结果反推**（查不到样本时，"没数据"和"没授权"
    // 两种情况在界面上如实并列说明），见 ContentView 的空态文案。
}

enum HealthAuthError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "此设备不支持 HealthKit"
        }
    }
}
