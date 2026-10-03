# 手表端 App —— 设计方案

> 对应代码：`watch/`。落地步骤（Xcode 配置、entitlement、App Group）见 `watch/README.md`。
> 事实依据：`docs/AppleWatch健康数据App-可行性调研.md`（每条结论都带 Apple 官方链接）。

---

## 0. 设计原则：**不追求数据完整性**（已确认）

> "数据只需要做到有的就收集，没有的就没有，不用强求完整性。"

这条原则一次性砍掉了一整类设计焦虑。**下面这些，本设计明确不做**：

| 不做的事 | 原因 |
|---|---|
| ❌ 不做历史回填 | 手表上 HealthKit 只有近期窗口，拿不到就是拿不到；长期档案在 iPhone |
| ❌ 不做缺口检测 / 补数 | 不判断"哪段时间缺数据"，不为此重跑同步 |
| ❌ 不做失败重试直到成功 | 单次同步失败只记日志，下次跑到什么算什么 |
| ❌ 不强求"测完立刻能读到" | HealthKit 同步延迟官方无任何承诺，读到什么就用什么 |
| ❌ 不为"未授权指标"做特殊处理 | 每个指标独立空态，没数据就不显示这一行 |
| ❌ 不做与 HealthKit 的完整对账 | 不保证本地副本 == HealthKit 全量 |

### ⚠️ 但有两个问题**不属于**"完整性"，不能一起砍掉

| 保留的事 | 为什么必须保留 |
|---|---|
| **7 天保留窗口**（§1.2、§6） | 这是**磁盘空间**问题，不是完整性问题。心率每 5 秒一条 → 7 天就是 12.1 万行，**不做保留限制手表会被撑爆** |
| **处理 `HKDeletedObject`** | 这是**正确性**问题。用户删了数据你还显示，就是显示错误信息——而修复它只需要一行代码 |
| **分页拉取**（`limit: 2000`） | 这是**内存/超时**问题。一次拉 1.7 万条会 OOM 或超时被杀 |

> 一句话区分：**放弃"补齐没有的数据"，但继续控制"已有的数据别撑爆设备"。**

### 这条原则带来的正面效果

现有实现本来就符合这个方向，不需要改动逻辑，只需要**停止担心**：

- `syncAll` 已经是"逐指标跑、失败只记录、继续下一个"；
- 快照只包含**有数据的**指标，没数据的指标直接不出现在列表里（不是显示 `—`）；
- 后台被节流、锁屏读不到、只授权了一部分 —— 全部按"正常情况"处理。

**唯一按此原则顺手调小的是首次同步回看窗口**（见 `MetricCatalog.initialLookbackDays`）：
既然不追求完整，首次同步就没必要往回拉很久，窗口越小首次同步越快、越不容易超时。

---

## 1. 你做的手表端三件事，对应到代码

| 你的需求 | 实现位置 | 状态 |
|---|---|---|
| 1. 定期读取增量，全部存到手表 app | `HealthSyncEngine` + `HealthStore` + `BackgroundCoordinator` | ✅ 已实现 |
| 2. 提取最新值缓存，给小组件用 | `SnapshotService` + `SharedContainer` | ✅ 已实现 |
| 3. 上传数据（预留） | `UploadTransport` + `PendingUploadRecord` | ✅ 已预留，只入队不发送 |

### 1.1 基线（已确认）：只支持 watchOS 27.0+ / Apple Watch Series 12

这个约束**简化**了三件事：

| 原来的顾虑 | 现在的状态 |
|---|---|
| 要兼容 watchOS 10/11，小组件**不能配置**，得用 `WidgetBundle` 堆一堆固定 widget | ✅ watchOS 26+ 支持用户配置 → **一个 `AppIntentConfiguration` 可配置小组件搞定**，加指标不用改 widget 代码 |
| 要给每个新 API 套 `#available` 分支 | ✅ 全去掉 |
| SE 3 没有 ECG / 血氧 / 水深传感器，要处理能力差异 | ✅ S12 传感器齐全，不用管 |

但它**新增**了一件必须认真处理的事：**数据量**。

### 1.2 ⚠️ 由 S12 引发的新问题：心率密度暴涨

Apple 官方（Newsroom, 2026-09-09）：

> "With larger, power-efficient green LEDs on the optical heart sensor, Apple Watch Series 12 and Apple Watch Ultra 4 now **measure heart rate every five seconds, all day long**."

再对照 Apple 2024 年那份心率白皮书里的**官方原始节奏**：

