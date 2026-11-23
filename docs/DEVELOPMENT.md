# 开发、测试与发布流程

## 环境要求

| 工具 | 建议版本 | 用途 |
| --- | --- | --- |
| Flutter | 3.44.4 | 与 GitHub Actions 保持一致 |
| Dart | Flutter 自带版本 | 格式化、分析、测试 |
| JDK | 17 | Android Gradle 构建 |
| Android SDK | Flutter 当前稳定版支持的 SDK | APK/AAB 与真机调试 |
| Xcode | 16+ | iOS 构建，仅 macOS |
| CocoaPods | 当前稳定版 | iOS Plugin 依赖 |
| GitHub CLI | 当前稳定版 | PR、Actions Artifact 和 Release |

优先使用仓库 CI 相同的 Flutter 版本。升级 Flutter、Gradle、Kotlin、Xcode 或依赖时应单独提交，并同时验证 Android 与 iOS。

Windows 工作区路径包含空格时，某些 Native Asset Hook 可能错误截断命令。遇到类似问题时，优先把仓库放到无空格路径，或用短盘符映射同一个工作区后重新执行 `flutter pub get`；不要修改源码来绕过本机路径问题。

## 初始化

```bash
git clone https://github.com/pandablin/Netcatty-mobile.git
cd Netcatty-mobile
flutter pub get
flutter doctor -v
```

GitHub Device Flow 在编译期读取 `GITHUB_OAUTH_CLIENT_ID`，没有第三方默认值：

```bash
flutter run --dart-define="GITHUB_OAUTH_CLIENT_ID=<your-client-id>"
```

在自己的 GitHub 账号的 **Settings → Developer settings → OAuth Apps** 注册应用，并启用 **Device Flow**；复制公开 Client ID，而不是 Client Secret。官方步骤见 [创建 OAuth App](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app) 和 [Device Flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow)。授权页展示的应用所属账号取决于该 Client ID，不是 APK 名称或授权用户的登录名。

当前客户端只保存 access token，尚未实现 refresh token 自动续期。GitHub 新注册应用默认启用的 **Expire user access tokens** 会使令牌八小时后过期，此后需要重新登录。官方兼容说明允许未支持短期令牌的客户端先关闭该项，但关闭后会失去这项定期过期保护，应妥善保护令牌并按需撤销；未来增加自动续期支持后再评估启用。

作用域由应用请求 `gist read:user`。Client ID 可以随客户端分发，此流程无需 Client Secret。Client Secret、访问 Token 和用户授权码不得写入源码、文档、Issue 或日志。

本仓库 CI 的 Android 签名构建从 Repository variable `NETCATTY_GITHUB_OAUTH_CLIENT_ID` 读取配置，并使用同名环境变量。设置入口为 **仓库 Settings → Secrets and variables → Actions → Variables**；这项 OAuth 配置不需要用户 Token 或 Client Secret。自动签名构建和发布要求该变量配置为本仓库批准的自有 Client ID，缺失或不匹配时停止发布。本地构建可以省略该配置，此时 GitHub Device Flow 在运行时明确不可用，手动 Token、WebDAV/S3 不受影响。手动 iOS 构建也使用 Dart 参数显式注入 ID；配置变更只影响重新构建的安装包。

