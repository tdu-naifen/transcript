# 个人会议知识库 — 产品与工程计划

> iPhone 采集 + Mac 知识层。最后更新：2026-09-05
> 本轮已确认迁移到 Apple 系统转写；以下新增要求是待实施、待验收计划，不代表功能已完成。历史完成标记不代替本轮验收。

---

## 1. 产品定位（1+1 > 2）

| | 单独使用 | 价值 |
|---|---|---|
| **iPhone** | 一支很好的录音笔：转写 + 实时 Speaker N | 完整可用，独立成立 |
| **Mac** | 没有输入源 | 无意义 |
| **合起来** | 个人会议知识库：跨会议 RAG，答案附带**原始音频片段** | 不可替代 |

两边都不可替代，这是 1+1>2 的来源。

### 核心产品原则

> **不追求文本答案 100% 准确，而是把原始音频作为 ground truth，让用户 3 秒内 verify。**

理由：ASR 对数字最易出错（fifteen/fifty、1.5B/15B）。纯文本 RAG 会一本正经地给出错误答案。返回音频 clip 把这个弱点变成优势，同时解决 LLM 幻觉的信任问题。

---

## 2. 职责划分

```
iPhone  →  录音 + Apple SpeechTranscriber 转写 + on-device 实时 diarization
           纯采集设备，不做 analysis
           【音频 / transcript / speaker 命名的唯一 truth】

Mac     →  被动接收同步 + LLM metadata 自动打标 + hybrid RAG + audio clip 播放
           （会后全局重聚类与跨会议 identity 关联仍在未来范围）
           【分析结果的唯一 truth，iPhone 只读】

iCloud  →  CloudKit private DB 同步 speaker 库（alias 明文 + embedding E2EE）
```

---

## 3. 同步模型（已锁定）

### 3.1 单向权威，无双副本

**只有一个版本，不是两端各存各的。** 每一层数据有唯一 owner，另一端只读。

| Layer | Owner | 流向 | 另一端 |
|---|---|---|---|
| **A. 音频** | **iPhone** | iPhone → Mac (P2P) | Mac 只读副本 |
| **B. Transcript** | **iPhone** | iPhone → Mac | Mac 只读 |
| **C. Speaker（归属 + 命名 + 声纹）** | **iPhone** | iPhone → Mac | Mac 只读 |
| **E. 分析结果 / metadata / RAG 索引** | **Mac** | Mac → iPhone | iPhone 只读 |

> ✅ **模型很干净：iPhone 拥有全部原始数据，Mac 只拥有派生分析。**
>
> （原计划中的 Layer D「Mac 会后全局重聚类」**已移出当前范围**，见 §9.1。
> 一旦重聚类回归，Mac 就会写 `utterance.speakerId`，权威模型立刻变成「按列划分」，
> 那时才需要 HLC。）

> ⚠️ **唯一的跨端写入例外：`meeting.audioVerifiedOnMacAt`**。
> 它在 iPhone 拥有的 `meeting` 表上，但必须由 **Mac** 写（只有 Mac 能证明自己校验过）。
> 之所以安全：**write-once、单调、永不竞争** —— 只会从 nil 变成一个时间戳，不会被改回。
> 写入时必须把 Mac 的 deviceId 盖到 `originDeviceId` 以便审计。
> 引入 HLC 时这个字段不需要特殊处理，但不要忘了它是个例外。

### 3.1.1 Speaker 是全局实体，命名一次处处生效

`speaker.id` 是跨会议稳定的。用户把某个 speaker 命名为「John」，**所有会议里引用该
`speakerId` 的地方全部变成 John**，不需要逐场改。

**声纹相似度是身份匹配证据，不是同一人的保证。** 匿名 diarization 槽位也不等于已确认身份。若 diarization 错误地把同一个人拆成了两个 speaker：

- 提供 **merge 操作**（`mergeSpeakers(keep:absorb:)`）：重指全部 `utterance.speakerId`、
  合并 embedding、清理 `meetingSpeaker`，**整个过程在一个事务内**
- 命名时如果检测到其他 speaker 声纹余弦相似度超阀，弹 suggestion：
  「**Otter 好像也是 John，合并？**」—— 用户确认才合并，不自动执行