| 数据 | 旧节奏（白皮书原文） | S12 之后 |
|---|---|---|
| 后台心率 | "attempts to report one heart rate in bpm **every 5 minutes**"（仅在静止时） | **每 5 秒**，全天 |
| 运动中心率 | "In every non-overlapping **five seconds** window … publish to HealthKit" | 不变（本来就是 5 秒） |
| HRV | "default tachogram cadence is **every four hours**"；开启不齐律通知→2 小时；AFib History→**15 分钟** | "as often as every 5 minutes" |

**算账**：每 5 秒一条 = **17,280 条/天**。原设计保留 90 天 = **155 万行**，手表存不下。

> ❗ **但有一个关键未知**：Apple 只说了手表"**测量**"的节奏，
> **没有说多少条会真正写进 HealthKit**。完全可能 5 秒数据只服务于手表自己的算法，
> HealthKit 仍然是 5 分钟一条。**这个只能真机实测**（测量方法见 `watch/README.md` 第五节）。

因此存储策略定成一条极简规则：**本地只保留最近 7 天，所有指标统一**。

```
SampleRecord（落盘在手表硬盘）
   ↑ 增量写入
   7 天窗口内的全部样本
   ↓ 超期即删（StoragePolicy.retentionDays = 7）
```

**为什么 7 天是安全的**：最坏情况 `17,280 条/天 × 7 天 ≈ 12.1 万行`，
SwiftData 落盘几十 MB，Apple Watch 完全放得下。而且**增量同步只拉新增样本**，
本地行数多不会让同步变慢。配合 `#Index<SampleRecord>([\.metricID, \.startDate], [\.startDate])`
索引，"取最新一条"和"按日期删过期"都不会全表扫描。

**之前那版"分层聚合"已经删掉**：它原本是为了"长期保留 + 压缩体积"，
现在既然不留长期，聚合就只剩额外复杂度（水位线、聚合顺序约束、快照兜底），收益为零。

保留下来的两个实现细节：
- **分页拉取**：官方建议给 `HKAnchoredObjectQuery` 一个 `limit` 并从返回的 anchor 继续，
  而不是按日期翻页（`HealthSyncEngine.pageSize = 2000`）——这是**内存/超时**问题，必须保留；
- **落盘而非内存**：`ModelConfiguration(isStoredInMemoryOnly: false)`，启动时打印 store 路径便于核对。


---

## 2. 一条必须先接受的硬约束：**"定期"在 watchOS 不是你说了算**

你的需求 1 写的是"定期执行读取数据"。这句话在 watchOS 上必须重新表述，因为官方规则是：

| 规则 | 官方原文 | 影响 |
|---|---|---|
| 后台刷新约 4 次/小时 | "the system performs **approximately four tasks per hour**" | "定期"的实际粒度是 **≈15 分钟**，不是秒级/分钟级 |
| **必须有 complication** | "your app **must have a complication on the active watch face**" | 用户不装小组件 → **后台预算为 0** |
| 只有"几秒" | "The system gives your app only **a few seconds** of background execution time" | 一轮同步必须能在几秒内结束或优雅放弃 |
| 只是"不早于" | "attempts to trigger your background task **no earlier than** the time specified" | 系统可以推迟、可以节流，**不能假设准时** |
| 锁屏读不到 | "the device **encrypts the HealthKit store when the user locks the device**. As a result, your app may not be able to read data from the store when it runs in the background" | 被唤醒了也可能读失败，**这是正常情况不是 bug** |

### 因此本设计采用「双路径」而不是「定时任务」

```
     ┌─────────────────────────────────────────────┐
     │  路径 A：前台同步（主路径，一定成功）        │
     │  用户打开 app → 时间充足 → 跑完整一轮        │
     └─────────────────────────────────────────────┘
     ┌─────────────────────────────────────────────┐
     │  路径 B：后台补同步（机会式，可能不发生）    │
     │  系统唤醒 → 8 秒硬预算 → 超时就放弃，下次再来 │
     └─────────────────────────────────────────────┘
```

**每次同步结束都重新排下一次后台刷新**——这是官方要求的降级设计：
> "don't expect the system to trigger every background task. **Design a fallback mechanism** so your app behaves correctly even when throttling occurs."

### 为什么不用 `HKObserverQuery` + `enableBackgroundDelivery`

技术上可以（watchOS 8+ 支持），但本场景**不需要**：

- 官方明确 `HKAnchoredObjectQuery` **不能注册后台投递**，所以真要做得是
  "observer 负责唤醒 + anchored 负责拉数据"两套机制；
- 而我们的目标只是"定期把数据抄进自己库里"，**被唤醒后跑一次 anchored query 就够了**；
- 少一个长期存活的查询，就少一类生命周期 bug，也少一份后台预算消耗。

> 例外：如果将来要做**低延迟通知类**功能（例如心率异常要立刻提醒），
> 那时才需要引入 observer——因为 watchOS 上只有少数事件类型支持 `.immediate`
> （`highHeartRateEvent`、`lowHeartRateEvent`、`irregularHeartRhythmEvent` 等，
> **普通心率/HRV/血氧都不在里面**）。

