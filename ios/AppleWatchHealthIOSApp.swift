import SwiftUI
import UIKit

/// iPhone 端入口。
///
/// ## 它现在**不再是占位 app**
/// 之前这个 app 只有一个作用：作为 watch app 的载体以便分发
/// （`WKRunsIndependentlyOfCompanionApp` 让手表端能独立运行）。
/// 现在它是数据链路的下游：接收手表传过来的样本、长期保存、画图表。
///
/// ## 两端的职责分工
/// - **手表**：采集 + 7 天缓冲（磁盘小、后台预算紧）
/// - **手机**：长期档案（原始 180 天 + 永久汇总桶）+ 图表
///
/// 这个分工不是拍脑袋定的，是 watchOS 的现实逼出来的：
/// 后台每小时约 4 次、每次几秒、设备锁定时读不到 HealthKit。
/// 手表没法承担"长期趋势"这件事。
@main
struct AppleWatchHealthIOSApp: App {

    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// ⚠️ **WCSession 必须尽早激活**（官方口径："activate the session as early as possible"）。
///
/// 为什么不能只在 `RootView` 的 `.task` 里激活：
/// 手表在后台把数据传过来时，**手机上的 app 可能从来没被打开过**。
/// 那种情况下系统会启动 app 并走 launch 路径，而任何 SwiftUI 视图都还没被创建
/// —— 在视图里激活的话，正好错过第一批数据。
///
/// 这是"手机上一直没数据"最容易踩、又最难查的一个坑：
/// 界面上什么都正常，就是数据不来。
final class IOSAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PhoneServices.shared.startLink()
        return true
    }
}
