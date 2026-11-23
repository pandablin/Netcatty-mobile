# 上游同步与本仓库发布

本分支的源码、更新检查和安装包入口统一为 [pandablin/Netcatty-mobile](https://github.com/pandablin/Netcatty-mobile)。[wxte/Netcatty-mobile](https://github.com/wxte/Netcatty-mobile) 的 `main` 仍是合入上游源码的来源；它不是本分支手机更新检查或 APK 下载的目的地。

本页说明自动化的配置约束和验收方式，不能作为远端定时任务已经启用、某次构建已经通过或附件已经发布的证明。工作流与远端配置完成后，应以本仓库 [Actions](https://github.com/pandablin/Netcatty-mobile/actions) 和 [Releases](https://github.com/pandablin/Netcatty-mobile/releases) 的实际记录确认状态。

## 调度与流程

同步入口为 `.github/workflows/sync-upstream.yml`，支持手动运行，以及 UTC `17 */6 * * *` 的定时计划，即北京时间每天 **02:17、08:17、14:17、20:17** 检查。实际开始时间和远端启用状态以 Actions 记录为准。

1. `scripts/sync_upstream.py` 在本分支基础上准备合并，输出 `changed`、`version`、`build`、`sha`、`base_sha` 和 `upstream_sha`。
2. 有可合并更新时，候选推送到 `automation/upstream-<完整40位上游SHA>`，显式 dispatch 本仓库 `mobile.yml`，指定候选 `source_ref`、`promote=true`、`base_sha` 和 `upstream_sha`。
3. `mobile.yml` 的检查和签名构建在不同虚拟机运行。检查阶段没有签名 Secrets，构建阶段按已检查的实际提交 SHA 取源码。
4. 测试、构建及 APK 身份检查都通过后，才确认 `main` 仍指向 `base_sha` 并快进更新，随后创建本仓库 Release。

上游语义版本更高时采用上游版本；否则将本地 patch 加一。基础 Build Number 使用 `max(本地 Build Number, 上游 Build Number) + 1`，不用 Actions Run Number。工作流保留该基础构建号并使用 `--split-per-abi --target-platform android-arm64`，Flutter 为 ARM64 添加 2000 偏移：最终 APK 的 `versionCode = 基础 Build Number + 2000`，例如 `+49` 对应 `2049`，以便沿用已发布测试包的递增序列。

## 合并与构建的边界

- 在本分支当前提交上合并上游，保留已有的命令分组、自有 OAuth 配置、同步兼容性、剪贴板安全策略与手机布局修复；不能用整树覆盖或统一 `ours`/`theirs` 取代冲突处理。
- 合并冲突、发布相关受保护文件或依赖变动、格式检查、静态分析、测试或发布构建失败时，停止 Actions，不自动推进 `main` 或发布该候选。维护者从失败记录接管，必要时自行创建 PR；不承诺失败时会自动创建 PR。
- 合并提交、测试对象、APK 构建对象和 Release 目标必须是同一份已核验候选，发布前再次检查 `main` 没有被其他更新改变。
- GitHub 的 `GITHUB_TOKEN` Push 不会自动触发另一个 Push 工作流。检查、构建与发布应在同一条明确的流程中完成，或显式调用复用工作流；不能把“已推送源码”当作“已产出新 APK”。见 [GitHub 官方说明](https://docs.github.com/en/actions/concepts/security/github_token)。
- Android 与 iOS 的产物状态要分别描述；Android APK 发布不应被称为已验证 iOS 安装包。

## 失败提醒与处理

维护提醒工作流 `Maintenance alerts` 使用 GitHub Issue 提醒维护者，不通过 Netcatty App 推送，也不需要重新打包 APK。以下说明提醒规则；是否已在远端启用、提醒测试是否通过，应以本仓库 Actions 和维护 Issue 的实际记录为准。

- 仅处理本仓库 `Sync upstream`、`Netcatty Android` 在 `main` 上由 Push、手动运行或定时计划发起，且最终状态为失败或超时的 Run。成功、取消、PR 和 Fork 的运行不发送维护提醒。
- 每个被监控工作流使用一个维护 Issue，由 GitHub Actions Bot 创建，指派给并 `@pandablin`。提醒包含 Run 链接、失败步骤和中文处理建议，依据固定同步错误代码及步骤分类，不把原始日志、环境变量或 Secrets 复制进公开 Issue。
- 同一 Run/Attempt 不重复写入；同一源码、同一原因连续失败时也不重复写入，避免每六小时刷屏。新源码或新原因会在对应 Issue 追加评论提醒。恢复后由维护者手动关闭 Issue；关闭后再次失败时可以重新打开。
- 提醒测试应明确标记为“提醒测试、非故障”，不能把测试 Issue 当作同步或发布出了问题的证据。

收到提醒后，先打开其中的 Actions Run 和失败步骤，再按下表处理。Issue 只提供排查入口，不应在评论中粘贴密钥、密码、Token 或完整环境变量。

| 失败类型 | 怎么处理 |
| --- | --- |
| 合并冲突 | 从最新 `main` 创建处理分支，逐项解决冲突并保留本分支定制；必要时手动创建 PR，重新通过检查与签名构建。反复重试同一冲突不会解决代码差异。 |
| 保护文件或依赖变化 | 人工审查 CI、Android、发布脚本、依赖及迁移影响，补充相应验证后再继续；不要为了通过而直接关闭保护。 |
| Format、Analyze 或 Tests | 按候选提交和失败步骤复现，修复格式、代码或兼容性问题后重跑。明确的代码失败不能按网络故障反复重试。 |
| 签名配置、证书或 OAuth 配置 | 检查下节列出的四项签名 Secrets 及批准的公开 Client ID，恢复既有签名身份后重跑。不要生成替代密钥，也不要把配置值贴进 Issue。 |
| 网络超时、下载失败或服务端暂时错误 | 对构建前或构建阶段的暂时故障，可有限重试原失败 Run；已有候选时优先重跑对应 Android Run。若失败在 Publish 步骤，应按下一条发布说明复用原 Artifact，不能盲目重编同版本。持续的 401/403 应检查权限，限流则等待恢复。 |
| `main` 已前移或候选分支已存在 | 基于最新 `main` 重新准备候选；先核对已有候选，避免覆盖仍待处理的内容。不强推，也不复用过期 `base_sha` 推进 `main`。 |
| Release 标签或资产冲突 | 先比对标签目标提交、本次 Run 已校验的 Artifact 和已上传资产的 SHA-256，复用完全相同的产物补齐发布。重编同一版本的摘要可能变化，不能盲目覆盖；内容不同时应提升版本重新构建，不覆盖已发布标签或附件。 |

**发布失败不一定代表源码尚未更新。** 流程先快进 `main`，随后发布 Release；失败如果发生在发布阶段，`main` 可能已经推进。应分别核对源码、Actions Artifact 和 Release 状态，再决定是补齐发布还是准备新版本。

提醒会进入 GitHub 的参与及 `@mention` 通知渠道。维护者可在 [GitHub 通知设置](https://github.com/settings/notifications) 中启用 **On GitHub**；若还希望关注本仓库全部 Issue，可选择仓库 **Watch → Custom → Issues**。手机推送需另在 GitHub Mobile 启用 Direct mentions，并允许系统通知；邮件、工作时间和免打扰设置也会影响送达。详见 [GitHub 官方通知设置说明](https://docs.github.com/en/subscriptions-and-notifications/get-started/configuring-notifications)。工作流不会修改用户通知设置，也不保证邮件或手机推送必定送达。

## 必须保留的配置

**OAuth：** Repository variable 使用 `NETCATTY_GITHUB_OAUTH_CLIENT_ID`，CI 通过环境变量将它传给 Dart 编译参数 `GITHUB_OAUTH_CLIENT_ID`。该值是公开 Client ID，不是 Client Secret 或用户 Token。自动签名构建和发布要求本仓库批准的 ID，缺失或不匹配时阻止发布。本地未注入 ID 的构建中，GitHub Device Flow 不可用，不会回退到第三方应用；手动 Token、WebDAV/S3 不受影响。

**Android 安装身份：** 当前 Android 源码将包名固定为 `app.netcatty.mobile.audit`，显示名称为 **Netcatty**，与已提供的定制测试包一致。覆盖升级要求相同包名、相同签名证书及更大的 `versionCode`，显示名称相同并不足以保证可覆盖。自动发布必须核对 APK 的真实 Manifest 和证书摘要，不应把随机调试签名产物作为稳定升级包。

**签名：** 私钥与密码仅通过维护者配置的 Actions Secrets 提供：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。别名从配置读取，证书必须与维护者固定的已发布证书匹配。正式自动发布缺少所需签名配置或证书不匹配时，应停止发布，不能悄悄改用另一把调试密钥；不要把私钥、密码或 Base64 编码密钥写进文档或源码。

## 发布后核验

1. 在 Actions 查看此次同步/构建 Run，确认成功、来源上游提交及被测试/构建的本分支提交；有冲突时按失败记录接管，必要时手动创建 PR。
2. 检查本仓库 Release 的标签、目标提交、更新说明、预发布状态与 APK 附件。
3. 比对 Release 的 SHA-256 Digest 和本地下载摘要，检查包名、签名证书、ABI、最低系统版本及 `versionCode`。
4. 应用的更新检查只读取本仓库 Release；它也可显示预发布，不包含草稿。上传 Actions Artifact 之后仍需实际发布 Release，才会进入该检查渠道。

可用以下只读命令查看结果；版本和 Run ID 请替换为实际值：

```bash
gh run list --repo pandablin/Netcatty-mobile --limit 5
gh run view <run-id> --repo pandablin/Netcatty-mobile
gh release list --repo pandablin/Netcatty-mobile
gh release view vX.Y.Z --repo pandablin/Netcatty-mobile
```

## 来源、署名与历史链接

README 中的上游谱系、许可证/原作者署名、历史 Release 的来源提交和过去 APK 的审查事实应保留。同步脚本读取上游仓库也是明确的维护行为。应迁移到本仓库的是运行时更新端点、当前下载与源码入口、克隆命令和 CI 操作入口；不要为了消除字符串匹配而改写历史或删除法定声明。

保留的外部仓库引用按用途分类：

| 位置 | 分类与用途 |
| --- | --- |
| README 开头、本文的上游来源说明 | 分支谱系与上游来源署名 |
| `scripts/upstream-policy.json`、`scripts/sync_upstream.py` | 明确指定上游源码获取目标，以及记录实际合并来源 |
| `scripts/upstream-policy.json` 的 `forbidden_runtime_text` | 防止运行时重新指向旧仓库的禁止列表，不会向其中地址发请求 |
| `docs/SECURITY_REVIEW_2026-11-23.md` | 当时官方包与基线提交的审查事实 |
| `docs/releases/v1.5.0.md`、`v1.9.4.md`、`v1.9.5.md`、`v1.10.0.md` | 历史来源提交及与原版安装身份的差异 |

当前运行时更新、下载、克隆和 CI 操作入口均应使用本仓库；许可证和第三方依赖来源不属于需要替换的入口。
