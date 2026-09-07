# Transcript

原生 iPhone 会议录音与 Mac 本地处理，使用共享 Swift/SQLite 数据层和经过认证的局域网同步。原始音频是核实依据；转写、说话人归属和处理结果不能冒充确定事实。

## 当前入口与状态

**2026-09-07 17:42 用户反馈后的软件修复已集成至 `8a81aef`，两端更新后的物理闭环仍待复验。**
用户已报告拔掉 USB 后无线同步可用。本轮补齐 Mac 三模型声纹处理和原子发布、修复身份更新造成的结果回传拒绝、改善 iPhone 证据积累和录音交互。
测试、剩余延迟、安装构建与提交对应关系只在[验收表](SYNC_ACCEPTANCE.md)记录；构建成功不是用户真机验收通过。

| 文档 | 唯一职责 |
|---|---|
| [iOS 当前范围](IOS_UI.md) | 采集、详情、语言、身份和手机交互要求 |
| [Mac 当前范围](MAC_UI.md) | 原生窗口、会议处理、本地声纹、模型设置和存储要求 |
| [验收与未关闭问题](SYNC_ACCEPTANCE.md) | 当前反馈、证据边界、历史回归项及最终 QA 门禁 |
| [同步 ADR](SYNC_ADR.md) / [v1 契约](SYNC_CONTRACT.md) | 自动双向同步的架构与规范；不是产品验收报告 |
| [固定副本 v2](MAC_SYNC_PROTOCOL.md) / [配对协议](MAC_PAIRING_PROTOCOL.md) | 保留兼容性的冻结协议 |
| [机器可读状态](agent_state.yaml) | 当前快照与上述文档链接，不保存历任代理任务日志 |

已删除互相矛盾的 `PLAN.md`、`UI.md`、`BUGS.md`、`MAC_COPY_QA.md`。
必要要求、未关闭问题及副本回归门禁已合并至上述文档；旧设计、阶段记录和完整报告留在 Git 历史，不另建归档目录。
优先级：版本化协议约束 wire/认证语义；平台文档描述当前产品要求；验收表才记录是否验证通过。
协议中的历史验收文字也不覆盖最新验收表。

## 当前范围与不可破坏的边界

- iPhone 独立采集，Apple Speech 转写与 Sortformer/CAM++ 说话人处理分离；Mac 从真实音频处理并将已发布结果同步回手机。后者的产品闭环仍是本轮门禁。
- 配对、已连接、持久同步、可播放音频、处理完成、结果回到另一端是不同状态。Bonjour 名称/TXT 和绿色圆点都不是授权或回执。
- 自动同步使用独立 `automaticSync.v1` / `automaticSyncResources.v1` 能力、持久操作和输入版本保护；不改造旧副本协议来暗中传送新功能。逻辑排序、删除和分段映射以 v1 契约为准，不再采用旧单向权威或裸墙钟覆盖方案。
- 声纹授权按已固定身份的设备单独控制，配对不等于同意分享。未知模型/预处理来源的模板保留但不参与不兼容匹配；不能放宽阈值、伪造向量或强分 speaker 制造成功。
- 音频先可靠封存，再完成识别；重处理失败/取消保留原音频、原结果、会议 ID、标题及用户名字。会议删除与仅清理本地音频不同：删除传播遵循持久 tombstone，保留全局身份/声纹；旧回执不能复活已删会议。
- 不自动清理唯一音频副本；历史 `audioVerifiedOnMacAt` 等字段不授予自动处理或新同步权限。取消配对/撤销分享不是远端全量抹除。
- **LLM、RAG、自动摘要/命名和相关新界面不在本轮范围。** 已有用户 LLM 数据、配置及其他保留资料不因此删除；本文不声称已删除这些数据，也不授权清理它们。翻译、云端兜底、Python 应用运行时、CloudKit 改造及分发/公证不纳入本轮。

## 工程与验证入口

唯一 Mac target 是根 [project.yml](project.yml) 的 `TranscriptMac`，源码在 [MacApp](MacApp)；
iOS 在 [App](App)，widget 在 [WidgetExtension](WidgetExtension)，共享数据库/同步在 [TranscriptCore](Packages/TranscriptCore)。
[Shared](Shared) 保留共用配对与兼容桥接；[设计预览](design/mac-app.html) 只是历史交互参考，不是原生验收。

