# 无 Mac 打包部署指南（Windows + GitHub Actions + TestFlight）

> 前提：你已有付费 Apple Developer 账号、Apple Watch S12（watchOS 27）、iPhone，**没有也不打算租 Mac**。
> 结论：**这条链路完全走得通。** 本文是把每一步拆开的操作手册。

---

## 0. 先认清代价：省下的是钱，付出的是迭代速度

| 没有 Mac 的后果 | 具体表现 | 应对 |
|---|---|---|
| ❌ 用不了模拟器 | UI 只能"改代码 → push → CI 构建 → TestFlight → 装表上看"，**一轮 15~40 分钟** | 界面尽量简单；一次多改几处再推 |
| ❌ 用不了 Xcode 调试器 / 断点 | 不能单步 | 代码里多写防御性判断 |
| ❌ 用不了 Console.app 看日志 | 排查困难 | ⭐ **见下面第 7 节：让 app 自己汇报** |
| ⚠️ 用不了 Xcode 的 GUI 建工程 | 工程必须由 CI 用文本描述生成 | 已提供 `project.yml`（XcodeGen） |
| ⚠️ 导出方式字符串改过名 | `ExportOptions.plist` 里 `method` 可能不匹配 | CI 里先跑 `xcodebuild -help` 确认 |

**最重要的一条建议**：**把要验证的东西做成 app 内的界面，而不是靠日志。**
具体见第 7 节——这一条能抵掉上面大半的痛苦。

---

## 1. 你需要准备的东西（都在网页上办，不需要 Mac）