- merge 是 **iPhone 独占操作**（与命名同属 Layer C）

### 3.2 为什么没有冲突

**Speaker 名字只能在 iPhone 上修改**（产品决策）。这让命名从"多写者冲突"变成**单写者**，因此：

- ✅ 当前实现**不需要 HLC / LWW / CRDT**
- ✅ 同步逻辑退化为简单的单向 push + 版本号递增
- ⚠️ 见 §9 TODO：未来若开放 Mac 端编辑，必须补 HLC + LWW

**`revision` 语义**：per-record 单调递增（`utterance`、`analysisResult` 各自维护）。
这与“per-layer 版本向量”是**不同的东西** —— 后者用于按层拉 delta，需要独立的 `syncState` 表。
当前 P2P 同步按 meeting 整体推送，暂不需要；见 §9.4。

### 3.2.1 状态机（无终态，全部可恢复）

**录音与实时转写属于同一工作流**，不要求用户录完后另行启动转写。
采集不能等待模型：先可靠保存音频，模型就绪后按同一音频时间线追赶，不丢帧、不重复。
停止采集与推理收尾必须区分；收尾期间不再显示正在录音，也不能取消尚未落库的结果。

```
recording ──▶ recorded ──▶ audioSynced ──▶ queued ──▶ analyzing ──▶ analyzed
（录音+转写）    （音频已保存）                    ▲                            │
                                                └──────────────────────────┘
                                                 重新分析（重打标 / 换模型）

任意状态 ──▶ failed ──▶ 回到 failedFromState 本身，或它的任一合法后继
```

- `recording` —— 录音 + 实时转写 + 实时 diarization 同时进行
- `recorded` —— 音频已保存；另行记录转写/说话人处理的完成、部分完成或失败状态，不能仅凭 meeting 状态宣称转写完整。具体字段与迁移需实现时确定
- 正常停止等待 ASR、diarization 和数据库写入收尾；准备期间停止也必须保留音频与已有结果
- 部分 speaker 无法归属不是整场录音失败；保留 Unknown，允许命名和保存。采集/存储失败与可恢复的识别问题必须区分
- **没有任何终态**。`analyzed` 可回 `queued`（Layer E “派生、可重算”）；
  `failed` 可重试

**重试语义（已定）**：`failed` 可回到 `failedFromState` **本身**（重做该阶段）
**或**它的任一合法后继（跳过该阶段）。两者都要允许：
- 上传失败 → 重试 `audioSynced` 本身
- 边界处失败（实际已成功） → 直接前进到后继

**崩溃录音的恢复（已定）**：`recording` 失败时，**部分音频和部分转写必须保留**，
允许 `failed → recorded` 把残局敲定为一场短会议。
对录音类产品而言，**丢掉一场会议是不可接受的**，宁可给一个不完整的结果。


### 3.3 音频传输

- **P2P 直传**（Network framework），不走 iCloud Drive
- **连上 Mac 即自动后台同步所有未同步音频**，而非上滑时才传
- 上滑 process 只传 transcript + embedding（~1.3MB），瞬间完成
- 断点重传 + SHA-256 校验

### 3.3.1 容器必须是 fragmented MP4（实测结论）

🔴 **`AVAudioFile` 的经典 M4A writer 会在 close 时原地回填 `moov`**（实测：
close 后字节 [0, 24576) 内有 436 处 diff，文件大小不变）。
→ **边写边累加的 SHA-256 会是错的**，§3.4 的校验方案直接失效。

解法：用 `AVAssetWriter` 的 **segment delegate 产出 fragmented MP4**，字节交出时即为终值。

两个连带后果：
1. 容器 UTI 是 `public.mpeg-4`，**`com.apple.m4a-audio` 在设了 segment delegate 时会被直接拒绝**。
   `.m4a` 扩展名只是命名约定，不是真实容器类型
2. ✅ **这才让 §3.2.1 的「崩溃录音可救」真正成立** —— 未 finalize 的经典 M4A 是不可播放的垃圾，
   而 fMP4 可以播到最后一个完整 fragment。**崩溃损失上限 = `segmentSeconds`（当前 5s）**

