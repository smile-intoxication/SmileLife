import Foundation
import WatchConnectivity

/// 手表侧的 WatchConnectivity 会话（单例）。
///
/// ## 为什么用 `transferUserInfo` 而不是 `sendMessage`
///
/// |              | `sendMessage`                  | `transferUserInfo`           |
/// |--------------|--------------------------------|------------------------------|
/// | 对端可达要求 | **必须** `isReachable == true` | 不需要                       |
/// | 送达时机     | 立刻，对端没开就失败           | 系统排队，对端可用时投递     |
/// | app 被杀     | 直接失败                       | **系统持久化，仍会送达**     |
/// | 大小上限     | 文档明确（65 KB 级别）         | **没有公开数字**（见下）     |
///
/// 我们的场景是"手表在后台跑完几秒内把一批样本交出去"，
/// 而 **iPhone 几乎永远不可达**（手机在口袋里、app 没开）——
/// 用 `sendMessage` 等于每次后台同步都白跑。所以只能 `transferUserInfo`。
///
/// ## ⚠️ 大小上限是个未知数
/// Apple **没有**公布 `transferUserInfo` 的负载上限（只有 `sendMessage` 有）。
/// 社区里出现过 `PayloadTooLarge` 报错。所以我们在 `WatchWire` 里
/// 按 32 KB / 200 条保守分批，而不是赌一个没人写下来的数字。
/// 依据：<https://stackoverflow.com/questions/34683648/wcsession-payloadtoolarge>
///
/// ## 线程
/// `WCSessionDelegate` 的回调在**后台队列**上。所以这个类刻意**不做任何 UI 状态**：
/// 界面要读的东西都是即时查询（`isActivated` / `outstandingCount` 等属性），
/// 需要在回调里更新的少量记账（最后一次送达时间）由调用方切回主线程再写。
final class WatchLinkSession: NSObject {

    static let shared = WatchLinkSession()

    /// 一次传输结束（送达或失败）时回调。参数：批次 id、错误。
    ///
    /// 刻意**不做"已送达才删队列"的记账** —— 见 `OutboxFlusher` 里的说明。
    /// 这个回调目前只用来：① 记录最后一次送达时间（诊断界面看）；
    /// ② 腾出系统队列位置后再触发一轮发送。
    var onTransferSettled: ((UUID, Error?) -> Void)?

    /// 会话激活状态变化时回调（主线程外的队上，调用方自己切线程）。
    var onActivationChanged: (() -> Void)?

    private override init() {
        super.init()
    }

    private var session: WCSession? {
        // 模拟器 / 部分 iPad 上 isSupported 为 false，必须判空，
        // 否则 `WCSession.default` 会直接抛 Objective-C 异常。
        WCSession.isSupported() ? WCSession.default : nil
    }

    // MARK: - 激活

    /// 激活会话。
    ///
    /// ⚠️ **必须尽早调用**（官方口径是 "as early as possible"）。
    /// 未激活时 `transferUserInfo` 会直接失败，而且失败得很安静
    /// —— 表现是"手机上一直接收不到数据"，本地却看不出任何异常。
    /// 所以手表在 `applicationDidFinishLaunching` 里就调用它，
    /// iPhone 在 `didFinishLaunchingWithOptions` 里调用。
    func activate() {
        guard let session else {
            print("[WC] 本设备不支持 WCSession（模拟器？）—— 数据传输不可用")
            return
        }
        if session.delegate == nil {
            session.delegate = self
        }
        if session.activationState != .activated {
            session.activate()
        }
    }

    // MARK: - 状态（诊断界面读）

    var isSupported: Bool { WCSession.isSupported() }

    var isActivated: Bool { session?.activationState == .activated }

    var activationStateText: String {
        guard let session else { return "不支持" }
        switch session.activationState {
        case .activated:  return "已激活"
        case .inactive:   return "未激活（inactive）"
        case .notActivated: return "尚未激活"
        @unknown default: return "未知"
        }
    }

    var isPaired: Bool { session?.isPaired ?? false }
    var isCompanionAppInstalled: Bool { session?.isCompanionAppInstalled ?? false }
    var isReachable: Bool { session?.isReachable ?? false }
    var outstandingCount: Int { session?.outstandingUserInfoTransfers.count ?? 0 }

    // MARK: - 发送

    /// 把一批样本交给系统队列。
    ///
    /// 返回值表示**系统是否收下了**，不代表送达。
    /// 送达与否只能通过 `session(_:didFinish:error:)` 知道。
    @discardableResult
    func enqueue(_ batch: SampleBatch) -> Bool {
        guard !batch.isEmpty else { return true }   // 空批当成功，别占队列
        guard let session else { return false }
        guard session.activationState == .activated else { return false }

        let payload = batch.encoded()
        guard !payload.isEmpty else {
            // 编码失败是**真的出错**（不是"没数据"），必须留下痕迹，
            // 否则表现就是"队列永远发不出去但没有任何报错"。
            print("[WC] 批次编码失败，丢弃 batchID=\(batch.batchID)")
            return true   // 返回 true 让调用方把这批从队列里删掉，避免卡死队列头
        }

        // 字典里只放 version / batchID / payload 三个键：
        // version 与 batchID 让接收方**不必先解码整份负载**就能判断与记日志。
        // 返回值（WCSessionUserInfoTransfer）这里刻意不用：
        // 传输的最终结果通过 `session(_:didFinish:error:)` 回调告知，
        // 拿到 transfer 对象也没法从中推出"送到了没有"。
        _ = session.transferUserInfo([
            WatchWire.versionKey: batch.version,
            WatchWire.batchIDKey: batch.batchID.uuidString,
            WatchWire.payloadKey: payload
        ])
        return true
    }
}

// MARK: - WCSessionDelegate

extension WatchLinkSession: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            print("[WC] 激活失败：\(error.localizedDescription)")
        } else {
            print("[WC] 激活完成：\(activationState.rawValue)")
        }
        onActivationChanged?()
    }

    /// 一次 `transferUserInfo` 的最终结果。
    ///
    /// ⚠️ 这个回调**可能在 app 被系统重启后才到达**（传输是系统在做的）。
    /// 所以这里只做两件事：记一句日志、通知调用方可以继续发下一批。
    /// **不要**在这里做"没收到回调就永远不删队列"之类的强依赖——
    /// app 被杀时那套状态会丢，反而更容易把队列卡死。
    func session(_ session: WCSession,
                 didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                 error: Error?) {
        let idString = userInfoTransfer.userInfo[WatchWire.batchIDKey] as? String
        let batchID = idString.flatMap { UUID(uuidString: $0) } ?? UUID()
        if let error {
            print("[WC] 批次投递失败 batchID=\(batchID)：\(error.localizedDescription)")
        } else {
            print("[WC] 批次已送达 batchID=\(batchID)")
        }
        onTransferSettled?(batchID, error)
    }
}
