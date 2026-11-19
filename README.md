# 映匣 Yingxia · iOS

映匣的独立 iOS 源码，面向 iPhone / iPad，最低 iOS 16.2。当前版本为 **1.8.13**，支持 Python、Node、QuickJS、FFmpeg、KSPlayer、原盘读取和离线语音字幕；iOS 不执行 JVM、JAR 或 DEX。

## 内容

- `App/`：SwiftUI 界面、播放器和 iOS 原生桥。
- `Sources/`：媒体、订阅、脚本运行、弹幕与原生播放器接口。
- `Runtime/`：Python / Node / JavaScript 宿主。
- `Vendor/`：本地适配、固定版本信息、补丁、许可证及依赖下载清单。
- `Scripts/`：依赖准备、iOS 工程生成、IPA 构建及包体完整性检查。
- `Services/`、`website/`：可选服务和介绍网站；不参与 iOS IPA 编译。
- `SOURCE-MANIFEST.json`：最初源码包附带的清单与 SHA-256；后续版本以 Git 提交和每次构建的源码校验报告为准。

当前包不携带个人订阅、账号数据、API 凭据、签名证书、Git 历史、已编译 App 或大型依赖归档。先准备依赖，再编译 IPA；它不是开箱即编译的离线依赖全集。

## 编译环境

- macOS，完整安装并选中的 Xcode；维护环境为 **Xcode 16.1 / Swift 6.0.2 / iPhoneOS SDK 18.1**。
- Python 3.10 或以上、Git、curl、XcodeGen、ripgrep、pkg-config。
- Python 构建会使用独立的 CPython 3.14 工具解释器；FFmpeg 构建会准备固定版本 Meson/Ninja。

使用 Homebrew 的环境可安装命令行依赖：

```sh
brew install python xcodegen ripgrep pkgconf
```

固定版本 Rust 工具链、iOS 目标和原生 Python 扩展由现有依赖脚本准备。`XCODEGEN` 可指向自定义 XcodeGen 可执行文件，`HOST_PYTHON` 可指向 CPython 3.14。

## 准备依赖

第三方归档以固定 URL 和 SHA-256 记录在 `Vendor/dependency-downloads.json`，准备后存放于被 Git 忽略的目录。FFmpeg、dav1d、CPython、NodeMobile 的固定版本及校验信息保留在对应构建脚本。

**AV3A 参考实现单独准备。** 此源码包保留本地适配、来源清单及 UWA 条款，未附带第三方参考源码和其中的模型。该参考实现并不按本项目 GPL 许可证授权，现有来源记录也未确认公开再分发许可。请先阅读 `Vendor/AV3A/UPSTREAM.md`，按原许可取得其中固定版本的归档；本工具只导入清单中的文件，并逐文件核对 SHA-256。

在项目根目录执行：

```sh
python3 Scripts/prepare-ios-dependencies.py --av3a-archive /path/to/av3a-pinned-source.tar.gz
```

该命令准备原生源码归档、Python、NodeMobile、原盘库、FFmpeg、离线语音库及 Swift Package 缓存，并生成 `Yingxia-iOS.xcodeproj`。后续依赖已齐备时可不带 `--av3a-archive`。下载和编译所需时间取决于网络与机器性能。

已在 GitHub Actions 的 macOS 构建机完成完整依赖准备、应用归档和未签名 IPA 校验，首次成功记录见 [build06](https://github.com/fei256/yingxiaios/actions/runs/44439647067)，对应源码提交 `b11852e`。准备脚本会在缺少工具、下载失败或哈希不匹配时停止；请依据输出处理。

## 构建 IPA

### 在 Windows 上通过 GitHub Actions 构建

打开仓库的 **Actions → Build iOS IPA → Run workflow**，选择 `main` 后运行。`Build number` 留空时采用 Actions 运行编号，也可以填写一个正整数。推送到 `main` 的应用、运行时、原生依赖或构建脚本修改也会自动触发构建；仅修改网站、服务或说明文档不会触发。

工作流使用 `macos-15-intel` 和 Xcode 16.1，补装缺少的 iOS 18.1 平台组件，下载固定版本依赖并校验 SHA-256，再调用下方相同的工程生成、归档和 IPA 检查脚本。AV3A 参考归档从 `Vendor/AV3A/SOURCE-INVENTORY.json` 记录的上游仓库及固定提交下载，源码不提交到本仓库；其原始条款仍适用，见 `Vendor/AV3A/UPSTREAM.md`。首次构建需要编译原生依赖，完成后先保存缓存，再解析 Swift 包和归档应用；网络下载失败会自动重试，后续运行会尝试复用平台下载包和原生依赖缓存。

构建成功后，从运行页面的 **Artifacts** 下载 `Yingxia-iOS-build…-unsigned`，解压得到 IPA、`SHA256SUMS.txt` 和检查报告。IPA 保留 30 天，诊断日志保留 14 天。输出面向 iPhone/iPad、最低 iOS 16.2，安装前需自行签名。此流程不需要 Apple 签名证书或开发者账号，也不会自动发布 Release。

### 在 macOS 上本地构建

```sh
python3 Scripts/build-ios-ipa.py --check --build-number 1
python3 Scripts/build-ios-ipa.py --build-number 1
```

构建目标为 `TVBox-iOS`，Release，`generic/platform=iOS`，arm64，iPhone/iPad，最低 iOS 16.2。只检查条件时使用 `--check`，并行度可用 `--jobs 4` 调整。

输出为未签名 IPA。构建号从 1 开始，文件名至少保留两位：

```text
artifacts/latest/Yingxia-1.8.13-build01-iOS16.2-NoJava-unsigned.ipa
```

已有最新交付记录时，不指定 `--build-number` 会在它的基础上递增。只有归档、源码一致性、原生依赖、部署信息、Java 排除、ZIP 和校验和检查通过后，才更新 `artifacts/latest/`。安装需要自行签名。

工程文件和依赖缓存均为本机生成内容；保留 `Package.resolved`，通过脚本生成工程即可。构建工具能够从普通解压目录读取源码，不依赖父目录或既有 `.git` 历史。

## 可选凭据和服务

用户自行添加订阅及弹幕 API。官方 Dandanplay API 如需应用凭据，在仓库外创建 JSON，包含 `appId` 和 `appSecret`，再通过环境变量 `DANDANPLAY_CONFIG` 指向它；未提供时不嵌入凭据。不要把该文件提交到 GitHub。

如部署 `Services/` 或 `website/`，请按各自 README 配置自己的资源、域名和服务凭据。源码包不执行部署或发布。

## 许可证

本地版本基于 [jo32/tvbox-silicon](https://github.com/jo32/tvbox-silicon)，项目许可见 [LICENSE](LICENSE)。本地适配与当前维护范围为独立版本，不自动同步应用上游。

第三方组件分别遵循其原始许可。保留 `Vendor/*/LICENSE*`、`Vendor/*/licenses/`、`Vendor/*/UPSTREAM.md` 及 `App/Resources/ThirdPartyNotices.txt`；AV3A/UWA 和部分可下载语音模型有各自条款。当前组合 FFmpeg 构建明确带有 GPL/nonfree 标记，不能把所有依赖视为统一的 GPL 授权。
