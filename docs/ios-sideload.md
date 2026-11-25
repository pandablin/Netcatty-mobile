# Netcatty iOS 侧载包

本仓库发布的 `Netcatty-<版本>-ios-arm64-unsigned.ipa` 是真实 iPhone/iPad ARM64 的 Release 构建，应用名称为 **Netcatty**。它未经 Apple 分发签名，需要你使用自己的签名工具及账号签名后再安装；下载后不能直接点击安装，也不是 App Store 或 TestFlight 版本。

## 下载和安装

1. 在 [本仓库 Releases](https://github.com/pandablin/Netcatty-mobile/releases) 下载对应版本的 `ios-arm64-unsigned.ipa`，不要下载源码 ZIP 代替 IPA。
2. 可用同版本 `IOS-SHA256SUMS.txt` 核对下载文件的 SHA-256。
3. 将 IPA 导入你使用的侧载签名工具，用自己的 Apple 账号或签名材料完成签名并安装。签名工具需要处理主应用 `app.netcatty.mobile` 和内含的 Live Activity 扩展 `app.netcatty.mobile.LiveActivity`。重签后文件的 SHA-256 会变化。
4. 按签名工具及 iOS 的实际提示完成设备信任/开发者设置。签名有效期、设备限制和续签由你的签名方式决定。不要把 Apple 密码、Token、证书私钥发给本项目。

主应用最低系统要求由 IPA 中的 `MinimumOSVersion` 和构建清单记录；Live Activity 扩展需要 iOS 16.2。旧版 iOS 上相应功能受系统可用性限制。没有声称已完成 iPhone/iPad 实体设备测试。

首次安装后，通过自己的 WebDAV、GitHub/Gist 或 S3 同步保险库。iOS 使用你为本仓库提供的公开 GitHub OAuth Client ID，更新入口也指向 `pandablin/Netcatty-mobile`。侧载身份或签名团队变化可能影响覆盖安装和 Keychain 访问，覆盖前请保留可解密的保险库备份。

## 构建与发布

- 独立的 **Netcatty iOS** 工作流可手动填写已发布的版本标签，例如 `v1.10.1`，为该版本补充 IPA。它从该标签的精确源码编译，并使用受信工作流版本的校验与发布脚本。
- 后续 **Netcatty Android** 发布成功后会调用 iOS 工作流，为同一源码提交、同一 Release 补充 IPA；iOS 失败不会撤销已经成功的 Android 发布。
- macOS/Xcode 构建使用 `flutter build ios --release --no-codesign`，无需 Apple 签名 Secrets。编译时必须注入本仓库批准的公开 OAuth Client ID。
- 打包器核对包身份、版本、真实设备 ARM64、Live Activity 扩展、自有 OAuth/更新地址及未签名状态，并输出 iOS 专用构建清单和校验和。构建验证不等于实体设备功能测试。
- Flutter/CocoaPods 在临时构建目录生成的工程配置会单独核验，主程序、扩展、签名身份或其他源代码被改变时停止发布。Actions 中标为 `unverified-recovery` 的 ZIP 是保留权限与链接的构建恢复备份，不能当成已经校验的 Release IPA。
- 发布器只给已存在且源码标签一致的本仓库 Release 添加 iOS 资产；不会移动标签、删除 Android 资产或覆盖同名但摘要不同的文件。
- iOS 构建失败会进入本仓库现有维护提醒流程。可在 Actions 查看失败阶段，修复后重新运行对应版本；已有不同摘要的产物不会被自动覆盖。

如需完全相同产物续传，优先使用对应成功打包步骤保存的 Artifact。若需要改变 iOS 源码，应准备新版本，不把修改后的源码冒充旧标签发布。

参考：[Flutter iOS 构建说明](https://docs.flutter.dev/deployment/ios)、[GitHub 托管 macOS 环境](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。
