# 当前验收与未关闭问题

更新：2026-09-07，依据 17:42 用户反馈。**本轮修复进行中，未最终验收、未宣告合并/推送完成。**
本文取代旧计划中的完成/阻塞总论；[README](README.md) 是入口，[iOS](IOS_UI.md)/[Mac](MAC_UI.md) 是要求，协议文件保持独立规范职责。

## 最新用户反馈：不是新测试日志

| ID | 观察或要求 | 当前状态与关闭条件 |
|---|---|---|
| NOW-001 | 拔掉 USB 后无线同步可用 | **用户报告可用**，不是自动化日志；保留该正向反馈，不再笼统声称“无线完全不可用”。实际 build、endpoint/path、同网重连/重启证据仍未补齐。 |
| NOW-002 | Mac 重处理结果没回到 iPhone | **活动修复，未通过**。真实 Mac 原音频处理→版本发布→传输→iPhone 原会议已挂载详情更新；覆盖断线、重连、重试、取消及过期输入，不能只验证 Core 仓库。 |
| NOW-003 | Mac 没有本地声纹 | **活动修复，未通过**。在 Mac 产品任务中实际调用 diarization/CAM++、保存兼容模板、匹配/未知拒绝；授权后回到 iPhone。基线 ASR-only 与声纹库展示不是该能力。 |
| NOW-004 | iPhone Identifying 太久 | **活动修复，未通过**。记录干净音频积累、加载/推理、绑定/提交/观察/显示各阶段；验证真实多声音及返回说话人，阈值/模型精度不降级。 |
| NOW-005 | App 前台应保持唤醒 | **新需求，未通过**。前台浏览/录音等实际场景不自动锁屏，离开前台恢复正常系统行为；不等于后台持续推理授权。 |
| NOW-006 | 底部录音控件与上滑动画 | **活动修复，未通过**。收起/展开、safe area、最后一行、整卡跟手、回弹/提交、无障碍和减少动态效果；不误触录音或阻塞浏览。 |
| NOW-007 | Mac 整张会议卡可点 | **活动修复，未通过**。卡片留白/边缘与标题均可选中，子按钮独立，键盘/VoiceOver 回归。 |

这些条目不得继承之前测试的通过状态。物理双端**完整闭环仍未关闭**，也不能把用户的无线可用报告扩写成声纹或结果回传成功。

## 已有证据：固定到旧源版本

此前 main 已合并并推送 `3bfc72b`（协调者报告）；生产包来源 `7dac0e34883e2d4b940693c646289435f85d4881`，真模型测试 `dcf161e`，`3bfc72b` 为相应 QA 文档记录。
本轮新增代码尚待最终复核，这些历史结果不是其验收凭据。

| 验证 | 已记录结果 | 范围 / 证据名 |
|---|---|---|
| macOS Core 声纹选择 | 75 passed：17 XCTest + 58 Swift Testing，无 skip | `voiceprint-core-mac-final.log`；包含真实 CAM++ 与确定性安全回归 |
| iOS Simulator Core | 39 named tests / 42 参数化调用，无 skip | `voiceprint-core-ios-final.log`、对应 xcresult；真实 CAM++ |
| Native iOS | 70 passed，无 skip | `voiceprint-ios-qa-tests.xcresult`、`voiceprint-ios-qa-receipt.json`；观察/生命周期/授权/重处理用注入引擎，不是自然身份识别 |
| Native Mac | 最终 31 passed，无 skip | `voiceprint-mac-qa-rerun2.xcresult`、`voiceprint-mac-qa-report.txt`；11 声纹库、19 同步集成、1 双端授权，使用 synthetic vectors |
| AAC 输入边界 | 生产 `7dac0e3` 修复；Core 21 / iOS 37 定向回归通过 | 采集 16,000 帧可解码 16,320 帧，按封存区间排除不足一包的 AAC padding；原音频哈希不变，真实越界继续拒绝。用户截图录音修复后重试未据此关闭。 |
| 模型持久化与拒绝 | 两个平台引擎测试通过 | 正确绑定/改名/数据库重开、删会议保留全局模板、移除另一模板后该声音拒绝匹配 |
| 自然识别、物理手机与双端声纹闭环 | 未完成 | 未由上述 QA 安装用户 iPhone、操作用户录音或批准权限/信任；后来的无线用户报告单列于 NOW-001 |

公开语音来自 LibriSpeech test-clean：`1089-134686-0000`、`1089-134686-0002`、`1188-133604-0000`（Panayotov et al., OpenSLR 12，CC BY 4.0）。
相同 CAM++ 模型指纹：`campplus:62ce4257968340816c1404499bf07e862d6a10a2c8dc74156ed525823d8459f8:16k:192`。

| 干净语音 | macOS 引擎 | iOS Simulator 引擎 |
|---|---|---|
| 1 秒 | 需更多音频 | 需更多音频 |
| 2 秒 | 不匹配，cosine 0.689 | 不匹配，cosine 0.686 |
| 3 秒 | 匹配 1089，0.761 | 不匹配，0.757，candidate margin < 0.1 |
| 5 秒 | 匹配 1089，0.818 | 匹配 1089，0.811 |

