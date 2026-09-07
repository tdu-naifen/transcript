# 当前验收与未关闭问题

更新：2026-09-07，依据 17:42 用户反馈。**软件修复集成提交 `8a81aef` 已通过下列验证；用户两端更新后的物理闭环仍待复验。**
本文取代旧计划中的完成/阻塞总论；[README](README.md) 是入口，[iOS](IOS_UI.md)/[Mac](MAC_UI.md) 是要求，协议文件保持独立规范职责。

## 最新用户反馈：不是新测试日志

| ID | 观察或要求 | 当前状态与关闭条件 |
|---|---|---|
| NOW-001 | 拔掉 USB 后无线同步可用 | **用户报告可用**，不是自动化日志；保留该正向反馈，不再笼统声称“无线完全不可用”。实际 build、endpoint/path、同网重连/重启证据仍未补齐。 |
| NOW-002 | Mac 重处理结果没回到 iPhone | **实现与软件回归通过，物理复验待进行**。`a35501e` 在发布端和接收端识别身份-only revision 漂移；内容哈希必须仍匹配。保留最新归属/明确清除，真正文字、音频、时长、语言修改仍受围栏保护。结果在原 meeting ID 发布，不重新导入。 |
| NOW-003 | Mac 没有本地声纹 | **产品接入与真实模型回归通过，双端物理声纹回传待复验**。`9153b54` 三模型真实任务、发布/重处理/恢复和 192 维模板持久化；`a35501e` 同一事务提交文字、稳定身份、资源及同步意图，保持每设备声纹授权。 |
| NOW-004 | iPhone Identifying 太久 | **证据积累根因已修复，但不承诺即时识别**。`b865c96` 将不确定干净证据从反复 2 秒改为积累至 4/5 秒；返回说话人不再被未绑定过渡锚永久否决。真实模型仍有 10 秒窗口下限，更多延迟与覆盖数字见下文。 |
| NOW-005 | App 前台应保持唤醒 | **实现与生命周期回归通过**。`8a81aef` 的场景级 idle-timer lease 覆盖前台浏览/录音，inactive/background/移除释放，其他活跃场景不被误释放；未在用户 iPhone 上等待自动锁屏复验。 |
| NOW-006 | 底部录音控件与上滑动画 | **实现、原生 UI 和无障碍回归通过**。`8a81aef` 底部原生导航旁固定 mic，录音控制在其上方；拖动时直接跟手，松手按速度收敛，阈值/取消/重复提交受同步 action gate 保护。设备帧率与主观手感仍需用户试用。 |
| NOW-007 | Mac 整张会议卡可点 | **实现/review 完成，窗口自动化阻塞**。`9153b54` 完整选择行矩形命中区域，保留键盘/焦点；新增窗口测试未执行成功，不计作通过，需在新构建点留白/边缘复验。 |

这些条目不得继承之前测试的通过状态。物理双端**完整闭环仍未关闭**，也不能把用户的无线可用报告扩写成声纹或结果回传成功。

## 本轮实现、独立审查与 QA

生产集成提交：`8a81aefcc492a70842c2c98af507f461c6295023`。
逻辑提交依次为文档 `807f65a`、实时声纹 `b865c96`、原子发布/并发合并 `a35501e`、
Mac 产品接入 `9153b54`、iPhone 交互 `8a81aef`。之后的验收文档提交不改变生产字节。

| 验证 | 实际结果与范围 | 证据位置 |
|---|---|---|
| 独立 Core/UI/Mac review | 发现并修复一个推断身份默认值导致并发 publication 不收敛的问题；最终复核无剩余高置信 blocker。保留原 v1 inferred-ID 格式，不改旧端解析或冻结协议。 | session review 记录、`acceptance-core-review-repaired.log`、`acceptance-final-publication.log` |
| 发布与冲突 | 身份赋值/清除可回传并双向收敛；publisher 身份/名字修改可合并，文字/时长/语言修改仍拒绝旧结果；4 种身份元数据/资源顺序、重复交付、原子回滚与授权过滤通过。 | `acceptance-final-publication.log`；初始 `.staleRevision` 复现见 `acceptance-result-return-before.log` |
| Core 集成回归 | 初次 45 XCTest 中 8 个模型 opt-in 跳过，131 Swift Testing 通过，无失败；随后独立加载真实模型的 27 XCTest 全部通过、无 skip，覆盖该 opt-in 路径。最后发布围栏补充选择另行通过。 | `acceptance-core-integrated.log`、`acceptance-live-real-independent-verified.log` |
| 独立 iOS 原生 | 112 passed，0 failed/skip，11 个 suite；生产/test/project 清单前后稳定，478 个生产文件逐一核对一致。 | `acceptance-ios-receipt.json`、`acceptance-ios-*` 日志/xcresult/清单 |
| 独立 Mac 原生 | 83 passed、1 范围外 LLM opt-in skipped、0 failed；实际三模型处理/发布/重处理运行，真实 192 维声纹持久化、来源指纹与原始音频完整性通过。普通签名包不含 XCTest 或公共测试模型。 | `mac-acceptance-final-receipt.txt`、对应日志/xcresult/生产清单 |
| iPhone UI 目标 | 29 unit + 4 UI tests passed：底部布局、展开/收起、旋转、详情导航、最大 Dynamic Type 下的录音控制、减少动态效果、中英文 accessibility 和重复隐藏 dock 修复。不是整个 App 的无障碍全量认证。 | `acceptance-recording-ui.log`、`.xcresult`、`acceptance-recording-ui-evidence/` |
| Mac 产品真实路径 | 签名三模型实际运行生成 5 个 ASR 片段、2 个声纹/9 个时间段；发布/重处理、原始字节不变、模板和身份持久化回归通过。共享模型来源重建选择为 28 passed、0 skip。 | `.build/mac-final-handoff/shared-provenance.xcresult`；最终独立矩阵见 Mac acceptance receipt |