### 3.3.2 时长的权威来源

三个来源互相矛盾（实测：5000ms 采集帧 vs 5.18s 容器时长，AAC priming + fragment padding 导致）：

- ✅ **采集帧数 ÷ 采样率 —— 权威值**。只有它能正确穿越暂停和中断
- ❌ 墙钟（含暂停时间）
- ⚠️ 文件容器时长 —— 仅崩溃救回时作为 fallback，因此**救回的会议时长会略偏大**

### 3.3.3 音频密封点

Layer A “sealed 后 immutable” 的 seal 发生在 **`recording → recorded` 转换**，
一个事务内同时写入 `durationMs` / `audioFileName` / `audioSHA256` / `audioByteCount`。
**`failed` 也可 seal** —— 这是崩溃救回的必要条件。

### 3.4 iPhone 本地音频清理（可选功能）

一年约 32GB 音频，手机放不下。既然 Mac 有完整副本：

> **「已备份到 Mac 的录音，30 天后自动清理本地音频（转写文本保留）」**

🔴 **清理必须以「Mac 校验通过」为门槛，而不是「传输完成」。** 两者是不同的状态：

| 字段 | 含义 | 由谁写 |
|---|---|---|
| `syncedToMacAt` | 字节已传完 | iPhone（发送方） |
| `audioVerifiedOnMacAt` | **Mac 落盘后重算 SHA-256 并比对通过** | **Mac**，回传给 iPhone |

**只有 `audioVerifiedOnMacAt` 非空才允许删本地音频。** 只看「传完了」就删，等于把唯一副本赌在一次未校验的传输上 —— 这是本项目唯一的不可逆数据丢失路径。

- 转写文本永久保留在 iPhone
- 用户可关闭；可手动从 Mac 拉回音频

---

## 4. 技术选型（2026-09-05 更新）

### 4.1 ASR：迁移到 Apple 系统模型

