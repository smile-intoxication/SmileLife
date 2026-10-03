import SwiftUI

/// iOS 配套 App —— **极简占位**。
///
/// 它的存在不是为了功能，而是为了**分发**：
/// watch app 需要一个 iOS app 作为载体才能走 TestFlight / App Store。
/// 手表端本身是独立的（Watch App target 里勾了
/// `WKRunsIndependentlyOfCompanionApp`），不依赖这个 app 运行。
///
/// 将来 iPhone 端要做"数据存储 / 上传服务器"时，从这里开始写。
@main
struct AppleWatchHealthIOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSPlaceholderView()
        }
    }
}

struct IOSPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "applewatch")
                .font(.system(size: 56))
                .foregroundStyle(.pink)

            Text("请在 Apple Watch 上使用")
                .font(.title3.weight(.semibold))

            Text("数据采集和展示都在手表端完成。\niPhone 端后续会用于数据汇总与同步。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
