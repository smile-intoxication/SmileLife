import Foundation
import HealthKit

/// `HKHeartbeatSeriesQuery` 的**唯一调用点**。
///
/// ## 为什么必须收敛到一处
/// 这个查询的回调里有一个 `precededByGap` 参数，Apple 对它的定义是：
///
/// > "A Boolean value that indicates whether this heartbeat was **immediately preceded
/// > by a gap in the data**, indicating that **one or more heartbeats may be missing**."
/// > —— <https://developer.apple.com/documentation/healthkit/hkheartbeatseriesquery/init(heartbeatseries:datahandler:)>
///
/// 也就是说：**这一拍和前一拍之间的时间差不是一个真实的心跳间隔**。
/// 而我们的 RR 间期正是"相邻时间戳相减"算出来的 —— 漏 1 拍会把 800 ms
/// 变成 1600 ms，而 1600 ms 落在手机端 300–2000 ms 的生理范围内，
/// 于是它会**伪装成一个真实的心跳间隔**画进散点图、并把 SDNN 拉大。
///
/// 之前这个参数被写成 `_` 丢掉了。为了让"丢掉它"不再可能发生：
/// 查询、回调、洞标记的收取**全部只在本文件**，
/// 调用方拿到的是一个"时间戳和洞标记成对、长度必然相等"的值类型，
/// 想只取一半反而是费劲的。自检脚本第 16 节断言
/// `HKHeartbeatSeriesQuery` 只出现在本文件。
///
/// 📌 这条思路和 `MetricCatalog.heartbeatSeriesType` 是同一个：
/// **一个事实只允许有一处定义**。上一轮踩的坑就是"心跳序列类型在两处就地构造"
/// （申请 A、查 B，而 HealthKit 对没授权的类型只返回空数组、不报错）。
enum HeartbeatReader {

    /// 一次逐拍读取的产出。
    ///
    /// `stamps` 与 `gaps` **一一对应、长度必然相等** —— 它们在同一个回调里成对收下。
    /// 用结构体而不是元组，是为了让"只解构一半"这件事在类型上就写着别扭。
    struct Beats: Sendable {
        /// 逐拍时间戳（相对序列起点的**秒**）。
        var stamps: [TimeInterval] = []
        /// 每一拍的 `precededByGap`。
        var gaps: [Bool] = []
    }
    // 📌 这里**刻意没有**一个 `isPaired` 之类的"两个数组长度对不对"校验属性：
    //    · 类型上已经成立 —— 两个数组只在同一个回调里成对 append，
    //      没有任何一条路径能只加其中一个；
    //    · 而 `watch/` 里出现 `isPaired` 这个名字会**撞上自检第 14 节**
    //      （那一节查的是"手表端用了 WCSession 的 iOS 专属属性 `isPaired`"，
    //      判据是名字）。实测加了这个属性就直接让自检变红 —— 一次纯误报。
    //      与其放宽守卫，不如别用这个名字。

    /// 读出一条心跳序列的逐拍时间戳 + 洞标记。
    ///
    /// ⚠️ `dataHandler` 是**逐拍回调**的（一条几十拍的序列就是几十次回调），
    /// `done` 为 true 时才是最后一次 —— 所以调用方必须**限量**，
    /// 不能在一个后台轮次里展开很多条（见 `HealthSyncEngine.maxSeriesToExpandPerRound`）。
    ///
    /// continuation 必须**恰好 resume 一次**，所以用 `finished` 守住；
    /// 并且 `error != nil` 时也要 resume —— 否则会永久挂住，
    /// 把后台那几秒预算烧光（然后被系统按退避算法收紧额度）。
    static func beats(of sample: HKHeartbeatSeriesSample,
                      store: HKHealthStore) async throws -> Beats {
        try await withCheckedThrowingContinuation { continuation in
            var result = Beats()
            var finished = false

            let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) {
                _, timeSinceStart, precededByGap, done, error in

                if let error {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                // ⚠️ 无论 done 与否都收下这个时间戳：Apple **没有文档说明**
                //    "收尾那一次回调带不带有效时间戳"。
                //    多收一个无意义的值，会在算 RR 时被 `delta > 0` 过滤掉；
                //    少收一个则是**真的丢一拍**（少一个间期）。两害相权取其轻。
                result.stamps.append(timeSinceStart)
                // 洞标记和时间戳**成对**收 —— 下标必须始终对齐。
                result.gaps.append(precededByGap)

                if done && !finished {
                    finished = true
                    continuation.resume(returning: result)
                }
            }
            store.execute(query)
        }
    }
}