- **已确定方向**：iOS 26 的 `SpeechAnalyzer` + `SpeechTranscriber`，替换 Nemotron，覆盖实时转写与保存音频的重新处理。不是 Apple Intelligence 文本模型，也不是 Core AI 社区模型。
- 先在当前 Simulator 检查运行时可用性、中英文支持与语言资源安装；不支持则明确报告阻塞，不暗中改用真机、Mac 原生或云端结果。
- 通过 `AssetInventory` 管理语言资源；首次可能下载，离线能力必须在资源就绪后验证。界面语言不决定 ASR 语言，中英混说/语言选择策略需要验证 API 后确定，不能假设自动检测可用。
- 使用 `prepareToAnalyze` 预热，评估模型复用和驻留；分别测量下载、冷加载、热启动、首个 partial、final 延迟与内存。不能宣称换成 Apple 一定更快。
- 迁移期间保留旧引擎作回归对照；新流程验收后才删除无调用的 Nemotron 引擎、专属下载逻辑及依赖，不保留未经约定的生产 fallback。
- 参考：[SpeechAnalyzer 官方介绍](https://developer.apple.com/videos/play/wwdc2025/277/)、[预热 API](https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze(in:))。Apple 研究论文中的模型和准确率不能直接视为公开 API 的性能保证。

### 4.2 Diarization

保留 **FluidAudio + Sortformer** 判断谁在什么时候说话，以及 **CAM++** 声纹提取/身份匹配。两者与 ASR 独立，不随转写引擎一起删除。

- 排查模型重复加载、输入积压、每条更新全量查库/对齐的成本；优先复用模型与增量处理。
- 保留 finalized 时间段，只替换 tentative 尾部；实时页和历史页共享一致的 speaker 映射与音频时间基准。
- 长文本跨过多个人发言时，结合可靠时间戳细分；证据不足保留未知，不把整段强行归给最大重叠者。
- 发言时长基于 diarization 音频区间，不能用 ASR 长段长度代替。静音、多人重叠、未确定时段和百分比分母必须明确定义并用标注时间线验证，具体展示口径见 UI §4.5。
- CAM++ 只使用足够干净的非重叠语音，匹配阈值需验证；不能通过降低阈值制造看似完整的身份识别。

> ⚠️ Apple Speech 框架只有 `SpeechTranscriber` / `DictationTranscriber` / `SpeechDetector`(纯 VAD)，**无 speaker 分离能力**。

截至本轮查阅，[Core AI 官方目录](https://github.com/apple/coreai-models)没有现成 diarization 模型，且要求 Xcode/iOS 27；不纳入当前 iOS 26 迁移。重叠活动检测也不等于把同时说话的两个人分别转写，本轮不承诺后者。

### 4.3 Mac 端 LLM

- **纯 Swift native，不需要 Python**：`ml-explore/mlx-swift-lm` 提供 `MLXLLM` / `MLXVLM` / `MLXEmbedders`
- **Gemma 4**：Mac 用 12B / 26B-A4B，与 iPhone 拉开真实质量差距
- 🔴 **绝不嵌 Python**：公证要求所有 `.so`/`.dylib` 单独签名（Python wheel 二进制签不动），App Store 分发基本不可能，包体爆炸

### 4.4 存储

- **GRDB (SQLite)**，iOS/macOS 共用 Swift Package
- 向量规模十万级（几百场 × 500 句），**暴力余弦仍是毫秒级**（10万×768维≈300MB）
- **不引入向量数据库**
- SQLite **FTS5** 内置，零成本做 BM25

---

## 5. 关键平台约束

### 5.1 设备门槛（不可逆决策）

```xml
<key>UIRequiredDeviceCapabilities</key>
<array><string>iphone-performance-gaming-tier</string></array>
```

→ App Store **直接阻止 iPhone 15 Pro 以下机型安装**（非运行时报错）

> 🔴 **不可逆**：Apple 规定更新只能放宽不能收紧 capability。**必须第一版就加**，漏了就永远补不上（除非换 bundle ID 重发）。

Apple SpeechTranscriber 改为主转写方案，而非旧设备兜底。迁移不自动改变现有 capability、签名或 deployment target；设备门槛需结合保留的 diarization 模型另行评估。

### 5.2 内存与后台

- `com.apple.developer.kernel.increased-memory-limit`（iOS 15+）
- 用 `os_proc_available_memory()` 查实际额度，必须优雅降级
- `BGContinuedProcessingTask` + `...continued-processing.gpu` → 前台启动、后台继续、可用 GPU

### 5.3 网络

- MultipeerConnectivity 已 **deprecated** → Network framework (TN3213)
- `NWParameters.includePeerToPeer = true` → AWDL peer-to-peer Wi-Fi + Bluetooth 发现，**离网可用**
- 不用裸蓝牙（BLE ~1-2KB/s，传 30MB 要几小时）

### 5.4 iCloud 的两套机制（不要混淆）

| | 机制 | 存什么 | 用户可见 |
|---|---|---|---|
| **CloudKit**（CKRecord/CKAsset） | 数据库同步 | 结构化记录 | ❌ **完全不可见** |
| **iCloud Drive Ubiquity Container** | 文件同步 | 文件/文件夹 | ✅「文件」app 里显示，带 app 图标 |

**speaker 库 → CloudKit private DB**（不可见，正确）

**想在「文件」app 里露出文件夹**（如 PDF Expert 那种）→ Ubiquity Container：
1. Entitlement `com.apple.developer.ubiquity-container-identifiers` = `iCloud.$(BUNDLE_ID)`
2. Info.plist `NSUbiquitousContainers` 字典：
   - **`NSUbiquitousContainerIsDocumentScopePublic = true`** ← 关键，决定是否可见
   - `NSUbiquitousContainerName = "Transcript"`
   - `NSUbiquitousContainerSupportedFolderLevels = "Any"`
3. `FileManager.url(forUbiquityContainerIdentifier:)` 首次调用时系统自动创建容器

> ⚠️ **绝不能在主线程调用** `url(forUbiquityContainerIdentifier:)`（Apple 明确警告）
> ⚠️ 判断 iCloud 可用性用 `ubiquityIdentityToken`

**CloudKit 加密字段限制**（`CKRecord.encryptedValues`）：
- 🔴 加密字段**不能建索引**，不能进 CKQuery predicate/sort
- 🔴 **只能对新字段加密**，已有 schema 字段改不了 → **schema 一次设计对**
- ⚠️ 只有开启 Advanced Data Protection 才是真 E2EE，营销须诚实

### 5.5 音频不走 iCloud Drive

诱人（省掉 P2P 传输），但三个硬伤：
1. **配额**：一年 32GB vs 用户免费 5GB → 逼用户买 iCloud+
2. **与「No Internet Required」核心卖点直接冲突**
3. **不可控**：上传下载由系统调度，无法保证「iPhone 一进门就同步完」

→ **P2P 为主**。Ubiquity Container 作为可选，独立价值是让用户在「文件」app 里直接看到自己的数据。

---

## 6. Mac app 分发（已定）

**Developer ID 直发 + 公证（notarization）**，不上 Mac App Store。

**优势**：
- **无沙盒** → `NWListener` 无需 entitlement、模型文件随意放、音频库路径自由
- 可装 **`SMAppService` 登录项** → Mac app 常驻后台、始终可被发现，用户不用手动打开
- 可直接分发数 GB 模型

**代价**：
- 自建更新：**Sparkle**（EdDSA 签名 appcast，**必须 HTTPS**）
- 自建付费授权（无 StoreKit）：Paddle / Lemon Squeezy / Stripe + license key
- Hardened Runtime + 公证：所有二进制必须签名
- Gatekeeper 首次启动摩擦 → 需清晰安装引导

---

## 7. Phases

### Phase 0 — 数据模型与地基验证
- `0a` Layered schema（A–E）+ 单向版本号（**不需要 HLC**，见 §3.2）
- `0b` GRDB schema，两端共用 Swift Package
- `0c` 🔴 CloudKit schema **一次设计对**（加密字段只能新建）
- `0d` speaker stable ID 与 display index 分离
- `0e` ⚠️ **验证 CloudKit 能否跨「App Store iOS app」与「Developer ID Mac app」同步**（同 Team ID + 同 container）。这是 speaker 同步方案的地基，**必须最早验证**。若不行 → 退回走 P2P 通道
- `0f` ⚠️ 验证 MLX Metal shader 是否需要 `com.apple.security.cs.allow-jit`
- `0g` Ubiquity Container 配置（Info.plist / entitlement 一并设计）

### Phase 1 — iPhone 采集端（独立可用的完整产品）
- `1a` 🔴 Info.plist 加 `UIRequiredDeviceCapabilities = [iphone-performance-gaming-tier]`（**第一版必须加**）
- `1b` 将实时与重新处理的 ASR 迁移到 Apple SpeechAnalyzer / SpeechTranscriber（§4.1）
- `1c` 分别管理 Apple 语言资源和 Sortformer / CAM++ 模型，不再以 Nemotron 安装完成作为录音门槛
- `1d` `increased-memory-limit` entitlement + `os_proc_available_memory()` 检测
- `1e` 集成 diarization（FluidAudio / nemotron-3-diarization-coreml），实时 Speaker N
- `1f` retro-relabel 策略：**stable ID / display index 分离** + 过渡动画
- `1g` UI 按 UI.md：两个 tab、全局录音浮层、Live Activity；无 Translate tab
- `1h` 用 partial/准备状态表达转写进度，不显示固定 2240ms 或工程参数

### Phase 2 — Speaker 库与 iCloud 同步
*依赖 Phase 1*
- `2a` Consent 流程（生物特征数据）+ 一键清空
- `2b` 本地 speaker embedding 库（GRDB）+ 暴力余弦匹配
- `2c` CloudKit private DB：alias 明文 + embedding 走 `encryptedValues`
- `2d` 新说话人 → 匿名动物名（Hippo / Otter / …）
- `2e` 「称呼→应答」suggestion chip（「Possibly Florence」样式），**用户确认才写入**
- `2f` **重命名只在 iPhone**，单向同步到 Mac

### Phase 3 — 配对、传输与音频同步
*依赖 Phase 0*
- `3a` Bonjour `_vtscribe._tcp` + `includePeerToPeer = true`
      Info.plist：`NSLocalNetworkUsageDescription` + `NSBonjourServices`
- `3b` 配对：6 位短码双端确认 → pin 公钥存 Keychain → TLS + pinned identity。**未配对一律拒绝**
- `3c` 消息类型：`handshake` / `meeting-metadata` / `audio-blob` / `audio-verified` / `transcript+embedding` / `job-status` / `analysis-result` / `clip-request`
- `3d` Mac 端 `SMAppService` 登录项常驻 → 始终可被发现
- `3e` **连上即自动后台同步未同步音频**，断点重传 + SHA-256 校验
- `3f` iPhone 本地音频清理策略（§3.4）
- `3g` Mac 端音频存储管理：一年约 32GB，需归档/压缩/清理
- `3h` process button 三态 + Live Activity 进度
      - 未配对 → 灰，引导配对
      - 已配对但离线 → 灰，「Mac 上线后可分析」
      - **已连接 → 彩色可点**
- `3i` 🔴 非阻塞 UI：上滑后可自由离开。**不能只做 in-app 通知**，必须同时发 `UNUserNotificationCenter` 本地通知 + Live Activity

### Phase 4 — Mac 端 metadata 打标
*依赖 Phase 2 + 3*
- `4a` **LLM metadata 自动打标** batch job：topic 标签（如 "azure storage"）+ 参与者 + 关键实体 → 这些是 RAG 的 filter 维度
- `4b` Gemma 4（12B / 26B-A4B），MLX Swift
- ⚠️ 会后全局重聚类、跨会议 identity 关联 —— **已移出当前范围**，见 §9.1

### Phase 5 — Hybrid RAG + Audio Clip
*依赖 Phase 4*
- `5a` chunk = **speaker turn 聚合成 30–60s 语义块**（单 utterance「是的」「对」语义不完整）
      存 `(meetingId, speakerId, startMs, endMs, text, embedding)`
- `5b` `MLXEmbedders` 生成向量；SQLite FTS5 建全文索引
- `5c` **Hybrid retrieval**：metadata filter（date / speaker / tag）→ **先 filter 再 semantic** → FTS5 BM25 + 向量混合打分
- `5d` 对话框 UI：答案 + **可播放 clip（前后各 2 秒 padding）** + 跳转原会议
- `5e` **跨会议对比**（「这 20 个人对 azure storage 定价的分歧？」）—— 单列为差异化功能

---

## 8. Spike（先于对应 Phase 执行）

| ID | 内容 | 优先级 |
|---|---|---|
| **S1** | 仅在 Simulator 验证 Apple ASR 可用性，并测量 ASR + diarization 并行的冷/热启动、延迟、RTF、积压和内存 | **最高** |
| **S2** | Simulator 中分开测量 Sortformer 和 CAM++ 的加载/推理耗时，以及双人标注音频的归属与发言时长误差 | 高 |
| **S3** | Gemma 4 12B/26B MLX Swift 在目标 Mac 的可行性与速度（含最低配置要求） | 中 |
| **S4** | hybrid retrieval 质量评估（FTS5+向量 vs 纯向量），用真实会议数据 | 中 |
| **S5** | CloudKit `encryptedValues` 同步 embedding 的实际延迟与配额 | 低 |
| **S6** | Network framework peer-to-peer 离网实测吞吐（音频同步场景） | 低 |

---

### 8.1 本轮修复与最终验收（全部待验收）

**只用 Simulator，不安排真机测试。** 记录宿主机、Xcode、runtime、模型/语言资源版本和重复运行结果；模拟器结果不能证明 iPhone 的 ANE、耗电、发热或性能。

1. Apple 模型实际加载和转写：中文、英文、中英混说；分别报告可用性、准确率和冷/热启动结果。
2. 点击录音立即采集，模型准备时不中断音频；用主持机扬声器播放双人会议，经真实麦克风进入 Simulator。确认非零输入、实时文本、不同说话人；文件输入和 fixture 不能冒充麦克风 E2E，路由不可用需报告阻塞。
3. 修复 `incompleteSpeakerAssignments` 阻止保存；未知/重叠允许存在，但不可隐藏实际处理或存储失败。验证短录音、准备中停止、最终 chunk 与数据库收尾。
4. 核对 finalized diarization 历史、每段 speaker/时间戳、实时/历史映射一致性，以及基于标注音频的发言比例。检测到三个槽位不等于验证了三个人。
5. 停止后展示日期时间预填的命名弹窗；名字不能为空，允许之后修改。原始音频不依赖弹窗确认才保存；本轮不实现自动 LLM 命名。
6. `⋯ → Speaker Insights` 可改名；离开重进、终止重启后 transcript、speaker 名字和标题仍保留；播放与定位正常。
7. 停止后锁屏/Dynamic Island 不再显示 still recording：停止采集就结束录音计时与状态，不等识别完成；覆盖 App 内停止、锁屏停止、失败收尾和重启清理遗留 Activity。
8. 空 transcript 的旧录音可重新处理；成功时原子替换派生结果，失败/取消保留旧结果，音频、会议 ID、用户标题与确认过的名字不被破坏。
9. Settings 语言下拉菜单与系统语言标签按 UI §5.2 验收；在浅色/深色外观检查截图中的颜色、材料、可读性、控件遮挡问题，不预设真机颜色问题根因。
10. 功能验证后才清理无用代码：核对调用、重新处理、测试与 widget 依赖，保留仍使用的 FluidAudio 和有效回归工具。清理后重跑相关测试、App/widget build 和 Simulator 流程。

每个逻辑改动独立 git commit，说明改动便于回滚；只暂存自己的文件/改动，保留已有签名、配置、数据库、录音和未提交工作。不新增无关 Markdown 报告；在本计划中区分通过、失败和未验证，build 成功不算功能验收。

## 9. TODO / Future

### 9.1 Mac 会后全局重聚类（已移出当前范围）

**现状**：iPhone 的 on-device 实时 diarization 直接产出最终 speaker 归属，Mac 不修改。
用户靠 **merge 操作**（§3.1.1）手动修正 diarization 错误。

**为什么先不做**：它把权威模型从「按表」变成「按列」，直接引入双写者冲突，
而收益（精度提升）在 POC 阶段无法量化。

**回归时需要**：
- Mac 写 `utterance.speakerId` + `meetingSpeaker.displayIndex`，iPhone 写 `speaker.displayName`
  → 权威必须精确到**列**，并需要 §9.3 的 HLC
- UI 需要过渡动画提示编号变化，避免用户困惑

> ⚠️ `remapDisplayIndexes`（两趋负值占位交换，避免中途踩中 `unique(meetingId, displayIndex)`）
> **现在就在用**，服务于 §1f 的录音中实时 retro-relabel。它不是为重聚类预留的休眠代码，**不要删**。

### 9.2 Speaker merge 的 CloudKit 表示（必须在 Phase 0c 设计）

§3.1.1 的 merge 是一个 **delete + re-parent** 操作：删掉一个 `speaker` 行、把它的
embedding 和 utterance 引用转移到另一个 speaker。

这与 §5.4 直接冲突：CloudKit 镜像**需要明文定位字段**（加密字段不能查询），
而**加密属性事后不能补加**。所以必须现在就想清楚：
- merge 如何跨设备传播？（tombstone？重定向记录？）
- 两台设备各自 merge 了不同组合怎么办？
- 被吸收的 speaker 删除后，其他设备的本地引用如何修复？

→ **写任何 CloudKit 代码之前必须先定。**

### 9.3 HLC + LWW 冲突解决（重要，不要忘）

**当前状态**：因为 iPhone 拥有全部原始数据（A/B/C）、Mac 只拥有派生分析（E），
没有任何一张表被双端写入，**不需要冲突解决**。

**触发条件**：以下任一情况发生时必须补上
- **启用 §9.1 的 Mac 重聚类**（最可能的触发点）
- 开放 Mac 端编辑 speaker 名字或 transcript 文本
- 支持多台 iPhone 采集同一 speaker 库
- 支持多用户协作

**届时需要实现**：
- Hybrid Logical Clock（不依赖墙钟，避免时钟偏移）
- Per-entity Last-Writer-Wins（speaker 名字是小标量，LWW 足够，不需要完整 CRDT）
- 用户编辑锚定到 `(startMs, endMs) + 原文快照`，**不锚定 segmentId**
  （Mac 重转写会重新分段，index 会全变）
- Re-anchor 算法：时间重叠 + 文本模糊匹配，匹配不上标记 `orphaned edit` 让用户确认

> **设计约束**：即使现在不实现，schema 也要预留 `updatedAt` / `originDeviceId` 字段，避免将来迁移

### 9.4 Schema 已知缺口（实现时补）

- ~~**`audioVerifiedOnMacAt`**~~ ✅ 已实现
- ~~**`failedFromState`**~~ ✅ 已实现
- ~~**语言下沉到 utterance**~~ ✅ 已实现（`utterance.localeIdentifier` 为真值，
  `meeting.localeIdentifier` 为派生摘要）
  ⚠️ **刷新时机已定**：在 `recording → recorded` 转换时重算一次，不做实时刷新
- ~~**匿名名字池扩到 100+**~~ ✅ 已实现
- 🔴 **`analysisResult` 的 revision 单调性漏洞**：`analyzed → queued` 重分析合法后，
  Mac 会对同一 `(meetingId, kind)` 产出多个结果，而 `revision` 由调用方传入，
  无任何保证新值 > 旧值 → `latest()` 可能返回旧结果。
  需改为 **DB 侧单调递增**（插入时取 `MAX(revision)+1`），而非信任调用方
- **`syncState` 表**：若将来改为按层拉 delta（而非按 meeting 整体推送），需新增
- **CloudKit 镜像 schema 必须先设计再写代码**（§5.4 + §9.2）：加密字段不能建索引/查询，
  所以 `SpeakerEmbedding` record type 需要至少一个**明文**字段用于同步定位，
  而**加密属性事后不能加**
- **RAG chunk 表不存在**：§5a 的 30–60s speaker-turn 块是独立表，**不是 `utterance` 的视图**。
  FTS5 虚拟表应建在 chunk 上，随 Phase 5 一起加

### 9.4.1 Phase 0 验收后遗留（已知，非阻塞）

- ~~`meeting.durationMs` 无人写入~~ ✅ 已关闭（§3.3.3 的原子 seal）
- `syncedToMacAt` 没有 write-once 保护（不像它的兄弟 `audioVerifiedOnMacAt`）。
  iPhone 独占所以不竞争，但重传会静默覆盖，导致“字节何时落地”不可考
- `utterance.revision` 被 bump 但**无人读取** —— P2P 传输层落地前它是 write-only 状态
- `mergeSpeakers` 逐行搬运 embedding，不做 `sampleCount` 合并 →
  合并后的 speaker 会累积多行而非整合。当前规模无碍，但**影响 §9.2 的 CloudKit 表示设计**
- `AppDatabase.writer` 仍是 public，可绕过仓储层直接 INSERT。
  schema CHECK 已封住数据丢失和状态机两条路；revision 单调性无法用 CHECK 表达，
  需要 `BEFORE INSERT` 触发器（~6 行）才能彻底封死。UNIQUE 索引已挡住有害情形
- 🔴 **音频文件的生命周期无人管**：PLAN 没写删除 meeting 时音频文件怎么办，
  也没有孤儿文件清扫（在创建文件和插入 DB 行之间崩溃会泄漏文件）
- 录音尚未做后台延续：`UIBackgroundModes: audio` 已声明，但没有代码主动保活会话

### 9.5 其他

- `eraseDatabaseOnSchemaChange` 目前是 DEBUG-only，任何 schema 修改会**静默清库**。
  真机上有真实用户数据前必须复审
- Core AI 后端转换留待未来评估，不作为本轮迁移依赖；不再投入 Nemotron 更低延迟 tier 的转换
- Mac 端 Sparkle 更新机制
- 付费/授权系统


---

## 10. 明确排除

- ❌ iPhone 端做 analysis / RAG
- ❌ 自动切换云端或旧 ASR 兜底；Apple `SpeechTranscriber` 已改为本轮主方案
- ❌ 自建中继服务器 / 云端推理
- ❌ **Mac app 嵌 Python runtime**
- ❌ 用 CloudKit 同步 meeting 音频/transcript（只同步 speaker 库）
- ❌ 录制过程中的音频增量同步（改为连上 Mac 后批量同步）
- ❌ 向量数据库（暴力余弦足够）
- ❌ iPad 版
- ❌ 裸蓝牙传输
