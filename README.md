# Apple Watch 健康数据 App

一个 watchOS 27+ 应用：定期从 HealthKit 读取增量健康数据、存到手表本地、
把最新值缓存给表盘小组件，并预留上传通道。

**只支持 Apple Watch Series 12 / watchOS 27 及以上。**

---

## 📌 当前状态：代码尚未编译验证

开发机是 Windows，没有 Xcode 也没有 Swift 工具链。代码是按 Apple 官方 API 文档
写出来的**可落地骨架**，不是"已验证可运行"的成品。

**编译与部署走 GitHub Actions + TestFlight，不需要 Mac**（用户没有也不打算租 Mac）。

---

## 📚 先读哪份文档

| 你想知道 | 看这里 |
|---|---|
| **怎么打包部署到手表**（无 Mac） | [docs/无Mac打包部署指南.md](docs/无Mac打包部署指南.md) |
| **手表端设计思路**（为什么这么写） | [docs/手表端App-设计方案.md](docs/手表端App-设计方案.md) |
| **HealthKit 能不能拿到某类数据** | [docs/AppleWatch健康数据App-可行性调研.md](docs/AppleWatch健康数据App-可行性调研.md) |
| **怎么在本地/CI 落地这个工程** | [watch/README.md](watch/README.md) |

三份文档的分工：**调研**回答"Apple 到底给不给"（每条结论都带官方链接）；
**设计方案**回答"我们怎么设计、为什么"；**部署指南**回答"怎么把它装到手表上"。

---

## 🗂 目录结构

```
.github/workflows/build.yml   CI：compile（免签名编译检查）/ testflight（打包上传）
project.yml                   XcodeGen 工程描述（Windows 产不出可靠的 .xcodeproj）
ci/ExportOptions.plist        导出与上传设置
docs/                         三份文档
watch/                        手表端全部代码
  App/                        入口、后台调度、主界面
  Health/                     指标注册表、授权、增量同步引擎
  Storage/                    SwiftData 模型、本地库、快照、App Group
  Upload/                     上传预留（协议已定义，暂不发送）
  Widget/                     表盘小组件
ios/                          iOS 极简占位 app（只为承载 watch app 分发）
```

---

## ⚙️ 关键设计约束（都是从 Apple 官方文档核出来的）

| 约束 | 官方原文要点 |
|---|---|
| watchOS 后台刷新**每小时约 4 次**，且**必须有表盘 complication** | "the system performs approximately four tasks per hour for each app **with a complication on the active watch face**" |
| 每次后台**只有几秒** | "The system gives your app only **a few seconds** of background execution time" |
| 设备锁定时**读不到** HealthKit | "the device encrypts the HealthKit store when the user locks the device. As a result, your app **may not be able to read data** from the store when it runs in the background" |
| 手表上的旧数据**会被系统清除** | "old data is **periodically purged from Apple Watch**" |
| S12 **全天每 5 秒**测一次心率 | "Apple Watch Series 12 and Apple Watch Ultra 4 now **measure heart rate every five seconds, all day long**" |

因此本项目采用：**前台同步为主 + 后台机会式补同步**，本地**只保留 7 天**，
小组件**只读 App Group 快照、不查 HealthKit**。

---

## 🎯 设计原则（已与需求方确认）

1. **不追求数据完整性**——有的就收集，没有的就没有。不做历史回填、不做缺口检测、
   不做失败重试到成功。但**磁盘占用仍然要控制**（这是空间问题，不是完整性问题）。
2. **只支持 watchOS 27+ / S12**，不需要任何向后兼容分支。
3. **数据落在手表硬盘上**，不是运行内存。

---

## ⭐ 下一步该做什么

1. 把代码推到 GitHub（**公开仓库**，这样 macOS runner 免费）；
2. 跑 `compile` 模式，看 Job Summary 里的编译错误；
3. 修到编过 → 配 Secrets → 跑 `testflight` 模式 → 装到手表。

**真机第一天必须先测三件事**（Apple 官方无文档、只有真机能回答）：
5 秒心率有没有进 HealthKit、`heartRateVariabilityRMSSD` 有没有数据、
`HKHeartbeatSeriesSample` 有没有数据。

> 💡 因为开发机上没有 Mac、看不到设备日志，**这三项验证要做成手表上的诊断界面**，
> 而不是 `print()`。详见部署指南第 7 节。
