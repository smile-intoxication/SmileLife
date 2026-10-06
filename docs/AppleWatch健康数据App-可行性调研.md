# Apple Watch 健康数据 App — 可行性调研

> 调研范围：HealthKit 数据可得性、watchOS 能力边界、表盘小组件、watch ↔ iPhone 数据同步架构。
> 方法：只以 Apple 官方文档（developer.apple.com 的 `.md` / HTML / JSON 端点）为结论依据；社区实测证据单独标注。
> 凡官方文档未明确写明的，一律标注「**未核实/不确定**」，不作为设计前提。

---

## 0. 结论速览

| 你的需求 | 结论 | 关键限制 |
|---|---|---|
| 1. 获取心率、HRV 等健康数据 | ✅ 可以 | 全部经由 HealthKit，需用户授权 |
| 1. 获取 **RR 间期**原始数据 | ⚠️ **可以，但不是"直接读 RR"** | 无 RR 类型；需走 heartbeat series 或 ECG 自行换算；**无法连续/实时获取** |
| 2. 手表端缓存 + 查看最新数据 | ✅ 可以 | 手表端 HealthKit store 只保留近期数据，长期数据在 iPhone 端 |
| 3. 每个数据都做表盘小组件 | ✅ 可以（WidgetKit） | 用 ClockKit 的老路已弃用；每个指标一个 widget `kind` 没问题，但 **watchOS 11 及更早没有配置界面**，且用户表盘槽位有限（§4.3） |
| 4. 定时打包上传到手机端 | ✅ **不需要做** | 数据已在 iPhone 的 HealthKit 里，手机端直接读即可。若目标是**自有服务器**，手表端也能直传（§5.8，官方支持，最快 15 分钟一次） |

**架构一句话结论**：手表端只负责**采集/展示/小组件**，数据同步交给 HealthKit 系统机制；iPhone 端用 `HKObserverQuery` + `HKAnchoredObjectQuery` 拉增量并落库。

**本方案最大的技术风险**：`HKHeartbeatSeriesSample`（逐拍心跳序列，RR 间期的唯一自动来源）**官方文档没有说明 Apple Watch 在什么条件下会自动写入**。这必须在真机上实测确认（见 §1.6）。

---

## 1. 关键问题：RR 间期到底能不能拿到

### 1.1 HealthKit 里没有"RR 间期"这个数据类型

Apple 官方对 HRV 的定义原文（`heartRateVariabilitySDNN`）：

> "HealthKit uses **SDNN** heart rate variability, which uses the standard deviation of the **inter-beat (RR) intervals** between normal heartbeats (typically measured in milliseconds). **The system automatically records samples on Apple Watch.**"

这句话的意思是：**RR 间期是 Apple 内部计算 SDNN 的原始输入，但 Apple 只把计算结果（SDNN）暴露给第三方 app，没有暴露原始 RR 序列。**

- 来源：<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn>
- Availability：iOS 11.0+ / **watchOS 4.0+**（同一页面 Availability 徽章）

### 1.2 四条可行路径

| 路径 | 能拿到什么 | iOS / watchOS | 触发方式 | 限制 |
|---|---|---|---|---|
| `HKHeartbeatSeriesSample` + `HKHeartbeatSeriesQuery` | **逐拍心跳时间戳序列**；相邻时间戳之差 = RR 间期 | 13.0+ / **6.0+** | Apple Watch 自动写入（条件见 §1.3） | 触发时机官方未写明；无法实时 |
| `HKElectrocardiogram` + `HKElectrocardiogramQuery` | 30 秒单导联**电压波形**（`samplingFrequency` 为 512 Hz 级），可自行检测 R 波并算 RR | 14.0+ / **7.0+** | **用户手动测量**，不能自动触发 | 每天几次、每次 30 秒；用户需主动操作 |
| `HKQuantityTypeIdentifier.heartRateVariabilitySDNN` | Apple 算好的 **SDNN 结果值** | 11.0+ / **4.0+** | 系统自动 | 只有结果，没有原始序列 |
| 🆕 `HKQuantityTypeIdentifier.heartRateVariabilityRMSSD` | Apple 算好的 **RMSSD 结果值** | **27.0+ / 27.0+** | 官方文档未说明 | **太新（2026-09 才随 watchOS 27 上线）**；官方页面连正文都还没有 |

Availability 均取自各符号页面的 Availability 字段（如 <https://developer.apple.com/documentation/healthkit/hkheartbeatseriessample>、<https://developer.apple.com/documentation/healthkit/hkelectrocardiogram>、<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd>）。