使用已有 XcodeGen、Xcode 26+/Swift 6 和 SwiftPM runner；deployment target 以 `project.yml` 为准。
在独占的工程生成窗口运行 `xcodegen generate`，不要与其他 owner 并发重写工程。
只有缺失工具/依赖导致验证失败时才安装或恢复；不要为文档修改运行会更改环境的 bootstrap。

以下为**针对性验证示例，不是全部验收，也不是本轮执行记录**。在仓库根目录运行，先分配全新的专用 Simulator，并将其 UDID 设置为 `SIMULATOR_UDID`；禁止使用用户已有设备。

```sh
RUN_ID="$(uuidgen)"
QA_ROOT="$PWD/.build/qa-$RUN_ID"
mkdir -p "$QA_ROOT"

swift test --package-path Packages/TranscriptCore \
  --scratch-path "$QA_ROOT/core" \
  --filter 'AutomaticSyncPublicationReviewTests|AutomaticSyncProcessingInputTests'

xcodebuild -project Transcript.xcodeproj -scheme TranscriptTests \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID:?dedicated simulator required}" \
  -derivedDataPath "$QA_ROOT/ios" \
  -clonedSourcePackagesDirPath "$QA_ROOT/packages" \
  -parallel-testing-enabled NO \
  TRANSCRIPT_TEST_RUN_ID="$RUN_ID" \
  -only-testing:TranscriptTests/RecordingActivityLifecycleTests \
  -only-testing:TranscriptTests/LibraryObservationTests \
  -resultBundlePath "$QA_ROOT/ios.xcresult" test

xcodebuild -project Transcript.xcodeproj -scheme TranscriptMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$QA_ROOT/mac" \
  -clonedSourcePackagesDirPath "$QA_ROOT/packages" \
  -parallel-testing-enabled NO \
  TRANSCRIPT_MAC_TEST_RUN_ID="$RUN_ID" \
  -only-testing:TranscriptMacTests/MacProcessingTests \
  -only-testing:TranscriptMacTests/MacMeetingCopySessionTests \
  -resultBundlePath "$QA_ROOT/mac.xcresult" test
```

### 严格隔离

- iOS DEBUG 测试必须同时设置 `TRANSCRIPT_TEST_STORAGE=1` 与 UUID `TRANSCRIPT_TEST_RUN_ID`；hosted scheme 已提供前者。`TRANSCRIPT_UI_FIXTURE` 只控制播种，不替代隔离。UI runner 使用现有 `isolatedApp`。
- iOS 数据位于专用 Simulator 的 `Library/Caches/TranscriptTestRuns/<UUID>/Transcript/`；Mac 使用 `TRANSCRIPT_MAC_TEST_RUN_ID` 的私有测试库/偏好/配对命名空间。重启测试沿用同 UUID，独立运行换 UUID，绝不回退生产库。
- Mac app-hosted 测试可能影响同 bundle 正在运行的应用，须先协调独占测试窗口；不终止用户进程、不替换用户已安装应用。真实 Keychain 测试需要现有开发签名和正确 entitlement，关闭认证/签名不是修复。
- 只用隔离 fixture 或明确许可的公开语音。文件推理、synthetic-vector、UI fixture、真实麦克风 E2E、物理双端闭环分别记录。模型测试 opt-in 跳过不算推理通过。
- 不操作用户 iPhone、信任确认、权限弹窗、麦克风授权、录音、数据库或现有模拟器。局域网与防火墙权限分开；不关闭防火墙或自动批准声纹共享。
- 产物/中间文件放本 checkout 的唯一目录；结束后先关闭本轮自己启动的服务，再仅清理确切归属本轮的目录和新建 Simulator，保留需要的 QA 证据。不扫描清空共享缓存，不用临时系统目录。
- 每条验收附来源提交、测试选择、平台/runtime、输入、实际结果与证据名。新生产修改必须重新验证，不能继承旧提交的“通过”。
