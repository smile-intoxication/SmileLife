import SwiftUI
import WatchKit

@main
struct AppleWatchHealthApp: App {

    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// 后台任务的入口。
///
/// `applicationDidFinishLaunching` 里就排上第一次后台刷新——
/// 用户装完 app 打开一次之后，后台链路才开始运转。
final class AppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        // ⚠️ 顺序很重要：**先**激活 WatchConnectivity 会话，**再**排后台刷新。
        //    WCSession 未激活时 transferUserInfo 会静默失败 ——
        //    那种"手机上一直接收不到数据、手表这边看不出问题"的状态最难查。
        //    （activate 本身是异步的，激活完成后 WatchServices 里的回调
        //      会把之前发不出去的队列补发一次。）
        WatchServices.shared.startLink()

        BackgroundCoordinator.shared.scheduleNextRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {

            case let refresh as WKApplicationRefreshBackgroundTask:
                // 定期读取健康数据的主路径
                BackgroundCoordinator.shared.handle(refresh)

            case let urlSession as WKURLSessionRefreshBackgroundTask:
                // 预留接点：等接入 background URLSession 上传数据后，
                // 在这里根据 sessionIdentifier 收尾并标记上传完成。
                // （官方原文：有 complication 时每小时最多 4 次这类任务，
                //   建议 earliestBeginDate 间隔 ≥ 15 分钟）
                urlSession.setTaskCompletedWithSnapshot(false)

            default:
                // 其它类型（快照刷新、 connectivity 刷新等）当前不处理，
                // 但**必须**回调，否则系统会停止给这个 app 后台时间。
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