> 🆕 **关于新增的 RMSSD 类型（值得单独说明）**
>
> `heartRateVariabilityRMSSD` 的 Availability 徽章实测为 **iOS 27.0+ / watchOS 27.0+**（我已直接核对官方 `.md` 端点）。这有意义，因为 **RMSSD 是短时 HRV 的标准指标**，本来正是从 RR 间期算出来的——Apple 现在直接把结果给你了。
>
> **但要冷静看待三点**：
> 1. 官方这一页**只有符号定义，没有 Discussion 正文**（很新，文档还没写）；我在 [watchOS 27 的官方 What's New 页](https://developer.apple.com/watchos/whats-new/) 的 Health & Fitness 部分也**没有找到任何 HRV/RMSSD 的提及**（那里只讲了 workout zones 和 menopause API）；
> 2. **是否由 Apple Watch 自动写入、写入频率如何，官方文档完全没有说明** → 属于必须真机验证的项；
> 3. 要求 watchOS 27（2026-09 发布），**会排除掉绝大多数存量设备**。工程上应该把它做成 `if #available(watchOS 27, *)` 的**增强项**，而不是基础依赖。
>
> 顺带澄清一个常见误解：第三方报道里说的 "Apple Watch 现在报两个 HRV 数字（Recovery HRV / Overall HRV）" 属于**第三方媒体说法，我在 Apple 官方文档中没有找到对应依据**，不作为设计前提。

`HKHeartbeatSeriesQuery` 的回调签名（官方 JSON 端点原文）说明了它给出的正是**逐拍时间戳**：

```
init(heartbeatSeries:dataHandler: (HKHeartbeatSeriesQuery, TimeInterval, Bool, Bool, (any Error)?) -> Void)
```
来源：<https://developer.apple.com/documentation/healthkit/hkheartbeatseriesquery>

### 1.3 Apple Watch 到底会不会自动写入 heartbeat series？

**官方文档：没有说明。** Apple 只把 `HKHeartbeatSeriesSample` 描述为 "A sample that represents a series of heartbeats"，并说明第三方 app 可以用 `HKHeartbeatSeriesBuilder` **自己创建**这类样本。是"给 app 写入用的容器"，还是"系统也会自动产生"，文档没有正面回答，也没有列出触发条件。

**社区实测证据（非官方，但一致）**：一位开发者在 2025-09 的公开记录中写道：

> "my Apple Watch was collecting **beat-to-beat HR data every 4 minutes** while I was asleep... it wasn't available as HRV data. So I looked into HealthKit and decided to build a simple app to show me daily HRV based on **overnight beat-to-beat measurements**."
> "RMSSD calculated from overnight HR measurements (**in AF mode the Apple Watch will measure every 4 minutes**)"
>
> 来源：<https://forum.intervals.icu/t/sleep-hrv-an-app-to-record-true-overnight-rmssd-hrv-from-the-apple-watch/111712>

这段证据指向两点，都很关键：
1. Apple Watch **确实**会产生逐拍（beat-to-beat）数据，并能被第三方 app 通过 HealthKit 读到；
2. 频率与**房颤历史（AFib History）**、**睡眠**状态强相关，不是"想采就采"。

> ⚠️ 这是社区记录，不是 Apple 文档。**必须真机验证**（见 §1.6）。

#### 📌 实测记录（2026-10-07，本机，watchOS 27 / Series 12）

| 条件 | 结果 |
|---|---|
| 房颤历史（AFib History）未开启 | 近 7 天 0 条心跳序列（手表「诊断」→ HealthKit 直查） |
| **复核探针代码后发现** | ⚠️ **这个 0 无效，不能作为任何结论的依据** |

**为什么无效（这一条比结论本身更重要）**：
探针本身是对的（`HKSeriesType.heartbeat()` 没写错），但 **v1.7 从来没有申请过读这个类型的权限** ——
`MetricCatalog.readTypes` 是从指标表派生的，而心跳序列是 `HKSeriesType`（**不是** `HKQuantityType`），
根本进不了那张表。

而 HealthKit 对**没授权的类型返回空数组、不返回错误**（这正是 §3.5 反复强调的那条）。
所以那个「0 条」的真实含义是**「我们没权限」**，
和设备产不产生逐拍数据、和房颤历史开没开，**一点关系都没有**。

> 🔴 **教训（已做成自检脚本第 15 节）**：
> 一个"直接问 HealthKit"的探针，**只有在它查的类型确实在 `readTypes` 里时才可信**。
> 否则它的输出与"设备没数据"完全无法区分 —— 而这类错误会伪装成**事实**，
> 比单纯的 bug 危险得多（本次就差点据此写下"房颤历史是必要条件"的结论）。

**修正后的状态**：`readTypes` 已补上 `HKSeriesType.heartbeat()`，
并统一由 `MetricCatalog.heartbeatSeriesType` 提供（探针不再就地构造，避免"申请 A、查 B"）。
**真正的实测要等重新授权之后再跑一次** —— 这一步尚未完成。

**顺带澄清一个必须分清的边界**（这是本问题最容易混的地方）：

| | 房颤历史（被动后台） | 移动心电图 ECG（主动） |
|---|---|---|
| 用户要不要操作 | **不要**，戴着就行 | **要**：打开 App、手指按住表冠 30 秒 |
| 会不会产生心跳序列 | 社区证据指向"会"，**待验证** | 每次测量会产生一条 |
| 结论 | ← **我们要的是这条** | 按需求方标准已排除 |

⚠️ 关于"被动那条路是不是**必须**开房颤历史"，目前的证据只有：
① 官方文档从未说明被动写入的条件；
② 社区实证把逐拍测量和 "AF mode" 绑在一起（§1.3）。
**两条都还不足以下结论** —— 我们自己那条实测已经被判定为无效。


### 1.4 ECG 路径能补什么

`HKElectrocardiogram` 官方原文：

> "The `HKElectrocardiogram` sample provides high-level details about the ECG reading, such as the **sampling frequency** or classification. HealthKit provides **read-only** access to electrocardiogram (ECG) data saved by Apple Watch."

配合 `HKElectrocardiogramQuery` 可逐点取到 `.appleWatchSimilarToLeadI` 的电压值，因此**可以自己写 R 波检测算法算出 RR 间期**。

- 来源：<https://developer.apple.com/documentation/healthkit/hkelectrocardiogram>
- 前提：Apple Watch Series 4 及以上 + 所在地区支持 ECG app；必须用户主动测量。

### 1.5 做不到的事（先排除幻想）

- ❌ **连续/实时 RR 间期**：HealthKit 不提供。即使用户在跑 workout，`HKWorkoutSession` 给到的也是心率**点值**（官方原文："All workout sessions generate high-frequency heart rate samples"），不是逐拍序列。
  来源：<https://developer.apple.com/documentation/healthkit/hkworkoutsession>
- ❌ **主动触发一次 RR 采样**：第三方 app 无法命令 Apple Watch 去做一次逐拍测量，只能等系统测完再去读。
- ❌ **自定义采集频率**：采集频率由 watchOS 决定，与 AFib History、睡眠、运动状态有关。

其中"实时拿不到"还有一个**结构性**证据，比文档措辞更硬：`HKLiveWorkoutDataSource.typesToCollect` 的类型是 `Set<HKQuantityType>`，而心跳序列 `HKHeartbeatSeriesSample` 是 **`HKSeriesSample` 的子类，根本不是 `HKQuantityType`**。也就是说从类型系统上，心跳序列就不可能出现在 workout 的实时数据集合里。

来源：<https://developer.apple.com/documentation/healthkit/hkliveworkoutdatasource>、<https://developer.apple.com/documentation/healthkit/hkheartbeatseriessample>

### 1.6 结论与"第一天就要做"的验证动作

**结论**：RR 间期可以拿，但只能"**事后读系统已经采到的**"，不能"**主动、连续地采**"。产品设计必须按这个前提走。

**开发第一步（强烈建议）**：先做一个**数据可用性探测器**——一个最小 watchOS + iOS app，请求全部你关心的类型读权限，然后：

1. 用 `HKSampleQuery` 分别统计过去 7 天每类数据的**样本条数、时间分布、来源设备**；
2. 用 `HKHeartbeatSeriesQuery` 把 heartbeat series 样本**逐拍打印出来**，确认是否真有数据、间隔是多少毫秒；
3. 用 `HKSource` / `HKSourceRevision` / `HKDevice` 打印每条样本的来源，确认哪些来自 Apple Watch。

这份探测器跑完的真实结果，比任何文档都可靠，而且它本身就是后续数据层的雏形。

---

## 2. Apple Watch 可采集的 HealthKit 数据类型全表

### 2.0 速查（S12 / watchOS 27）

> 本节是**取舍视角**的整理，回答"有什么、谁产生的、我们收不收"。
> 逐类型的 Availability 徽章与官方链接在 §2.2–§2.9，两处不会重复列徽章。
> 本节与那几张表**必须同步改** —— 同一批类型写在两个地方就一定会漂移。

#### 先纠正一个常见误解：HealthKit 的类型可用性**不按机型分**

它是**四个独立条件的交集**，机型只影响其中一条：

| 条件 | 由什么决定 | 例子 |
|---|---|---|
| ① 类型存在 | **OS 版本**（Availability 徽章） | `heartRateVariabilityRMSSD` 要 watchOS 27 |
| ② 本机会不会产生 | **硬件传感器** | SE 3 没有电学心率传感器 → 永不产生 ECG |
| ③ 用户有没有开 | **设置 / 主动操作** | 不开"不齐律通知"就没有 `irregularHeartRhythmEvent` |
| ④ 地区有没有 | **法规**（Apple 的功能可用性） | 血氧在部分地区被关掉 |

所以"**S12 能拿到哪些**"这个问题的准确答案是：
**类型清单由 watchOS 版本决定，实际有没有数据由 ②③④ 决定。**
`S12` 这个机型名不构成任何一条 API 前提（代码里**不要**写机型判断）。

#### S12 的硬件底座（决定②）

| 传感器 | S12 / Ultra 4 | 决定了哪些指标 |
|---|---|---|
| 光学心率（新绿色 LED 阵列） | ✅ | `heartRate`、`restingHeartRate`、`walkingHeartRateAverage`、HRV、`atrialFibrillationBurden`、`hypertensionEvent` |
| 电学心率（数码表冠电极） | ✅（**SE 3 ❌**） | `HKElectrocardiogram` |
| 血氧 | ✅（**SE 3 ❌**，且受地区限制） | `oxygenSaturation` |
| 双温度传感器（腕温） | ✅ | `appleSleepingWristTemperature` |
| 加速计 / 陀螺仪 / 气压计 | ✅ | 活动圆环、步数、爬楼、`physicalEffort` |
| 环境光 | ✅ | `timeInDaylight` |
| 麦克风（只测声压，**不录音**） | ✅ | `environmentalAudioExposure` |
| 水深计 / 水温 | **只有 Ultra** | `underwaterDepth`、`waterTemperature` |
| UV / 血压计 / 血糖 / 核心体温计 | ❌ **任何机型都没有** | 见 §2.10② |

> ⚠️ **S12 最容易误判的一点**：Apple 只公布了手表**测量**心率的节奏
> （"every five seconds, all day long"，Newsroom 2026-09-09），
> **没有说多少条会写进 HealthKit**（白皮书里后台写入仍是"每 5 分钟一条"）。
> 这是本项目第 1 号待验证项，用 **手表「诊断」界面**回答。

#### ① 手表**自己产生**的数据 —— 可以放心当数据源

**A. 心率族（本项目主体）**

| 常量 | 我们收不收 | 节奏 |
|---|---|---|
| `heartRate` | ✅ 已收（首次回看 1 天） | 后台 + 运动时高频；**警告：会被 condense，见 §3.6** |
| `restingHeartRate` | ✅ 已收 | 后台自动，**随当日数据变准会覆盖**旧样本 |
| `walkingHeartRateAverage` | ✅ 已收 | 后台自动，只读、覆盖式 |
| `heartRateVariabilitySDNN` | ✅ 已收 | 默认 4 小时；开不齐律通知 → 2 小时；AFib History → 15 分钟 |
| 🆕 `heartRateVariabilityRMSSD` | ✅ 已收（**运行时探测**） | watchOS 27 新增；**官方页面无正文，是否自动写入未知** |
| `heartRateRecoveryOneMinute` | ⬜ 未收 | 每次运动结束 1 条 |
| `HKHeartbeatSeriesSample` | ⬜ 未收（探测中） | **逐拍时间戳 → 唯一的自动 RR 间期来源**；触发条件官方未写，见 §1.3。⚠️ v1.7 报的「0 条」**已判定无效**（当时没申请读权限），修正后待复测 |
| `HKElectrocardiogram` | ⬜ 未收 | **用户主动测量**，30 秒/次，可自行算 RR |
| `atrialFibrillationBurden` | ⬜ 未收 | 每周 1 条；Watch 采集、**iPhone 计算** |
| `lowHeartRateEvent` / `highHeartRateEvent` | ⬜ 未收 | 事件驱动，阈值在 metadata |
| `irregularHeartRhythmEvent` | ⬜ 未收 | 后台"偶尔检查"，**Apple 未给固定间隔** |

**B. 呼吸 / 血氧 / 体温**

| 常量 | 我们收不收 | 节奏 |
|---|---|---|
| `oxygenSaturation` | ✅ 已收 | 按需 + 不活动时（含睡眠）周期性；**受地区限制** |
| `respiratoryRate` | ✅ 已收 | 后台自动，**以睡眠期间为主** |
| `appleSleepingWristTemperature` | ✅ 已收 | 睡眠中每 5 秒采样 → **整夜聚合成 1 条** |
| `appleSleepingBreathingDisturbances` | ⬜ 未收 | 整夜分析（睡眠呼吸暂停） |

**C. 睡眠 / 正念 / 日光**

| 常量 | 我们收不收 | 备注 |
|---|---|---|
| `sleepAnalysis` | ✅ 已收 | 枚举型（卧床/清醒/核心/深睡/REM）；**Watch 只记夹在两段睡眠之间的 `awake`** |
| `mindfulSession` | ⬜ 未收 | 用户主动 |
| `timeInDaylight` | ⬜ 未收 | 环境光，后台累计 |

**D. 活动 / 运动 / 体能**

| 常量 | 我们收不收 | 备注 |
|---|---|---|
| `activeEnergyBurned` | ✅ 已收（**默认关**） | Move 环；会被 condense |
| `appleExerciseTime` | ✅ 已收（**默认关**） | Exercise 环 |
| `vo2Max` | ✅ 已收（**默认关**） | 需先戴 ≥1 天，首次运动不生成 |
| `basalEnergyBurned` | ⬜ 未收 | 静息能量 |
| `appleMoveTime` / `appleStandTime` / `appleStandHour` | ⬜ 未收 | 三个环的细项 |
| `stepCount` / `distanceWalkingRunning` / `flightsClimbed` | ⬜ 未收 | **iPhone 也会产生**，不算手表独有 |
| `distanceCycling` / `distanceSwimming` / `swimmingStrokeCount` | ⬜ 未收 | 运动时 |
| `physicalEffort`（METs） | ⬜ 未收 | 后台自动 |
| `workoutEffortScore` / `estimatedWorkoutEffortScore` | ⬜ 未收 | 每次训练后 |
| `HKWorkout` | ⬜ 未收 | 复合样本；**要做"按运动分段"就必须收它** |
| `lowCardioFitnessEvent` | ⬜ 未收 | 约每 4 个月一次 |
| `distanceWheelchair` / `pushCount` | ⬜ 未收 | 轮椅模式 |

**E. 步态（手表**有**的那部分）**

| 常量 | 我们收不收 | 备注 |
|---|---|---|
| `sixMinuteWalkTestDistance` | ⬜ 未收 | 每周 1 条估算，设 500 m 上限 |
| `stairAscentSpeed` / `stairDescentSpeed` | ⬜ 未收 | 需爬 ≥3 米楼梯，每天约 20 条 |
| `numberOfTimesFallen` | ⬜ 未收 | 用户取消提醒则不记录 |

**F. 听觉**

| 常量 | 我们收不收 | 备注 |
|---|---|---|
| `environmentalAudioExposure` | ⬜ 未收 | 只测声压，**Apple 不录音** |
| `headphoneAudioExposure` | ⬜ 未收 | iPhone 或手表（配耳机） |
| `environmentalAudioExposureEvent` / `headphoneAudioExposureEvent` | ⬜ 未收 | 超标事件 |

**G. 事件 / 风险提示（都不是"数值"）**

`hypertensionEvent`（26.2+，光学心率被动分析，**以 30 天为周期**）、`handwashingEvent`、
`appleWalkingSteadinessEvent`、`lowCardioFitnessEvent`、环境噪声/耳机音量超标事件。

> ⚠️ `hypertensionEvent` **不是血压值**。Apple Watch 没有血压计，它只是被动风险提示。

#### ② iPhone 产生的 —— **不要**放进手表端

这一组的徽章都写着 watchOS 7.0+，看起来"手表可用"，但**数据全部由 iPhone 产生**，
Apple Watch 一条都不写。把它们当手表数据源，采集方案会直接落空：

`appleWalkingSteadiness`、`appleWalkingSteadinessEvent`、
**`walkingSpeed`、`walkingStepLength`、`walkingAsymmetryPercentage`、`walkingDoubleSupportPercentage`**
（后 4 个注意**没有 `apple` 前缀**）、`basalBodyTemperature`（手动/第三方）、
`environmentalSoundReduction`（AirPods 等耳机）。

> 但这不等于"iOS 端不能收" —— iPhone 端**可以读**这些（它们是 iPhone 产生并存在
> iPhone 的 HealthKit 里的）。只是**别指望手表端采到**。

#### ③ 手表**没有**的（别抱期望）

| 指标 | 真相 |
|---|---|
| UV / 紫外线 | 没有任何 Watch 机型有 UV 传感器 |
| 血压 | 无血压计；`hypertensionEvent` 只是风险提示 |
| 血糖 | 无传感器，需第三方 CGM |
| 核心体温 | 手表只写**腕温**，不写 `bodyTemperature` |
| `peripheralPerfusionIndex` | 需第三方医疗设备写入 |
| `toothbrushingEvent` | 手表无刷牙检测，需第三方电动牙刷 App |
| 身高 / 体重 / BMI / 月经 / 绝经状态 | 手动录入或第三方设备 |

#### ④ 我们当前收了哪些

`watch/Health/MetricCatalog.swift` 里共 **12 个**指标（`shared/MetricDisplay.swift`
是展示元数据的唯一定义处，两边 id 由自检脚本第 12 节强制一致）：

- **默认开启 9 个**：心率、静息心率、步行心率、HRV(SDNN)、HRV(RMSSD)、呼吸频率、血氧、睡眠腕温、睡眠
- **默认关闭 3 个**：活动能量、锻炼时间、最大摄氧量（用户可在设置里打开）

**建议的下一步候选**（按"值不值得为此加一个指标"排序）：

| 候选 | 理由 |
|---|---|
| `HKWorkout` | 唯一的"把一天切成若干段"的依据。现在画心率曲线，运动期间的高心率和平静期混在一起，看不出"那次跑步" |
| `heartRateRecoveryOneMinute` | 一条就能反映心肺恢复能力，数据量极小 |
| `appleSleepingBreathingDisturbances` | 与已有的睡眠数据天然配套，用户关心度高 |
| `timeInDaylight` | 数据量小、隐私敏感度低，属于"顺手就有"的加分项 |
| `HKHeartbeatSeriesSample` | **先看诊断界面的实测结果**再决定 —— 它才是真正的 RR 间期来源（§1.3） |
| `HKElectrocardiogram` | 需要用户主动操作，采不到稳定数据；但如果要做"HRV 深度分析"，它是唯一的高采样率来源 |

#### ⑤ 读这张清单时最容易踩的三件事

1. **`walkingHeartRateAverage` 等会被系统覆盖**：同一天重新计算后，旧样本的值会变。
   本地库必须按 `uuid` **upsert 更新**，不能"已存在就跳过"（手机端已经这么做了）。
2. **`heartRate` 会被 condense**：`HKQuantitySample.count > 1` 说明它其实是个 series，
   必须用 `HKQuantitySeriesSampleQuery` 拆开读，否则拿到的是"一条覆盖很长区间、带平均值"的样本（§3.6）。
3. **只读类型不能写回**：`HKElectrocardiogram`、`HKHeartbeatSeriesSample`、
   `atrialFibrillationBurden`、各类事件、`appleSleepingWristTemperature`、
   `walkingHeartRateAverage` —— 这些只能读出来存到自己库里，**不能请求写授权**（§2.10③）。

---

### 2.1 怎么读这张表（图例）

- **★Watch独有**：Apple 官方文档明确该样本**由 Apple Watch 产生**，iPhone 无法产生；
- **✖非Watch**：API 在 watchOS 上存在，但 **Apple Watch 不产生该数据**（由 iPhone、第三方设备或手动录入产生）；
- **⚠️只读**：只能请求**读**授权，app **不能写入**；
- 所有 Availability 均取自 developer.apple.com 各符号页 `.md` 端点顶部的 `availability` 元数据（逐个抓取 70+ 个页面，非记忆值）。

> **⚠️ 全表最重要的一条阅读原则**：**"watchOS 可用" ≠ "数据由手表产生"。**
> 例如 `uvExposure`、`bloodGlucose`、`height`、`toothbrushingEvent` 的徽章都写着 watchOS 2.0+/6.0+，但它们**和 Apple Watch 硬件毫无关系**。判断数据来源必须看 Discussion 段落里的设备描述，不能只看徽章。这就是本表专门设"产生来源"一列的原因。

**版本基准**：当前最新为 **watchOS 27**（2026-09-14 发布，最新小版本 27.0.1 / 2026-09-28）与 **iOS 27**；上一代为 watchOS 26。现役机型 Series 12 / Ultra 4 / SE 3。
来源：<https://developer.apple.com/documentation/watchos-release-notes>

---

### 2.2 心率 / 心电 / HRV

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `heartRate` | 心率 | bpm | 8.0+ | 2.0+ | Apple Watch 全系光学心率传感器 | 连续 + 后台自动 + 运动时高频 |
| `restingHeartRate` | 静息心率 | bpm | 11.0+ | 4.0+ | **★Watch独有** | 后台自动；随当日数据变准会**覆盖**当日/前一日样本 |
| `walkingHeartRateAverage` | 步行平均心率 | bpm | 11.0+ | 4.0+ | **★Watch独有**（官方："automatically created by HealthKit. **You cannot save your own**"） | 后台自动，覆盖式 |
| `heartRateVariabilitySDNN` | HRV（SDNN） | ms | 11.0+ | 4.0+ | **★Watch独有** | 后台自动（静息/睡眠） |
| 🆕 `heartRateVariabilityRMSSD` | HRV（RMSSD） | 页面未标注 | **27.0+** | **27.0+** | Apple Watch（页面无 Discussion） | 后台自动；**页面无说明，需真机验证** |
| `heartRateRecoveryOneMinute` | 运动后 1 分钟心率恢复 | bpm | 16.0+ | 9.0+ | **★Watch独有** | 每次运动结束自动 1 条 |
| `atrialFibrillationBurden` | 房颤负荷 ⚠️ | % | 16.0+ | 9.0+ | **★Watch独有**（Watch 采集 → **iPhone 计算**） | 后台自动，**每周一次** |
| `lowHeartRateEvent` | 低心率通知事件 ⚠️ | 无量纲（阈值在 metadata） | 12.2+ | 5.2+ | **★Watch独有** | 事件驱动 |
| `highHeartRateEvent` | 高心率通知事件 ⚠️ | 同上 | 12.2+ | 5.2+ | **★Watch独有** | 事件驱动 |
| `irregularHeartRhythmEvent` | 不规则心律（疑似 AFib）⚠️ | 无量纲 | 12.2+ | 5.2+ | **★Watch独有**（Series 3+，光学心率） | 后台"偶尔检查"，Apple **未给固定间隔** |
| `HKElectrocardiogram` | 心电图波形 ⚠️ | µV 波形，30 秒/次 | 14.0+ | 7.0+ | **★Watch独有**（Series 4+，电学心率传感器 + 数码表冠电极；**SE 系列无**） | **用户主动按需**（手指按住表冠成回路） |
| `HKHeartbeatSeriesSample` | 心跳序列（逐拍时间戳 → **可推 RR 间期**）⚠️ | 序列样本 | 13.0+ | 6.0+ | **★Watch独有**（AFib History 期间 / ECG 相关） | 后台自动；用 `HKHeartbeatSeriesQuery` 读 |

来源：<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn>、<https://developer.apple.com/documentation/healthkit/hkelectrocardiogram>、<https://developer.apple.com/documentation/healthkit/hkheartbeatseriessample> 等（路径规律：`.../documentation/healthkit/hkquantitytypeidentifier/<小写常量名>`）。

#### 📌 采集节奏（决定数据量，进而决定存储架构）

Apple Watch Series 12 / Ultra 4 引入了新的 Health Sensing System，**心率采集密度大幅提升**。官方两处说法要对起来读：

**① Apple Newsroom（2026-09-09）——讲的是"测量"：**
> "With larger, power-efficient green LEDs on the optical heart sensor, Apple Watch Series 12 and Apple Watch Ultra 4 now **measure heart rate every five seconds, all day long**."

**② Apple 白皮书《Heart Rate, Calorimetry, and Activity on Apple Watch》（2024-11）——讲的是"写入 HealthKit"：**
> 后台："In every non-overlapping **five minutes** window, Apple Watch attempts to **publish one background heart rate to HealthKit**"
> 运动："In every non-overlapping **five seconds** window, the algorithm chooses one heart rate measurement with the highest quality to display and **publish to HealthKit**"

来源：<https://www.apple.com/newsroom/2026/09/apple-advances-health-and-fitness-capabilities-using-apple-intelligence/>、Apple 心率白皮书（2024-11）

| 数据 | 旧节奏 | S12 之后 |
|---|---|---|
| 后台心率 | 每 5 分钟 1 条（仅静止时）→ 约 288 条/天 | **每 5 秒** → 理论 **17,280 条/天** |
| 运动心率 | 每 5 秒 1 条 | 不变 |
| HRV | 默认每 4 小时；开不齐律通知→2 小时；AFib History→15 分钟 | "as often as every 5 minutes" |

> ❗ **关键未知（必须真机实测）**：Apple 只公布了手表**测量**的节奏，
> **没有说多少条会真正写进 HealthKit**。5 秒数据完全可能只服务于手表自身的算法
> （如 readiness / 活动圆环），而 HealthKit 仍按 5 分钟写入。
> **在拿到实测数据前，不要假设任何一边。**
>
> 对存储的影响是决定性的：若 17,280 条/天全部落库，90 天就是 **155 万行**，
> Apple Watch 存不下 → 必须做**分层存储**（原始短期 + 小时聚合长期）。
> 这个策略在任何密度下都成立，所以可以先按它实现，再等实测结果调参数。

---

### 2.3 呼吸 / 血氧

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `oxygenSaturation` | 血氧 SpO₂ | % | 8.0+ | 2.0+ | **★Watch独有**（Series 6+ 血氧传感器；**SE 3 无**） | 按需 + 不活动时（含睡眠）周期性后台 |
| `respiratoryRate` | 呼吸频率 | count/min | 8.0+ | 2.0+ | **★Watch独有** | 后台自动（睡眠期间为主） |
| `appleSleepingBreathingDisturbances` | 睡眠呼吸障碍（呼吸暂停） | 见官方页 | 18.0+ | 11.0+ | **★Watch独有** | 整夜后台自动分析 → 触发通知 |
| `peripheralPerfusionIndex` | 外周灌注指数 | % | 8.0+ | 2.0+ | **✖非Watch**（需第三方医疗设备/App 写入） | 按需 |

> ⚠️ 常量名修正：官方**没有** `breathingDisturbances` 这个常量，正确写法是 **`appleSleepingBreathingDisturbances`**。

---

### 2.4 活动 / 运动 / 体能

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `activeEnergyBurned` | 活动能量（Move 环） | kcal | 8.0+ | 2.0+ | Apple Watch（iPhone 亦可写） | 后台自动；**样本可能被 condense** |
| `basalEnergyBurned` | 静息能量 | kcal | 8.0+ | 2.0+ | Apple Watch | 后台自动 |
| `appleMoveTime` | 活动时间 | 分钟 | 14.5+ | 7.4+ | **★Watch独有**（加速计+陀螺仪） | 后台自动，按整分钟 |
| `appleExerciseTime` | 锻炼时间（Exercise 环） | 分钟 | 9.3+ | 2.2+ | **★Watch独有** | 后台自动 + 运动会话 |
| `appleStandTime` | 站立时间 | 分钟 | 13.0+ | 6.0+ | **★Watch独有** | 后台自动 |
| `appleStandHour` | 站立小时 | 枚举 | 9.0+ | 2.0+ | **★Watch独有** | 每小时判定 |
| `stepCount` | 步数 | count | 8.0+ | 2.0+ | iPhone + Apple Watch | 连续后台；**iOS 上最高只能 hourly 后台投递** |
| `distanceWalkingRunning` | 步行/跑步距离 | m | 8.0+ | 2.0+ | iPhone + Apple Watch | 后台自动 / 运动时 |
| `distanceCycling` | 骑行距离 | m | 8.0+ | 2.0+ | Apple Watch（GPS）；室内需外接传感器 | 运动时 |
| `distanceSwimming` | 游泳距离 | m | 10.0+ | 3.0+ | **★Watch独有** | 运动时 |
| `swimmingStrokeCount` | 划水次数 | count | 10.0+ | 3.0+ | **★Watch独有** | 运动时 |
| `distanceWheelchair` / `pushCount` | 轮椅距离/推次 | m / count | 10.0+ | 3.0+ | **★Watch独有**（轮椅模式） | 后台自动 |
| `flightsClimbed` | 爬楼层数 | count | 8.0+ | 2.0+ | iPhone / Apple Watch（气压高度计） | 后台自动 |
| `distanceDownhillSnowSports` | 高山滑雪距离 | m | 11.2+ | 4.2+ | Apple Watch | 运动时 |
| `vo2Max` | 最大摄氧量 | mL/kg·min | 11.0+ | 4.0+ | **★Watch独有**（Series 3+，户外步行/跑步估算） | 后台自动；**需先戴 ≥1 天，首次运动不生成** |
| `lowCardioFitnessEvent` ⚠️ | 低心肺适能事件 | 无量纲 | 14.3+ | 7.2+ | Apple Watch + iPhone 分级 | 约**每 4 个月**一次通知 |
| `HKWorkout` | 体能训练样本 | 复合 | 8.0+ | 2.0+ | Watch 训练 App / 第三方（iOS 26 起 iPhone 也可开始会话） | 用户发起 |
| `workoutEffortScore` / `estimatedWorkoutEffortScore` | 运动用力程度 | 见官方页 | 18.0+ | 11.0+ | Apple Watch + 用户评分 | 每次训练后 |
| `physicalEffort` | 体力消耗 | **METs** | 17.0+ | 10.0+ | **★Watch独有**（"recorded automatically by Apple Watch"） | 后台自动 |

---

### 2.5 步态 / 移动 —— ⚠️ **本节最容易做错产品**

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `appleWalkingSteadiness` | 步行稳定性 | % | 15.0+ | 8.0+（**仅 API**） | **✖iPhone 独有**（官方："on **iPhone 8 or later**"，需手机放腰附近、平地匀速走、健康 App 里设身高；轮椅模式不记录） | 后台自动，**每 7 天 1 条** |
| `appleWalkingSteadinessEvent` ⚠️ | 步行稳定性下降事件 | 枚举 | 15.0+ | 8.0+ | **✖iPhone** | 事件驱动 |
| `walkingAsymmetryPercentage` | 步行不对称度 | % | 14.0+ | 7.0+ | **✖iPhone 独有** | 后台自动，**每天 10–30 条** |
| `walkingDoubleSupportPercentage` | 双支撑时间占比 | % | 14.0+ | 7.0+ | **✖iPhone 独有** | 每天 10–30 条 |
| `walkingSpeed` | 步行速度 | m/s | 14.0+ | 7.0+ | **✖iPhone 独有** | 每天 10–30 条 |
| `walkingStepLength` | 步长 | m | 14.0+ | 7.0+ | **✖iPhone 独有** | 每天 10–30 条 |
| `sixMinuteWalkTestDistance` | 六分钟步行试验距离 | m | 14.0+ | 7.0+ | **★Watch独有**（Series 3+） | 后台自动，**每周 1 条**估算（有佩戴时长门槛，上限 500 m） |
| `stairAscentSpeed` | 上楼速度 | m/s | 14.0+ | 7.0+ | **★Watch独有**（Series 5+，需爬 ≥3 米楼梯） | 每天约 **20 条** |
| `stairDescentSpeed` | 下楼速度 | m/s | 14.0+ | 7.0+ | **★Watch独有**（Series 5+） | 每天约 20 条 |
| `numberOfTimesFallen` | 摔倒次数 | count | 8.0+ | 2.0+ | **★Watch独有**（Series 4+ / SE 摔倒检测；用户取消提醒则不记录） | 事件驱动 |

**本节的结论（对你的项目至关重要）**：**5 个核心"走路"指标（`appleWalkingSteadiness`、`walkingAsymmetryPercentage`、`walkingDoubleSupportPercentage`、`walkingSpeed`、`walkingStepLength`）全部由 iPhone 产生，Apple Watch 不产生。** 把"走路相关数据"整体当成手表数据源，采集方案会直接落空。

来源：<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applewalkingsteadiness>、<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/walkingasymmetrypercentage>

> 📌 常量名修正：官方**没有** `appleWalkingAsymmetryPercentage` / `appleWalkingDoubleSupportPercentage` 这两个名字，正确写法是 **`walkingAsymmetryPercentage`** / **`walkingDoubleSupportPercentage`**（无 `apple` 前缀）。

---

### 2.6 体温

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `bodyTemperature` | 核心体温 | °C | 8.0+ | 2.0+ | **✖非Watch**（Apple 未说明任何 Watch 写此类型，需第三方体温计/手动） | 按需 |
| `appleSleepingWristTemperature` ⚠️ | 睡眠腕温 | °C | 16.0+ | 9.0+ | **★Watch独有**（Series 8 / Ultra 双温度传感器） | 睡眠中**每 5 秒**采样 → **整夜聚合成 1 条**；Health 里按相对基线显示 |
| `basalBodyTemperature` | 基础体温 | °C | 9.0+ | 2.0+ | **✖非Watch**（手动/第三方；Watch 写的是上一行的腕温） | 按需 |

---

### 2.7 睡眠 / 正念 / 日光

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `sleepAnalysis` | 睡眠分析 | 枚举（inBed / awake / asleepCore / asleepDeep / asleepREM / …） | 8.0+ | 2.0+ | **★Watch独有**（阶段需过夜佩戴；watchOS 9+ 分阶段）；iPhone 也能写 inBed | 后台自动整夜 |
| `mindfulSession` | 正念会话 | 枚举 | 10.0+ | 3.0+ | Watch 正念 App | **用户主动发起** |
| `timeInDaylight` | 日光下时间 | 分钟 | 17.0+ | 10.0+ | **★Watch独有**（环境光传感器） | 后台自动累计 |

> 注意 Apple 原文的一个细节：**Watch 只记录夹在两段睡眠之间的 `awake` 样本**，所以 in-bed 样本的首尾可能没有对应的细分样本。这会影响你画睡眠图表的边界处理。

---

### 2.8 听觉 / 环境噪声

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| `environmentalAudioExposure` | 环境音量暴露 | dBASPL | 13.0+ | 6.0+ | **★Watch独有**（噪声 App；**Apple 不录音**） | 后台自动 |
| `headphoneAudioExposure` | 耳机音量暴露 | dBASPL | 13.0+ | 6.0+ | iPhone 或 Apple Watch（配耳机） | 后台自动 |
| `environmentalSoundReduction` | 环境降噪量 | dBASPL | 16.0+ | 9.0+ | **✖非Watch**（AirPods Pro 等耳机） | 佩戴耳机时自动 |
| `environmentalAudioExposureEvent` ⚠️ | 环境噪声超标事件 | 枚举 | 14.0+ | 7.0+ | **★Watch独有** | 事件驱动（3 分钟均值达阈值） |
| `headphoneAudioExposureEvent` ⚠️ | 耳机音量超标事件 | 枚举 | 14.2+ | 7.1+ | iPhone 和 Apple Watch | 事件驱动（7 天累计超量） |
| `audioExposureEvent` | **已废弃** | — | 13.0–14.0 | 6.0–7.0 | — | 改用上面两个 Event 类型 |

---

### 2.9 其他 / 环境 / 生殖健康

| 常量名 | 说明 | 单位 | iOS | watchOS | 产生来源 | 采集方式 |
|---|---|---|---|---|---|---|
| 🆕 `hypertensionEvent` | 高血压通知事件 | 无量纲 | **26.2+** | **26.2+** | **★Watch独有**（Series 11+/Ultra 3+，**光学心率被动分析**；SE 3 不支持） | 后台被动分析，**以 30 天为周期**回顾 |
| `bloodPressureSystolic` / `Diastolic` / `bloodPressure` | 血压 | mmHg | 8.0+ | 2.0+ | **✖非Watch**（第三方血压计/手动；**Watch 无血压计**） | 按需 |
| `bloodGlucose` | 血糖 | mg/dL, mmol/L | 8.0+ | 2.0+ | **✖非Watch**（第三方 CGM；**Watch 无血糖传感器**） | 按需 |
| `uvExposure` | UV 暴露 | UV 指数 | 9.0+ | 2.0+ | **✖非Watch**（**没有任何 Watch 机型有 UV 传感器**） | 按需 |
| `waterTemperature` | 水温 | °C | 16.0+ | 9.0+ | **★Watch独有（Ultra）** | 潜水/游泳时自动 |
| `underwaterDepth` | 水下深度 | m | 16.0+ | 9.0+ | **★Watch独有（Ultra）** | 潜水会话自动 |
| `height` / `bodyMass` / `bodyMassIndex` | 身高/体重/BMI | m / kg / count | 8.0+ | 2.0+ | **✖非Watch**（手动录入或第三方秤） | 手动 |
| `menstrualFlow` | 月经流量 | 枚举 | 9.0+ | 2.0+ | 用户录入（Watch 腕温用于回溯性排卵估算） | **手动** |
| 🆕 `menopausalState` | 绝经状态 | 枚举 | **27.0+** | **27.0+** | 用户录入（点状样本） | 手动 |
| 🆕 `bleedingAfterMenopause` | 绝经后出血 | 枚举 | **27.0+** | **27.0+** | 用户/App 录入（区间样本） | 手动 |
| `handwashingEvent` | 洗手事件 | 枚举 | 14.0+ | 7.0+ | **★Watch独有**（Series 4+ 自动检测） | 事件驱动 |
| `toothbrushingEvent` | 刷牙事件 | 枚举 | 13.0+ | 6.0+ | **✖非Watch**（Watch 无刷牙检测，需第三方电动牙刷 App） | 事件驱动 |

> ⚠️ 关于 `hypertensionEvent` 的**重要澄清**：它**不是血压值**，只是基于光学心率信号的**被动风险提示**。Apple Watch **没有血压计**。通知发出后 Apple 建议用户用第三方血压计记录 7 天。做产品时不要把"高血压通知"宣传成"测血压"。

---

### 2.10 关键结论

**① Apple Watch 独有产生的完整清单（iPhone 无法产生）**

`restingHeartRate`、`walkingHeartRateAverage`、`heartRateVariabilitySDNN`、`heartRateVariabilityRMSSD`、`heartRateRecoveryOneMinute`、`atrialFibrillationBurden`、`lowHeartRateEvent`、`highHeartRateEvent`、`irregularHeartRhythmEvent`、`HKElectrocardiogram`、`HKHeartbeatSeriesSample`、`oxygenSaturation`、`respiratoryRate`、`appleSleepingBreathingDisturbances`、`appleMoveTime`、`appleExerciseTime`、`appleStandTime`、`appleStandHour`、`distanceSwimming`、`swimmingStrokeCount`、`distanceWheelchair`、`pushCount`、`distanceDownhillSnowSports`、`vo2Max`、`physicalEffort`、`sixMinuteWalkTestDistance`、`stairAscentSpeed`、`stairDescentSpeed`、`numberOfTimesFallen`、`appleSleepingWristTemperature`、`sleepAnalysis`（睡眠阶段）、`timeInDaylight`、`environmentalAudioExposure`、`environmentalAudioExposureEvent`、`waterTemperature`、`underwaterDepth`、`handwashingEvent`、`hypertensionEvent`

**② Apple Watch 没有的传感器（不要指望）**

| 指标 | 真相 |
|---|---|
| UV / 紫外线 | **没有任何 Watch 机型有 UV 传感器** |
| 血压 | 无血压计；`hypertensionEvent` 只是被动风险提示 |
| 血糖 | 无传感器，需第三方 CGM |
| 核心体温 | Watch 只写**腕温**（`appleSleepingWristTemperature`），不写 `bodyTemperature` |

另外 **SE 3 还缺**：ECG（无电学心率传感器）、血氧传感器、水深计与水温传感器。

**③ 只读类型清单（app 不能写入，只能读）**

`HKElectrocardiogram`、`HKHeartbeatSeriesSample`、`atrialFibrillationBurden`、`lowHeartRateEvent`、`highHeartRateEvent`、`irregularHeartRhythmEvent`、`appleSleepingWristTemperature`、`appleWalkingSteadinessEvent`、`lowCardioFitnessEvent`、`environmentalAudioExposureEvent`、`headphoneAudioExposureEvent`、`walkingHeartRateAverage`

→ **对写入方案有硬约束**：这些数据你只能"读出来、存到自己的库里"，**不能反向写回 HealthKit**。

**④ 常量名修正（网上流传的错误写法）**

| 错误写法 | 正确常量 |
|---|---|
| `breathingDisturbances` | `appleSleepingBreathingDisturbances` |
| `appleWalkingAsymmetryPercentage` | `walkingAsymmetryPercentage` |
| `appleWalkingDoubleSupportPercentage` | `walkingDoubleSupportPercentage` |
| `audioExposureEvent` | 已废弃 → `environmentalAudioExposureEvent` / `headphoneAudioExposureEvent` |
| `HKDataType` | **该类型在 Apple 文档中不存在**（404）；对应体系是 `HKObjectType` 及其子类 |

**⑤ 已知核查缺口（如实标注）**

`support.apple.com` 的支持文章正文由 JS 渲染，本次**只能取到标题、取不到正文**，因此以下细节**未经 Apple 页面证实，表中未填数字**：

- 高/低心率通知的具体阈值与触发时长；
- 血氧功能的**地区可用性现状**（这个对你的产品上架很关键）；
- 睡眠呼吸暂停通知的机型下限；
- AFib History 的机型下限；
- watchOS 27 官方机型兼容列表。

涉及页面：<https://support.apple.com/en-us/120276>、<https://support.apple.com/en-us/120358>、<https://support.apple.com/en-us/117296>、<https://support.apple.com/en-us/120031>。**建议在能渲染 JS 的浏览器里人工复核这几个数字再定产品文案。**

---

## 3. watchOS 上 HealthKit 的能力边界

### 3.1 官方对 watchOS 的唯一一条总体限制

> "The HealthKit capability is available for iOS and watchOS apps. **watchOS apps can only access certain health data. Clinical Health Records aren't accessible by watchOS apps.**"

来源：<https://developer.apple.com/documentation/Xcode/configuring-healthkit-access>

**注意：Apple 没有给出「watchOS 可用类型白名单」这样的清单。** 判断某个类型能否在手表端用，唯一可靠办法是查该符号自己的 Availability 徽章。本节的表都是这么核对出来的。

另有一条工程细节：**含独立 WatchKit Extension 的 watchOS app，HealthKit capability 必须加在 WatchKit Extension target 上**（不是加在手表 app 主 target）。

### 3.2 watchOS 能力速查表

| 能力 | watchOS | 备注 |
|---|---|---|
| HealthKit framework / `HKHealthStore` | 2.0+ | `isHealthDataAvailable()` 官方称数据在 iOS / watchOS / visionOS 可用 |
| `requestAuthorization(toShare:read:)` | 2.0+ | **watchOS 6+ 直接在手表上弹授权窗** |
| `HKObserverQuery` / `HKUpdateFrequency` | 2.0+ | |
| `enableBackgroundDelivery(...)` | 8.0+ | 需 background-delivery entitlement（watchOS 8.0+） |
| `HKStatisticsCollectionQuery` | 2.0+ | 手表端可做统计查询 |
| `HKActivitySummary` / `Query` | 2.2+ | 活动圆环，**只能读、不能请求写授权** |
| `HKWorkoutSession` | 2.0+ | iOS 侧 17.0+ |
| `HKLiveWorkoutBuilder` / `HKLiveWorkoutDataSource` | 5.0+ | iOS 侧 26.0+ |
| `HKWorkoutRoute` | 4.0+ | |
| `HKQuantitySeriesSampleQuery` | 5.0+ | 读高频/序列数据 |
| `HKHeartbeatSeriesSample` / `Query` / `Builder` | **6.0+** | **RR 间期的来源** |
| `HKHeartbeatSeriesQueryDescriptor` | 8.5+ | Swift Concurrency 版本 |
| `HKElectrocardiogram` / `Type` / `Query` | **7.0+** | 只读 |
| `heartRateVariabilitySDNN` | 4.0+ | |
| `oxygenSaturation` | 2.0+ | |
| `appleSleepingWristTemperature` | 9.0+ | **只读**，不能请求写授权 |
| `.healthDataAccessRequest`（SwiftUI） | 10.2+ | |
| `HKClinicalRecord` / `supportsHealthRecords()` | **无 watchOS** | 手表端不可用 |
| `authorizationViewControllerPresenter` / `handleAuthorizationForExtension` | **无 watchOS** | iOS 扩展授权专用 |

来源：<https://developer.apple.com/documentation/healthkit>、<https://developer.apple.com/documentation/healthkit/hkhealthstore>、<https://developer.apple.com/documentation/healthkit/hkclinicalrecord>、<https://developer.apple.com/documentation/healthkit/hkhealthstore/supportshealthrecords()> 及各符号自身页面。

### 3.3 手表端的 store 里有什么、能不能查历史

官方原文（关键）：

> "**iPhone, Apple Watch, and visionOS each have their own HealthKit store.** … HealthKit automatically syncs data between these devices. **To save space, old data is periodically purged from Apple Watch.** Use `earliestPermittedSampleDate()` to determine the earliest samples available on Apple Watch."

来源：<https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework>

由此：

- 手表**能**做历史查询（`HKSampleQuery`、`HKStatisticsCollectionQuery` 在 watchOS 2.0+ 就有）。
- 但**手表上只有"近期窗口"**，长期数据在 iPhone 端。你的功能 2（手表端看到"全部最新数据"）在"最新"这个词上是成立的，在"全部历史"上不成立。
- `earliestPermittedSampleDate()` 是**系统级约束，对所有 app 一致**，与用户给你的授权范围无关。

**官方没写**：手表本地保留多少天、同步的触发条件与延迟。

### 3.4 ⚠️ 最容易踩的坑：设备锁定时读不到 HealthKit

官方原文：

> "The user's device stores all HealthKit data locally. For security, the device **encrypts the HealthKit store when the user locks the device. As a result, your app may not be able to read data from the store when it runs in the background.** However, your app can still **write** to the store, even when the phone is locked."

来源：<https://developer.apple.com/documentation/healthkit/protecting-user-privacy>

这条和 §5.4 的"后台唤醒"组合起来会产生一个真实的工程矛盾：**系统把你叫醒了，但此时手机可能是锁屏的，你读不到数据。** 所以后台链路必须设计成"读失败就放弃本次、等下次唤醒"，而不是"醒了就必须成功"，更不能因为失败就不调用 completion handler（那会导致投递被彻底停掉，见 §5.5）。

### 3.5 授权（Authorization）的 watchOS 特殊要求

- Info.plist 必须同时设置 `NSHealthShareUsageDescription`（读）和 `NSHealthUpdateUsageDescription`（写），**缺一个会在请求授权时直接崩溃**。
- **watchOS 6 起，用户可以在 Apple Watch 上独立授权**，因此**必须把用途描述加到 WatchKit App Extension 的 Info.plist 里**：
  > "In watchOS 6 and later, users can authorize reading and sharing data on Apple Watch. As a result, **you must add usage descriptions to your WatchKit App Extension.**"
  来源：<https://developer.apple.com/documentation/healthkit/running-workout-sessions>
- `requestAuthorization` 的官方说明：**watchOS 6+ 在手表上弹窗；watchOS 5 及更早必须在配对的 iPhone 上授权**。
  来源：<https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization(toshare:read:completion:)>
- 顺带一条反直觉的：`healthkit` 这个 required device capability **对 watchOS app 不适用**（"The `healthkit` entry isn't used by watchOS apps."）。
- **只能读、不能请求写授权**的类型：`HKElectrocardiogram`、`appleSleepingWristTemperature`、`HKActivitySummary`、临床记录。

**关于"能不能在表盘小组件里请求授权"**：Apple 的 HealthKit 文档**从未直接表态**（这是一个文档空白）。但官方证据链清楚地指向"不能"：扩展进程请求授权要走 host app 的 `handleAuthorizationForExtension` / `authorizationViewControllerPresenter`，而这两个 API **都没有 watchOS 版本**，后者还依赖 UIKit 的 `UIViewController`。

> ✅ 工程结论：**授权只能在主 app 里做，小组件只读已授权的数据。** 顺带一个设计后果——用户要是没先打开过 app 授权，表盘上那个小组件只能是空态，所以首次启动引导和空态设计必须认真做。

### 3.6 高频数据会被系统"压缩"（condensed），读取方式要选对

first-party workout 产生的高频数据会被 HealthKit **condense/coalesce**：原本多条样本被合并成 quantity series，心率还会被合并成带连续时间区间的样本。

- `HKQuantitySample.count > 1` 说明它实际是一个 series，**必须用 `HKQuantitySeriesSampleQuery` 拆开读**。
- 被 condense 的类型包括：`distanceWalkingRunning`、`distanceCycling`、`basalEnergyBurned`、`activeEnergyBurned`、**`heartRate`**。

来源：<https://developer.apple.com/documentation/healthkit/accessing-condensed-workout-samples>

**这对你的项目影响很大**：如果你想要"心率明细曲线"而不是"每小时一个平均点"，就必须走 series query，不能用普通的 `HKSampleQuery` 拿完事。

### 3.7 三个必须承认的"文档空白"

不要把它们当事实，要在真机上验证：

1. watchOS 本地数据保留多久、同步的确切触发条件与延迟；
2. `enableBackgroundDelivery` 在 watchOS 上是否需要先有 `HKWorkoutSession`、或是否必须先在前台跑过一次（官方文档没有这个前提要求，但也没有否认）；
3. widget / complication 能否请求 HealthKit 授权（HealthKit 文档从未直接表态）。

---

## 4. 表盘小组件（Complication）

### 4.1 技术选型：WidgetKit，不是 ClockKit

- 官方明确：**"ClockKit-based complications are deprecated in watchOS 10 and later. Use WidgetKit to create complications."**
- 一旦你提供了基于 WidgetKit 的 complication，**系统就停止调用 ClockKit API**：
  > "As soon as you offer a widget-based complication, the system stops calling ClockKit APIs. For example, it no longer calls your `CLKComplicationDataSource` object's methods to request timeline entries."
- 工程结构：watchOS app + **watchOS Widget Extension target**，用 SwiftUI + WidgetKit。

来源：<https://developer.apple.com/documentation/clockkit>、<https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications>、<https://developer.apple.com/documentation/widgetkit/converting-a-clockkit-app>

> ⚠️ 查 Availability 徽章时有个坑：`CLKComplicationDataSource` 这个 protocol **本身没有 deprecated 标记**（徽章仍写 `watchOS 2.0.0 -`），弃用是在 **ClockKit 框架层级**声明的。别因为看到 protocol 徽章没标就以为还能用。

### 4.2 四种 accessory family

watchOS 上 WidgetKit 只支持 4 个 family（官方明确说这是从 ClockKit 的 12 个收敛来的），**全部 watchOS 9.0+**：

| Family | 出现位置 |
|---|---|
| `accessoryCircular` | 表盘圆形 complication、Smart Stack |
| `accessoryCorner` | **仅 watchOS**，表盘角标（支持沿曲线渲染文字/仪表） |
| `accessoryRectangular` | Smart Stack、表盘矩形 complication |
| `accessoryInline` | 表盘单行文字 complication |

来源：<https://developer.apple.com/documentation/widgetkit/widgetfamily>、<https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy>

**颜色能力有区别**：只有 `accessoryRectangular` 支持 `fullColor`，其余三个在手表上只有 `accented` / `vibrant`（不能用全彩渐变和全彩图片）。做设计时要按这个前提画稿。

**官方没给字符数上限**，处理方式是用 `ViewThatFits` + 系统字体样式自适应：
> "the amount of displayable characters varies depending on the context where the widget appears. On Apple Watch, the size of the inline complication varies depending on the watch face. Include it in a `ViewThatFits` view to make sure text always fits the available space."

来源：<https://developer.apple.com/documentation/widgetkit/creating-views-for-widgets-live-activities-and-watch-complications>

### 4.3 「给每个数据都做一个小组件」到底能做到什么程度

先把两个问题分开：**能定义多少个** 和 **用户能在表盘上放多少个**。

**能定义多少个** —— 官方给了三种做法，没有数量上限：

| 做法 | 适用 | API |
|---|---|---|
| 一个 `WidgetBundle` 里放多个 widget，每个一个 `kind` | 固定的几个指标 | `WidgetBundle` |
| 一个 widget + `AppIntentConfiguration` + `recommendations()` 返回预配置列表 | 指标多、想动态决定 | `WidgetConfigurationIntent`、`AppIntentTimelineProvider`（watchOS 10+） |

**关键坑（watchOS 特有，很容易误判）**：官方明确区分了 iOS 和 watchOS 上 intent 的含义：

> "In iOS, the app intents describe elements that the user can customize. **For WidgetKit complications in watchOS, these intents aren't user configurable. Instead, they represent items that your app can dynamically configure.**"

更进一步：**watchOS 11 及更早没有配置 widget/complication 的界面**：
> "watchOS 11 and older don't have an interface for configuring widgets or complications. If you support older watchOS versions, offer preconfigured complications and widgets."

也就是说：在 watchOS 11 及更早，**用户不能自己"添加一个小组件然后选显示哪个指标"**，只能从你预先准备好的一堆选项里挑。**watchOS 26 起才支持用户自行配置**（`AppIntentConfiguration` 被列为 watchOS 26 新能力）。

来源：<https://developer.apple.com/documentation/widgetkit/making-a-configurable-widget>、<https://developer.apple.com/documentation/widgetkit/converting-a-clockkit-app>、<https://developer.apple.com/documentation/updates/widgetkit>

**用户能在表盘上放多少个** —— 官方**没有给出 per-app 的上限数字**（"一个 bundle 最多 5 个 widget"之类是社区传言，Apple 论坛被机器人验证拦截，**本次未能核实，不作为结论**）。官方只给了这些侧面数字：

- 单个表盘的槽位是有限的（ClockKit 文档举 Modular 表盘为例：一个大的 + 四个小的）；
- **Smart Stack 最多放 3 个 complication**（这是 Smart Stack 的槽位，不是 per-app 配额）。

来源：<https://developer.apple.com/documentation/widgetkit>、<https://developer.apple.com/documentation/clockkit>

> ✅ **工程结论**：你的"每个数据一个表盘小组件"在**能定义**这一层没有障碍，但在**用户实际摆放**这一层受表盘槽位限制。所以正确做法是：**用 `WidgetBundle` 提供覆盖你全部指标的固定一组，同时用 `recommendations()` 让系统/用户在合适场景推荐展示**，而不是假设"指标数量 = 用户能看到的小组件数量"。

### 4.4 刷新预算（这是整个功能的硬约束）

官方给出的数字：

| 指标 | 数值 |
|---|---|
| widget 刷新预算周期 | **24 小时**（窗口跟随使用习惯，不一定午夜重置） |
| 普通 widget（用户常看） | **约 40~70 次/天**，约等于每 15~60 分钟一次 |
| **watchOS complication** | **最多 75 次/天**；且"**表盘上的 complication 永远算作被查看，所以预算偏向上限**" |
| 时间线条目最小间隔 | **至少约 5 分钟** |
| 多实例预算 | "WidgetKit maintains different budgets for each active widget"——每个实例独立预算 |

来源：<https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date>、<https://developer.apple.com/documentation/widgetkit/converting-a-clockkit-app>

**主动刷新与推送**：

- `WidgetCenter.reloadTimelines(ofKind:)` / `reloadAllTimelines()`（watchOS 9.0+）；官方建议先用 `getCurrentConfigurations(_:)` 判断哪些 kind 真的被放在表盘上，避免无谓刷新。
- **APNs 可以更新 widget**：`apns-push-type: widgets`、topic 为 `<bundleID>.push-type.widgets`、body `{"aps":{"content-changed":true}}`；widget extension 需要 Push Notifications capability + `WidgetPushHandler`。
  > 官方 Important：**"Like timeline updates, the system budgets WidgetKit push notifications and delivers them opportunistically"** —— 推送**同样受预算与机会式投递限制**，不是"想推就推"。

来源：<https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications>、<https://developer.apple.com/documentation/widgetkit/widgetcenter>

> ⚠️ 注意这里有个容易搞混的地方：**widget 的刷新预算（~75 次/天）和 watchOS 后台刷新任务预算（~4 次/小时）是两套不同的机制**，不要混为一谈。§5.4 讲的是后者（决定你的 app 能不能被唤醒去干活）。

### 4.5 HealthKit 与小组件：官方文档的盲区 + 唯一可落地的模式

**这是本次调研中最需要"如实说明不确定"的一节。**

官方**没有正面回答**"widget extension 能不能读 HealthKit"。三个空白：

1. ❌ widget extension 能否直接 `HKHealthStore()` 查询健康数据 —— 无官方说明；
2. ❌ 能否在 widget extension 内发起 HealthKit 授权请求 —— 无官方说明（唯一相关的 `handleAuthorizationForExtension` **没有 watchOS 版本**）；
3. ❌ watchOS widget extension 需要哪个 entitlement —— **HealthKit entitlement 的徽章里根本没有 watchOS**（`com.apple.developer.healthkit` 只列 iOS/iPadOS/visionOS），属文档盲区。

**但官方给出了一条明确可依据的落地模式**（这正是我 §6.2 建议的做法，现在有出处了）：

> "the extension target and your app are part of the same app group… **your app can download data and store it in a database in the shared container, and then a widget can access the database**"

并且官方在 Smart Stacks 文档里明确点名了 HealthKit 权限，写法是"**app 和 widget extension 都要请求权限**"：
> "make sure **your app and your widget extension** request a person's permission to access location, workout, or sleep schedule information. For example, you need to request the `HKCategoryTypeIdentifier.sleepAnalysis` permission…"

来源：<https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy>、<https://developer.apple.com/documentation/widgetkit/widget-suggestions-in-smart-stacks>

> ✅ **可安全落地的结论**：**主 app 拿授权 → 把数据写入 App Group 共享容器 → widget extension 只读容器里的快照。** 不要在小组件里直接查 HealthKit。这条路线每一步都有官方原文支撑，且规避了 §3.4 的锁屏读不到问题和引用的授权弹窗问题。

### 4.6 离线可用性，和一个容易踩的坑

**离线能显示 —— 这是官方设计前提**：provider 一次性返回 `Timeline(entries:policy:)` 之后，"When each date in the timeline arrives, WidgetKit invokes the widget's content closure and displays the result" —— 到点直接用**已经拿到的 entry 数据**渲染，不回调 provider、不需要网络。

watchOS 文档的措辞更硬：
> "**It's vital that your app continue to provide useful information even when it can't connect with its companion, so you can't rely on WatchConnectivity as your only means of updating the watchOS app.** Instead, use the WatchConnectivity framework as an **opportunistic optimization**, rather than the primary means of supplying fresh data."

来源：<https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date>、<https://developer.apple.com/documentation/watchOS-Apps/keeping-your-watchos-app-s-content-up-to-date>

> 这段官方原文顺带**独立地**印证了 §5 的架构结论：**不要把 WatchConnectivity 当成主链路。**

**坑：不标记 `privacySensitive` 会显示成占位**

> "If you don't use the `privacySensitive(_:)` view modifier anywhere in your view hierarchy, **the system displays a placeholder instead of a live complication**. By default, the placeholder redacts all of your complication's content."

也就是说：手表锁屏 / Always On 状态下，如果你没用 `privacySensitive(_:)` 标注哪些内容是敏感的，系统会把整个 complication 显示成全遮蔽占位。健康数据显然属于敏感数据，**这一块的交互设计必须专门做**。

来源：<https://developer.apple.com/documentation/widgetkit/converting-a-clockkit-app>

---

## 5. 数据同步架构：手表上传 vs 手机直读

### 5.1 你先问的那个问题，官方答案是

> "iPhone, Apple Watch, and visionOS **each have their own HealthKit store**. ... HealthKit **automatically syncs** data between these devices."

来源：<https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework>

也就是说：**Apple Watch 采集的健康数据会经由 HealthKit 系统机制自动同步到 iPhone 的 HealthKit store，iPhone 上的第三方 app 可以直接查询到。** 你不需要让手表 app 主动"调用接口把数据发给手机"。

两个必须澄清的前提，否则结论会被误用：

1. **只有进入 HealthKit 的数据才会被同步。** 如果你的手表 app 采集了 HealthKit 之外的自有数据（原始传感器流、自定义指标），那 iPhone 端谁也读不到，**这种情况必须自己传**（这才是 WatchConnectivity 的用途）。
2. **没有实时性保证。** 官方只承诺"自动同步"，**从未给出频率、时限或前置条件**。刚测完的数值，手机端不保证立即可读。

### 5.2 iPhone 端能否区分"这是手表来的数据"

可以，官方推荐两条路（**不要**再用已废弃的 `HKMetadataKeyDeviceManufacturerName` 字符串）：

| 你想知道的 | 官方 API |
|---|---|
| 哪个 app / 设备**保存**了该样本 | `HKObject.sourceRevision` → `HKSourceRevision` |
| 来源的版本 / 系统 / 产品型号 | `HKSourceRevision.version` / `.operatingSystemVersion` / `.productType` |
| 产生数据的**硬件** | `HKObject.device` → `HKDevice`（官方原文："Devices include **Apple Watch**, iPhone, and any other health or fitness peripherals"） |

来源：<https://developer.apple.com/documentation/healthkit/hkdevice>、<https://developer.apple.com/documentation/healthkit/hksourcerevision>

### 5.3 什么情况下才真的需要 WatchConnectivity

| 场景 | 需要吗 | 用什么 |
|---|---|---|
| 数据本来就写进 HealthKit | ❌ 不需要 | HealthKit 自动同步 |
| 手表采集的**自有数据**（不写入 HealthKit） | ✅ 需要 | `transferUserInfo(_:)`（FIFO 排队、app 挂起/终止后继续传、不要求对端可达） |
| 运动中的**实时**数据流 | ✅ 需要 | 优先用官方 `HKWorkoutSession` 的 mirroring（`startMirroringToCompanionDevice`），而不是自己搭通道 |
| 只是同步"当前状态/最新一条" | — | `updateApplicationContext(_:)`，但注意它**只保留最新一份，会覆盖历史**，绝不能用来传累积记录 |

关键限制（官方原文）：

- `transferUserInfo` / `updateApplicationContext` **必须在 `activationState == .activated` 时调用**，否则是 programmer error。
- 后台传输**不是即时送达**："background transfers are **not delivered immediately**... the system **may delay transfers slightly to improve power usage**."
- **发送成功 ≠ 送达**：`session(_:didFinish:error:)` 只表示发送端传完，确认送达必须依赖接收端 `session(_:didReceiveUserInfo:)`。
- `sendMessage` 要求 `isReachable == true`（双方前台/高优先级运行），**不适合定时后台场景**。
- 官方要求"只发变化项"以省电；且 `transferUserInfo` **在模拟器上不支持**，必须真机测。

来源：<https://developer.apple.com/documentation/watchconnectivity/wcsession>

### 5.4 后台刷新的硬约束（这条决定架构可行性）

**watchOS 端**（官方原文）：

> "The system budgets the number of background refresh tasks available to an app. In general, the system performs **approximately four tasks per hour** for each app **with a complication on the active watch face**. All the complications on the current watch face **share this budget**."
> "For the system to allocate background execution time to your app, your app **must have a complication on the active watch face**."
> "The system gives your app only **a few seconds** of background execution time."

来源：<https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask>、<https://developer.apple.com/documentation/watchkit/using-background-tasks>

**HealthKit 后台投递在 watchOS 上的频率**（官方原文）：

> "In watchOS, **most data types have an hourly maximum frequency**; however, the following data types can receive updates at `HKUpdateFrequency.immediate`: `highHeartRateEvent`, `lowHeartRateEvent`, `irregularHeartRhythmEvent`, `environmentalAudioExposureEvent`, `headphoneAudioExposureEvent`, `lowCardioFitnessEvent`, `numberOfTimesFallen`, `vo2Max`, `handwashingEvent`, `toothbrushingEvent`."

来源：<https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)>

