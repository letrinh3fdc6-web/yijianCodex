# 安域一键配置 Codex

在 Windows 和 macOS 上一次完成 Codex CLI、Codex 桌面版、CC Switch 与安域 AI 网关配置。API Key 只在本机输入和保存，不会通过网页或命令行参数上传。

## 快速下载

| 系统 | 下载入口 | 支持范围 |
| --- | --- | --- |
| Windows 10/11 | [下载 Windows 一键安装器](https://x.ailzd.com/downloads/one-click-codex-installer.exe) | x64 / ARM64 |
| macOS 12+ | [下载 macOS 通用安装器](https://github.com/letrinh3fdc6-web/yijianCodex/releases/latest/download/Anyu-One-Click-Codex-macOS-universal.dmg) | Apple Silicon / Intel |

macOS 下载后打开 DMG，将 `Anyu AI One-Click Codex.app` 拖入“应用程序”，然后双击运行。安装器会在终端中询问网关、默认模型和 API Key。

如果 macOS 阻止首次打开，请在终端执行：

```bash
xattr -cr "/Applications/Anyu AI One-Click Codex.app"
```

然后重新打开应用。

## 自动完成的配置

- 检查 Node.js；缺失时下载并校验 Node.js 官方安装包。
- 安装 `@openai/codex`，执行官方 API Key 登录流程。
- 备份并写入 `~/.codex/config.toml`，默认启用安域 AI 网关和完整本机权限。
- 安装 CC Switch，并打开安域 AI Codex 提供商导入确认。
- Apple Silicon 自动安装并配置 Codex++；Intel Mac 保留 Codex、CC Switch 和桌面版完整流程，跳过当前仅提供 ARM64 包的 Codex++。
- 安装完成后打开 Codex、CC Switch，以及可用时的 Codex++。

## 安全与兼容性

- API Key 使用隐藏输入，不写入下载 URL 或项目文件；CC Switch 导入通过本机自定义协议完成，不会发送到网页或下载服务器。
- 下载的 Node.js、CC Switch 和 Codex++ 均在执行前校验 SHA-256。
- 修改现有 Codex 或 Codex++ 配置前会创建带时间戳的备份。
- macOS 安装器是未公证的开源构建产物；源码和构建流程均在本仓库中。

## 从源码构建

需要 macOS 12 或更高版本：

```bash
bash macos/test-installer.sh
bash macos/build-dmg.sh --clean --version 1.0.0
```

输出文件位于 `dist/Anyu-One-Click-Codex-macOS-universal.dmg`。
