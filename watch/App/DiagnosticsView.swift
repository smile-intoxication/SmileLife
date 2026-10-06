import SwiftUI

/// 诊断界面。
///
/// ## 为什么必须有这个界面（而不是 `print` 打日志）
/// 本项目的开发机是 Windows，**没有 Mac、看不到设备日志、连不上 Xcode**。
/// 所以「到底采到多少数据」「某个类型到底存不存在」「RR 间期到底有没有」
/// 这些问题只能做成**手表上能读的界面**，否则永远无法回答。
///
/// ## 三个层次刻意分开显示
/// 1. **本地库**（我们存下来的）—— 这是"我们拿到了什么"
/// 2. **App Group 快照**（小组件的数据源）—— 这是"小组件能看到什么"
/// 3. **HealthKit 直查**（设备里究竟有什么）—— 这是"设备有没有产生这个数据"
///
/// 三者必须分开看：本地库是 0，可能是没授权、可能是同步没跑、
/// 也可能是设备根本没这个类型 —— 只有第 3 层能把这三种情况区分开。
struct DiagnosticsView: View {

    @State private var report = DiagnosticsReport()
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("探测中…")
                    }
                }
            }

            // ——— 1. 同步状态 ———
            Section("同步状态") {
                row("上次尝试", Self.relative(report.status.lastAttemptAt))
                row("上次成功", Self.relative(report.status.lastSuccessAt))
                if let error = report.status.lastError {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最近错误").font(.caption2).foregroundStyle(.secondary)
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }

            // ——— 2. 本地库（手表硬盘）———
            Section("本地库") {
                row("样本总数", "\(report.totalSamples) 条")
                row("磁盘占用", Self.bytes(report.storeBytes))
                row("保留天数", "\(StoragePolicy.retentionDays) 天")
                if let path = report.storePath {
                    Text(path)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }

            // ——— 3. App Group 快照 ———
            Section("App Group 快照") {
                row("容器可用", report.appGroupAvailable ? "是" : "❌ 否")
                row("快照条目", "\(report.snapshotItemCount) 项")
                row("文件大小", Self.bytes(report.snapshotBytes))
                row("生成时间", Self.relative(report.snapshotGeneratedAt))
                Text("小组件只读这里，不查 HealthKit")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // ——— 3.5 传往 iPhone 的通道 ———
            // 这一节存在的理由和整个诊断界面一样：开发机是 Windows，
            // 看不到设备日志。「手机上没数据」可能是五六种完全不同的原因，
            // 只有把这几项分开显示才能定位。
            Section("iPhone 连接") {
                row("WCSession 支持", report.linkSupported ? "是" : "❌ 否（模拟器？）")
                row("会话状态", report.linkActivation)
                // ⚠️ 这里**刻意没有**「已配对手表」那一行：
                //    `WCSession.isPaired` 是 **iOS 专属**（头文件里标了 __WATCHOS_UNAVAILABLE），
                //    在手表端取它编译不过。而且语义上也没意义 —— 手表本来就是被配对的一方。
                //    手表真正需要知道的是"手机上装没装本 App"，那是 isCompanionAppInstalled。
                row("手机已装 App", report.companionInstalled ? "是" : "❌ 否")
                row("当前可达", report.linkReachable ? "是" : "否（正常，后台几乎不可达）")

                row("待发送样本", "\(report.outboxPending) 条")
                row("待转发删除", "\(report.pendingDeletions) 条")
                row("系统队列中", "\(report.outstandingTransfers) 个传输")

                if let at = report.lastFlushAt {
                    row("上次发送", Self.relative(at))
                }
                if let summary = report.lastFlushSummary {
                    Text(summary)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Text("「当前可达 = 否」不代表坏了：传输走的是 transferUserInfo，"
                     + "它交给系统排队、对端可用时投递，不需要手机此刻可达。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // ——— 4. 各指标采集量 ———
            Section("各指标采集量") {
                if report.rows.isEmpty {
                    Text("还没有数据").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(report.rows) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(item.title).font(.caption2)
                                Spacer(minLength: 4)
                                Text("\(item.count)")
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                                    .foregroundStyle(item.count == 0 ? .tertiary : .primary)
                            }
                            if let latest = item.latest {
                                Text(Self.relative(latest))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("无数据")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            // ——— 5. HealthKit 直查 ———
            Section("HealthKit 直查") {
                if let hr = report.probe?.heartRate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("心率密度（近 \(hr.hours) 小时）").font(.caption2)
                        Text("\(hr.sampleCount) 条").font(.system(size: 11, weight: .semibold))
                        if let gap = hr.medianGap {
                            Text("中位间隔 \(Self.seconds(gap))　最小 \(Self.seconds(hr.minGap))　最大 \(Self.seconds(hr.maxGap))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Text("S12 宣称每 5 秒一次 → 中位间隔应接近 5 秒")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    row("心率密度", "探测失败")
                }

                if let rmssd = report.probe?.rmssd {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HRV (RMSSD)").font(.caption2)
                        if !rmssd.typeAvailable {
                            Text("类型不可用").font(.system(size: 11)).foregroundStyle(.orange)
                            Text("这台设备/系统拿不到 heartRateVariabilityRMSSD")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("近 7 天 \(rmssd.sampleCount) 条").font(.system(size: 11, weight: .semibold))
                            Text("类型存在；0 条 = Apple 没往这个类型写")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let hb = report.probe?.heartbeat {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("心跳序列 / RR 间期（近 \(hb.days) 天）").font(.caption2)
                        Text("\(hb.seriesCount) 条序列").font(.system(size: 11, weight: .semibold))
                        if let at = hb.latestSampleDate {
                            Text("最新一条 \(Self.relative(at))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        if let beats = hb.beatsInLatestSeries {
                            Text("最新一条含 \(beats) 拍")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        if let rr = hb.medianRRms {
                            Text("中位 RR 间期 \(Int(rr)) ms")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        // ⚠️ 这条提醒不是凑字数的：v1.7 就是因为**没申请读这个类型的权限**，
                        //    导致这里显示 0 条，而 0 条被误读成"设备不产生这个数据"。
                        //    HealthKit 对没授权的类型返回空数组**而不是错误**，
                        //    所以「0」永远是两种含义的叠加。
                        Text("⚠️ 0 条有两种含义：设备没数据，或我们没拿到这个类型的读权限。"
                             + "HealthKit 不报错，只返回空数组 —— 所以别只看这一行下结论。")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text("被动逐拍数据预期需要开启「房颤历史」；移动心电图那条路要用户手动按表冠 30 秒。")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // ——— 6. 说明 ———
            Section {
                Text("⚠️ HealthKit 读不到数据时返回的是**空数组**而不是错误，所以「0 条」同时意味着「没数据」或「没授权」。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("指标注册表里共 \(report.probe?.catalogMetricCount ?? 0) 个类型。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach(report.probe?.errors ?? [], id: \.self) { err in
                    Text(err).font(.system(size: 9)).foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { await load() }
                } label: {
                    Label("重新探测", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
    }

    // MARK: - 小组件

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11, weight: .medium))
        }
    }

    // MARK: - 数据装配

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        var r = DiagnosticsReport()

        // 同步状态 + App Group（都是本地文件，不碰 HealthKit）
        r.status = SharedStore.readStatus()
        r.appGroupAvailable = SharedContainer.containerURL != nil

        let snapshot = SharedStore.readSnapshot()
        r.snapshotItemCount = snapshot.items.count
        r.snapshotGeneratedAt = snapshot.generatedAt == .distantPast ? nil : snapshot.generatedAt
        if let url = SharedContainer.snapshotURL {
            r.snapshotBytes = LocalFile.size(at: url)
        }

        // 本地库
        let services = WatchServices.shared
        r.storePath = services.storeURL?.path
        r.storeBytes = services.storeBytes

        let catalog = MetricCatalog.all
        let stats = (try? await services.store.stats(for: catalog.map(\.id))) ?? []
        let byID = Dictionary(uniqueKeysWithValues: stats.map { ($0.metricID, $0) })

        // 按注册表顺序展示，**没有数据的指标也要列出来**（否则看不出"少了哪个"）
        r.rows = catalog.map { metric in
            let s = byID[metric.id]
            return MetricDiagnosticsRow(id: metric.id,
                                        title: metric.title,
                                        count: s?.count ?? 0,
                                        latest: s?.latest)
        }
        r.totalSamples = r.rows.reduce(0) { $0 + $1.count }

        // ——— 传往 iPhone 的通道 ———
        let link = WatchLinkSession.shared
        r.linkSupported = link.isSupported
        r.linkActivation = link.activationStateText
        r.companionInstalled = link.isCompanionAppInstalled
        r.linkReachable = link.isReachable
        r.outstandingTransfers = link.outstandingCount
        r.outboxPending = (try? await services.store.pendingUploadCount()) ?? 0
        r.pendingDeletions = await services.deletions.pendingCount()

        let flushSnapshot = await services.outboxFlusher.snapshot()
        r.lastFlushAt = flushSnapshot.lastFlushAt
        // 注意变量名不要叫 report —— 那会遮蔽这个视图的 @State 属性
        if let sent = flushSnapshot.report, sent.didSendAnything {
            let tail = sent.stopReason.map { "（\($0)）" } ?? ""
            r.lastFlushSummary = "上次交给系统：\(sent.batches) 批 / "
                + "\(sent.samples) 条样本 / \(sent.deletions) 条删除\(tail)"
        } else if let reason = flushSnapshot.report?.stopReason {
            r.lastFlushSummary = "上次未发出：\(reason)"
        }

        // HealthKit 直查
        r.probe = await HealthProbe.shared.runAll(heartRateHours: 6, days: 7)

        report = r
    }

    // MARK: - 格式化

    private static func relative(_ date: Date?) -> String {
        guard let date else { return "无" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    private static func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.1f 秒", value) : "\(Int(value)) 秒"
    }

    private static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(value)
        var index = 0
        while size >= 1024 && index < units.count - 1 {
            size /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(size)) B" : String(format: "%.1f %@", size, units[index])
    }
}

// MARK: - 展示模型

struct MetricDiagnosticsRow: Identifiable {
    let id: String
    let title: String
    let count: Int
    let latest: Date?
}

/// 一次探测的全部结果
struct DiagnosticsReport {
    var status: SyncStatus = .unknown
    var appGroupAvailable = false
    var snapshotItemCount = 0
    var snapshotBytes: Int64 = 0
    var snapshotGeneratedAt: Date?

    var storePath: String?
    var storeBytes: Int64 = 0
    var totalSamples = 0
    var rows: [MetricDiagnosticsRow] = []

    // ——— 传往 iPhone 的通道 ———
    var linkSupported = false
    var linkActivation = "—"
    var companionInstalled = false
    var linkReachable = false
    var outstandingTransfers = 0
    var outboxPending = 0
    var pendingDeletions = 0
    var lastFlushAt: Date?
    var lastFlushSummary: String?

    var probe: HealthKitProbeReport?
}
