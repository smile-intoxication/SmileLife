import Foundation
import WatchKit

/// 后台调度——手表端功能 1「定期执行」的唯一可行实现方式。
///
/// ## 必须先理解的现实
/// watchOS **不提供**"每 N 分钟准时跑一次"的定时器。官方规则：
/// - 后台刷新任务**每小时约 4 次**，且 **前提是表盘上有本 app 的 complication**；
/// - `withPreferredDate` 只是"**不早于**这个时间"的**建议**，系统可以推迟或节流；
/// - 每次后台只给 **"几秒"**执行时间，超时会被系统杀掉（可能 `EXC_CRASH (SIGKILL)`）；
/// - 系统只允许**同时排一个**刷新任务，排第二个会取消第一个。
///
/// 官方还明确要求："don't expect the system to trigger every background task.
/// **Design a fallback mechanism**"——所以下面每次跑完都会**重新排下一次**，
/// 并且把"排不上"当作正常情况处理（前台同步兜底）。
final class BackgroundCoordinator {

    static let shared = BackgroundCoordinator()

    /// 15 分钟是官方对后台传输给的建议下限（"no closer than 15 minutes apart"）。
    /// 后台刷新预算约 4 次/小时，正好也是 15 分钟一轮。
    private let preferredInterval: TimeInterval = 15 * 60

    private let userInfoKey = "com.applewatchhealth.sync"

    private init() {}

    /// 排下一次后台刷新。**每次跑完都要重新排**，否则只会触发一次。
    func scheduleNextRefresh() {
        let date = Date().addingTimeInterval(preferredInterval)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: date,
            userInfo: nil
        ) { error in
            if let error {
                // 排不上不算故障：用户没把小组件放上表盘、或系统在节流。
                // 前台打开 app 时的同步就是兜底。
                print("[Background] 排程失败：\(error.localizedDescription)")
            }
        }
    }

    /// 处理系统给的后台刷新任务。
    ///
    /// ⚠️ **必须调用 `setTaskCompleted`**。不回调的后果是系统用退避算法重试，
    /// 连续几次无响应后就不再给这个 app 后台时间了。
    func handle(_ task: WKApplicationRefreshBackgroundTask) {
        Task {
            defer {
                task.setTaskCompletedWithSnapshot(false)
                // 无论成败都排下一次——这是官方要求的"降级设计"
                scheduleNextRefresh()
            }

            do {
                _ = try await HealthAuthorizer.shared.requestReadAuthorizationIfNeeded()
                await WatchServices.shared.syncEngine.syncAll(reason: .background)
            } catch {
                print("[Background] 同步失败：\(error.localizedDescription)")
            }
        }
    }
}