这项 GitHub 配置变量不能命名为 `GITHUB_OAUTH_CLIENT_ID`，因为 [GitHub 禁止配置变量使用 `GITHUB_` 前缀](https://docs.github.com/en/actions/reference/workflows-and-actions/variables#naming-conventions-for-configuration-variables)。CI 将 `NETCATTY_GITHUB_OAUTH_CLIENT_ID` 的值映射到 `--dart-define="GITHUB_OAUTH_CLIENT_ID=..."`；Dart 读取的编译参数名和本地构建命令仍保持 `GITHUB_OAUTH_CLIENT_ID`。

认证单元测试使用虚构 Client ID 和内存 HTTP 客户端，不需要配置真实 OAuth 应用或访问 GitHub。

## 日常开发命令

```bash
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter run
```

提交前的无修改格式检查：

```bash
dart format --output=none --set-exit-if-changed lib test
```

只运行相关测试示例：

```bash
flutter test test/sftp_terminal_usability_test.dart
flutter test test/system_management_service_test.dart
flutter test test/github_auth_service_test.dart
```

## 构建

### Android

Debug APK：

```bash
flutter build apk --debug
```

Release APK / App Bundle：

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --dart-define="GITHUB_OAUTH_CLIENT_ID=<your-client-id>"
flutter build appbundle --release \
  --dart-define="GITHUB_OAUTH_CLIENT_ID=<your-client-id>"
```

签名信息通过环境变量或本机忽略文件提供。不要提交 `.jks`、`key.properties`、证书密码或 Base64 编码后的签名文件。

### iOS

无签名可重签 App：

```bash
flutter build ios --release --no-codesign \
  --dart-define="GITHUB_OAUTH_CLIENT_ID=<your-client-id>"
```

在 macOS 中把 `build/ios/iphoneos/Runner.app` 放入 `Payload/` 后压缩即可生成可重签 IPA。App Store 或 TestFlight 构建需要自己的 Bundle ID、Team、Provisioning Profile 和分发证书。

Windows 无法完成原生 iOS 编译；涉及 Swift、Info.plist 或 iOS Plugin 的修改必须以 macOS CI 结果为准，并尽量在真机验证文件共享、Keychain、PiP 与后台生命周期。

## 测试矩阵

### 测试保留与运行范围

测试按风险而不是数量删减。主机/密钥删除、桌面端未知字段及 Agent 设置、凭据加载、同步期间编辑、文件移动源删除条件、键盘与行号等回归用例必须保留。Gist、WebDAV、S3 的 v2 往返看似相似，但分别保护 JSON 包装、临时 MOVE/覆盖、签名与对象路径，不能只保留一个。

同步测试中的共同桌面 v2 样例集中于 `test/fixtures/desktop_v2_vault.dart`。协议算法测试不重复运行真实加密；真实 AES-GCM/PBKDF2 的固定桌面向量和错误密码验证保留在 `netcatty_crypto_test.dart`，各存储测试保留真实端到端编解码。云同步测试文件允许最多 3 分钟/例，避免慢机器上的 600000 次 PBKDF2 加密触发默认 30 秒误超时，不降低生产密钥派生强度。

日常协议修改先跑快速用例：

```bash
flutter test test/convergent_sync_adapter_test.dart test/vault_merge_service_test.dart test/auto_sync_controller_test.dart
```

涉及网络、恢复或加密再跑：

```bash
flutter test test/cloud_sync_service_test.dart test/netcatty_crypto_test.dart test/vault_loading_test.dart
```

大规模同步重构及发布仍跑完整套件。模拟 HTTP 通过不等于所有真实 WebDAV/S3 部署都已验证；还需使用专门的测试保险库做两设备并发、断网重试和退出重进验证，不使用真实用户凭据或生产保险库。

| 测试文件 | 重点覆盖 |
| --- | --- |
| `vault_model_test.dart` | Vault 字段、未知字段无损往返和模型迁移 |
| `vault_loading_test.dart` | 保险库快照优先显示与后台敏感字段加载 |
| `netcatty_crypto_test.dart` | 桌面端兼容加密向量与 AES-GCM 格式 |
| `github_auth_service_test.dart` | Device Flow、轮询、重试、取消与网络错误 |
| `update_check_service_test.dart` | GitHub Latest Release 解析、语义版本比较与网络错误 |
| `vault_export_service_test.dart` | JSON 导出与取消路径 |
| `host_editor_layout_test.dart` | 键盘弹出、滚动和窄屏表单布局 |
| `terminal_connection_dialog_test.dart` | Pending 标签、连接弹窗和会话隔离 |
| `terminal_input_controller_test.dart` | 软键盘输入、iOS 回车重复上报折叠与工具栏修饰键 |
| `ssh_identity_test.dart` | 主机私钥装配、空口令归一化与私钥类型识别 |
| `sftp_terminal_usability_test.dart` | SFTP 递归传输、进度、零拷贝、快捷键与 PiP 文本 |
| `system_management_service_test.dart` | 进程、Docker、Compose、服务、Caddy、tmux 命令与解析 |
| `mobile_v1_features_test.dart` | 关键移动端功能回归 |

协议解析、Shell 参数转义、模型序列化和控制器状态转换优先写单元测试。触屏布局问题应补充固定窗口尺寸的 Widget Test，并使用 `tester.takeException()` 检查 RenderFlex Overflow。

## 真机回归清单

### 通用

- 密码、私钥、跳板机和代理连接
- 同一主机打开两个以上标签，关闭确认和分屏
- 中文输入、文本选择、拖动选区、复制与粘贴
- 软键盘回车只提交一次命令，长按/连按回车仍逐条提交
- 性能面板与系统识别
- 进程、Docker/Compose、Caddy 和 tmux 操作的确认弹窗
- WebDAV、GitHub Gist 与 S3 的统一立即同步及条件写入
- 桌面端兼容的三方合并、加密共同 base、删除墓碑和 PC 删除数据不复活回归
- 自动同步开关、修改防抖、前台刷新、失败重试及同步期间继续编辑
- 保险库导入/导出

### Android

- Android 13+ 通知权限和 SSH 前台服务
- 进入后台、返回前台和系统省电限制下的连接行为
- SAF 目录选择、权限持久化、上传/下载和大文件进度
- 窄屏双栏 SFTP 工具栏不越界
- 画中画进入、退出和终端方向
- 使用 CI 签名 APK 覆盖安装上一版本

### iOS

- “文件”App 中出现 Netcatty 文件夹，并能读写上传/下载文件
- 无签名 IPA 重签后安装
- Keychain 数据在升级后保留
- PiP 文字方向、颜色、更新和停止
- 大文件 SFTP 时界面保持响应，进度平稳更新
- 前后台切换后的 SSH 状态和系统回收提示
- 系统键盘与第三方输入法的回车键各提交一次，不出现重复执行

## 分支与提交

- 新功能和较大的 Bug 修复使用独立分支，通过 PR 和 CI 合并。由 DSH Agent 创建的仓库分支统一使用 `dsh/` 前缀，例如 `dsh/ios-terminal-enter-fix`；`codex/` 是历史遗留前缀，不要继续使用。
- 很小且边界明确的文档、版本或维护修改，可按维护者要求直接在 `main` 完成，避免为每个微小改动积累分支。
- 一个 PR 只包含一个可解释的目标；不要使用 `git add -A` 把附件、构建产物或用户未提交修改一并加入。
- PR 合并后删除远端功能分支。
- 提交信息使用简洁的 Conventional Commit 风格，例如 `feat: add SFTP progress`、`fix: constrain dual-pane toolbar`、`docs: add development guide`。

## GitHub Actions

本仓库的 [Mobile CI](https://github.com/pandablin/Netcatty-mobile/actions/workflows/mobile.yml) 定义于 `.github/workflows/mobile.yml`，可在 [Actions](https://github.com/pandablin/Netcatty-mobile/actions) 查看实际触发和完成情况。上游同步与自动发布的配置及验收另见 [上游同步说明](UPSTREAM_SYNC.md)。不要仅凭一次自动 Push 就认定后续构建已经运行。

检查和签名构建在不同 job/虚拟机中进行：检查阶段运行 `flutter pub get`、格式检查、`flutter analyze`、完整 `flutter test`，不接触签名 Secrets；构建阶段按检查阶段实际使用的提交 SHA 获取源码，生成 ARM64 APK，并核对安装身份、签名及摘要。以 workflow 中的具体触发条件和 Run 记录为准。

自动发布需要完整的签名 Secrets：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

公开 OAuth 配置仍为 Repository variable `NETCATTY_GITHUB_OAUTH_CLIENT_ID`。签名缺失或证书与维护者固定的已发布证书不符时，禁止自动发布，不回退到随机调试密钥。Android 包名保持 `app.netcatty.mobile.audit`，显示名称为 Netcatty。

Android 发布 APK 命名为 `Netcatty-X.Y.Z-android-arm64.apk`，构建不使用 Actions Run Number 覆盖版本。`versionName` 与基础 Build Number 取自经检查的 `pubspec.yaml`；在本分支使用的 `--split-per-abi --target-platform android-arm64` 构建中，Flutter 为 ARM64 添加 2000 偏移，因此最终 APK 的 `versionCode = 基础 Build Number + 2000`，例如 `+49` 对应 `2049`。上游同步准备脚本负责递增版本：上游语义版本更高则取上游版本，否则本地 patch 加一；基础 Build Number 为本地和上游较大值再加一。Artifact 的保留时间和名称以工作流为准。

iOS 不参与这条 Android 自动发布链路；如需提供 IPA，应由维护者另行手动构建并核验对应源码、扩展及安装要求。不能将 Android 成功描述为 iOS 已验证。

## 版本号

版本只在 `pubspec.yaml` 中维护：

```yaml
version: MAJOR.MINOR.PATCH+BUILD
```

- `MAJOR.MINOR.PATCH` 映射 Android `versionName`、iOS `CFBundleShortVersionString`。
- `BUILD` 是基础构建号，映射 iOS `CFBundleVersion`；本分支 ARM64 split APK 的实际 Android `versionCode` 为 `BUILD + 2000`。发布时基础构建号必须单调增加，并核验 APK 的实际值。
- 设置页底部通过 `package_info_plus` 读取构建信息，不要再硬编码一份版本字符串。

修改版本后运行一次 `flutter pub get`，并检查 Android/iOS 构建输出与设置页。

## Release 流程

1. 确认目标 PR 已合并，`main` 与 `origin/main` 一致。
2. 更新 `pubspec.yaml` 的版本和 Build Number。
3. 更新 README、开发文档和 Release Notes。
4. 执行格式检查、`flutter analyze`、完整 `flutter test` 和本地 Android 构建。
5. 使用检查与签名构建流水线验证同一候选提交；自动流程在全部检查通过后才确认 `main` 未变并快进更新。不要假定机器人 Push 会触发另一轮构建。
6. 下载该候选对应 Run 的 `Netcatty-X.Y.Z-android-arm64.apk`，核对 Manifest、固定签名证书、版本号与摘要。iOS 或其他 ABI 如另行提供，分别记录其构建和验证状态。
7. 创建对应 `vX.Y.Z` Tag，并以同名 GitHub Release 发布已核验的产物、更新说明和必要构建清单。GitHub 资产 Digest 与随附校验文件都应对应实际附件。
8. 检查本仓库 [Releases](https://github.com/pandablin/Netcatty-mobile/releases)、README 徽章、安装包下载和 GitHub 显示的 Digest；核对来源提交、包名、签名和递增的 `versionCode`。预发布也应从完整 Releases 列表核验，不能只看 GitHub 的 `/releases/latest` 正式版入口。

示例命令中的 Run ID 和版本必须替换为当前值：

```bash
gh run download <run-id> --repo pandablin/Netcatty-mobile --dir dist
git tag -a vX.Y.Z -m "Netcatty Mobile X.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z <assets...> --repo pandablin/Netcatty-mobile --title "Netcatty Mobile X.Y.Z" --notes-file <notes.md>
```

不要在 CI 未通过时提前移动 `latest` Tag，也不要上传来自不同提交或不同 CI Run 的 Android/iOS 包。

### Beta / 预发布流程

Beta 版本必须同时满足以下约束：

1. `pubspec.yaml` 使用预发布版本，例如 `1.4.0-beta.1+15`。
2. Git Tag 使用对应名称，例如 `v1.4.0-beta.1`。
3. GitHub Release 必须标记为 Pre-release；CLI 发布时必须添加 `--prerelease`：

```bash
gh release create vX.Y.Z-beta.N <assets...> --repo pandablin/Netcatty-mobile --prerelease --title "Netcatty Mobile X.Y.Z Beta N" --notes-file <notes.md>
```

本定制分支的应用内更新检查读取 `pandablin/Netcatty-mobile` 的 Release 列表，跳过草稿，并纳入预发布版本；不再以 `/releases/latest` 作为唯一版本来源。发布者仍须正确标记 Pre-release，并在说明中写清测试状态、安装身份及签名。用户也可从本仓库 Releases 页面或对应 Actions Run 获取附件；仅上传 Artifact 不等于已经创建可供应用检查的 Release。

## 隐私与调试信息

提交或发布前搜索并清理：

- 真实 IP、域名、用户名、邮箱、主机别名和主机指纹
- GitHub Token、WebDAV 密码、同步主密码、AI API Key
- 私钥、证书、Provisioning Profile 和 Android Keystore
- 截图通知栏、终端历史、登录来源 IP 和文件路径
- 开发者绝对路径、临时目录和附件缓存目录

文档截图只使用已脱敏版本，并检查 EXIF/设备元数据。日志示例应使用 `example.com`、`192.0.2.0/24` 等保留示例地址。