iPhone 模型延迟证据来自既有公开 LibriSpeech 拼接样本，不是用户的自然会议。
修复前后内部目标行覆盖由 **4/9 增至 6/9**，返回说话人恢复；保守的过渡区仍 Unknown。
首个/第二个身份出现在 **10 秒/22 秒累计音频**，不是毫秒级识别承诺，也不是物理 iPhone wall-clock 测量。
阶段中位示例：模型加载 38 ms、窗口提取 80 ms、聚类 0.56 ms、CAM 74 ms；
已有行在证据确认后的数据库/观察约 22–33 ms，捕获渲染约 49–58 ms。推理、干净证据等待和 UI 延迟分别记录。
没有降低 0.7 相似度、0.1 margin 或 2 秒干净音频门槛，也没有用前一个人或强制刷新填 Unknown。

动画参考 Robinhood 的直接操控、松手确认和取消回位原则；使用本地 SwiftUI 手势与弹簧，
不引入 Lottie 依赖，也不声称得到其私有参数。公开参考：[Robinhood motion case study](https://lottiefiles.com/case-studies/robinhood)。

**Mac 扩展窗口门禁未关闭**：实现者的一次窗口测试为 1 passed / 1 failed：真实处理/播放生成了公开 fixture 截图，
整卡实验 harness 在取得 `NSAccessibility` 对象前 `XCTUnwrap` 失败，尚未验证点击动作。该实验被替换为独立 QA bundle 的 opt-in XCUITest，
不能把失败当作通过。后续独立窗口/播放复验三次在 XCTest IDE-session 建立阶段停滞，尚未执行 test methods。
另一个隔离 bundle-ID 方案缺少开发 provisioning profile；未修改账号、profile 或系统权限，也未终止用户进程 PID 8293。
这些中止不是新的 pass/skip，之前的 83 passed 仍有效，但不包含后加的窗口断言。`c0a5e49` 的最终窗口测试与 LLM UI 范围 gate
已通过签名 `build-for-testing`，编译不等于运行通过。详见 `acceptance-mac-owner-native-view.xcresult`、`mac-acceptance-window-*`、
`mac-acceptance-playback*`、`acceptance-final-mac-test-build.log` 和最终 receipt。

失败/重跑保留：发布 baseline 因身份 revision 漂移失败；编译期间并发 API/测试 fixture 签名和 macro 修正；
Mac 最初模型说明缺少中英文 key 的测试失败，补齐资源后重跑；独立真实模型首次缺少 checkout 的公开音频路径，
只临时链接已有公开 corpus 后 27/27 通过并移除链接。iOS 第一次测试期间发现两个 Core 文件变化，
已以稳定的最终生产清单重新构建并重跑 112 项，不使用最初那次 green 作为最终凭据。

证据根为本机 session `~/.copilot/session-state/a4ab0df9-4371-44ee-be89-af180b56d832/files/`；
需要保留的 checkout QA 日志/截图在清理前复制到该目录。开发签名包未自动安装到用户设备，
Mac 当前用户进程未被替换/终止。合并、远端 SHA、包签名/校验值在最终 `acceptance-release-receipt.json` 记录。
**必须两端都更新后，才能复验本轮结果回传和声纹闭环。** 无线可用反馈不被扩写成全部通过。

## 历史基线证据：不覆盖本轮验收

此前 main 已合并并推送 `3bfc72b`（协调者报告）；生产包来源 `7dac0e34883e2d4b940693c646289435f85d4881`，真模型测试 `dcf161e`，`3bfc72b` 为相应 QA 文档记录。
这些历史结果不是本轮新增代码的验收凭据；本轮证据在上节。

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
