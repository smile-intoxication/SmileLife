import SwiftUI
import HealthKit

/// 手表端主界面。
///
/// 数据来源刻意用**快照文件**而不是直接查库：
/// 这样"用户在手表上看到的"和"小组件显示的"永远是同一份数据，
/// 不会出现两处数字不一致的诡异问题。
struct ContentView: View {

    @State private var snapshot: LatestSnapshot = .empty
    @State private var status: SyncStatus = .unknown
    @State private var isSyncing = false
    @State private var authDenied = false

    var body: some View {
        List {

            // ——— 同步状态：如实展示"数据是什么时候的" ———
            Section {
                if isSyncing {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("同步中…")
                    }
                } else {
                    Text(lastSyncText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = status.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            // ——— 各指标最新值 ———
            if snapshot.items.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(snapshot.items) { item in
                        MetricRow(item: item)
                    }
                }
            }

            // ——— 手动触发 ———
            Section {
                Button {
                    Task { await manualSync() }
                } label: {
                    Label("立即同步", systemImage: "arrow.clockwise")
                }
                .disabled(isSyncing)
            }

            if authDenied {
                Section {
                    Text("部分指标未授权。请在「设置 → 健康 → 数据访问」中开启。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await bootstrap() }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有数据")
                    .font(.headline)
                Text("下拉「立即同步」跑一次。\n后台自动同步需要你把本 app 的表盘小组件放到当前表盘上——这是 watchOS 的硬性要求。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 行为

    private func bootstrap() async {
        do {
            try await HealthAuthorizer.shared.requestReadAuthorizationIfNeeded()
        } catch {
            print("[UI] 授权失败：\(error.localizedDescription)")
        }

        let unauthorized = await HealthAuthorizer.shared.unauthorizedMetrics()
        authDenied = !unauthorized.isEmpty

        // 前台打开时同步一次——这是后台被节流时的兜底
        await manualSync()
    }

    private func manualSync() async {
        isSyncing = true
        defer { isSyncing = false }

        status = await WatchServices.shared.syncEngine.syncAll(reason: .foreground)
        snapshot = SharedStore.readSnapshot()

        // 前台跑完顺便排一次后台，保证链路不断
        BackgroundCoordinator.shared.scheduleNextRefresh()
    }

    private var lastSyncText: String {
        guard let date = status.lastSuccessAt else { return "尚未同步" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return "更新于 " + f.localizedString(for: date, relativeTo: .now)
    }
}

/// 单行指标展示。
///
/// 注意这里同时展示**采样时间**：HealthKit 的同步延迟官方没有任何承诺，
/// 所以必须让用户清楚这条数据是什么时候采的，而不是暗示"实时"。
private struct MetricRow: View {

    let item: LatestSnapshot.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: item.symbolName)
                .foregroundStyle(.red)
                .font(.footnote)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.displayValue)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                if !item.unitSuffix.isEmpty {
                    Text(item.unitSuffix)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(item.sampleDate) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: item.sampleDate)
    }
}
