# 手表端 App —— 落地说明

## ⚠️ 先读这一条

**这批代码没有经过编译验证。** 当前开发环境是 Windows，没有 Xcode 也没有 Swift 工具链，
所以代码是按 Apple 官方 API 文档写出来的**可落地骨架**，不是"已验证可运行"的成品。
第一次在 Xcode / CI 里编译时，预计需要处理少量编译错误（主要是并发标注和 API 签名细节）。

**已确定的编译部署方式是「Windows + GitHub Actions + TestFlight」，不需要 Mac。**
CI 文件已就位：

| 文件 | 作用 |
|---|---|
| `.github/workflows/build.yml` | CI 流程：`compile` 编译检查 / `testflight` 打包上传 |
| `project.yml` | XcodeGen 工程描述（因为 Windows 产不出可靠的 `.xcodeproj`） |
| `ci/ExportOptions.plist` | 导出与上传设置 |
| `docs/无Mac打包部署指南.md` | **操作手册：从注册 App ID 到装上手表的每一步** |

---

## 零、在 Windows 上怎么编译这个项目

### 硬事实：watchOS 模拟器**只能**跑在 macOS 上

没有任何变通办法，原因有两层：

1. watchOS SDK 和模拟器运行时**只随 Xcode 分发**，苹果不单独发布；
2. HealthKit / SwiftData / SwiftUI / WidgetKit **在 Apple 平台之外不存在**——
   所以连"用 Windows 版 Swift 工具链先做类型检查"这条退路也没有
   （Windows 版 Swift 只能编译纯逻辑代码，本项目几乎没有这种代码）。

### 三条可行路径

| 方案 | 成本 | 能否用模拟器 | 适合阶段 |
|---|---|---|---|
| **① 按需/包月租云 Mac** | 按需几美元起，包月约 $25+ | ✅ 完整 Xcode + 模拟器 | **建议先走这条** |
| **② GitHub Actions macOS runner** | **公开仓库免费** | ❌ 只能编译+跑测试，不能交互调试 | 后期自动化回归 |
| **③ 买二手 Mac mini（M1/M2）** | 一次性，长期最划算 | ✅ | 打算长期做的话 |