---

## 3. 数据流

```
Apple Watch 系统采集（你无法控制频率）
        │
        ▼
  HealthKit store（手表本地，★旧数据会被系统定期清除）
        │
        │  HealthSyncEngine：HKAnchoredObjectQuery + 持久化 anchor
        ▼
  app 自己的 SwiftData 库（SampleRecord）  ←── 只有这里才不会被系统清理
        │
        ├──▶ SnapshotService：取每个指标最新值 → 格式化
        │            │
        │            ▼
        │     App Group: latest-snapshot.json  ←── 小组件只读这个文件
        │
        └──▶ PendingUploadRecord 队列（功能 3 预留，本版不发送）
```

**关键点**：数据在手表上存了**两份**——
一份是系统的 HealthKit store（会被清理），一份是你自己的 SwiftData 库（不会被清理）。
这正是"手表端缓存"存在的意义。

---

## 4. 三个关键设计决策（及理由）

### 决策 1：增量用持久化的 `HKQueryAnchor`，而不是每次全量查

- `HKAnchoredObjectQuery` 在 anchor 为 nil 时返回 **store 里全部匹配样本**。
  S12 最坏情况心率每 5 秒一条 = 17,280 条/天——手表后台只有几秒，**必然超时被杀**。
- 所以：**首次同步限定回看窗口**（`MetricDescriptor.initialLookbackDays`，
  按"不追求完整性"原则刻意取小：心率 **1 天**、其它默认 **3 天**），
  之后的增量全部交给 anchor。
- **分页拉取**：给查询一个 `limit`（`pageSize = 2000`）并从返回的 anchor 继续——
  这是官方建议的做法，比按日期翻页更能扛住密度暴涨。
- anchor **必须持久化**（`SyncAnchorRecord`）。放内存里会在 app 被杀后丢失，
  下次就变成全量重拉。
- 同时必须处理 `HKDeletedObject`：用户在健康 App 里删了数据，你的本地副本也要删。
  （这属于**正确性**，不属于被砍掉的"完整性"，见 §0。）

### 决策 2：小组件不查 HealthKit，只读 App Group 里的快照文件

三个理由，每个都有官方依据（调研 §4.5）：

1. **官方推荐的就是这个模式**："your app can download data and store it in a database
   in the shared container, and then a widget can access the database"；
2. **锁屏时小组件会白屏**：设备锁定时 HealthKit store 加密，扩展进程很可能读不到；
3. **时间预算**：小组件渲染窗口很紧，查 HealthKit 会拖慢 timeline 生成。

顺带一个好处：**手表主界面也读同一份快照**，所以"用户在主界面看到的"和
"表盘上显示的"永远是同一份数据，不会出现两个地方数字不一致。

> 为什么快照用 JSON 文件而不是在共享容器里再放一个 SwiftData 库？
> 多进程同时打开同一个 SQLite 有并发和版本迁移风险；
> 小组件只是只读展示层，给它一个原子写入的小 JSON 最稳。

### 决策 3：上传队列与传输方式解耦

`PendingUploadRecord`（队列）+ `UploadPayload`（协议中立的载荷）+ `UploadTransport`（传输）。

这样无论最后选哪条路，**上层的同步和存储代码一行都不用改**：

| 最终选择 | 实现什么 | 必须记住的官方约束 |
|---|---|---|
| 传给手机 app | `WatchConnectivityTransport`（`transferUserInfo`） | 必须在 `activationState == .activated` 时调用；只保证入队不保证送达；**模拟器不支持** |
| 直传服务器 | `HTTPTransport`（**必须** `URLSessionConfiguration.background`） | 后台传输跑在独立进程，app 终止也继续；但调度受"每小时 4 次、间隔 ≥15 分钟"限制 |

> 我会推荐**双端都传 + 服务端按 `uuid` 幂等去重**（调研 §5.8）：
> 手表端负责低延迟增量，iPhone 端负责全量与历史回填。
> 因为 `HKObject.uuid` 天然唯一，服务端去重几乎零成本，
> 手表端那点限制就只影响"数据多快到"，不影响"数据会不会丢"。

#### 按 §0 原则，上传路径也可以大幅简化

既然**不追求完整性**，上传就**不需要保证送达**：

- ❌ 不需要"上传成功前无限重试"——失败超过 N 次直接丢弃；
- ❌ 不需要 exactly-once 语义——服务端按 `uuid` 幂等 upsert，重复上传无害；
- ❌ 不需要"本地必须保留到确认上传成功"——队列可以定期清理；
- ✅ 只需要一个**有上限的队列** + **丢弃计数器**（用于观测丢了多少，而不是阻止丢弃）。