**由此得到两条对设计有决定性影响的结论**：

1. **功能 3（表盘小组件）不是可选项，而是功能 4（定时同步）的前置条件** —— 没有活动表盘上的 complication，watchOS 就不给后台执行预算。
2. **"定时"在 watchOS 上最多是"每小时几次"**，且系统可能推迟或节流。官方明确要求："don't expect the system to trigger every background task. **Design a fallback mechanism** so your app behaves correctly even when throttling occurs."

**entitlement 要求**：iOS 15 / watchOS 8 起必须为 app 添加 `com.apple.developer.healthkit.background-delivery`，否则 `enableBackgroundDelivery` 直接以 `errorAuthorizationDenied` 失败。且**后台查询在模拟器上不支持，必须真机测试**。

来源：<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit.background-delivery>

### 5.5 iPhone 端推荐链路（正确姿势）

容易踩的坑：**`HKAnchoredObjectQuery` 不能注册后台投递**（官方原文："you **can't register anchored object queries for background delivery**"）。所以正确组合是：

```
enableBackgroundDelivery + HKObserverQuery   → 负责"后台把我叫醒"（只告诉你"有变化"，不含内容）
        ↓ 被唤醒后
HKAnchoredObjectQuery + 持久化 HKQueryAnchor → 负责"拉增量"（含新增样本 + deletedObjects）
        ↓
本地库落库（SwiftData / GRDB / Core Data）+ 用 HKDevice/HKSourceRevision 标注来源
```

