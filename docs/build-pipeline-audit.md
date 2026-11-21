# Windows 上传与 GitHub Actions IPA 流程审计

审计日期：2026-11-19。仓库：[fei256/yingxiaios](https://github.com/fei256/yingxiaios)。范围包括源码导入、公开上传、依赖准备、云端归档、包体验证和下载交付。

## 判断依据与结论

首次成功的 [build06](https://github.com/fei256/yingxiaios/actions/runs/44439647067) 对应提交 `b11852e`，耗时 43 分 56 秒，其中应用归档约 28 分 47 秒。交付报告的错误列表为空，包含 104 个 framework、105 个 Mach-O 文件；构建期间没有检测到源码变化。

这证明该提交在当时的 macOS / Xcode 环境中完成了编译、链接与未签名 IPA 打包。不能把它扩大为“所有功能已经测试”或“未来永不失败”。截至 2026-11-21，后续 [build35](https://github.com/fei256/yingxiaios/actions/runs/44849028761) 的完整云端构建和模拟器测试均已通过；最新缓存与耗时复核见 [IPA 构建加速验证结果](build-optimization-results.md)。当前使用预装的 Xcode 16.4 / iOS 18.5，当前兼容目标为 iOS 16.1；下表中的 Xcode 16.1 / iOS 18.1 是审计当时的历史处理记录。

## 已发生的问题、原因与处理

| 环节 / 记录 | 确认的问题与原因 | 已实施的处理与防复发措施 |
| --- | --- | --- |
| Windows 导入；[build01](https://github.com/fei256/yingxiaios/actions/runs/44346168232) | `Packages/TVCore/Package.swift` 被解压成只写着路径的普通文本文件。Swift 读不到真正的 manifest 首行，于是报告不再支持 tools 3.1。不是应用本身要求 Swift 3.1。 | 三个包内别名恢复为 Git `120000` 链接，shell 和带 shebang 的 Python 脚本恢复为 `100755`。新增最先执行的源码预检，核对索引中的链接类型、目标、工作目录内容、脚本权限、LF 和 Swift 6.0 首行。 |
| GitHub 上传 | 此前出现 schannel / OpenSSL EOF、RPC 不能回绕等连接错误。本次 OpenSSL / HTTP 1.1 推送也再现 EOF；直接连接推送成功后，另一次只读检查出现 TLS packet-length 错误，随后 Schannel 检查成功。现有证据不能唯一确定代理、传输链路或远端临时故障的责任。 | 保留 TLS 验证，有限重试并以远端实际提交 SHA 判断是否成功。曾同时出现失败退出码与 `Everything up-to-date`，不能只相信最后一句文字。改变连接参数是恢复手段，不能宣称网络已永久修好。 |
| Git 同步 | 远端 README 被修改，直接推送被 `fetch first` 拒绝。 | 先获取远端，再整理未发布的本地提交，保留远端修改；未强推覆盖。之后推送前检查两端差异。 |
| 浏览器创建仓库 | 原拟名称中的连字符没有保留，最终实际名称为 `yingxiaios`。 | 当前 Git remote、README 与 Actions 链接均指向实际仓库。名称差异不影响构建。 |
| 依赖下载；[build02](https://github.com/fei256/yingxiaios/actions/runs/44354189085) | FFmpeg Git clone 报 `Could not resolve host: github.com`，当时没有 clone 重试。诊断附件上传也出现过超时，服务自身重试后成功。 | FFmpeg / dav1d clone、依赖准备与 Swift 解析都有有限重试，仍核对固定提交。归档下载统一写临时文件并校验 SHA-256，成功后才替换正式文件；已损坏的缓存会重新下载。 |
| 平台组件；[build03](https://github.com/fei256/yingxiaios/actions/runs/44359199322)、[build04](https://github.com/fei256/yingxiaios/actions/runs/44432592899) | 能找到 iPhoneOS SDK 18.1，但归档仍提示 `iOS 18.1 is not installed`。仅切换 Xcode 或初始化 simctl 没有解决本次 runner 的平台状态问题，第四次仍失败。 | 明确选择 Xcode 16.1，并安装 / 导入对应平台组件。新增 SDK、DMG 完整性、缓存收据和实际可用 runtime 版本检查；损坏缓存或导入失败会尝试重新下载，不只相信命令退出码。 |
| Swift 编译；[build05](https://github.com/fei256/yingxiaios/actions/runs/44433777070) | 完整 archive.log 在 `App/LocalSettingsReorderRow.swift:10:13` 报 `call to main actor-isolated parameter 'completion' in a synchronous nonisolated context`。Swift 6 不允许从该同步回调直接调用受主线程隔离的 completion。 | 用 `Task { @MainActor in ... }` 调用 completion，build06 已编译通过。独立类型检查移到平台和原生依赖准备之前；失败摘要同时显示前面的编译错误与日志尾部，避免错误被大量 note 淹没。 |
| 下载交付 | Actions 显示约 197 MB，容易被当成 IPA 体积。它还包含约 80 MB 链接图和约 23 MB 编译日志，且外层压缩为 0。 | IPA 与小型校验报告使用明确文件清单上传；完整日志另存为压缩等级 6 的诊断附件。 |
| 本次整改复验；[build07](https://github.com/fei256/yingxiaios/actions/runs/44463555002) | 新增检查把 `hdiutil verify` 的 `has no checksum` 非零退出误判为损坏，导致三次导出合法的 Apple DMG 后仍失败。这是校验实现错误，不能归因于下载损坏。 | 有内置 checksum 的镜像必须通过 verify；仅明确没有 checksum 时，进一步验证 imageinfo 可读，再由 Xcode 导入与可用 runtime 版本检查确认，之后记录完整文件 SHA-256。新增四个测试，分别覆盖有 checksum、合法无 checksum、实际 checksum 错误及不可读镜像。 |
| 本地清理 | 组合式递归清理命令曾被自动审批审查拒绝。 | 改为核对明确目录后逐文件和空目录清理；保留原有用途不明的文件。审计采集脚本和临时工具不作为项目源码提交。 |

最主要的原流程缺陷是没有在昂贵的依赖准备前检查源码结构与编译环境，且一次失败时只输出日志尾部。结果是多个问题需要等到后半段才暴露。build07 还说明：检查本身也可能误判，模拟测试必须覆盖实际文件格式，并由真实云端运行补充验证。现在能独立检查的条件已前置；应用完整编译仍不可省略。

## 审计中发现并补强的隐患

1. **中断下载被反复使用。** 原 AV3A 下载直接写正式文件，仅判断文件存在；其哈希失败后，外层重试仍会读同一份坏文件。现统一原子下载、SHA-256 核对和无效缓存重新获取，也用于 CPython、Rust / OpenSSL 等已有固定哈希的归档。
2. **Python 缓存失效不彻底。** 旧 `.prepared` 只代表少数输入文件的签名，没有验证缓存输出；即使脚本修改触发重新组装，同版本 wheel 仍可能被复用。现将构建脚本与工具链纳入签名，按签名使用独立中间目录，并逐文件验证完整 runtime 收据。旧收据、损坏文件和额外文件均不能被当成有效缓存；只有构建成功才写新收据。
3. **缓存命中时依赖链接没有完全恢复。** ASR 提前返回会略过链接创建，Node 则只看 framework 目录存在。现 ASR 在缓存命中路径也恢复链接；Node 检查设备二进制与许可证，修复缺失 / 错误链接，并拒绝覆盖真正的目录。
4. **构建前后比对的覆盖不足。** 旧源码快照忽略符号链接和执行权限，原生快照只检查已有文件。现跟踪链接目标和脚本权限，并对前后完整集合比较，覆盖增加、删除及修改，也覆盖 Python 与 Node 设备 runtime。
5. **校验可能被 Python 优化模式关闭。** 包装脚本包含 `assert`，`python -O` / `PYTHONOPTIMIZE` 会跳过它。关键入口现明确拒绝优化模式，内嵌补丁检查改用显式失败；IPA validator 的错误列表也显式导致失败。
6. **arm64 不等于 iOS 设备二进制。** 原 all-Mach-O 循环检查架构与最低版本，但未逐个限制平台。现应用和每个 Mach-O 都必须报告 `IOS`，防止 arm64 模拟器或其他平台文件漏过。
7. **Swift 缓存保存时机不对。** 原生缓存早于 Swift 解析保存，因此其中通常没有有效的 SourcePackages。现单独在解析前恢复、解析成功后保存固定 Package.resolved 对应的 Swift 缓存。
8. **Actions 的 Node 20 弃用提示。** build06 仍使用 v4 actions，被 runner 强制切换 Node 24。现使用固定提交的 checkout v5、cache v5 和 upload-artifact v6，均声明原生 Node 24 支持，继续关闭 checkout 凭据持久化。

原生缓存仍采用严格输入哈希，不跨不同配方盲目恢复。修改构建脚本、原生来源或 Python 配置时发生冷构建属于预期；首次完整原生准备曾耗时约 26 分钟。缓存保存失败只影响下次速度，不允许绕过本次构建和校验。

## 验证记录

- Windows：38 个回归测试全部通过，包含链接丢失、索引目标错误、脚本模式、CRLF、中断下载、错误哈希、缓存配方 / 工具链改变、损坏收据、原生文件新增、优化模式、错误 Mach-O 平台，以及 Apple DMG 的合法无 checksum 格式。
- Python 文件、工作流内嵌 Python 与 Bash 脚本语法检查通过。
- actionlint 1.7.12 工作流检查通过；测试工具归档按官方 release 的 SHA-256 校验，临时工具在审计结束时清理。
- 已跟踪文件中未发现 `.p12`、`.p8`、`.mobileprovision`、`.ipa` 或本项目列出的个人配置文件。此检查针对明确文件类型，不等于任意形式秘密的全局证明。
- 后续完整 GitHub Actions 运行：[build35](https://github.com/fei256/yingxiaios/actions/runs/44849028761) 已成功，48 个流水线回归测试、19 个播放缓存测试、13 个模拟器测试及 IPA 校验均通过；IPA 任务耗时 38 分 11 秒。应用编译缓存命中但仍发生重复编译，不能宣称增量编译加速已验证，详见 [加速验证结果](build-optimization-results.md)。

回归测试使用临时目录和模拟下载 / Xcode 返回结果，验证故障处理分支；它们不能替代实际 macOS 编译。完整构建仍须通过工程生成、固定 Swift 包解析、Release 归档、源码 / 原生一致性检查、包体验证和上传。

## 包体大小与下载选择

build06 的 IPA 实际为 **102,902,207 bytes，约 103 MB / 98.1 MiB**。SHA-256：

```text
4419f31e3413af3deab71ade08260ca7308bb49233efc487b9a177d46c52276b
```

Node 引擎、Python 及原生扩展、FFmpeg / ASR 和主程序本身占据包体；这不是单纯界面程序。此次拆分附件减少的是下载中的诊断文件，不声称删减 runtime 或改变 IPA 功能。之后下载 `Yingxia-iOS-build…-unsigned` 并解压，取其中 `.ipa`；排障时才下载 `iOS-build…-logs-…`。两类附件分别保留 30 天与 14 天。

## 后续修改的检查顺序

1. 在根 `App/`、`Sources/` 或 `Runtime/` 修改源码。在 Windows 上，三个包内链接可能显示为短文本占位；它们依赖 Git 的链接类型，不要当作普通 manifest 或源码目录编辑。
2. 推送前执行 `python Scripts/preflight-ios-source.py`、`python -m unittest discover -s Tests/BuildPipeline -v` 和 `git diff --check`。新增带 shebang 的脚本需在 Git 中设置执行位。
3. 获取远端状态，保留远端的新修改，再提交 / 推送。应用或构建相关路径变更会自动构建；仅 README / 网站 / 服务修改不会自动生成新 IPA。
4. 在 Actions 查看失败步骤与最早的实质错误。下载阶段检查网络及哈希；平台阶段检查 SDK / runtime；编译阶段查看 error 和完整 archive.log。不要通过关闭哈希、TLS 或校验来把运行变绿。
5. 下载成功附件，核对 SHA256SUMS；完成签名后，在最低支持版本及当前 iOS 真机检查启动、拖拽、Python / Node 来源、播放、原盘和字幕等实际使用功能。

## 尚不能由此保证的部分

- **签名与真机安装。** 输出为未签名 IPA，必须签名后安装；当前流程没有进行 Apple 账号、签名有效期或设备授权验证。
- **实际功能。** player-validation 明确是 linked-binary inspection，没有在设备上执行解码 / 推理。它能证明所需符号和资源被打入包，不能证明所有媒体、订阅、网络接口、音视频同步、拖拽体验或离线字幕运行正常。
- **未来环境和外部可用性。** macOS runner 镜像、Xcode 安装、GitHub / Apple 下载服务和第三方来源都可能变化。流程会在不满足条件时停止并保留诊断，不能保证这些外部条件不发生故障。

因此应以“当前提交的实际成功记录 + 已验证的故障拦截 + 明确的真机测试边界”评估可靠性，而不承诺整个应用或未来每次构建都绝对没有问题。
