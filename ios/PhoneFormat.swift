import Foundation

/// iPhone 端的展示格式化。
///
/// 集中在一处的原因和 `MetricDisplay.formatted` 一样：
/// 同一个数字在概览、图表、状态三处显示成不同的样子（62 / 62.0 / 62 bpm）
/// 会让人怀疑数据本身有问题。
enum PhoneFormat {

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func dateTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return timeFormatter.string(from: date) }
        return dateTimeFormatter.string(from: date)
    }

    /// 相对时间。"无" 而不是空字符串 —— 空字符串在界面上看起来像加载失败。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "无" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 0 { return "刚刚" }
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return day(date) + " " + time(date)
    }

    /// 按指标语义格式化数值。
    ///
    /// 枚举型走 `MetricDisplay.categoryLabel`（睡眠阶段的中文名），
    /// 数值型走 `MetricDisplay.formatted`（统一小数位）。
    static func value(metricID: String, value: Double?, categoryValue: Int?) -> String {
        if let categoryValue {
            return MetricDisplay.categoryLabel(metricID: metricID, raw: categoryValue)
        }
        guard let value else { return "—" }
        return MetricDisplay.formatted(metricID: metricID, value: value)
    }

    static func hours(_ value: Double) -> String {
        let totalMinutes = Int((value * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(m) 分钟" }
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(value)
        var index = 0
        while size >= 1024 && index < units.count - 1 {
            size /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(size)) B" : String(format: "%.1f %@", size, units[index])
    }

    static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
