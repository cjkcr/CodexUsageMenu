# Codex Usage Menu

macOS 菜单栏小工具，每分钟通过已登录的 Codex CLI 查询一次 ChatGPT Codex 用量。

菜单栏用两列两行显示 `5 H`、`WEEK` 及对应的剩余百分比，沿用第一版的 `↻1` 样式显示可用重置次数。右侧使用由用户提供的 Codex 图标制作的透明标记。整块内容作为 macOS 菜单栏模板图像交给系统着色，会随菜单栏背景明暗切换前景色；应用自身不绘制背景。点击可查看两个窗口的下次重置时间和最近更新时间。

界面支持简体中文、繁体中文和英文。菜单栏顶部的 `5 H`、`WEEK` 固定不变；下拉菜单、提示、错误信息和时间格式按系统首选语言显示，其他语言回退到英文。App 每 5 秒检查一次首选语言，切换后会重新绘制现有数据，无须等待下一次用量查询。

## 构建与运行

需要 macOS、Swift 命令行工具，以及已登录 ChatGPT 账号的 Codex CLI。运行：

```sh
./build.sh
open build/CodexUsageMenu.app
```

程序优先查找 `/usr/local/bin/codex` 和 `/opt/homebrew/bin/codex`，然后查找 ChatGPT/Codex 应用内的 Codex CLI 和 `PATH`。首次运行可先用 `codex login` 登录。菜单栏出现 `Codex —` 时，点击图标可查看错误并手动刷新。

## 安装包

从 [GitHub Releases](https://github.com/cjkcr/CodexUsageMenu/releases/latest) 下载最新 DMG。打开 DMG，将应用拖入“应用程序”。需要 macOS 13 或更新版本，以及已登录的 Codex CLI 或附带 Codex CLI 的 ChatGPT/Codex 应用。

当前没有 Apple Developer ID 证书，应用仅进行本地签名，DMG 未经公证。首次打开如被 macOS 阻止，先尝试打开应用，然后进入“系统设置 → 隐私与安全性”，在安全性提示处选择“仍要打开”。请只从此项目的 Releases 页面下载。

本地运行 `./package.sh` 会生成 Apple Silicon 与 Intel 通用 DMG 和 PKG，文件位于 `dist/`。`VERSION` 是应用和安装包的版本来源。每次完成代码更新并提交后，运行 `./release.sh`：脚本将补丁版本号加一，创建并推送 Git 标签；GitHub Actions 随后构建 DMG 并发布新版本。首次版本是 `v1.0.0`。

数据来自 Codex app-server 的 `account/rateLimits/read`。这里的“重置次数”指服务端 `rateLimitResetCredits.availableCount`，不会自动使用重置额度。剩余百分比根据 `100 - usedPercent` 计算；没有返回的数据以 `—` 表示。刷新间隔为 60 秒。
