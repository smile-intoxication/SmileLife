import Foundation

// MARK: - 单条样本

/// 一条样本的**线上格式**。
///
/// ## 为什么和本地库的模型分开
/// 本地库用的是 SwiftData 的 `@Model`（`SampleRecord`），它**不是 `Sendable`**，
/// 也不能跨设备传输。线上格式必须是纯值类型 `Codable`，而且要能独立演进：
/// 以后本地库加字段不应该自动改变线协议。
///
/// ## 为什么不用字典直接传
/// `transferUserInfo` 的字典只能是 **property list** 类型。
/// 嵌在字典里的 `Date` / `UUID` / 可选值要逐个手工转换，很容易漏；
/// 而 `Data` 本身就是合法的 property list 类型 —— 所以：
/// **整个批次先编码成一份 JSON `Data`，字典里只放这一个 Data**。
struct UploadPayload: Codable, Equatable, Sendable {

    var uuid: UUID
    var metricID: String
    var startDate: Date
    var endDate: Date
    var value: Double?
    var categoryValue: Int?
    var unitString: String?

    // ——— 来源追踪：让 iPhone 能回答"这条是不是手表产生的" ———
    var sourceBundleID: String?
    var sourceName: String?
    var deviceName: String?
    var deviceModel: String?
    var deviceManufacturer: String?

    /// 落库时间（不是采样时间）。用于排查"手表采集 → 手机可见"的端到端延迟。
    var ingestedAt: Date

    init(uuid: UUID,
         metricID: String,
         startDate: Date,
         endDate: Date,
         value: Double? = nil,
         categoryValue: Int? = nil,
         unitString: String? = nil,
         sourceBundleID: String? = nil,
         sourceName: String? = nil,
         deviceName: String? = nil,
         deviceModel: String? = nil,
         deviceManufacturer: String? = nil,
         ingestedAt: Date) {
        self.uuid = uuid
        self.metricID = metricID
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.categoryValue = categoryValue
        self.unitString = unitString
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.deviceManufacturer = deviceManufacturer
        self.ingestedAt = ingestedAt
    }

    func encoded() -> Data { WireCodec.encode(self) }

    static func decode(_ data: Data) -> UploadPayload? {
        WireCodec.decode(UploadPayload.self, from: data)
    }
}

// MARK: - 批次

/// 一个传输批次。
///
/// ## 为什么删除要单独一个列表
/// 用户在健康 App 里删掉一条数据后，HealthKit 会通过 `HKDeletedObject` 通知我们。
/// 手表本地删了、手机不删，手机上就会一直显示**用户已经删掉的数据**——
/// 这属于**正确性**问题，不是被砍掉的"数据完整性"（见设计方案 §0）。
///
/// ## 为什么带 version
/// 手表和 iPhone 的版本**不保证同步**（用户可能只更新了一端，
/// 而且 TestFlight 分阶段推送时更是常态）。解码方必须先看版本再决定怎么读，
/// 而不是"解不出来就崩"。
struct SampleBatch: Codable, Equatable, Sendable {

    /// 当前协议版本。**只增不改**：新增字段一律做成可选，老版本能安全忽略。
    static let currentVersion = 1

    var version: Int
    var batchID: UUID
    var sentAt: Date
    var samples: [UploadPayload]
    var deletedUUIDs: [UUID]

    init(batchID: UUID = UUID(),
         sentAt: Date = Date(),
         samples: [UploadPayload],
         deletedUUIDs: [UUID] = [],
         version: Int = SampleBatch.currentVersion) {
        self.version = version
        self.batchID = batchID
        self.sentAt = sentAt
        self.samples = samples
        self.deletedUUIDs = deletedUUIDs
    }

    /// 空批（既没有样本也没有删除）不该被发送 —— 那只是白占系统队列。
    var isEmpty: Bool { samples.isEmpty && deletedUUIDs.isEmpty }

    func encoded() -> Data { WireCodec.encode(self) }

    static func decode(_ data: Data) -> SampleBatch? {
        WireCodec.decode(SampleBatch.self, from: data)
    }
}

// MARK: - 字典键与限额

/// `transferUserInfo` 字典里的键名，以及分批限额。
enum WatchWire {

    /// 协议版本。单独放在字典里，让接收方**不必先解码整份负载**就能判断支不支持。
    static let versionKey = "wireVersion"
    /// 批次 id。同样是"不解码就能拿到"的元信息，用于日志和去重排查。
    static let batchIDKey = "batchID"
    /// 批次负载（`SampleBatch` 的 JSON）
    static let payloadKey = "payload"

    /// 单批最多多少条样本。
    static let maxSamplesPerBatch = 200

    /// 单批最多多少字节。
    ///
    /// ⚠️ Apple **没有公布** `transferUserInfo` 的大小上限（这本身就是个坑：
    /// 只有 `sendMessage` 有明确的 65 KB 级别限制）。社区里出现过
    /// `PayloadTooLarge` 的报错，所以这里取一个明显保守的值，
    /// 宁可多发几批，也不要撞在一个没有文档的上限上。
    /// 依据：<https://stackoverflow.com/questions/34683648/wcsession-payloadtoolarge>
    static let maxBytesPerBatch = 32 * 1024

    /// 系统队列里最多允许压着多少个未完成的传输。
    ///
    /// 为什么要有这个上限：`transferUserInfo` 是"交给系统、系统负责送"，
    /// 手机长期不可达时系统队列会一直涨。涨到系统自己的上限之后，
    /// 官方没有任何承诺说它会怎么处理（丢新的还是丢旧的都不知道）。
    /// 所以我们在**自己的**待上传队列里留一手：压着太多就先不发，
    /// 等 `didFinish` 回调腾出位置再继续 —— 至少丢的是我们自己能看见、能记数的那一份。
    static let maxOutstandingTransfers = 24
}

// MARK: - 编解码

/// 统一的 JSON 编解码。
///
/// ⚠️ 每次调用都**新建** `JSONEncoder` / `JSONDecoder`，不缓存成 static let。
/// 原因是编解码会**并发发生**：手表在 actor 上编码，iPhone 在 WCSession 的
/// 回调队列上解码。`JSONEncoder` 不是文档保证的线程安全类型，
/// 为了省这点创建开销去赌它，不值得。
enum WireCodec {

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // ISO8601 而不是默认的 timeIntervalSinceReferenceDate：
        // 线上格式要能被别的语言/工具读懂（排查问题时可以直接看 JSON）。
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? makeEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? makeDecoder().decode(type, from: data)
    }
}
