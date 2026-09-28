# Codex Usage Menu

macOS 菜单栏小工具，通过已登录的 Codex CLI 查询 ChatGPT Codex 用量。使用 Codex 时每 2 分钟查询一次，空闲时每小时查询一次。

菜单栏用两列两行显示 `5 H`、`WEEK` 及对应的剩余百分比，沿用第一版的 `↻1` 样式显示可用重置次数。右侧使用由用户提供的 Codex 图标制作的透明标记。整块内容作为 macOS 菜单栏模板图像交给系统着色，会随菜单栏背景明暗切换前景色；应用自身不绘制背景。点击可查看两个窗口的下次重置时间和最近更新时间。

在有刘海的屏幕上，自动模式使用 24 点宽的仅图标布局；其他较窄的屏幕使用 116 点宽的紧凑布局。下拉菜单或应用窗口的“菜单栏显示”可选择自动、完整、紧凑或仅图标。macOS 可能因菜单栏项目过多而把图标藏在刘海后，此时应用窗口与 Dock 图标仍可显示用量和错误信息。请先关闭其他菜单栏项目腾出空间；本图标出现后，可按住 Command 将它拖到右侧。关闭窗口不会退出应用，点击 Dock 图标可重新打开窗口。

界面支持简体中文、繁体中文和英文。菜单栏顶部的 `5 H`、`WEEK` 固定不变；下拉菜单、提示、错误信息和时间格式按系统首选语言显示，其他语言回退到英文。App 收到系统语言或地区设置变化通知后重新绘制现有数据，无须等待下一次用量查询。

## 构建与运行

需要 macOS、Swift 命令行工具，以及已登录 ChatGPT 账号的 Codex CLI。运行：

```sh
./build.sh
open build/CodexUsageMenu.app
```

程序自动查找 ChatGPT/Codex 应用内的 Codex CLI、`~/.local/bin` 等常见用户安装位置、Node 版本管理器目录、Homebrew 路径和 `PATH`。菜单栏 App 不一定继承终端的 `PATH`；若仍找不到，请在终端运行 `command -v codex`，然后在菜单栏下拉菜单选择“选择 Codex CLI…”，指定该文件。所选路径只保存在本机。可运行 `/Applications/CodexUsageMenu.app/Contents/MacOS/CodexUsageMenu --diagnose-cli` 查看 App 实际找到的路径。首次运行可先用 `codex login` 登录。菜单栏出现 `Codex —` 时，点击图标可查看错误并手动刷新。

## 安装包

从 [GitHub Releases](https://github.com/cjkcr/CodexUsageMenu/releases/latest) 下载最新 DMG 或 PKG。打开 DMG 后，双击其中的“安装 Codex Usage Menu.pkg”，按 macOS 安装器的步骤安装；也可以直接下载 PKG 安装。**只打开 DMG 不会安装应用。**安装结束后，从“应用程序”打开 Codex Usage Menu，即可看到显示版本和用量的窗口。需要 macOS 13 或更新版本，以及已登录的 Codex CLI 或附带 Codex CLI 的 ChatGPT/Codex 应用。更新前请退出旧版本。

当前没有 Apple Developer ID 证书，应用仅进行本地签名，DMG 未经公证。首次打开如被 macOS 阻止，先尝试打开应用，然后进入“系统设置 → 隐私与安全性”，在安全性提示处选择“仍要打开”。请只从此项目的 Releases 页面下载。

本地运行 `./package.sh` 会生成 Apple Silicon 与 Intel 通用 DMG 和带有欢迎、安装进度、完成页面的 PKG，文件位于 `dist/`。`VERSION` 是应用和安装包的版本来源。每次完成代码更新并提交后，运行 `./release.sh`：脚本将补丁版本号加一，创建并推送 Git 标签；GitHub Actions 随后构建 DMG、PKG 并发布新版本。首次版本是 `v1.0.0`。

数据来自 Codex app-server 的 `account/rateLimits/read`。这里的“重置次数”指服务端 `rateLimitResetCredits.availableCount`，不会自动使用重置额度。剩余百分比根据 `100 - usedPercent` 计算；没有返回的数据以 `—` 表示。App 启动时立即查询，之后每分钟检查一次本机活动状态：Codex/ChatGPT 在前台，或最近 5 分钟有 Codex 会话文件更新时，每 2 分钟查询；否则每小时查询。“立即刷新”不受间隔限制。