这比"可靠消息队列"的实现简单一个数量级，而且对这个产品是够的。

---

## 5. 失败与降级矩阵

这是本设计的核心部分——**每一条失败路径都有明确行为**，而不是崩或者卡死。

| 失败场景 | 系统行为 | 本设计的处理 |
|---|---|---|
| 设备锁定，后台读不到 HealthKit | 查询返回错误或空 | 记录错误、**不重试轰炸**、照常回调 completion、排下一次 |
| 后台时间不够（>8 秒） | 会被系统 kill | 引擎内设 8 秒 deadline，**超时主动 break**，未同步的指标留到下次 |
| 用户没把小组件放上表盘 | **后台预算为 0** | 前台打开时的同步是兜底；UI 空态里明确引导用户去装小组件 |
| 用户只授权了部分指标 | 未授权类型查不到数据 | 每个指标独立空态；`unauthorizedMetrics()` 给出精确提示，而不是笼统"没权限" |
| 首次同步数据量过大 | 可能超时 | `initialLookbackDays` 限定回看窗口 |
| 共享容器写失败 | 小组件读到旧快照 | 原子写入（临时文件 + replace），失败只记日志，不影响同步流程 |
| 系统反复不给后台时间 | 后台彻底静默 | 符合官方预期（"don't expect the system to trigger every background task"）。前台打开时尽量补，**补不上也不强求**（符合 §0 原则） |

---

## 6. 存储与保留策略

**一条规则：本地只保留最近 7 天**（`StoragePolicy.retentionDays = 7`，所有指标统一）。
详见 §1.2 的算账。

### 6.1 落在硬盘上，不是运行内存

```swift
ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
```

- SwiftData 用**文件型**库，位置在 app 沙盒的 Application Support 目录；
- app 重启、被系统杀掉、手表重启，数据都在；
- 启动时会打印实际落盘路径，真机上可直接核对：
  `[Store] SwiftData 落盘位置：/private/var/mobile/Containers/Data/.../HealthStore.sqlite`

> 这里刻意把 `isStoredInMemoryOnly: false` **显式写出来**（虽然它本来就是默认值），
> 是为了防止以后有人误改成 `true`，造成"app 一重启数据全没"这种很难查的问题。

### 6.2 保留窗口

| 项 | 值 | 说明 |
|---|---|---|
| 保留天数 | **7 天** | `StoragePolicy.retentionDays` |
| 最坏行数 | **≈12.1 万行** | 心率 17,280 条/天 × 7 天 |
| 典型行数 | 数千~2 万行 | 若 HealthKit 实际仍按 5 分钟写入 |
| 索引 | `[\.metricID, \.startDate]`、`[\.startDate]` | 分别服务"取最新"和"按日期删" |

- 删的只是**你自己的副本**，**不影响 HealthKit 里的数据**；
  而且长期档案本来就在 iPhone 上（官方："old data is periodically purged from Apple Watch"）。
- **不做预聚合**：既然只留 7 天，趋势图需要时直接从 `SampleRecord` 取即可，
  没必要维护一套聚合表和它带来的一致性约束。
- 待上传队列有**容量上限**（`trimUploadQueue`，默认 5,000）：满了丢最老的。
  按"不追求完整性"原则，这里不需要"保证送达"那套机制。
  接入真实传输后，再加上"上传成功即删除"即可。

---

## 7. 待你确认的三点

### ① ~~手表端要不要做"历史回填"？~~ ✅ **已决定：不做**

按"不追求完整性"原则，手表端只收集**能拿到的**：首次同步回看 1~3 天，之后靠 anchor 增量。
手表上 HealthKit 只有近期窗口，拿不到更早的历史就算了。
如果将来需要看长期趋势，一律引导用户到 iPhone 端——手表屏幕小，看趋势本来就是手机的活。

### ② 睡眠的"最新值"到底是什么？

现在显示的是**最后一个睡眠阶段**（如"深睡"），这大概率不是用户想看的。
更有意义的选项：
- "昨晚总睡眠时长"；
- "昨晚深睡占比"；
- 或者干脆做成"最近一次睡眠会话的开始/结束时间 + 总时长"。

**这是个产品决策，需要你定。** 定了之后我加一个 `SleepAggregator` 替换掉现在的简单格式化。

### ③ 上传先不管，但**上传的触发时机**要不要现在定？

队列已经在了，但"什么时候真的发送"会影响架构：
- 每次同步后就发 → 依赖后台唤醒频次，可能积压；
- 攒够一批再发 → 延迟更高但更省电（官方也建议"send only the items that have changed"）。

这个可以等确定传输目标后再定，但如果你现在就倾向某一种，我可以先把队列的批量策略定下来。