三条必须做对的细节（官方原文）：

1. **在 `application(_:didFinishLaunchingWithOptions:)` 里就注册好所有 observer query**，否则后台唤醒时查询还没准备好。
2. **必须调用 completion handler**：不调用会触发 backoff 算法，"If your app **fails to respond three times**, HealthKit assumes your app can't receive data and **stops sending background updates**."
3. **必须持久化 anchor 并处理 `deletedObjects`**，否则本地副本会残留已删除样本、或重复拉取。
4. **要能容忍"被叫醒但读不到"**：设备锁定时 HealthKit store 是加密的，后台可能读不出数据（见 §3.4）。正确做法是「读失败 → 记录、放弃本次、仍然调用 completion handler、等下次唤醒」，而不是重试到超时或干脆不回调。

来源：<https://developer.apple.com/documentation/healthkit/executing-observer-queries>、<https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery>、<https://developer.apple.com/documentation/healthkit/executing-anchored-object-queries>

### 5.6 同步延迟：官方没说的部分

- **官方只说"automatically syncs"**，未给频率、时限、前置条件。**未找到**任何 Apple 文档说明"是否需要 iPhone 在附近 / 是否需要解锁 / 最长多久"。
- 因此对 app 的正确假设是：**刚做完测量，手机端不保证立即可读**。UI 上应展示"最后同步时间"，而不是暗示"实时"。
- 相关论坛讨论（thread 780012、780009）因 Apple 论坛的机器人验证**抓取被拦截，内容无法核实**。

