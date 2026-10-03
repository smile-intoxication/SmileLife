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
                case .unnecessary:      cont.resume(returning: true)
                case .shouldRequest:    cont.resume(returning: false)
                default:                cont.resume(returning: true)
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

    /// 逐类型查询授权状态。
    ///
    /// 注意 `authorizationStatus(for:)` **只能判断"是否已授权"**，
    /// 出于隐私设计，HealthKit **不会告诉你用户拒绝的是"读"还是"写"**，
    /// 也不能据此判断"有没有数据"。真正判断有没有数据要靠查询结果。
    func status(for metric: MetricDescriptor) -> HKAuthorizationStatus {
        healthStore.authorizationStatus(for: metric.sampleType)
    }

    /// 哪些指标当前是「未授权」的，用于 UI 上给出精确提示
    /// （比笼统说"没权限"友好得多）。
    func unauthorizedMetrics() -> [MetricDescriptor] {
        MetricCatalog.all.filter { status(for: $0) == .notDetermined || status(for: $0) == .sharingDenied }
    }
}

enum HealthAuthError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "此设备不支持 HealthKit"
        }
    }
}