两个公开身份保持可区分；5 秒同人匹配使用独立 utterance。策略未变：cosine ≥ 0.7、candidate margin ≥ 0.1、干净音频 ≥ 2 秒。
这只是小样本 smoke，不是准确率校准或 40 人声学验收；3 秒平台差异保留，不能用降低阈值抹平。

### 证据定位与失败记录

历史证据根（本机 session 产物，不是 checkout 内保证存在的链接）：
`~/.copilot/session-state/a4ab0df9-4371-44ee-be89-af180b56d832/files/`。
上述文件名相对此目录；生产清单为 `voiceprint-qa-production.sha256`，包校验值见该 session 的 packaging receipt。
这些 development-signed 包不是 App Store/TestFlight 或已公证发行，不代表已安装到用户设备。

- Mac 最初 26 passed / 5 fixture 访问失败，另一次目录设置在测试前中止；最终签名测试 host 使用自身 sandbox 中唯一根后 31/31。失败证据保留，未放松权限或生产实现。
- 较早 `256ee83145d74ad39096381d868baf2b879b1365` 集成的 Core 222、Mac 209（1 opt-in skip）、iOS 152、postcommit Mac 30 等详见该目录 `core-integrated-migration-fixed.log`、`mac-final.log`、`ios-final.log`、`postcommit-mac.log`；不是新修复回归。
- 独立发布/输入围栏回归 12 Swift Testing tests 见 `cleanup-review-regressions.log`。早期编译/cache/签名、fixture、render deadline 失败仍在 session 证据，不因删历史 Markdown 抹除。
- `live-render-evidence/manifest.json` 的约 67 ms 是 synthetic 已挂载行更新捕获，不是自然推理延迟/物理屏幕扫描。
- 旧 baseline `nemotronIsTheOnlyTranscriptionEngine` 与既有 Apple 引擎冲突曾单独复现并从选择中排除，不将其算作全套 green；opt-in skip 不算真实模型通过。
- **历史隔离偏差仍需披露**：早期 worker 曾使用共享 Simulator `A565…`，安装/偏好受影响；结果排除，不宣称零访问/零影响，也未擅自重置。记录为 `live-shared-simulator-disclosure.json`。更早 fixture 回落污染另一专用测试库的报告在 `3bfc72b:IOS_UI.md` 的 IOS-COMPLETE-FIX-03；该库未擅自恢复。此次文档整理未操作任何设备、权限或录音。

## 保留的回归问题

旧 BUG/REQ 编号保留以便追溯；以下是**需复核的验收要求，不断言当前代码仍有全部旧缺陷，也不标为已关闭**。

| ID | 必须保留的验证 |
|---|---|
| BUG-001 · P0 | 停止→命名→返回/重开→终止重启后，文字/标签/时间戳/音频保留；短录音、准备中停止、尾段未定稿、恢复失败均覆盖，不能只凭空页面断言 DB 丢失。 |
| BUG-002 · P1 | 未归属保留 Unknown，允许保存，不暴露 `incompleteSpeakerAssignments` 原始枚举；真实存储失败仍报错。 |
| BUG-003 · P1 | 人工标注双人轮流样本核对 finalized 历史、换人区间、重采样/暂停时基和跨人长 ASR 段；无可靠依据不强分，不承诺重叠语音分别完整转写。 |
| BUG-004 · P1 | 参与者、实时/历史文本使用同一稳定 ID；Insights 改名跨会议/重启保留，零身份也解释状态，不伪造可改名实体。 |
| BUG-005 · P1 | diarization 发言占比核对区间合并、分母、舍入、未知/重叠/静音/缺失分析；未分析不显示假 0%。 |
| BUG-006 · P1 | 冷/热加载、首 partial/final、积压/内存、ASR/Sortformer/CAM++ 耗时分别测；准备中采集/停止可用，回填无丢帧/重复；与 NOW-004 相关。 |
| BUG-007 · P1 | 采集停止立即结束计时/Activity，覆盖 App/锁屏停止、暂停、失败、重启与晚到更新；不支持的 Simulator 交互标未验证。 |
| BUG-008 · P2 | 列表/设置/详情/录音/命名/身份弹窗在浅深色可读，状态栏对比正确；正常系统蒙层不是故障。 |
| BUG-009 · P2 | 收起、切 tab、重新展开仍是同场录音；最后一行和播放器不遮挡；与 NOW-006 共同回归。 |
| REQ-001 | 日期时间预填非空命名、之后可改；音频保存不依赖弹窗，不做 LLM 命名。 |
| REQ-002 | 空转写可重处理；成功原子发布，取消/失败/新编辑保留旧结果、原音频、ID、标题和名字。 |
| REQ-003 | 仅系统/简中/English 的紧凑语言菜单，系统标签不跟 App 手选语言变，立即生效且重启保持，与 ASR 语言独立。 |
| REQ-004 | Apple API/语言资源、离线中英转写/混说/时间戳分别实际验证；缺支持不能换平台/云/旧引擎冒充通过。 |
| REQ-005 | Apple 语言资源与 Sortformer/CAM++ 就绪、下载、取消、失败、重试分别可见；安装不代表已调用。 |
| REQ-006 | 后续代码清理仅删确认无调用的代码，保留模型/重处理/widget/回归依赖及用户数据库、录音、签名和其他 WIP。 |