### 5.7 手表本地到底存不存？会不会全同步到手机？

这是最容易误解的一节，先把官方原文完整摆出来：

> "**iPhone, Apple Watch, and visionOS each have their own HealthKit store.** iPadOS 17 and later also has its own HealthKit store. … **HealthKit automatically syncs data between these devices. To save space, old data is periodically purged from Apple Watch.** Use `earliestPermittedSampleDate()` to determine the earliest samples available on Apple Watch."

来源：<https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework>

**逐句拆解（三个结论，注意它们的强度不同）：**

| 问题 | 官方是否明确 | 结论 |
|---|---|---|
| 手表本地会不会保存？ | ✅ **明确** | **会。** Apple Watch 有**自己的** HealthKit store，不是"只上传不落地"，也不是 iPhone store 的镜像 |
| 会不会自动同步到手机？ | ✅ **明确** | **会。** "HealthKit automatically syncs data between these devices" —— 这是**系统行为，不需要你的 app 写任何传输代码** |
| 是不是"全部"都同步？ | ❌ **文档没写** | 官方**只承诺"自动"，没有承诺范围、完整性、时机、延迟上限**。因此"全部都会同步"这个说法**不能从官方文档推出** |
| 有没有 API 能主动触发同步？ | ❌ **未找到** | 官方文档中没有"立即同步"之类的接口 |

