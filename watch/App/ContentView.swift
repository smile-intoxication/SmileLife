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
    /// 还没交给 iPhone 的样本条数。0 表示队列已经发空。
    @State private var pendingSends = 0

    // ⚠️ 这里**刻意没有** "未授权指标" 状态。
    // HealthKit 的读权限是不可查询的（详见 HealthAuthorizer 里的说明），
    // 任何基于 authorizationStatus(for:) 的判断都会变成"永远显示未授权"的假提示。
    // 授权情况只能靠"有没有数据"间接体现，所以空态文案里把两种可能都讲清楚。

    var body: some View {
        NavigationStack {
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
                    // 如实告诉用户"还有多少没送到手机"。
                    // 不发「同步完成」这种笼统的提示 —— 那样用户会以为手机上已经有了。
                    //
                    // ⚠️ 三元表达式两边必须写全 `Color.`：
                    //    `.secondary` 是 `HierarchicalShapeStyle`，`.orange` 是 `Color`，
                    //    简写形式会让编译器把两边推断成同一个类型然后失败
                    //    （CI 上就是这么红的：member 'orange' in 'HierarchicalShapeStyle'
                    //      produces result of type 'Color', but context expects 'HierarchicalShapeStyle'）。
                    Text(pendingSends == 0
                         ? "数据已全部交给 iPhone"
                         : "还有 \(pendingSends) 条待发送到 iPhone")
                        .font(.caption2)
                        .foregroundStyle(pendingSends == 0 ? Color.secondary : Color.orange)
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

                // ——— 诊断 ———
                // 开发机是 Windows、看不到设备日志，所以「到底采到多少数据」
                // 「某个类型到底存不存在」只能靠这个界面回答。
                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("诊断", systemImage: "stethoscope")
                    }
                }

            }
            .navigationTitle("长明护心")
        }
        .task { await bootstrap() }
    }
    // MARK: - 子视图

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有数据")
                    .font(.headline)
                Text("点「立即同步」跑一次。\n\n如果一直没数据，两种可能：\n① 健康权限没开——去 iPhone 的「设置 → 健康 → 数据访问」检查；\n② 表盘上没有本 app 的小组件——watchOS 要求这样才给后台刷新额度。")
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
            // 后台调用时弹不出授权窗，这里失败是正常的，不当错误抛出
            print("[UI] 授权请求未完成：\(error.localizedDescription)")
        }

        // 前台打开时同步一次——这是后台被节流时的兜底
        await manualSync()
    }

    private func manualSync() async {
        isSyncing = true
        defer { isSyncing = false }

        // 会话没激活就发不出去，而 activate 是幂等的 —— 这里再兜一次，
        // 覆盖「App 是被后台唤醒启动、AppDelegate 还没跑完」这类时序。
        WatchLinkSession.shared.activate()

        status = await WatchServices.shared.syncEngine.syncAll(reason: .foreground)
        snapshot = SharedStore.readSnapshot()
        pendingSends = (try? await WatchServices.shared.store.pendingUploadCount()) ?? 0

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
