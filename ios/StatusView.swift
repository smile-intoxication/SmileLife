import SwiftUI

/// 状态：数据链路还活着吗？
///
/// ## 为什么这个页签不是"调试用的、可以砍掉"
/// 本项目的开发机是 Windows —— **没有 Mac、看不到设备日志、连不上 Xcode**。
/// 「手机上没数据」至少有六种完全不同的原因：
/// ① 手表端没授权健康；② 手表端同步没跑；③ WCSession 没激活；
/// ④ 手机没装/没配对；⑤ 传输在系统队列里排着；⑥ 收到了但落库失败。
/// 没有这个页面，这六种情况在用户眼里**长得一模一样**，
/// 而每一种的修法都不同。手表端的「诊断」界面就是为这件事存在的，
/// 这里是它的手机侧对称物。
struct StatusView: View {

    @ObservedObject private var status = LinkStatus.shared

    @State private var totalSamples = 0
    @State private var rollupCount = 0
    @State private var oldestDate: Date?
    @State private var newestDate: Date?
    @State private var summaries: [PhoneMetricSummary] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var storeBytes: Int64 { PhoneServices.shared.storeBytes }
    private var storePath: String? { PhoneServices.shared.storeURL?.path }

    var body: some View {
        NavigationStack {
            List {
                linkSection
                storeSection
                metricsSection
                notesSection

                if let loadError {
                    Section {
                        Text(loadError).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("状态")
            .refreshable { await load() }
            .overlay(alignment: .top) {
                if isLoading && totalSamples == 0 {
                    ProgressView().padding()
                }
            }
        }
        .task { await load() }
        .onChange(of: status.dataVersion) { _, _ in
            Task { await load() }
        }
    }

    // MARK: - 链路

    private var linkSection: some View {
        Section {
            row("WCSession 支持", status.isSupported ? "是" : "❌ 否")
            row("会话状态", status.sessionState)
            row("已配对手表", status.isPaired ? "是" : "❌ 否")
            row("手表已装本 App", status.isWatchAppInstalled ? "是" : "❌ 否")
            row("手表当前可达", status.isReachable ? "是" : "否")
            if status.isIngesting {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("正在落库…").font(.footnote)
                }
            }
            if let error = status.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("数据链路")
        } footer: {
            Text("「手表当前可达 = 否」是正常的：数据走 transferUserInfo，"
                 + "由系统排队、等手机可用时投递，不需要手表此刻连着。")
        }
    }

    // MARK: - 本地库

    private var storeSection: some View {
        Section {
            row("样本总数", PhoneFormat.number(totalSamples))
            row("汇总桶", PhoneFormat.number(rollupCount))
            row("磁盘占用", PhoneFormat.bytes(storeBytes))
            row("最早样本", PhoneFormat.relative(oldestDate))
            row("最新样本", PhoneFormat.relative(newestDate))
            row("最后收到", PhoneFormat.relative(status.lastReceivedAt))
            if let path = storePath {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        } header: {
            Text("本机数据")
        } footer: {
            Text("原始样本保留 \(PhoneStoragePolicy.rawRetentionDays) 天，"
                 + "汇总桶（\(PhoneStoragePolicy.bucketMinutes) 分钟一格）不删 —— "
                 + "所以超过半年的长期趋势仍然看得到。")
        }
    }

    // MARK: - 各指标

    private var metricsSection: some View {
        Section("各指标接收情况") {
            ForEach(summaries) { summary in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(MetricDisplay.infoOrFallback(id: summary.metricID).title)
                            .font(.subheadline)
                        Spacer(minLength: 4)
                        Text(PhoneFormat.number(summary.count))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(summary.count == 0 ? .tertiary : .primary)
                    }
                    Text(rangeText(summary))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func rangeText(_ summary: PhoneMetricSummary) -> String {
        guard let earliest = summary.earliestDate, let latest = summary.latestDate else {
            return "还没有收到这个指标"
        }
        if Calendar.current.isDate(earliest, inSameDayAs: latest) {
            return "\(PhoneFormat.dateTime(earliest)) 起"
        }
        return "\(PhoneFormat.day(earliest)) ~ \(PhoneFormat.day(latest))"
    }

    // MARK: - 说明

    private var notesSection: some View {
        Section {
            Text("接收批次 \(PhoneFormat.number(status.receivedBatches)) 批 / "
                 + "样本 \(PhoneFormat.number(status.receivedSamples)) 条 / "
                 + "删除 \(PhoneFormat.number(status.receivedDeletions)) 条")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let summary = status.lastIngestSummary {
                Text("最近一批：\(summary)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("传输是「至少一次」：同一批可能被投递多次，按样本 id 幂等去重，"
                 + "所以这里的条数不会因为重发而变多。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } header: {
            Text("接收统计")
        }
    }

    // MARK: - 小块

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(.subheadline, design: .rounded, weight: .medium))
        }
    }

    // MARK: - 装配

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let store = PhoneServices.shared.store
        do {
            totalSamples = try await store.totalSampleCount()
            rollupCount = try await store.rollupCount()
            oldestDate = try await store.oldestSampleDate()
            newestDate = try await store.newestSampleDate()
            summaries = try await store.metricSummaries()
            // 本地库给出的"最后收到时间"更可靠（它来自数据本身）；
            // 只有在一条都没收到过时才退回内存里那个计数器。
            if let persisted = try await store.lastReceivedAt() {
                status.update { $0.lastReceivedAt = persisted }
            }
            loadError = nil
        } catch {
            loadError = "查询本地库失败：\(error.localizedDescription)"
        }
    }
}
