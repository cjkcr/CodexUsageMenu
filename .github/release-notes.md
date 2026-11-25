## Codex Usage Menu v1.1.2

适配新版 Antigravity CLI（agy）的模型名称与额度池变化，修正旧选择失效和异常重置日期。

### 本次更新

- **新版模型自动显示**：按 agy 返回的信息生成 Neon、Carbon、Argon、Hydrogen、Orchestrator、Claude 和 GPT 等模型选项，无需逐个硬编码。实际选项随账号和服务端变化。
- **沿用旧的手动选择**：旧版 Flash、Claude 等通用名称更新为带版本的全名，或 Argon 从独立池移入共享池时，可在模型身份明确的情况下继续显示对应额度。
- **更准确的模型匹配**：区分明确的版本号，正确识别 Orchestrator 的 Neon、Carbon、Argon CLI ID，避免误匹配到同名独立模型；不存在或有歧义的模型不借用其他额度。
- **隐藏无效重置日期**：agy 返回 `1970-01-01` 作为尚未开始计时的标记时，不显示成真实重置日期。

### 额度说明

额度归属以当前 agy 响应为准。如果 Neon、Carbon、Argon、Hydrogen 与 Orchestrator 被列入同一 Gemini 共享池，它们显示相同的 `5 H` / `WEEK` 比例是正常的，代表共享池剩余量，不代表各模型独立消耗统计。若返回独立池，则分别处理。

自动跟随仍读取 agy 保存的模型设置；通过 `--model` / `--settings` 为单个会话临时指定模型时，请手动选择。

### Codex 验证

已分别用本机 ChatGPT 内置 Codex CLI 和独立 CLI **0.172.0** 的实际返回验证 5 小时、每周和可用重置次数解析，当前读取方式正常；本次没有更改 Codex 的额度显示方式。

### 下载、安装与本机更新

- **DMG**：打开后双击“安装 Codex Usage Menu.pkg”。
- **PKG**：直接运行安装器。
- 支持 **macOS 13+、Apple Silicon 和 Intel Mac**，固定安装到 `/Applications/Codex Usage Menu.app`。
- 安装器会退出正在运行的旧实例，替换应用后自动打开新版，无需手动退出重开。
- 关闭用量窗口后继续在菜单栏运行，不占用 Dock。
- 本地签名，尚未经过 Apple Developer ID 签名与公证；若首次打开被 macOS 阻止，请在“系统设置 → 隐私与安全性”中查看相关提示。

附带 `SHA256SUMS.txt` 用于检查下载完整性。

### 验证范围

覆盖新版 agy 响应、旧模型选择迁移、明确版本与歧义处理、Orchestrator ID、共享池变更、占位重置时间和原有 Codex 兼容性。发布流程检查双架构、应用签名、DMG 完整性及 PKG 的固定安装路径。