**关键那句是 "old data is periodically purged from Apple Watch"**：
- 手表本地保存 ✅，但它是**滚动窗口，不是永久档案**；
- 旧数据会被系统**定期清除**（理由是省空间）；
- `earliestPermittedSampleDate()` 就是让你查"手表上最早还剩到哪一天"的。

`earliestPermittedSampleDate()` 官方补充：早于该日期保存会 `errorInvalidArgument`，早于该日期查询只返回该日期之后的样本；且**这是系统级约束，对所有 app 一致，与用户给你多少授权无关**。
来源：<https://developer.apple.com/documentation/healthkit/hkhealthstore/earliestpermittedsampledate()>

**设计意图的推论**：既然手表只是"缓存 + 定期清理"，那被清掉的原始数据必然另有一份长期档案——**iPhone 是长期档案，Apple Watch 是滚动缓存**。这也从系统设计层面解释了为什么"手表 → 手机"的同步是默认且必要的。

> ⚠️ **一个官方没写、但会影响设计的点**：手表 store 里除了手表自己产生的数据，**是否也包含从手机同步过来的数据**，官方文档没有说明（原文只说设备间自动同步，没说同步方向或范围）。不要对此做任何假设，真机探测时一并验证。

**对项目的三条具体影响：**

1. **手机端读健康数据不需要你写传输代码**，这是系统干的 → 进一步印证 §5.1：功能 4 里"手表打包上传到手机"这件事基本不用做。
2. **手表端 app 读不到全量**。手表 app 读本地 store 只能拿到近期窗口，所以"在手表上看到**最新**数据"成立，"看到**全部**数据"不成立。
3. **这正是你要在手表上自建一层缓存的理由**：Apple 会定期清掉手表上的旧数据，你的 app 把这部分"锚"下来，才能给用户连续的体验。

