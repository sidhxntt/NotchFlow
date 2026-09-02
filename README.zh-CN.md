[English](README.md) · [简体中文](README.zh-CN.md)

# NotchFlow

你的刘海，随时待命。

NotchFlow 是一款直接下载的 macOS 应用。把问题、笔记、提醒或交给 AI Agent 的任务输入刘海，它会自动识别你的意图。

## 安装

从最新发行版下载 **DMG**（首选安装方式），打开后把 **NotchFlow.app** 拖到“应用程序”。如果 Mac 无法挂载磁盘映像，可以使用同版本的 **ZIP** 备用包。

命令行安装方式：

```bash
curl -fsSL https://raw.githubusercontent.com/sidhxntt/notchflow/main/install.sh | bash
```

- 需要 **macOS 14 (Sonoma)** 或更高版本。
- 仅支持 **Apple silicon（arm64）Mac**。
- 是否有硬件刘海不影响使用；外接显示器和无刘海 Mac 会显示虚拟刘海。
- 带标签的发行版使用 Apple Developer ID 签名并经过 Apple 公证。

## 试用与许可

每次新的安装均有完整的 **7 天试用期**（从第一次成功启动起连续七个 24 小时）。试用结束后，NotchFlow 会阻止所有产品功能，直到此 Mac 激活有效许可。

在受阻页面或“设置 → 关于 → 许可”中选择“购买许可”，通过 Lemon Squeezy 完成付款。付款成功后，Lemon Squeezy 会用电子邮件发送许可密钥；在 NotchFlow 中输入该密钥即可激活。你也可以在另一台获许可的个人 Mac 上再次输入相同密钥以恢复购买。

付费许可为**永久许可**，不是订阅：它让你永久使用 NotchFlow，并包含未来所有 NotchFlow 更新。NotchFlow 没有独立产品账号；Lemon Squeezy 只负责付款与许可密钥的交付。

## 隐私

NotchFlow 没有独立产品账号。提示词、聊天、笔记、提醒、Agent 会话、剪贴板和历史记录保存在你的 Mac 上，或直接发送给你所选择的 AI 服务商；NotchFlow 不会中转请求内容。

完整说明见仓库中受版本控制的[隐私政策](PRIVACY.md)，包括权限、本地存储、服务商网络请求、Lemon Squeezy 许可、保留和删除。公开发行前，必须将该政策发布到应用中配置的隐私网址；本仓库不会部署该网站。

## 常见问题

**试用期结束后会怎样？**

NotchFlow 会阻止所有产品功能，直到你激活有效的付费许可。选择“购买许可”后，Lemon Squeezy 会发送许可密钥；付费许可永久有效并包含未来更新。

**以后会收到更新吗？**

会。有效的付费许可包含未来所有 NotchFlow 更新。应用会检查经过签名的更新；DMG 是常规手动安装方式，ZIP 是备用包。

**我的数据会去哪里？**

NotchFlow 不运营用户数据后端。AI 提示词和你主动添加的上下文会发送给你选择的服务商或 CLI；网页搜索请求会发送给已配置的搜索服务。笔记、提醒、本地历史、剪贴板内容和本地文件则保留在你的 Mac 上。

## 产品许可

下载的 NotchFlow 产品在七天试用期后需要有效的 Lemon Squeezy 许可。付费许可永久有效并包含未来所有 NotchFlow 更新。开源和第三方声明见仓库的 [LICENSE](LICENSE) 与应用内说明。
