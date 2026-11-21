# IPA 构建加速验证结果

复核日期：2026-11-21（Asia/Shanghai）。分支：`codex/arcane-settings`。最新已验证提交：`c5ebe4ed681063b35dae4cb73fbc254906984989`。

## 已确认的结果

[build35](https://github.com/fei256/yingxiaios/actions/runs/44849028761) 的 IPA 构建和模拟器测试均成功。与优化前的 [build29](https://github.com/fei256/yingxiaios/actions/runs/44733790941) 相比，IPA 任务从 **72 分 22 秒降到 38 分 11 秒**，减少 **34 分 11 秒，约 47.2%**。

此数字是两次实际运行的比较，不是同源码、同工具链的严格 A/B 实验：期间使用了预装的 Xcode 16.4 / iOS 18.5，编译并行度从 2 调整为 3，应用也有界面修改。GitHub 托管构建机的负载、网络及排队时间仍会变化，不能保证以后每次都恰好用时 38 分钟。

| IPA 主线步骤 | build29 | build35 |
| --- | ---: | ---: |
| iOS 平台恢复、安装或验证 | 9 分 19 秒 | 1 秒 |
| 原生依赖缓存恢复与准备 | 25 分 47 秒 | 1 分 34 秒 |
| Release 编译、归档、校验和打包 | 33 分 56 秒 | 32 分 40 秒 |
| **IPA 任务总时间** | **72 分 22 秒** | **38 分 11 秒** |

表中步骤不是完整清单；任务总时间还包含源码检查、工具准备、Swift 包解析、缓存保存和附件上传。原生依赖一项按对应恢复、准备步骤相加：build29 为 5 + 1,542 秒；build35 为 84 + 10 秒，未混入原生缓存保存步骤。任务时间按 GitHub jobs API 的开始和结束时间计算，不包含等待构建机的排队时间。

build35 的模拟器任务耗时 **10 分 39 秒**，与 IPA 任务并行，先于 IPA 任务结束。保留测试没有增加这次构建的关键路径。该次运行从触发到最终状态更新约为 38 分 18 秒。

## 编译缓存的实际效果

原生依赖缓存复用已得到实际验证：build35 恢复了相同配方的 `ios-native-v3` 缓存，准备步骤只花 10 秒，Python runtime 收据和原生输出校验通过。iOS 平台报告为 `already-installed`，无需恢复旧的大型平台包。

**应用编译缓存虽命中，但没有观察到省掉重复编译。**

| 记录 | build33 | build35 |
| --- | ---: | ---: |
| `archive.log` 中以 `SwiftCompile ` 开头的记录数 | 216 | 216 |
| 其中应用目标 `TVBox-iOS` 的记录数 | 190 | 190 |
| 完整 `xcodebuild archive` 时间 | 1,995.60 秒 | 1,846.73 秒 |

[build33](https://github.com/fei256/yingxiaios/actions/runs/44802994418) 的提交为 `86505e25557c70024b3cca8de39c2130d99e8c56`。它与 build35 之间仅修改 `Tests/PlaybackCache/forward-cache.test.mjs`，应用源码相同。build35 恢复了 build33 的编译缓存，恢复了 1,508 个未变文件的修改时间；依赖准备日志还明确显示 XcodeGen 工程未变化。两次包体验证记录中的主程序 SHA-256 也相同：

```text
3b64ce1685e4335cf6cbdcf7c9432cc004284fa5f4d6cabfc53ffe286e32b1b8
```

以上 `SwiftCompile` 数量是统一口径的日志记录数，包含批次和单独编译记录，不代表 216 个不同源码文件。数量及目标分布没有下降，SwiftSyntax、TVCore 和应用仍有完整编译记录，因此不能把归档耗时的小幅变化归因于增量缓存。当前最主要的剩余耗时是 Release 编译、归档；造成缓存重编译的具体条件尚未得到验证。

本次复核使用现有成功运行、完整日志和附件确认结果，没有再次触发等价构建。构建中间缓存恢复和保存合计约 56 秒；不能把缓存上传成功本身当作编译加速的证据。

## 完整构建验证

- 构建流水线回归：48 个测试通过，实际测试执行耗时 4.224 秒。
- 播放缓存与范围恢复：19 个测试通过，0 失败、0 取消、0 跳过，执行耗时约 1.93 秒。
- 模拟器：6 个输入／日期测试和 7 个控件／日历交互测试通过，均为 0 失败；日志为 `TEST SUCCEEDED`。
- Release 归档成功；源码和原生输入在构建过程中均无变化；IPA 校验错误列表为空，ZIP 完整性通过。
- 产物为未签名 IPA，版本 1.8.13，构建号 35，最低 iOS 16.2，支持 iPhone 和 iPad。原有真机测试边界见 [流程审计](build-pipeline-audit.md)。

[build35 IPA 附件](https://github.com/fei256/yingxiaios/actions/runs/44849028761/artifacts/14685284380)：`Yingxia-iOS-build35-unsigned`。IPA 文件本身为 102,624,207 bytes，SHA-256：

```text
6037542f8e0a3f9a710744afdd7e982079cb590be36ecf005bf0d000ebc19958
```

这与外层 Actions 附件 ZIP 的 SHA-256 是不同的校验对象。

## 可复核证据

完整 GitHub run、jobs、artifacts 响应及日志保存在工作区同级目录 `arcane-settings-delivery/build-optimization-dda2cd8/`；结构化结果为该目录中的 `final-speedup-verification.json`。主要文件包括：

- `build29-baseline-jobs.json`、`build29-run.json`。
- `build33-run.json`、`build33-jobs.json`、`build33-artifacts.json`、`build33-diagnostics.zip`。
- `build35-run.json`、`build35-jobs.json`、`build35-artifacts.json`、`build35-diagnostics.zip`、`build35-build.log`、`build35-native-tests.log`。

两份诊断附件已分别核对 GitHub 提供的 SHA-256，随后读取其中的 `ipa/archive.log`、`ipa/archive-result.json`、`ipa/ipa-delivery.json`、`ci/cache-keys.json`、`ci/timestamp-restore.json` 和测试日志。接口使用已有 Git 登录凭据认证，证据文件不包含登录凭据。

第三方缓存说明通过 `smart-search fetch 'https://raw.githubusercontent.com/irgaly/xcode-cache/main/README.md' --raw --expect text --no-cache --timeout 35` 核对，来源：[xcode-cache README](https://github.com/irgaly/xcode-cache)。它说明缓存输入修改时间及内容哈希的作用；本报告中的实际加速结论以本仓库构建日志为依据。