| 项目 | 在哪里拿 |
|---|---|
| **Team ID**（10 位） | [developer.apple.com](https://developer.apple.com/account) → Membership details |
| **App Store Connect API Key**（.p8 文件 + Key ID + Issuer ID） | App Store Connect → Users and Access → Integrations → **App Store Connect API** → Team Keys → 生成。**.p8 只能下载一次** |
| **App Group 标识符** | developer.apple.com → Identifiers → **App Groups** → 注册 `group.com.smile.intoxication.applewatchhealth` |
| **App ID** | developer.apple.com → Identifiers → 注册 `com.smile.intoxication.applewatchhealth`（iOS），并勾选 **HealthKit**、**App Groups** |

> ⚠️ **App Store Connect API Key 的权限**：生成时选择 **App Manager** 或 **Admin** 角色，
> 否则 `xcodebuild -exportArchive` 上传时会报权限不足。

---

## 2. 在 GitHub 里配置 Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret，加四个：

| Secret 名 | 值 |
|---|---|
| `TEAM_ID` | 你的 10 位 Team ID |
| `ASC_KEY_ID` | API Key 的 Key ID（形如 `2X9R4HXF34`） |
| `ASC_ISSUER_ID` | Issuer ID（形如 `69a6de70-...`） |
| `ASC_PRIVATE_KEY` | **`AuthKey_XXXX.p8` 文件的完整内容**（含 `-----BEGIN PRIVATE KEY-----` 那几行） |

> ✅ 公开仓库也可以安全地放这些——GitHub Secrets 是加密的，不会出现在日志里。
> 但要避免在 CI 脚本里 `set -x` 把变量打出来。

---

## 3. 仓库结构

```
.github/workflows/build.yml     CI 流程（已提供）
project.yml                     XcodeGen 工程描述（已提供，改 bundleIdPrefix）
ci/ExportOptions.plist          导出/上传设置（已提供）
watch/                          手表端代码
  WatchApp.entitlements         HealthKit + 后台投递 + App Group
  Widget.entitlements           仅 App Group
  App/ Health/ Storage/ Upload/ Widget/
ios/                            iOS 极简占位 app
  AppleWatchHealthIOSApp.swift
  iOSApp.entitlements
```

### Bundle ID 与 App Group：已统一为 `com.smile.intoxication` ✅

**共 5 处必须完全一致**，改任何一个都要五处一起改（漏一处不会编译报错，
但会导致小组件读不到数据、或签名时提示 entitlement 不匹配）：

| # | 位置 | 当前值 |
|---|---|---|
| 1 | `project.yml` → `bundleIdPrefix` | `com.smile.intoxication` |
| 2 | `project.yml` → iOS 的 `PRODUCT_BUNDLE_IDENTIFIER` | `com.smile.intoxication.applewatchhealth` |
| 3 | `project.yml` → watch app 的 `PRODUCT_BUNDLE_IDENTIFIER` | `com.smile.intoxication.applewatchhealth.watchkitapp` |
| 4 | `project.yml` → widget 的 `PRODUCT_BUNDLE_IDENTIFIER` | `com.smile.intoxication.applewatchhealth.watchkitapp.widget` |
| 5 | `watch/WatchApp.entitlements`、`watch/Widget.entitlements`、`watch/Shared/SharedContainer.swift` 里的 App Group | `group.com.smile.intoxication.applewatchhealth` |

> ⚠️ **去开发者门户注册时，先试 `com.smile.intoxication.applewatchhealth`。**
> App ID 是**全球唯一**的。如果连这个都被占用（可能性不大），告诉我，我一次替换上面 5 处。
> **早试早发现**——等到 CI 打包时才发现会白折腾几轮。

> 💡 如果你想把 `applewatchhealth` 这段后缀也改成 `smilelife`（和仓库名一致），
> 说一声，一次全局替换就行。现在保持原后缀是为了改动最小。

---

## 4. 第一次跑：只做编译检查（零成本）

推到 `main` 分支即可，或手动触发 Actions → Build → Run workflow → mode 选 `compile`。

这一步：
- **不需要任何证书、不需要 Apple 账号介入**（`CODE_SIGNING_ALLOWED=NO`）；
- 会生成 Xcode 工程并编译，把去重后的错误列表写进 **Job Summary**；
- 完整日志作为 `build-log` 产物可供下载。

> 预期：**我这个工程第一次跑一定会报错。** 我把代码从没编译过，加上 XcodeGen 的
> watch app 嵌入方式（`project.yml` 里标了 ⚠️ 的两处）需要真机验证。
> 把 Job Summary 里的错误贴给我，我按真实报错逐个修。

---

## 5. 打包上传 TestFlight

编译通过后，手动触发 Actions → Build → Run workflow → mode 选 **`testflight`**。

CI 会依次做：写 API Key → 生成工程 → `archive`（自动签名）→ 导出 `.ipa`
→ **上传到 App Store Connect** → 同时把 `.ipa` 作为产物供下载。

### 签名是怎么解决的（不需要你手工做证书）

CI 用的是 **Xcode 自动签名 + App Store Connect API Key**：

```
CODE_SIGN_STYLE=Automatic
-allowProvisioningUpdates
-authenticationKeyPath / -authenticationKeyID / -authenticationKeyIssuerID
```

Xcode 会通过 API Key 在你的账号里自动创建/更新证书与描述文件。

> ⚠️ 如果 CI 报 "capability is not enabled" 之类的错：去开发者门户**手动**为
> watch app 的 App ID（`com.smile.intoxication.applewatchhealth.watchkitapp`）勾上 **HealthKit**，
> 然后重跑。自动签名通常能处理，但 HealthKit 这类能力偶尔需要手工开一次。

### 如果要走手工证书路线（备用）

万一自动签名在 CI 上不稳定，可以手工做证书——**这一步在 Windows 上也能完成**：

```powershell
# Windows 上用 OpenSSL 生成私钥和 CSR（不需要 Mac）
openssl req -new -newkey rsa:2048 -nodes `
  -keyout private.key `
  -out CertSigningRequest.certSigningRequest `
  -subj "/emailAddress=你的邮箱,CN=你的名字,C=CN"

# 1) 把 .certSigningRequest 上传到 developer.apple.com → Certificates → 新建发行证书
# 2) 下载得到的 .cer，转成 .p12：
openssl x509 -in distribution.cer -inform DER -out distribution.pem -outform PEM
openssl pkcs12 -export -inkey private.key -in distribution.pem -out distribution.p12

# 3) 把 .p12 和各描述文件 base64 后放进 Secrets，在 CI 里导入到临时钥匙串
```

---

## 6. 装到手表上

1. 上传完成后，App Store Connect → 你的 app → **TestFlight**；
2. 等构建处理完成（通常几分钟到半小时，Apple 会发邮件）；
3. 第一次可能要回答 **出口合规** 问题（"是否使用加密"）。
   > 💡 可以在 iOS 的 Info.plist 里加 `ITSAppUsesNonExemptEncryption = false` 一次性免掉这个问题。
4. **内部测试** → 添加你自己的 Apple ID 为测试员；
5. iPhone 上装 **TestFlight** app → 安装你的 app；
6. **手表 app 会随之安装**（手表需在附近、已配对）。

> ⚠️ 从 TestFlight 装的构建，**设备上要开启开发者模式**才能运行。

---

## 7. ⭐ 关键：没有 Mac 看日志，就让 app 自己汇报

这是整个方案里最重要的一条设计调整。

你看不到 Xcode 控制台，也没有 Console.app，所以**不要把关键结论放在 `print()` 里**——
那等于看不见。正确做法是**把探测结果做成手表上的一个界面**。

具体到我们最需要验证的三件事（见 `watch/README.md` 第五节）：

| 要验证的 | 应该怎么呈现 |
|---|---|
| 5 秒心率到底有没有进 HealthKit | 界面上显示"过去 24 小时心率条数 = N，中位间隔 = X 秒" |
| `heartRateVariabilityRMSSD` 有没有数据 | 显示两个 HRV 类型各自的条数与最新值，和「心率」App 里的数字对照 |
| `HKHeartbeatSeriesSample` 有没有数据 | 显示条数、最早/最晚时间、逐拍间隔的前 20 个值 |

**这个"诊断页"比任何日志都可靠**，而且它是后续数据层的雏形，不算白做。

（备选：Windows 上可以用 `libimobiledevice` 的 `idevicesyslog` 通过 USB 抓 iPhone 的系统日志。
但 watchOS 的日志不一定能中继过来，可靠性远不如上面这个方案。）

---

## 8. 每一次迭代的完整循环

```
Windows 上改代码
   ↓ git push
GitHub Actions（约 5~15 分钟）
   ↓ 上传到 App Store Connect
App Store Connect 处理构建（几分钟到半小时）
   ↓
iPhone 上 TestFlight 更新 → 手表装新版本
   ↓ 在手表上看结果
```

**一轮 15~40 分钟。** 这就是没有 Mac 的真实成本，心里要有数：
**改代码时尽量一次多改几处、多写几个诊断项**，不要一次只改一行。

---

## 9. 常见坑

| 现象 | 原因 / 解法 |
|---|---|
| `xcodebuild: error: SDK "watchos27.0" cannot be located` | runner 镜像里的 Xcode 还没有 watchOS 27 SDK。看 CI 里「打印可用 Xcode」那步的输出，换 `runs-on` 镜像标签 |
| `No signing certificate "iOS Distribution" found` | API Key 角色权限不够（要 App Manager/Admin），或 `-allowProvisioningUpdates` 没起作用 |
| 上传报 `Invalid Signature` / 缺 entitlement | 门户里 App ID 的 HealthKit / App Groups 没开 |
| TestFlight 里看不到构建 | 还没处理完（等邮件）；或 `ExportOptions.plist` 里的 `testFlightInternalTestingOnly` 让你只看到内部测试页 |
| `.ipa` 里没有 Watch 目录 | `project.yml` 里嵌 watch app 的 `copy.subpath` 写错了（标 ⚠️ 的风险点 1） |