### 5.8 手表端能不能直接传数据到服务器？——**能，而且是官方支持的模式**

**结论：可以。** 官方原文：

> "Your watchOS app **can connect directly to web services** and other online sources. When making these requests, the system can send data through **a paired iPhone as a proxy, over a known Wi-Fi network, or over the watch's own cellular connection**."
> "**Always upload and download data using a `URLSession` background transfer. Background transfers occur in a separate process and continue to transfer data even after your app terminates.** Asynchronous uploads and downloads, on the other hand, suspend with your app. Because watchOS apps have a short runtime, you can't guarantee that an asynchronous transfer finishes before the app suspends."

来源：<https://developer.apple.com/documentation/watchOS-Apps/keeping-your-watchos-app-s-content-up-to-date>

**这条"后台传输跑在独立进程"是关键的松动点**：手表后台只有"几秒"执行时间，本来会让人以为长上传不可能——但 `URLSession` 的 **background** 传输不占用那几秒，它在独立进程里继续跑，app 挂起甚至被终止都不影响。

**触发频率正好能对上"定时上传"**：

> "If your app has a complication on the active watch face, it can receive **up to four `WKURLSessionRefreshBackgroundTask` tasks per hour**. To avoid throttling, use the `earliestBeginDate` property to schedule background URL session tasks **no closer than 15 minutes apart**."

来源：<https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask>（watchOS 3.0+）

**但必须接受这 5 条硬约束：**

| # | 约束 | 后果 |
|---|---|---|
| 1 | 后台**必须**用 `URLSessionConfiguration.background`，不能用手写的 async upload | 用错就会"传一半被挂起" |
| 2 | 每小时**最多 4 次**，官方建议间隔 **≥ 15 分钟** | "定时"的现实下限就是 15 分钟一次，不是秒级 |
| 3 | **前提仍是表盘上有你的 complication** | 用户不装小组件 → 后台传输任务不给（§5.4） |
| 4 | 网络三条路由：iPhone 代理 → 已知 Wi-Fi → 手表蜂窝（仅 GPS+Cellular 机型）。**三条都不通就失败** | 用户手表没蜂窝、出门没带手机、又不在已知 Wi-Fi 上 → 传不出去，必须能积压待传 |
| 5 | 手表上的 HealthKit **只有近期窗口**，旧数据已被清除（§3.3） | **手表端无法补传历史数据**，回填只能靠 iPhone |

**官方还给了 CloudKit 这条路**（可以完全不用自己搭服务器）：
> "CloudKit includes support for `CKSubscription` and notifications in watchOS 6 and later… This makes **CloudKit a potential replacement for WatchConnectivity for independent apps**."

来源：同上。

#### 两种上传方案对比

| | 手表直传 | 手机端上传 |
|---|---|---|
| 延迟 | 更低（数据产生在手表） | 取决于 HealthKit 同步延迟（**无官方保证**，§5.6） |
| 数据完整性 | ❌ 只有近期窗口，无法回填历史 | ✅ iPhone 上有全量 |
| 可靠性 | ⚠️ 受三条网络路由 + 4 次/小时限制 | ✅ 更好，可配合后台传输 |
| 工作量 | 需要手表端上传逻辑 + 独立的重试/积压 | 集中在 iOS 端 |

#### ✅ 我的建议：**双端都传，用 `HKObject.uuid` 去重**

这不是妥协，而是这个场景下最优解，因为 HealthKit 对象**天然带全局唯一 UUID**，服务端按 UUID 做幂等去重几乎零成本：

- **手表端**：负责"**低延迟增量直传**"——只传上次 anchor 之后的新样本，用 background URLSession 排队上传；
- **iPhone 端**：负责"**全量 + 历史回填 + 兜底**"——它才有完整数据，也是手表传失败时的最终保障；
- **服务端**：按 `HKObject.uuid` 幂等 upsert，两端谁先到都不影响结果。

这样一来，手表端的 4 次/小时和网络路由限制都不再是"数据会不会丢"的问题，只影响"数据多快到"，而这是可以接受的降级。

---

## 6. 整体架构方案（初稿）

### 6.1 组件划分

```
┌─ watchOS App（SwiftUI）
│   ├─ 主界面：指标卡片列表（最新值 / 单位 / 采集时间 / 数据来源）
│   ├─ HealthKit 读取层：读手表本地 store（近期窗口）
│   ├─ 本地缓存：SwiftData（watchOS 10+）或 SQLite
│   ├─ 快照写入 App Group 共享容器 ←─┐
│   └─ 后台任务：刷新快照 + 补拉数据   │
│                                    │
├─ watchOS Widget Extension（WidgetKit）
│   └─ 表盘小组件 / Smart Stack：只读快照，不查 HealthKit、不请求授权
│
└─ iOS App
    ├─ 数据总览 / 历史曲线 / 设置
    ├─ HealthKit 增量同步层：
    │   enableBackgroundDelivery + HKObserverQuery（后台唤醒）
    │         ↓
    │   HKAnchoredObjectQuery + 持久化 HKQueryAnchor（拉增量）
    │         ↓
    │   SeriesQuery（心率等被 condense 的数据拆明细）
    ├─ 本地库：SwiftData / GRDB（全量，含 deletedObjects 处理）
    └─（可选）上传自有服务器
```

### 6.2 数据流与"谁负责什么"

| 环节 | 由谁负责 | 依据 |
|---|---|---|
| 数据采集 | **Apple Watch 系统**（不是你的 app） | 你无法控制采样频率，只能读 |
| 手表 ↔ 手机同步 | **HealthKit 系统机制** | §5.1 |
| 手机端落库 | 你的 iOS app，增量拉取 | §5.5 |
| 手表端展示 | 你的 watchOS app，读本地 store + 自有缓存 | §3.3 |
| 表盘展示 | Widget extension，读 **App Group 里的快照** | §4.5 |

