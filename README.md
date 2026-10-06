# Apple Watch 健康数据 App

一个 watchOS 27+ 应用：定期从 HealthKit 读取增量健康数据、存到手表本地、
把最新值缓存给表盘小组件，并把数据经 WatchConnectivity 传到 iPhone，
在手机上长期保存并画成图表。

**只支持 Apple Watch Series 12 / watchOS 27 及以上。**

---

## 📌 当前状态

编译与部署走 GitHub Actions + TestFlight（开发机是 Windows，没有 Xcode，
也**永远不会有** Mac）。**已打通到 TestFlight**，最近一轮 tag 是 `v1.6`。

进度、踩过的坑、待办都在 `AGENTS.md` —— 那份文件是**活的**，
本 README 只描述项目是什么、怎么读。

> ⚠️ `AGENTS.md` 位于**本仓库之外**（会话工作区根目录，即仓库的上一级），
> 所以它不随仓库分发，也不能用相对链接点开。

---

## 📚 先读哪份文档

| 你想知道 | 看这里 |
|---|---|
| **怎么打包部署到手表**（无 Mac） | [docs/无Mac打包部署指南.md](docs/无Mac打包部署指南.md) |
| **手表端设计思路**（为什么这么写） | [docs/手表端App-设计方案.md](docs/手表端App-设计方案.md) |
| **手机端怎么收数据、怎么画图** | [docs/手机端图表与数据传输.md](docs/手机端图表与数据传输.md) |
| **HealthKit 能不能拿到某类数据** | [docs/AppleWatch健康数据App-可行性调研.md](docs/AppleWatch健康数据App-可行性调研.md) |
| **中国区上架/收费要过哪些合规关** | [docs/中国区上架合规清单.md](docs/中国区上架合规清单.md) |
| **怎么在本地/CI 落地这个工程** | [watch/README.md](watch/README.md) |

分工：**调研**回答"Apple 到底给不给"（每条结论都带官方链接）；
**设计方案**回答"手表端怎么设计、为什么"；**手机端文档**回答"数据怎么过去、
为什么用 transferUserInfo、图表怎么取数"；**部署指南**回答"怎么装到手表上"；
**合规清单**回答"上架中国区、收费还差什么"。

---

## 🗂 目录结构

```
.github/workflows/build.yml   CI：compile（免签名编译检查）/ testflight（打包上传）
project.yml                   XcodeGen 工程描述（Windows 产不出可靠的 .xcodeproj）
ci/                           自检脚本（verify-project.sh）、发布脚本（ship.sh）、导出设置
shared/                       ★ 跨设备共享层（手表 ↔ iPhone），**只依赖 Foundation**
  MetricDisplay.swift         指标展示元数据的唯一定义处（id → 标题/单位/SF Symbol/小数位）
  WatchWire.swift             线协议（UploadPayload / SampleBatch）与分批限额
docs/                         五份文档（调研 / 手表设计 / 手机端 / 部署 / 合规）
watch/                        手表端全部代码（采集器 + 7 天缓冲）
  App/                        入口、后台调度、主界面、诊断界面
  Health/                     指标注册表、授权、增量同步引擎、探针
  Storage/                    SwiftData 模型、本地库、App Group 快照
  Upload/                     投递到 iPhone：WatchLinkSession / OutboxFlusher / DeletionQueue
  Shared/                     ★ 手表 app ↔ 小组件共享（App Group），也**只依赖 Foundation**
  Widget/                     表盘小组件（独立 target）
ios/                          iPhone 端（长期档案 + 图表）
  PhoneModels.swift           PhoneSample（180 天）/ PhoneRollup（15 分钟桶，不删）
  PhoneStore.swift            幂等落库、按受影响范围重算汇总桶、保留策略
  WatchLink.swift             WCSession 接收 + 会话状态
  OverviewView / ChartView / StatusView      概览 / 图表 / 状态 三个页签
```

> ⚠️ `shared/` 和 `watch/Shared/` 是**两个不同的东西**，别混：
> 前者是**手表 ↔ iPhone** 之间共享，后者是**手表 app ↔ 表盘小组件**之间共享。
> 两者都只能依赖 Foundation（自检脚本第 11 节守着），但原因不同：
> iOS app 刻意不申请健康权限，小组件不该碰 HealthKit。


---

## ⚙️ 关键设计约束（都是从 Apple 官方文档核出来的）

| 约束 | 官方原文要点 |
|---|---|
| watchOS 后台刷新**每小时约 4 次**，且**必须有表盘 complication** | "the system performs approximately four tasks per hour for each app **with a complication on the active watch face**" |
| 每次后台**只有几秒** | "The system gives your app only **a few seconds** of background execution time" |
| 设备锁定时**读不到** HealthKit | "the device encrypts the HealthKit store when the user locks the device. As a result, your app **may not be able to read data** from the store when it runs in the background" |
| 手表上的旧数据**会被系统清除** | "old data is **periodically purged from Apple Watch**" |
| S12 **全天每 5 秒**测一次心率 | "Apple Watch Series 12 and Apple Watch Ultra 4 now **measure heart rate every five seconds, all day long**" |

因此本项目采用：**前台同步为主 + 后台机会式补同步**，手表本地**只保留 7 天**，
小组件**只读 App Group 快照、不查 HealthKit**，
**长期档案在 iPhone 上**（原始样本 180 天 + 汇总桶不删）。

---

## 🎯 设计原则（已与需求方确认）

1. **不追求数据完整性**——有的就收集，没有的就没有。不做历史回填、不做缺口检测、
   不做失败重试到成功。但**磁盘占用仍然要控制**（这是空间问题，不是完整性问题）。
2. **只支持 watchOS 27+ / S12**，不需要任何向后兼容分支。
3. **数据落在硬盘上**，不是运行内存。
4. **删除要转发**——用户在健康 App 里删掉的数据，手机上必须跟着删。
   这属于**正确性**，不属于被砍掉的"数据完整性"。

---

## ⭐ 下一步该做什么

1. 轮到用户操作：App Store Connect → TestFlight → 等构建可用 →
   Internal Testing 建组 → iPhone 装 TestFlight → 装 App（手表 app 会跟着装）。
2. 手表上打开 App → 授权健康 → 点「立即同步」→ 把小组件加到表盘。
3. 进手表「诊断」界面读四个未知数（详见部署指南第 7 节）：
   **心率密度**、**HRV (RMSSD)**、**心跳序列 / RR 间期**、各指标采集量。
4. 看 iPhone「状态」页签，确认数据真的传过来了。

> 💡 开发机没有 Mac、看不到设备日志，所以"验证"这件事本身必须做成
> **两端都能读的界面**，而不是 `print()`。手表端的「诊断」和 iPhone 端的「状态」
> 就是为这件事存在的。
