import SwiftUI

/// 概览：各项指标的**最新值**。
///
/// 和手表端主界面刻意保持同一套信息结构（标题 / 采样时间 / 值 / 单位），
/// 这样用户在两个设备上看到的是同一件事，不会怀疑"哪个才是对的"。
struct OverviewView: View {

    @ObservedObject private var status = LinkStatus.shared

    @State private var summaries: [PhoneMetricSummary] = []
    @State private var totalSamples = 0
    @State private var isLoading = false
    @State private var loadError: String?

    private var rowsWithData: [PhoneMetricSummary] { summaries.filter(\.hasData) }
    /// 没有数据的指标**也要列出来**。
    /// 只显示有数据的那些，用户看到的是"少了几个指标"——那看起来像 bug；
    /// 而把空的也列出来，"这几个指标没数据"才是事实。
    private var rowsWithoutData: [PhoneMetricSummary] { summaries.filter { !$0.hasData } }

    var body: some View {
        NavigationStack {
            List {
                if totalSamples == 0 {
                    emptyStateSection
                } else {
                    if !rowsWithData.isEmpty {
                        Section("最新数据") {
                            ForEach(rowsWithData) { summary in
                                MetricSummaryRow(summary: summary)
                            }
                        }
                    }
                    if !rowsWithoutData.isEmpty {
                        Section {
                            ForEach(rowsWithoutData) { summary in
                                HStack {
                                    Text(MetricDisplay.infoOrFallback(id: summary.metricID).title)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("暂无数据")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } header: {
                            Text("尚未收到")
                        } footer: {
                            Text("这些指标手表端可能没有开启权限，或这台设备本来就不产生该类型的数据。"
                                 + "具体原因可以在手表上的「诊断」界面看到。")
                        }
                    }

                    Section {
                        Text("共 \(PhoneFormat.number(totalSamples)) 条样本，"
                             + "最后收到于 \(PhoneFormat.relative(status.lastReceivedAt))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let loadError {
                    Section {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("长明护心")
            .refreshable { await load() }
            .overlay(alignment: .top) {
                if isLoading && totalSamples == 0 {
                    ProgressView().padding()
                }
            }
        }
        .task { await load() }
        // 每落库一批就重新查一次。用计数器而不是观察 SwiftData：
        // 所有写操作都在 PhoneStore 这个 actor 上，用计数器最不容易出错。
        .onChange(of: status.dataVersion) { _, _ in
            Task { await load() }
        }
    }

    // MARK: - 空态

    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("还没有收到数据", systemImage: "applewatch")
                    .font(.headline)

                Text("""
                    数据是这样过来的：手表采集 → 存进手表的本地库 → 排队交给系统 \
                    → 系统在手机可用时投递 → 本 App 落库。
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("""
                    如果是刚开始用，请先做这三件事：
                    ① 在 iPhone 的「设置 → 健康 → 数据访问」里给本 App 开权限；
                    ② 把「长明护心」的小组件加到表盘上（watchOS 要求这样才给后台刷新额度）；
                    ③ 在手表上打开本 App，点一次「立即同步」。
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 装配

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let store = PhoneServices.shared.store
        do {
            summaries = try await store.metricSummaries()
            totalSamples = try await store.totalSampleCount()
            loadError = nil
        } catch {
            loadError = "查询本地库失败：\(error.localizedDescription)"
        }
    }
}

/// 单行指标：图标 / 标题 + 采样时间 / 值 + 单位。
private struct MetricSummaryRow: View {

    let summary: PhoneMetricSummary

    private var info: MetricDisplay.Info { MetricDisplay.infoOrFallback(id: summary.metricID) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: info.symbolName)
                .foregroundStyle(.pink)
                .font(.footnote)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.subheadline)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(PhoneFormat.value(metricID: summary.metricID,
                                       value: summary.latestValue,
                                       categoryValue: summary.latestCategoryValue))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                if !info.unitSuffix.isEmpty {
                    Text(info.unitSuffix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detailText: String {
        let time = PhoneFormat.relative(summary.latestDate)
        return "\(PhoneFormat.number(summary.count)) 条 · \(time)"
    }
}
