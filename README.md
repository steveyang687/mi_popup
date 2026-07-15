# MiPopup

MiPopup 是运行在 MacBook 刘海区域的轻量“灵动岛”。当前 macOS 版本会读取本机已经登录的 OpenAI Codex 和 Google Antigravity 订阅额度，并结合 Codex Radar 的公开模型 IQ 摘要推荐 Codex 模型配置；Android 伴侣应用仍处于美团、淘宝闪购通知采样阶段。

## AI 订阅额度

- OpenAI：通过本机 `codex app-server` 的 `account/rateLimits/read` 读取 ChatGPT Plus/Pro 等方案包含的 Codex 额度。
- Google：优先连接正在运行的 Antigravity 本地服务；未运行时短暂启动已登录的 `agy` CLI，读取完成后立即退出。
- 仅展示订阅方案额度，不读取 OpenAI API 或 Gemini API 的账单、余额和 Token 用量。
- 每 3 分钟自动刷新，也可以从展开界面或菜单栏手动刷新；失败时保留上次成功结果。
- 登录凭证始终由 Codex/Antigravity 自己管理，MiPopup 不读取、不保存也不输出 OAuth Token。

Google AI Pro/Ultra 个人订阅已迁移到 Antigravity，因此不再使用旧 Gemini CLI 的个人版额度通道。Antigravity 本地协议属于内部接口，产品升级后可能需要同步调整解析器。

## 模型推荐

- 展开刘海后切换到“模型推荐”Tab，可查看 Codex Radar 最新实测 IQ、任务通过数和测试成本。
- “当前最强”按最新 IQ 排序；“均衡推荐”从 IQ 不低于最高分 90% 的配置中选择测试成本最低者。
- 模型数据每 30 分钟刷新，页脚保留 Codex Radar 来源链接和固定署名。
- 当前只接入 `current.json` 公开摘要用于本地开发测试。该摘要声明二次开发和完整 API 使用需要站方授权，公开分发前必须联系 Codex Radar 获得许可/API Key。

## 安装包

- Android：`dist/MiPopupCapture-0.1.1-debug.apk`
- macOS Apple Silicon：`dist/MiPopup-0.1.0-arm64.pkg`

这些包均为本地开发签名。Android APK 使用 Android debug key；macOS `.app` 使用 ad-hoc 签名，`.pkg` 未使用 Apple Developer ID 签名且未公证。它们适合当前内部采样，不适合公开分发。

## Android 采样步骤

1. 将 APK 传到手机并安装。使用 ADB 时可执行：

   ```bash
   adb install -r dist/MiPopupCapture-0.1.1-debug.apk
   ```

2. 打开“MiPopup 通知采集”，点击“打开通知使用权设置”，允许该应用读取通知。
3. 在系统设置中确认美团、淘宝的配送通知本身已开启。小米/HyperOS 设备建议再将 MiPopup 设为“无省电限制”，避免系统长期终止监听服务。
4. 产生或等待外卖配送通知。回到采集器点击“刷新日志预览”，确认事件数增加。
5. 如果顶部灵动岛已经存在但事件仍为 0，点击“扫描当前活动通知”。页面会显示系统返回的活动通知数量、目标包匹配数量和相关包名。
6. 点击“导出脱敏 JSONL”，保存文件后传到 Mac。

监听会接收授权之后的新通知，并在服务连接或用户手动扫描时读取当前仍活跃的通知；已经消失的历史通知无法恢复。默认目标包名可以在应用内编辑；请以日志中的 `sourcePackage` 为准。

## macOS 使用步骤

1. 退出正在运行的旧版 MiPopup，然后安装 `dist/MiPopup-0.1.0-arm64.pkg`。
2. 首次运行如被 Gatekeeper 阻止，在“系统设置 → 隐私与安全性”中选择仍要打开。正式分发需要 Developer ID 签名和 Apple 公证。
3. MiPopup 启动后不显示 Dock 图标；顶部中央会出现黑色灵动岛，菜单栏有包裹图标。
4. 应用会自动读取本机 Codex 和 Antigravity 登录状态。鼠标移入刘海会自动展开，可在“额度”和“模型推荐”间切换；点击刘海可以立即手动收起，移出后也会等待 3 秒自动收起。
5. 菜单栏或展开界面的“刷新”按钮可以立即刷新当前 Tab。
6. Android 日志仍可从菜单栏选择“导入 Android 日志…”或拖入 `.jsonl` 文件；当前不推断配送阶段。

## 隐私边界

- Android Manifest 不声明 `android.permission.INTERNET`。
- 原始通知只写入应用私有目录，保留 7 天且总量上限为 20 MiB。
- 导出时会遮盖中国大陆手机号、8 位以上长编号和常见 token/cookie/authorization 值。
- 标题或正文仍可能包含姓名、短地址等个人信息。分享样本前请在文本编辑器中人工复核。

## 本地构建

Android 需要 JDK 17、Android SDK 36 和 Build Tools 36：

```bash
cd apps/android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export GRADLE_USER_HOME="$PWD/.gradle-user-home"
./gradlew test assembleDebug
```

macOS 需要 Xcode 26 或兼容的完整 Xcode：

```bash
cd apps/macos
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox
./scripts/package.sh
```

不打包直接运行 macOS 开发版本：

```bash
cd apps/macos
./scripts/dev.sh
```

运行前先退出已安装的 MiPopup，避免两个顶部面板重叠。开发脚本使用 debug 构建并在终端前台运行，按 `Ctrl+C` 退出；修改 Swift 源码后需要重新执行脚本，不提供浏览器式热更新。

## 目录

- `PROJECT_DESIGN.md`：产品、架构、隐私和后续解析设计
- `apps/android`：基于 NotificationForwarder 监听思路改造的纯本地 Android 采集器
- `apps/macos`：AppKit/SwiftUI 刘海应用和 JSONL 导入器
- `docs/CAPTURE_SCHEMA.md`：采集日志字段契约
- `LICENSES/CodexBar-MIT.txt`：AI 额度 Provider 参考实现的 MIT 许可
- `samples/mipopup-sample.jsonl`：Mac 导入测试样例
- `dist`：本次构建产物