- **①**：[MacinCloud](https://www.macincloud.com/pages/xcode.html) 官方页面明确支持
  "develop iOS, macOS, **watchOS**, and tvOS apps"、Xcode 模拟器，
  以及"submit their ... **watchOS** applications to the App Store"。
  分 Managed（按需，免管理）和 Dedicated（有管理员权限）两种。
  同类还有 MacStadium、Scaleway、AWS EC2 Mac（注意 EC2 Mac 有 24 小时最短计费）。
- **②**：GitHub 官方计费文档原文——"GitHub Actions usage is **free** for ...
  **public repositories** that use standard GitHub-hosted runners"。
  也就是**公开仓库用 macOS runner 是免费的**。
  但 CI 只能告诉你"编译过了/测试过了"，每次迭代要 10~30 分钟，**不适合早期交互调试**。
- **③**：如果确定要长期做，一次性买台二手 Mac mini 比拼月租便宜得多。

**不推荐**：Hackintosh / 在 Windows 里跑 macOS 虚拟机。除了许可问题，
watchOS 模拟器对图形和虚拟化支持很敏感，折腾成本远高于租一台云 Mac。

### 国内的情况（已核实）

**结论：国内主流公有云都不提供 macOS 实例。**

| 服务商 | 情况 | 依据 |
|---|---|---|
| **阿里云 ECS** | ❌ 不支持 macOS。官方社区回答原文："由于MAC系统是不属于非标准平台Linux镜像。目前这边**暂不支持导入MAC系统镜像**进行使用。" | [阿里云开发者社区](https://developer.aliyun.com/ask/643126) |
| **腾讯云 CODING** | ❌ 默认构建节点**不含 macOS**。官方文档原文：当官方节点无法满足时，"例如**需要使用 macOS Xcode 构建 iOS 应用时**，就可以通过接入**自定义类型节点**（物理机/虚拟机/容器等）"——也就是**要自备 Mac** | [腾讯云 CODING 构建节点类型](https://cloud.tencent.com/document/product/1726/97066) |
| **腾讯云 CODING 自定义节点** | ⚠️ 文档目录里有《[自定义节点停止接入公告](https://help-assets.codehub.cn/docs/ci/node/customize-offline.html)》，**这条路正在关闭**（公告正文本次未能读取，标注为未核实） | 同上 |

**国内实际可用的两类：**

1. **专门的"云 Mac 租赁"服务商**（本质是托管 Mac mini），国内外都有，有中文界面的如
   [macly.io](https://macly.io/zh)、vpsmac.com、sftpmac.com 等。
   > ⚠️ 这类属于**小众厂商，本次没有逐一验证**。选购前务必确认这几点：
   > 能否装 Xcode（磁盘够不够，几十 GB）、**能否用你自己的 Apple ID 做签名**、
   > 是否给管理员权限、VNC / Apple Remote Desktop 是否可用、网络延迟、数据安全与退款条款。
2. **海外大厂**：[AWS EC2 Mac](https://docs.aws.amazon.com/zh_cn/AWSEC2/latest/UserGuide/ec2-mac-instances.html)
   官方文档明确写着"非常适合为 Apple 平台（例如 iPhone、iPad、Mac、Vision Pro、
   **Apple Watch**、Apple TV 和 Safari）开发、构建、测试和签署应用程序"，
   可用 SSH 或 **Apple Remote Desktop** 连图形界面。
   ⚠️ 但注意：**计费单位是专属主机，最短分配期 24 小时**——"只想试一次"也得付一整天的钱；
   启动还要等 6~20 分钟。同类还有 MacStadium、MacinCloud。

### 💡 给国内用户的建议路径

**第一步不需要任何 Mac**：把代码推到**公开仓库**，用 **GitHub Actions 的 macOS runner
（对公开仓库免费）** 先把编译错误清掉。因为本文档开头就说了这批代码**未经编译验证**，
肯定有一批错误要修——用免费 CI 迭代这些错误，比租一台按小时的 Mac 划算得多。
（国内访问 GitHub 可能不稳，但 Actions 本身跑在云端，你只要能 push 就行。）

**第二步**，需要真正看模拟器 / 调 UI 时，再租云 Mac（国内小厂商延迟低但需甄别，
或按需租 MacinCloud / EC2 Mac），或者直接买二手 Mac mini M1。

**第三步**，真机部署走 TestFlight（需要 $99/年开发者账号）。

（另外提一句：Gitee Go / CODING 这类国内 CI，**据本次核实其默认节点不含 macOS**；
是否有其他国内 CI 提供 macOS 构建节点，建议下单前自行确认官方文档。）

### ⚠️ 但先想清楚：模拟器其实帮不了你多少

这点很关键，能帮你省下大量在模拟器上死磕的时间：

| 想在模拟器上验证 | 可行吗 |
|---|---|
| 界面布局、授权流程、数据流逻辑 | ✅ 可行（HealthKit 数据要**手动塞**：模拟器 Health app 里 Browse → Add Data） |
| 增量同步、本地库、保留策略 | ✅ 可行（自己写几条假数据就能测） |
| 小组件渲染 | ✅ 可行（但 App Group 要配对） |
| **HealthKit 后台投递** | ❌ **官方明确不支持**："Background server queries aren't supported on the Simulator" |
| **S12 的真实心率密度（5 秒？）** | ❌ 模拟器没有传感器 |
| **`heartRateVariabilityRMSSD` 有没有数据** | ❌ 同上 |
| **`HKHeartbeatSeriesSample` 有没有数据** | ❌ 同上 |

**结论：模拟器的定位是"把 UI 和逻辑跑通"，不是"验证数据可得性"。**
我们最关心的三个问题（见第五节）**只有真机能回答**。

### 真机部署的现实：**构建必须有 macOS，但你可以一台都不拥有**

先把"哪些步骤真的需要 macOS"拆开看：

| 步骤 | 需要 macOS？ | 能否从 Windows 操作 |
|---|---|---|
| 写代码 | ❌ | ✅ |
| 生成 Xcode 工程 | ⚠️ 要 Xcode 才可靠 | ✅ 用 `project.yml`（XcodeGen）描述，在 CI 上生成 |
| **编译**（`xcodebuild`） | ✅ **必须** | ❌ → 交给 CI 的 macOS runner |
| 创建签名证书 / 描述文件 | ❌ | ✅ Windows 上用 **OpenSSL** 生成 CSR → 上传开发者门户 → 下载 .p12 / .mobileprovision |
| **上传 App Store Connect** | ✅（`altool`/`notarytool` 只有 macOS 版） | ❌ → 交给 CI |
| 创建 App 记录、填元数据、提交审核 | ❌ | ✅ App Store Connect 网页 |
| **装到 iPhone / Watch** | ❌ | ✅ iPhone 上的 TestFlight app |

**结论：只有"编译"和"上传"两件事必须发生在 macOS 上，而这两件都可以在 CI 上完成，
你自己不需要买 Mac。**（需要 macOS 的那部分计算，由 GitHub Actions / Codemagic 之类的
macOS runner 提供。）

#### 三条路线的可行性

| 方式 | 可行性 |
|---|---|
| **TestFlight**（推荐） | ✅ 需要付费 Apple Developer 账号（$99/年）。CI 或云 Mac 上 archive → 上传 App Store Connect → iPhone 上装 TestFlight → 手表自动装 |
| 免费账号 7 天 provisioning | ❌ 需要在 Xcode 里连着**物理设备**操作，远程云 Mac 做不到 |
| 侧载工具（AltStore / Sideloadly） | ❌ 那些工具是围绕 iOS app 做的；watchOS app 正常通过 App Store / TestFlight 装到表上 |

#### CI 能不能直接吐出可安装的 .ipa？

**能。** Apple 官方文档
[Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
明确写：

> "For iOS, iPadOS, tvOS, visionOS, or **watchOS** apps, the folder contains the
> **iOS Package Archive file (with an `.ipa` extension)**."

CI 上的流程就是两行命令 + 一个上传：

```bash
xcodebuild archive \
  -project App.xcodeproj -scheme "App" \
  -archivePath build/App.xcarchive

xcodebuild -exportArchive \
  -archivePath build/App.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist   # 里面指定分发方式

# 然后把 build/export/*.ipa 用 actions/upload-artifact 传上去，
# 在 Actions 运行页面直接下载 —— 下载不需要 Mac。
```

**但有两个硬前提：**

| 前提 | 说明 |
|---|---|
| **必须签名** | 需要一个**付费** Apple Developer 账号（$99/年）：证书 + 描述文件，或在 CI 上用 App Store Connect API Key + `-allowProvisioningUpdates` 自动签名。**没有付费账号只能产出未签名的构建，装不上设备** |
| **设备必须注册** | Ad Hoc / Development 方式要求把设备 UDID 登记到开发者账号里（官方：每个产品类别**每年设备数有上限**，通常 100 台） |

#### 不需要 Mac 就能把 app 装到设备上的两条路

| 方式 | 怎么做 | 限制 |
|---|---|---|
| **OTA 安装** | 导出 Ad Hoc / Development 时勾选官方提供的 **"Include manifest for over-the-air installation"**，会得到 `.ipa` + `manifest.plist`；把两者放到任意 HTTPS 站点（GitHub Pages 都行），在 iPhone 上打开链接即可安装 | 设备 UDID 必须已注册；**设备要开启开发者模式** |
| **TestFlight**（更省心） | CI 上传 App Store Connect → iPhone 装 TestFlight → 手表自动装 | 要走 Apple 的构建处理流程 |

> ⚠️ 官方提醒：从 `.ipa` 安装的 app，**必须在设备上开启开发者模式**
> （"To run your iOS, iPadOS, visionOS, or watchOS app that you install from an
> iOS Package Archive, **enable Developer Mode** on that device."）。
> 这是设备上的设置，不需要 Mac。

> ⚠️ 关于测试机提醒：**开发者模式 + 注册设备**这套是自测用的。
> 如果将来要给外部测试者用，走 TestFlight 更合适。

#### 导出方式的选项（官方列的）

推荐设置四种：TestFlight & App Store、TestFlight Internal Only、Release Testing、Debugging；
自定义六种：App Store Connect、Ad Hoc、Enterprise、Developer ID、Development、Copy App。

对应到 `-exportOptionsPlist` 里的 `method` 字符串，Xcode 版本之间改过名
（Xcode 15 起 UI 显示的是 Debugging / Release Testing / App Store Connect）。
**在 CI 里可以先跑 `xcodebuild -help` 把当前 Xcode 支持的 `method` 取值打印出来**，
避免写错字符串。

#### 分阶段推进：每阶段只解决一件事

| 阶段 | 目标 | CI 产出什么 | 需要什么 | 成本 |
|---|---|---|---|---|
| **① 清编译错误** | 代码能编过 | 只编译，**不产出 .ipa** | 公开仓库 + GitHub Actions macOS runner，用 `CODE_SIGNING_ALLOWED=NO` | **¥0，且不需要 Apple 账号、不需要证书** |
| **② 调 UI / 看模拟器** | 界面逻辑跑通 | —（模拟器只能在本地 Mac 跑） | 租一台云 Mac | 按需几美元起 |
| **③ 上真机** | 装到手表 | **Ad Hoc `.ipa`（artifact 下载）** + **`app-store-connect` 上传 TestFlight**，两条互为备份 | $99/年账号 + 证书 + 设备注册 | $99/年 |

> 💡 **阶段① 是关键技巧**：`CODE_SIGNING_ALLOWED=NO` 会跳过整个签名环节，
> 但**依然会完整编译所有 Swift 代码**。也就是说你可以在**没有任何证书、
> 没有付费账号、甚至没有 Apple ID** 的情况下，先把所有编译错误暴露出来。
> 这是整个流程里投入产出比最高的一步。

### ⚠️ 一条重要修正：不要选 "Watch-only App"

Apple 官方文档
[Setting up a watchOS project](https://developer.apple.com/documentation/watchos-apps/setting-up-a-watchos-project)
明确说这是**先要决定的事**：

> "Before you start a new watchOS project, you need to decide **how you're going to
> distribute** that project: as a watch-only app or as a watchOS app with an iOS app."

而 Apple 开发者论坛里有一个标题就是
**"[Standalone WatchOS App to TestFlight impossible](https://developer.apple.com/forums/thread/760388)"**
的帖子——说明**纯 watch-only app 走 TestFlight 很可能会卡住**。
（⚠️ 该帖正文本次**未能读取**：Apple 论坛有机器人验证，抓取被拦截。
所以这是"有迹象"而不是"已证实"，但风险足够大，不值得赌。）

**因此本项目改用 "Watch App with New Companion iOS App" 结构**，理由三条：

1. ✅ TestFlight 走的是最标准、最有保障的路径（watch app 随 iOS app 一起分发）；
2. ✅ 你后面本来就要做 iPhone 端（数据存储 / 上传），现在建好正好；
3. ✅ iPhone 端可以做得极简——一个"请在 Apple Watch 上使用"的页面就够，
   不影响手表端的独立运行（勾上 `Supports Running Without iOS App Installation` 即可）。

代价几乎没有，但避开了"做完发现装不上表"的风险。

---

## 一、文件清单

```
watch/
├─ App/
│   ├─ AppleWatchHealthApp.swift   @main + AppDelegate（后台任务入口）
│   ├─ WatchServices.swift         依赖装配（ModelContainer / Store / 引擎）
│   ├─ BackgroundCoordinator.swift 后台刷新排程与处理
│   └─ ContentView.swift           主界面（读快照渲染）
├─ Health/
│   ├─ MetricCatalog.swift         ★指标注册表（加指标只改这里）
│   ├─ HealthAuthorizer.swift      授权（只读，不请求写权限）
│   └─ HealthSyncEngine.swift      ★增量同步引擎（功能 1）
├─ Storage/
│   ├─ Models.swift                SwiftData 模型（样本 / anchor / 待上传队列）
│   ├─ HealthStore.swift           本地库唯一入口（@ModelActor）
│   ├─ SnapshotService.swift       ★快照生成（功能 2）
│   └─ SharedContainer.swift       App Group 读写 + 快照数据结构
├─ Upload/
│   └─ UploadTransport.swift       ★上传预留（功能 3，本版只入队不发送）
└─ Widget/
    └─ LatestValueWidget.swift     表盘小组件（读快照）
```

## 二、Xcode 配置（这几步漏一个就跑不起来）

> ⚠️ **先纠正一个常见误解**：现在的 Xcode 建 watchOS 工程**没有独立的
> "WatchKit Extension" target 了**——watchOS 9 / Xcode 14 起，扩展已经合并进
> "Watch App" 这一个 target。所以下面所有 capability 和 Info.plist 都加在
> **Watch App target** 上。（网上很多老教程还在讲 Extension target，别被带偏。）

### 1. 建工程：选 **Watch App with New Companion iOS App**

> ⚠️ **不要选 "Watch-only App"** —— 纯 watch-only app 走 TestFlight 很可能卡住，
> 详见第零节末尾的说明。选带配套 iOS app 的结构，代价极小但避开了这个风险。

Xcode → File → New → Project → **watchOS → App**，语言 Swift，界面 SwiftUI，
然后选 **Watch App with New Companion iOS App**。

关于这个模板（出自 Apple 官方文档
[Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)）：

- iOS 端可以做得**极简**——一个页面写"请在 Apple Watch 上使用"就够了；
- 在 **Watch App target → General → Deployment Info** 里勾上
  **"Supports Running Without iOS App Installation"**，
  这样手表端可以独立运行，不必等 iPhone 那边装好；
- 注意官方提醒：独立 watchOS app **不能把 WatchConnectivity 当作主要数据来源**——
  "If you need to sync data between devices, consider using **CloudKit**, or
  syncing through **your own server**." 这正好呼应我们「手表可直传服务器」的方案（调研 §5.8）。

> 本仓库里的 `watch/` 代码目前只覆盖手表端；`watch/App/ContentView.swift` 就是手表主界面。
> iOS 端第一步只需要一个占位页面。

### 2. 加 Widget Extension
File → New → Target → **watchOS → Widget Extension**。
把 `watch/Widget/LatestValueWidget.swift` 放进去
（注意：Widget 里**不要**再加 `@main` 的 `App`，只保留那个 `WidgetBundle`）。

### 3. HealthKit capability（加在 **Watch App** target 上）

勾选：**HealthKit** + **Background Delivery**。

- `Background Delivery` 对应 entitlement
  `com.apple.developer.healthkit.background-delivery`，watchOS 8+ 起必需，
  否则 `enableBackgroundDelivery` 会以 `errorAuthorizationDenied` 失败。
- 本项目实际走的是"被后台刷新唤醒后跑 anchored query"，
  但这个 entitlement 建议一并勾上，将来要用 observer 时不用回来补。

### 4. Info.plist（加在 **Watch App** target 的 Info.plist）

```xml
<key>NSHealthShareUsageDescription</key>
<string>用于读取你的心率、HRV、血氧、睡眠等健康数据并显示在手表和表盘上。</string>
<key>NSHealthUpdateUsageDescription</key>
<string>本 App 不会向健康 App 写入数据。</string>
```

- 两个键都配上。官方文档明确：请求授权时**缺键会直接崩溃**。
- watchOS 6+ 授权弹窗出现在手表上（独立 app 的授权表单直接在 Apple Watch 上显示），
  所以键要配在手表 app 自己的 Info.plist 里。

### 5. App Group（**两个** target 都要配）
必须让 **Watch App** 和 **Widget Extension** 共享同一个 App Group：

```
group.com.smile.intoxication.applewatchhealth
```

ID 要和 `SharedContainer.appGroupID` **完全一致**，改的话两边都要改。

### 6. 测试
**后台链路必须用真机。** 官方明确：
- HealthKit **后台投递在模拟器上不支持**（"Background server queries aren't
  supported on the Simulator"）；
- `transferUserInfo`（将来做上传时会用到）**在模拟器上不支持**。

真机上还要确认一件事：**把本 app 的小组件放到当前表盘上**，否则后台刷新预算是 0。

## 三、系统要求与 v1 覆盖的指标

**只支持 watchOS 27.0+ / Apple Watch Series 12**（用户已确认）。这带来两个简化：

- 不需要任何 `#available` 兼容分支；
- 小组件可以用 `AppIntentConfiguration`（watchOS 26+ 才支持用户配置），
  于是**一个可配置小组件**就够了，不用堆一堆固定 widget。

`MetricCatalog.all` 里默认开启 9 个，全部是 **Apple Watch 独有产生**的：

| id | 指标 | 单位 | 备注 |
|---|---|---|---|
| `heart_rate` | 心率 | bpm | ⚠️ S12 全天每 5 秒测量 → **分层存储** |
| `resting_heart_rate` | 静息心率 | bpm | |
| `walking_heart_rate_average` | 步行心率 | bpm | |
| `hrv_sdnn` | HRV (SDNN) | ms | |
| `hrv_rmssd` | HRV (RMSSD) | ms | 🆕 watchOS 27 才有 |
| `respiratory_rate` | 呼吸频率 | 次/分 | |
| `oxygen_saturation` | 血氧 | % | |
| `sleeping_wrist_temperature` | 睡眠腕温 | °C | |
| `sleep_analysis` | 睡眠 | 枚举 | |

另外预留 3 个默认关闭的：`active_energy`、`exercise_time`、`vo2_max`。

**加指标只需要在 `MetricCatalog.all` 里加一条**，同步、缓存、快照、小组件配置界面全链路自动生效。

### 存储策略：本地只保留最近 7 天（已确认）

**数据落在手表硬盘上，不是运行内存。** SwiftData 用的是文件型库
（`ModelConfiguration(..., isStoredInMemoryOnly: false)`），存在 app 沙盒的
Application Support 目录；app 重启、被系统杀掉、手表重启都不会丢。
启动时会在 Console 打印实际落盘路径，真机上可以直接核对：

```
[Store] SwiftData 落盘位置：/private/var/mobile/Containers/Data/.../HealthStore.sqlite
```

**保留窗口 `StoragePolicy.retentionDays = 7`**，所有指标统一，超期即删。

#### 为什么 7 天是安全的（算给你看）

S12 全天每 5 秒测一次心率，**最坏情况**：

```
17,280 条/天 × 7 天 ≈ 12.1 万行
```

SwiftData 落盘大约几十 MB，Apple Watch 完全放得下。而且 **增量同步只拉新增样本**，
本地行数多**不会**让同步变慢——所以"行数多"本身不是问题。

为了撑住这个量级，`SampleRecord` 上加了索引（`#Index`，watchOS 11+ 可用）：

```swift
#Index<SampleRecord>([\.metricID, \.startDate], [\.startDate])
```

分别服务于"取某指标最新一条"和"按日期删过期数据"这两个高频操作。

> ⚠️ 但请注意：Apple **只说了手表"测量"的节奏，没说多少条会真正写进 HealthKit**
> （可能 5 秒数据只服务于手表自己的 readiness 算法，HealthKit 仍是 5 分钟一条）。
> 这个必须真机实测，见第五节。**不过实测结果不影响本策略**：
> 无论是 12.1 万行还是 2,000 行，7 天保留都成立。

#### 已删除的"小时聚合层"

之前设计过"原始 24 小时 + 小时聚合 365 天"的分层，是为了**长期保留同时压缩体积**。
现在既然只留 7 天、不留长期，聚合就只剩额外复杂度（水位线、聚合顺序约束、
快照兜底），**收益为零**，所以整个拿掉了。

### 关于开关

设置项用 `UserDefaults`，键名固定为 `metric.enabled.<指标id>`：

```swift
UserDefaults.standard.set(false, forKey: "metric.enabled.heart_rate")
```

没有设置过就按 `MetricDescriptor.enabledByDefault`。v1 还没有设置界面，
但同步引擎已经按这个约定过滤了，加 UI 时直接写这个键即可。

### 写新指标时要注意（都有官方依据，见调研文档 §2）

- 不要加"步态/走路"那一类（`walkingSpeed`、`walkingAsymmetryPercentage` 等）——
  **那些是 iPhone 产生的，不是手表产生的**；
- 别指望 `uvExposure`、`bloodGlucose`、`bloodPressure`——**Apple Watch 没有这些传感器**；
- 常量名要查官方文档 `.md` 端点核对，网上流传的 `appleWalkingAsymmetryPercentage` 之类的名字是错的；
- 高频指标（秒级）把 `initialLookbackDays` 调小（参考心率的 1 天），
  否则首次同步会一次拉太多。保留窗口统一由 `StoragePolicy.retentionDays` 控制，不用逐指标配。

## 四、编译时可能需要修的地方

按可能性排序：

1. **Swift 并发标注**：工程如果开了 Swift 6 语言模式，
   `WatchServices.shared`、`MetricCatalog.all` 这类全局状态会报 Sendable 错误。
   建议先在 Build Settings 里把 **Swift Language Version 设成 Swift 5**，
   跑起来之后再逐步迁移。
2. **`@ModelActor`**：`HealthStore` 用了 `@ModelActor`，它生成的
   `init(modelContainer:)` 是 nonisolated 的，正常可用；
   若报错，改成手写 `ModelActor` 或退化成普通 class + 串行队列。
3. **`withCheckedThrowingContinuation` + HealthKit 回调**：`HKAnchoredObjectQuery`
   的一次性 resultsHandler 只会回调一次，所以 continuation 不会被重复 resume；
   但如果你之后改用了带 `updateHandler` 的版本，**必须**改掉这个包装，
   否则会 "continuation resumed twice" 崩溃。
4. **`Gauge` 在 accessoryCircular 里的用法**：只是为了让圆环有视觉，
   数值本身没接。想做成真圆环需要给指标加"取值范围"元数据。

## 五、真机第一天必须先做的测量 ⭐

**这是整个项目优先级最高的一件事**，因为 Apple 官方没有文档，
而它直接决定架构是"够用"还是"要重做"。

戴上 S12 满一天后，用一个临时页面（或直接改 `ContentView` 加个调试入口）测三件事：

1. **5 秒心率到底有没有进 HealthKit？**
   用 `HKQuantitySeriesSampleQuery` 拉一个 24 小时窗口的 `heartRate`，
   统计 **落在窗口内的 quantity 条数**，以及**相邻两条的中位间隔**（区分运动中/非运动中）。
   - 如果中位间隔 ≈ 5 秒 → 17,280 条/天，**分层存储是必须的**（已经做好了）；
   - 如果 ≈ 5 分钟 → 只有 288 条/天，7 天也就 2,000 行，**当前实现绰绰有余**，什么都不用改。
   > 注意：`HKQuantitySample.count > 1` 表示它其实是个 series，要用
   > `HKQuantitySeriesSampleQuery` 拆开数，不能只数样本对象个数。

2. **`heartRateVariabilityRMSSD` 到底有没有数据？**
   Apple 说 S12 提供「Recovery HRV」和「overall HRV」两个变体，
   但**没说**它们是否分别对应 RMSSD 和 SDNN。所以两个类型都读出来，
   和「心率」App 里显示的数字对一下，看哪个对哪个。

3. **`HKHeartbeatSeriesSample`（RR 间期的唯一自动来源）在你手表上到底有没有？**
   用 `HKHeartbeatSeriesQuery` 逐拍打印时间戳。⚠️ **这一条已经问出来了**（2026-10-07 真机）：
   房颤历史开启后**确实有**，**约 4 分钟一条、每条约 50 拍、约 1 分钟长**。
   官方文档里也有一句正面回答（在 `HKMetadataKeyAlgorithmVersion` 的 Note 里：
   "the system uses this key for … HKHeartbeatSeriesSample samples **generated by Apple Watch**"），
   所以本文早先写的"官方从头到尾没说明"**已过时** —— 但**频率与触发条件官方仍然没写**，
   那部分只能实测。

这三条的实测结果，比任何文档都可靠。

## 六、明确没做 / 待确认的部分

> 📌 前置原则（已确认）：**不追求数据完整性**——有的就收集，没有的就没有。
> 所以下面很多"未做"是**刻意的设计决定，不是欠账**。

| 项 | 状态 |
|---|---|
| 上传数据（功能 3） | **只入队不发送**。`UploadTransport` 协议已定义，`NoopUploadTransport` 是占位实现。等确认走手机还是走服务器 |
| 历史回填 | ❌ **决定不做**（原则如此）。首次同步只看 1~3 天（`initialLookbackDays`），拿不到的历史就算了 |
| 缺口检测 / 补数 / 失败重试到成功 | ❌ **决定不做**。单次失败只记日志，下次跑到什么算什么 |
| `HKStatisticsCollectionQuery` | ❌ 暂不需要。它是为了"高效回看很久的历史"，而我们已经不追求历史完整 |
| 设置界面 | 未做（约定已定，见第三节）。用户关掉某指标只是让同步跳过它 |
| 睡眠聚合 | 未做。现在显示的是"最后一个睡眠阶段"，不是"昨晚睡了多久"——见 `SnapshotService.format` 的注释 |
| heartbeat series / RR 间期 | ✅ **已接入**（v1.9 起）。手表只搬原始时间戳 + **洞标记**；RR 在手机上算 |
| 趋势图 UI | 未做。本地有 7 天明细，画趋势需要时直接从 `SampleRecord` 取；**不做预聚合**（见第三节） |
| 未授权指标的提示 | 保持简单：没数据的指标**直接不出现在列表里**，不做"去设置里开启"的引导流程 |