旧计划还记录过分析 revision 单调性、`syncedToMacAt` 重写审计、speaker merge 模板聚合、公开 DB writer 绕过仓储、DEBUG 迁移清库和孤儿音频生命周期风险。
它们**不是经本轮复现的活动缺陷**，也不能因删除旧计划就视为已修复；相关代码再次改动时先核对现有迁移/契约与测试。
LLM/CloudKit/RAG、merge/split 新设计、自动音频缓存清理、routerless/Bluetooth-only、40 人声学质量及分发更新留待另行定范围，不作为本轮已完成能力。

## 必须关闭的产品门禁

1. 在选定最终 build 上复核 NOW-001 用户无线可用报告：USB 不连、同网、发现/真实路径、固定身份重连与重启。未经授权不操作真实设备。
2. 真实短/长音频双向传输、哈希/文字/播放相等、prefix 中断/终止恢复与丢回执，经两端产品入口验证。
3. iPhone 保存→无线同步→真实 Mac 模型→版本发布→iPhone 可见结果；取消、重试、过期结果与重新分段保护不丢编辑。
4. 本地与远端身份/改名/模板、真实来源与兼容模型、授权暂停/撤销、离线修改/重启/删除后保留；与真实声音匹配分开核实。
5. 自然识别→绑定→提交→已挂载行显示的分阶段延迟，前后台生命周期、持续采集、录音后立即开下一场与资源上限。
6. NOW-005/006/007 及语言/外观/大字体/键盘/VoiceOver 的原生交互，不以 build 或静态截图替代实际操作。
7. 最终代码审查、改动后针对性测试、实际包来源/哈希与最终提交/合并/推送记录由协调者补入。未执行项明确保持未验证。

### 旧 immutable-copy v2 回归入口

冻结来源 `5d61b80f84052897e476b5ff8c1c15f0648e410a`；契约 [MAC_SYNC_PROTOCOL.md](MAC_SYNC_PROTOCOL.md)，codec [MeetingCopyWire.swift](Shared/Sync/MeetingCopyWire.swift)。
这是明确授权后的新会议副本，不含自动处理/结果回传/身份/声纹/删除传播。不要把新自动同步的能力写入 v2。

- 原生 Mac 右上角 Connection 明确启用副本接收，iPhone 重新连接并显式 Send/Retry；首次 SAS 两端确认，固定身份重连无需重新比较。**不能再使用旧文档的 Command-3 Connection 导航。**
- 验证完整 hash/可播放 M4A/稳定 ID 后 durable receipt，重试幂等；prefix 中断与重启、丢回执、重复 chunk、changed manifest、错误 hash、disk/SQLite failure 均 fail closed。
- 现有 meeting/删除 tombstone 冲突不覆盖/复活；撤销接收/取消配对使会话失效；旧 v1/无 TXT hint 不主动 probe；超限在 status 前 `failed/storage`。
- 现有 XCTest suites：`MacMeetingCopyInboxTests`、`MacMeetingCopySessionTests`、`MacMeetingCopyConnectionTests`、`MacBonjourServiceTests`、`MacPairingIntegrationTests`；UI：`MacMeetingCopyUITests`。按 [README 隔离入口](README.md#严格隔离) 组合 `-only-testing`，使用 `TranscriptMacTests` / `TranscriptMacUITests` target。
- 日志 subsystem `com.transcript.mac` 的 BonjourPublishing/PairingSession/MeetingCopy 不得记录音频/文本载荷、完整向量或私钥。TCP reference-client 测试不是实际 iPhone sender→Mac 产品验收。

真 CAM++ 复测沿用已有 runner：在独占 fixture 根准备 `models/`、`audio/`，显式设置 `BACKEND_REAL_CAMPLUS=1`、`BACKEND_REAL_FIXTURE_DIR`，执行 `swift test --package-path Packages/TranscriptCore` 的 `Voiceprint|ReprocessingVoiceprintTests|SpeakerAnalysisProvenanceTests|LiveSpeakerRepositoryTests` 选择。
iOS 用专用 Simulator 的 `TranscriptCore` scheme 与对应 `TEST_RUNNER_BACKEND_REAL_*` 环境，fixture 须在该测试 host 可访问的隔离目录；准确 selectors/命令见既有 `voiceprint-core-ios-final.log`。
所有新产物目录按 README 隔离，不复用用户库或旧 session 的临时路径。

## 本轮最终记录

**待协调者在修复与 QA 结束后填写**：修复提交、真实执行测试/失败与重跑、未覆盖条件、设备/权限边界、最终 build 来源、merge/push 回执。
本次文档合并只整理范围与证据，不关闭任何 NOW/BUG/REQ 项。
