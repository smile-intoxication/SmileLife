import SwiftUI
import UIKit

/// 「新鲜度」—— 各个指标**多久更新一次**。
///
/// ## 这张表要回答的问题
/// "我打开 app 看到的这个数，是什么时候的？这个指标到底在不在更新？"
/// 单看"最新一条"回答不了 —— 一个每天只来一条的指标和一个 5 秒来一条的指标，
/// 都可能显示"最新一条 = 10 分钟前"。**必须把"典型间隔"和"条数"放在一起看。**
///
/// ⚠️ 中位间隔用**中位数**不用平均值（理由见 `MetricFreshness` 的注释）。
struct FreshnessSection: View {

    @ObservedObject private var status = LinkStatus.shared

    @State private var rows: [MetricFreshness] = []
    @State private var now = Date()
    @State private var isLoading = true
    @State private var copied = false

    /// 只显示"有过数据"的指标。
    ///
    /// 但这**不等于**把它们藏起来：一条都没有的指标会汇总成下面一行说明
    /// （"N 个指标一条数据都没有"），而不是静默消失
    /// —— "没数据"和"没这个指标"是两件完全不同的事。
    private var populated: [MetricFreshness] { rows.filter { $0.countTotal > 0 } }
    private var emptyCount: Int { rows.filter { $0.countTotal == 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if rows.isEmpty {
                Text(isLoading ? "正在统计…" : "读不到本地数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                columnHeader
                ForEach(populated) { row in
                    FreshnessRowView(row: row, now: now)
                    Divider()
                }
                footer
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .task(id: status.dataVersion) { await load() }
    }

    // MARK: 取数

    private func load() async {
        let store = PhoneServices.shared.store
        let stamp = Date()
        rows = (try? await store.metricFreshness(now: stamp)) ?? []
        now = stamp
        isLoading = false
    }

    // MARK: 小部件

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.purple)
            Text("各指标采集节奏（新鲜度）")
                .font(.headline)
            Spacer(minLength: 6)
            Button(copied ? "已复制" : "复制") {
                UIPasteboard.general.string = MetricFreshness.textReport(rows, now: now)
                copied = true
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .disabled(rows.isEmpty)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text("指标").frame(width: 96, alignment: .leading)
            Text("距今").frame(width: 62, alignment: .trailing)
            Text("中位间隔").frame(width: 70, alignment: .trailing)
            Text("近1h").frame(width: 38, alignment: .trailing)
            Text("近24h").frame(width: 44, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("**中位间隔**是相邻两条的典型时间差，窗口取最近 \(PhoneStore.freshnessIntervalWindowHours) 小时（心跳序列取 7 天 —— 系统一天可能只产生几条）。用中位数而不是平均值：一次过夜的长间隔就能把平均值拉到毫无意义。")
            if emptyCount > 0 {
                Text("另有 **\(emptyCount) 个**指标一条数据都没有（不是没显示，是真的没采到）。")
            }
            if populated.contains(where: { $0.intervalTruncated }) {
                Text("**有指标撞到了 \(PhoneStore.freshnessIntervalSampleCap) 条的统计上限** —— 它的中位间隔只代表窗口的开头一段，不代表全部。")
            }
            Text("点右上角「复制」可以把整张表导成文本（贴出来比截图有用得多）。")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

/// 一行。**每一列都单独一个 `Text`**（不拼字符串）—— 见坑 #27：
/// 把插值和修饰符堆在一起会让类型检查超时。
private struct FreshnessRowView: View {

    let row: MetricFreshness
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
                Text(ageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ageColor)
                    .frame(width: 62, alignment: .trailing)
                Text(intervalText)
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
                Text("\(row.countLastHour)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                Text("\(row.countLastDay)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Spacer(minLength: 0)
            }
            Text(spanText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 距今。**没有数据时显示「—」而不是 0**（0 会被当成真实测量值）。
    private var ageText: String {
        guard let age = row.age(now: now) else { return "—" }
        return MetricFreshness.duration(age)
    }

    /// 越久没更新越显眼 —— 但只是**提示**，不是判定（用户可能本来就没戴表）。
    private var ageColor: Color {
        guard let age = row.age(now: now) else { return .tertiary }
        if age < 3600 { return .primary }
        if age < 24 * 3600 { return .orange }
        return .red
    }

    private var intervalText: String {
        guard let value = row.medianInterval else { return "—" }
        return MetricFreshness.duration(value)
    }

    /// 第二行：最小/最大间隔 + 总条数 + 窗口内样本数。
    /// 把最小/最大放出来，是为了让"中位数有没有掩盖极端值"一眼可见。
    private var spanText: String {
        let minText = row.minInterval.map(MetricFreshness.duration) ?? "—"
        let maxText = row.maxInterval.map(MetricFreshness.duration) ?? "—"
        var parts = ["最短 \(minText) / 最长 \(maxText)", "共 \(row.countTotal) 条"]
        if row.intervalTruncated {
            parts.append("⚠️ 统计被截断（窗口内 ≥\(PhoneStore.freshnessIntervalSampleCap) 条）")
        }
        return parts.joined(separator: " · ")
    }
}