**关键设计选择：小组件不要直接查 HealthKit，而是读主 app 写好的快照。**

这不是我的发明，**Apple 官方文档明确推荐的就是这个模式**（§4.5）：
> "your app can download data and store it in a database in the shared container, and then a widget can access the database"

理由有四条，都是上面 §3/§4 的官方约束推出来的：

1. **官方支持**：App Group 共享容器是官方给出的扩展取数范式（§4.5），且每一步都有原文出处；
2. 小组件渲染有严格时间预算，HealthKit 查询 + 授权状态检查会拖慢 timeline 生成；
3. 设备锁定时可能读不到 HealthKit（§3.4），小组件会直接白屏；
4. 主 app 可以在后台任务里把"要展示什么"算好（比如"今天的 HRV 对比 7 天均值"），小组件只做渲染，逻辑简单、不易出错。

### 6.3 缓存设计建议

- **快照表**：每个指标一行 = 最新值 + 单位 + 采样时间 + 来源设备（`HKDevice`）+ 快照写入时间。小组件和手表主界面都读它。
- **时序表**：原始样本，用于画曲线。手表端只保留近期（例如 7~30 天）+ 按天聚合的长期数据；**手机端保留全量**。
- **同步游标**：手机端每类数据一个 `HKQueryAnchor`，持久化在本地库，绝不能用内存变量。
- **去重**：以 `HKObject.uuid` 为主键，天然幂等；同时处理 `HKDeletedObject`。

### 6.4 风险清单（按严重程度排序）

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| 1 | **`HKHeartbeatSeriesSample` 实际可能没有数据** | RR 间期功能做不出来 | **第一天就写真机探测器**（§1.6）；方案上同时准备 ECG 路径兜底 |
| 2 | 设备锁定时后台读不到 HealthKit | 后台同步失败率上升 | 失败的唤醒不消耗投递额度、不重试轰炸；以"下次成功"为正常态 |
| 3 | watchOS 后台预算 4 次/小时且**依赖表盘上的 complication** | "定时"只能做到小时级，且用户不装小组件就没有后台 | 产品文案不要承诺"实时"；把"装表盘小组件"做成引导流程 |
| 4 | 心率等高频数据被 condense | 拿到的可能是"区间样本"而非逐点 | 明细走 `HKQuantitySeriesSampleQuery` |
| 5 | HealthKit 数据不能用于广告等用途，用途描述必须真实 | 审核被拒 | 用途描述与实际功能严格一致；隐私政策要写清楚 |
| 6 | 模拟器不支持后台投递、不支持 `transferUserInfo` | 开发期难以验证 | 计划里必须包含真机测试环节 |
| 7 | watchOS 11 及更早**没有小组件配置界面** | 用户不能自选"这个小组件显示哪个指标" | 用 `WidgetBundle` 预定义一组 + `recommendations()` 给预配置列表（§4.3） |
| 8 | 锁屏 / Always On 下未标记 `privacySensitive` 会显示为**全遮蔽占位** | 表盘上看到的可能是空白占位而非数据 | 显式用 `privacySensitive(_:)` 标注，并专门设计锁屏态（§4.6） |

---

## 7. 需要你拍板的决策点

下面每条都会实质影响架构和工作量，**建议按顺序确认**。

### 7.1 最低支持版本

先对齐一下时间基准：**当前最新是 watchOS 27**（2026 年 9 月发布，最新小版本 27.0.1），上一代是 watchOS 26。

| 选项 | 能用的东西 | 代价 |
|---|---|---|
| **watchOS 10+ / iOS 17+（推荐）** | SwiftData、WidgetKit accessory 全家桶、SwiftUI 新 API 都齐 | 放弃 watchOS 9 及更早；**拿不到 27 才有的 RMSSD 类型** |
| watchOS 8+ / iOS 15+ | HealthKit 后台投递可用 | 缓存层不能用 SwiftData，要上 Core Data/GRDB；小组件要写两套 |
| watchOS 6~7 | heartbeat series 可用 | 大量 API 缺失，不建议 |
| watchOS 27+ | 可用 `heartRateVariabilityRMSSD` | ❌ **不现实**，会排除几乎所有存量设备 |

**我的建议**：**最低支持 watchOS 10+ / iOS 17+，把新 API 做成能力门控。**

也就是说：基础功能按 watchOS 10 写，遇到 watchOS 27 才有的东西（如 `heartRateVariabilityRMSSD`）用 `if #available(watchOS 27, *)` 包起来做增强。这样既不会为了一个新类型抬高门槛，也不会在 27 设备上浪费能力。

### 7.2 产品定位：被动采集，还是主动测量？

| 路线 | 数据 | 用户操作 | 结论 |
|---|---|---|---|
| **被动（推荐做主）** | 心率、HRV(SDNN)、睡眠、活动、血氧、腕温 | 零操作 | 但**采样时机由 Apple 决定**，你无法控制频率 |
| 主动 | ECG 30 秒电压波形 → 自己算 RR | 用户每天主动测 | 唯一能拿到高质量原始波形的路，但依从性差 |

**建议**：被动为主 + ECG 作为"深度分析"入口。**不要设计"连续 RR 监测"这类需求，HealthKit 做不到**（§1.5）。

### 7.3 数据边界 —— ✅ **已确认：全量健康数据**

你选了全量（心率、HRV、RR、睡眠、血氧、呼吸、腕温、活动、步态、体能训练…）。**三条必须提前知道的后果**：

1. **授权弹窗会很长**：用户要逐项勾选，容易中途放弃或只给部分权限。**架构上必须把"部分授权"当正常情况处理**，每个指标都要有独立的空态，不能假设"授权了就有数据"。
2. **小组件数量多**：按 §4.3，watchOS 11 及更早用户无法自己配置，你要用 `WidgetBundle` 预定义一组 + `recommendations()` 排序推荐，不能指望用户自己去挑。
3. **开发量翻倍**：建议数据层做成**通用的"指标注册表"**（一个指标 = 一个 `HKObjectType` + 单位 + 读取方式 + 展示元数据），而不是给每个指标写一遍逻辑。全量场景下这是必须的，否则代码会失控。

#### ⚠️ 全量方案下最容易踩的坑：**API 在 watchOS 上可用 ≠ 数据由手表产生**

这条我已经逐个核对过官方原文，是真的，而且**足以让"全量"方案做错产品**：

**「步态/移动」这一类指标的数据源其实是 iPhone，不是 Apple Watch：**

| 指标 | 官方原文 | 实际数据源 |
|---|---|---|
| `appleWalkingSteadiness` | "The system automatically records Walking Steadiness samples **on iPhone 8 or later**. The user must carry their phone near their waist—such as in a pocket… The system creates a Walking Steadiness sample **every 7 days**" | ❌ iPhone（手机需放腰附近） |
| `walkingAsymmetryPercentage` | "The system automatically records walking asymmetry samples **on iPhone 8 or later**… The system records **10 to 30** walking asymmetry samples on a typical day." | ❌ iPhone |
| `walkingDoubleSupportPercentage` / `walkingSpeed` / `walkingStepLength` | 同上同类表述 | ❌ iPhone |

来源：<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applewalkingsteadiness>、<https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/walkingasymmetrypercentage>

**注意这里的两层信息**：
1. 这些符号的 Availability 徽章**确实写着 watchOS 可用**（`appleWalkingSteadiness` 是 watchOS 8.0+）——所以"符号可用"这件事**完全不说明数据来自手表**；
2. 你的手表 app 只要能读到已同步的数据就能显示它们，但**数据实际由 iPhone 的传感器产生**，用户不随身带手机时就不会有新数据。轮椅状态开启时，这些样本完全不产生。

> ✅ **给你的方法论**：做全量方案时，**每一个指标都要单独问一句"这数据到底是谁产生的？"**，不能靠 Availability 徽章推断。这正是我把 §2 的数据类型全表逐条标注"产生来源"的原因。

### 7.4 数据去向 —— 待你确认最后一件事

**你的问题"手表能不能直接传服务器"已经查清了：能，官方支持**（详见 §5.8）。

关键结论：

- 手表端**可以**直接 `URLSession` 上传，系统会自动选路（iPhone 代理 / 已知 Wi-Fi / 手表蜂窝）；
- **后台必须用 background URLSession**，它在独立进程里跑，app 终止也继续传；
- **每小时最多 4 次 `WKURLSessionRefreshBackgroundTask`**，官方建议间隔 ≥ 15 分钟 —— 这就是"定时上传"的现实上限；
- 前提还是**表盘上有你的 complication**（§5.4）；
- ⚠️ **手表上只有近期 HealthKit 数据，无法回填历史** —— 历史数据只有 iPhone 有。

因此我建议**双端都传 + 服务端按 `HKObject.uuid` 幂等去重**（§5.8 详述）：手表端管低延迟增量，iPhone 端管全量与历史兜底。

**还需要你回答**：你有没有自己的后端？

- **有**：那我们按 §5.8 的双端上传设计，需要确认 API 形态（批量、幂等键、鉴权方式）。
- **没有，也不想搭**：那官方给的答案是 **CloudKit** —— 手表和手机都能直接写，不需要自己维护服务器。这是个可以省掉整个后端的选择。

### 7.5 RR 间期的真实用途（决定技术路线）

| 你想要的 | 可行方案 |
|---|---|
| 只要一个 HRV 数值 | 用系统的 `heartRateVariabilitySDNN`（watchOS 4+，覆盖面最广，零成本） |
| 要 **RMSSD**（短时 HRV 标准指标） | 🆕 watchOS 27+ 有现成的 `heartRateVariabilityRMSSD`；**老系统上只能读 heartbeat series 自己算** |
| HRV + 想看逐拍分布（散点图、Poincaré） | 读 `HKHeartbeatSeriesSample`（**需真机验证有没有数据**） |
| 想要 30 秒心电波形、自己做 R 波检测 | 读 `HKElectrocardiogram`，但必须用户主动测量 |
| 想要全天连续逐拍 | ❌ **HealthKit 不提供，需要改需求** |

### 7.6 小组件形态

调研结论（§4.3）让这个问题变得具体了——**关键分水岭是 watchOS 版本**：

| 最低版本 | 用户能否自己选"这个小组件显示哪个指标" | 你该怎么做 |
|---|---|---|
| watchOS 10 / 11 | ❌ 不能，**没有配置界面** | 必须用 `WidgetBundle` 预先定义好一组，或用 `recommendations()` 给预配置列表 |
| **watchOS 26+** | ✅ 能（`AppIntentConfiguration`） | 可以只做一个可配置小组件 |

所以：

- 若最低支持 **watchOS 26**：一个可配置 widget 最优雅，工作量最小；
- 若最低支持 **watchOS 10/11**（更现实，覆盖机型广）：**必须**用 "`WidgetBundle` 多 widget" 或 "预配置推荐列表" 的方式，**"每个指标一个小组件"在这个层面对应的是"每个指标一个 `kind`"**，是可以做的，但用户在表盘上的摆放数量受表盘槽位和 Smart Stack 3 个槽位的限制。

我的建议：**`WidgetBundle` 提供固定的一组（心率/HRV/血氧/睡眠…按 §7.3 的数据边界定），配上 `recommendations()` 让 Smart Stack 在合适时机推荐。** 单个表盘能放几个由用户决定，你在引导里说清楚就行。

### 7.7 前置条件（非技术，但会卡进度）

- ✅ 一台**真机 Apple Watch**：HealthKit 后台投递、`transferUserInfo` **在模拟器上都不工作**，必须真机。
- ✅ Apple Developer Program（¥/$99 一年）：HealthKit entitlement、真机调试、TestFlight 都需要。
- ✅ 手表系统版本必须 ≥ 你选的最低支持版本。
