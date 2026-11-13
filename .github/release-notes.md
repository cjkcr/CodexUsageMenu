## Codex Usage Menu v1.1.1

本次更新加入 Gemini 4 Hydrogen 支持，并重新设计用量窗口、下拉菜单和额度详情。

### Gemini 4 Hydrogen

- 在“模型/额度”中选择 **Gemini 4 Hydrogen**，或使用“自动跟随 agy”。
- 支持识别 Low、Medium、High、XHigh（Extra High）档位。
- 兼容旧版 agy `/usage` 中尚未更新的模型说明，显示 Hydrogen 对应的 Gemini 基础共享池 `5 H` / `WEEK` 额度，并标注“共享额度”。该比例代表共享池剩余量，不是 Hydrogen 单独的消耗统计。
- 如果 agy 明确返回 Hydrogen 独立池，则优先使用该池；没有对应池时不虚构额度。
- 保留 Argon 独立额度和 Codex 重置次数的原有显示。

额度范围参考 [Google Antigravity 官方说明](https://antigravity.google/docs/plans)。

### 界面更新

- **用量窗口**：统一字体、间距与原生控件，额度卡片增加细进度条及重置时间，重置次数与百分比统一对齐。
- **下拉菜单**：新增紧凑额度概览，集中展示剩余比例、重置时间和最近更新；长模型名不再撑宽主菜单。
- **额度池详情**：按池分组，窗口、剩余比例和重置时间分行排列。
- **Gemini 图标**：改用较小的中空描边图标，透明背景，自动适配菜单栏前景颜色。
- **外观与状态**：优化浅色/深色对比度，使用柔和分组背景及边框；刷新时显示进度，错误时提供清晰提示。
- **窗口尺寸**：根据 Codex / agy 内容自动调整高度，关闭后继续在菜单栏运行。

菜单栏原有完整/紧凑布局、间距、`5 H` / `WEEK` 英文标签保持一致。

### 使用提示

选择“用量来源 → Gemini”，接入的是本机已登录的 **Antigravity CLI（agy）**，不包含 Gemini 网页聊天或旧 Gemini CLI 额度。自动跟随读取 agy 保存的模型设置；单个终端通过 `--model` / `--settings` 临时覆盖时，请手动选择。

### 下载与安装

- **DMG**：打开后双击“安装 Codex Usage Menu.pkg”。
- **PKG**：直接运行安装器。
- 支持 **macOS 13+、Apple Silicon 和 Intel Mac**，固定安装到 `/Applications/Codex Usage Menu.app`。
- 安装后自动打开，关闭窗口后继续在菜单栏运行，不占用 Dock。
- 安装包使用本地签名，尚未经过 Apple Developer ID 签名与公证。首次打开如被 macOS 阻止，可在“系统设置 → 隐私与安全性”中查看并允许打开。

随附 `SHA256SUMS.txt`，用于检查下载文件完整性。

### 验证

已验证 Hydrogen 各推理档位匹配、共享池映射、独立池优先、缺失额度处理和原有 Codex 兼容性；并检查浅色/深色组件与真实 Hydrogen 用量显示。自动发布流程会运行测试，检查双架构、应用签名、DMG 完整性以及 PKG 的固定安装路径。
