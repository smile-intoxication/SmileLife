import SwiftUI

/// iPhone 端根视图。
///
/// 三个页签的划分是按"用户要回答的问题"来的，不是按数据结构：
/// - **概览**：现在各项指标是多少？（对应手表主界面）
/// - **图表**：某个指标这段时间怎么变化的？（这是做手机端的主要理由）
/// - **状态**：数据链路还活着吗？（对应手表端的诊断界面）
///
/// 第三个页签同样重要：手表端的诊断界面存在的原因是"开发机是 Windows、
/// 看不到设备日志"。手机端也一样 —— 没有这个页签，
/// "手机上一直接收不到数据"就完全无法远程定位。
struct RootView: View {

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("概览", systemImage: "list.bullet.rectangle.portrait") }

            ChartView()
                .tabItem { Label("图表", systemImage: "chart.xyaxis.line") }

            StatusView()
                .tabItem { Label("状态", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }
}
