import Foundation
import Combine
import WatchConnectivity

/// 连接状态（给界面看）。
///
/// ## 为什么刻意**不加** `@MainActor`
/// `WCSessionDelegate` 的回调在**后台队列**上。把整个类标成 `@MainActor`
/// 会让每个 delegate 方法都要写成 `nonisolated` 再手动跳线程，
/// 在 Swift 5 语言模式下换来一堆并发告警，却没有换来任何实际安全。
/// 真正需要的只有一条规则：**改 `@Published` 的时候必须在主线程**。
/// 这条由 `update(_:)` 统一保证 —— 它是这个类唯一的写入口。
final class LinkStatus: ObservableObject {

    static let shared = LinkStatus()

    // ——— 会话 ———
    @Published var isSupported = true
    @Published var sessionState = "尚未激活"
    @Published var isPaired = false
    @Published var isWatchAppInstalled = false
    @Published var isReachable = false

    // ——— 接收 ———
    @Published var lastReceivedAt: Date?
    @Published var receivedBatches = 0
    @Published var receivedSamples = 0
    @Published var receivedDeletions = 0
    @Published var isIngesting = false
    @Published var lastIngestSummary: String?
    @Published var lastError: String?

    /// 落库完成一次就 +1。视图靠它知道"该重新查库了"。
    ///
    /// 为什么用计数器而不是让视图观察 SwiftData：SwiftData 的
    /// `@Query` 要在 View 里直接持有 ModelContext，而这个 app 的所有写操作
    /// 都在 `PhoneStore` 这个 actor 上。用计数器是最不容易出错的做法。
    @Published var dataVersion = 0

    private init() {}

    /// **唯一的写入口**：统一切到主线程再改 `@Published`。
    ///
    /// 后台线程改 `@Published` 会让 SwiftUI 在渲染时读到半更新的状态，
    /// 表现是偶发崩溃或界面不刷新 —— 而这类问题在没有 Mac、看不到日志的
    /// 前提下几乎不可能定位。所以宁可麻烦一点，全部收口。
    func update(_ block: @escaping (LinkStatus) -> Void) {
        if Thread.isMainThread {
            block(self)
        } else {
            DispatchQueue.main.async { block(self) }
        }
    }
}

/// iPhone 侧的 WatchConnectivity 会话。
///
/// ## 只负责"收"
/// 手机**不主动向手表要数据**。理由是 `sendMessage` 要求手表此刻可达，
/// 而手表绝大多数时间在休眠 —— 主动拉取会大面积失败，
/// 然后在"失败了要不要重试"上越写越复杂。
/// 改成纯推送之后，链路是单向的：手表产生数据 → 排队 → 系统投递 → 手机落库。
///
/// ## ⚠️ 必须在 `didFinishLaunchingWithOptions` 里激活
/// 手表在后台把数据传过来时，**手机上的 app 可能从来没被打开过**。
/// 那种情况下系统会启动 app 并走 launch 路径 ——
/// 只在某个 SwiftUI 视图的 `.task` 里激活是收不到的，因为那个视图根本不会被创建。
final class WatchLink: NSObject {

    static let shared = WatchLink()

    private let status = LinkStatus.shared
    private var store: PhoneStore?

    private override init() {
        super.init()
    }

    private var session: WCSession? {
        // 模拟器 / 部分 iPad 上 isSupported 为 false，必须判空，
        // 否则 `WCSession.default` 会直接抛 Objective-C 异常。
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// 激活会话并绑定本地库。
    func activate(store: PhoneStore) {
        self.store = store

        guard let session else {
            status.update {
                $0.isSupported = false
                $0.sessionState = "本设备不支持 WCSession"
            }
            return
        }

        if session.delegate == nil {
            session.delegate = self
        }
        if session.activationState != .activated {
            session.activate()
        }
        publishState(session)
    }

    // MARK: - 状态

    private func publishState(_ session: WCSession,
                              state: WCSessionActivationState? = nil,
                              error: Error? = nil) {
        let resolved = state ?? session.activationState
        let text: String
        switch resolved {
        case .activated:    text = "已激活"
        case .inactive:     text = "未激活（inactive）"
        case .notActivated: text = "尚未激活"
        @unknown default:   text = "未知"
        }

        status.update {
            $0.sessionState = text
            $0.isPaired = session.isPaired
            $0.isWatchAppInstalled = session.isWatchAppInstalled
            $0.isReachable = session.isReachable
            if let error { $0.lastError = "会话激活失败：\(error.localizedDescription)" }
        }
    }

    // MARK: - 接收

    private func handle(_ userInfo: [String: Any]) {
        guard let store else {
            status.update { $0.lastError = "收到了数据但本地库还没准备好（activate 尚未调用）" }
            return
        }

        // 先看协议版本再看负载：手表可能比手机新（用户只更新了一端，
        // TestFlight 分阶段推送时这是常态）。解不出来就如实报错，
        // 不要假装收到了一批空数据 —— 那会表现成"手机上就是没数据"。
        let version = userInfo[WatchWire.versionKey] as? Int ?? 0
        guard version <= SampleBatch.currentVersion else {
            status.update {
                $0.lastError = "手表用的是更新的传输协议（v\(version)），请更新 iPhone 上的 App"
            }
            return
        }

        guard let data = userInfo[WatchWire.payloadKey] as? Data else {
            status.update { $0.lastError = "负载不是 Data（手表端版本可能过旧）" }
            return
        }

        guard let batch = SampleBatch.decode(data) else {
            status.update { $0.lastError = "批次解码失败（\(data.count) 字节）" }
            return
        }

        status.update {
            $0.receivedBatches += 1
            $0.receivedSamples += batch.samples.count
            $0.receivedDeletions += batch.deletedUUIDs.count
            $0.lastError = nil
            $0.isIngesting = true
        }

        // 落库放到后台：`didReceiveUserInfo` 的调用线程不该被磁盘 IO 占住。
        // PhoneStore 是 actor，多批数据会自然串行，不会并发写同一个 ModelContext。
        Task {
            do {
                let result = try await store.ingest(batch)
                status.update {
                    $0.isIngesting = false
                    $0.lastReceivedAt = .now
                    $0.lastIngestSummary = result.summary
                    $0.dataVersion += 1
                }
            } catch {
                status.update {
                    $0.isIngesting = false
                    $0.lastError = "落库失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchLink: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        publishState(session, state: activationState, error: error)
    }

    /// 用户在配对手表之间切换时会被调用。
    func sessionDidBecomeInactive(_ session: WCSession) {
        publishState(session)
    }

    /// ⚠️ 官方要求：这里**必须重新 activate**。
    /// 不重新激活的话，用户换了手表之后新表的数据**永远收不到**，
    /// 而界面上一切正常（旧的会话说自己还是 activated）。
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        publishState(session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publishState(session)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publishState(session)
    }

    /// 手表 `transferUserInfo` 过来的数据在这里到达。
    ///
    /// 注意它**可能在 app 处于后台时被调用**（系统为投递而唤醒 app）。
    /// 所以这里不能依赖任何 UI 已经存在。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }
}
