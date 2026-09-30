# Notchvisor

Notchvisor is a lightweight "Dynamic Island" status panel running in the MacBook notch area. 

The application reads the local subscription quotas for OpenAI Codex and Google Antigravity, combining them with Codex Radar's public model IQ summaries to recommend the optimal Codex configuration on the fly. 

The Android companion parses delivery notifications from Meituan and Taobao Flash Sale, then pushes minimal delivery updates to macOS over LAN and, optionally, an end-to-end encrypted personal VPS relay.

---

## How Codex and GPT-5.6 Were Used

Notchvisor utilizes and interacts with OpenAI Codex and GPT-5.6 in the following ways:
1. **Quota Monitoring**: The application integrates with the local `codex` client daemon (`codex app-server` via JSON-RPC over `stdio`) to query `account/rateLimits/read`. This reads the remaining quota windows allocated to ChatGPT Plus/Pro subscriptions for Codex usage.
2. **Model Optimization & Reasoning Levels**: The model recommendation engine fetches real-time performance summaries from Codex Radar (`https://codexradar.com/current.json`). It parses performance and cost figures for various `GPT-5.6 Sol` configurations (specifically comparing different `reasoning_effort` parameters: `max`, `xhigh`, and `medium`).
3. **Recommendation Logic**: When a developer hovers over the notch, Notchvisor determines whether the current coding task requires the maximum reasoning capability (`GPT-5.6 Sol max`) or if a more cost-effective configuration like `GPT-5.6 Sol medium` is sufficient based on the remaining subscription window.

---

## Features

### AI Subscription Quota
- **OpenAI**: Reads ChatGPT Plus/Pro limits allocated for Codex using the local `codex app-server` API `account/rateLimits/read`.
- **Google**: Automatically detects the running local Antigravity daemon or briefly spawns the logged-in `agy` CLI to fetch Gemini model quotas, exiting immediately after completion.
- **Privacy Boundary**: Notchvisor only displays the remaining subscription quota windows. It **does not** read OpenAI API or Gemini API billing details, balances, or token usages.
- **Auto-Refresh**: Quotas refresh automatically every 3 minutes. Manual refresh can also be triggered from the menu bar or the expanded notch panel.
- **Zero-Credential Storage**: Credentials are managed entirely by Codex and Antigravity. Notchvisor does not read, save, or transmit your OAuth tokens or API keys.

### Model Recommendation
- Hovering over the notch expands the "Model Recommendation" tab, showing the latest Codex Radar evaluation results, including IQ indices, passed tasks, and evaluation costs.
- **"Strongest"**: Recommends the highest IQ model configuration.
- **"Balanced"**: Recommends the most cost-efficient configuration among those scoring at least 90% of the strongest model's IQ.
- Data is refreshed every 30 minutes. A source link to Codex Radar is displayed at the footer.

### Delivery Sync
- **Event-driven**: Android pushes state changes directly; macOS does not poll the phone.
- **Dual transport**: Bonjour/TCP is used on the same LAN while HTTPS/WSS Relay supports cellular and different networks.
- **End-to-end encrypted Relay**: The VPS stores only AES-256-GCM ciphertext and never receives the content key.
- **Shared deduplication**: Both transports use the same `eventId`, so racing deliveries update the island once.

---

## Installation Packages

- **Android**: `dist/MiPopup-Android-0.1.5-network-test-debug.apk`
- **macOS Apple Silicon**: `dist/MiPopup-0.1.0-arm64.dmg` (drag into Applications) or `dist/MiPopup-0.1.0-arm64.pkg` (macOS Installer)

*Note: These packages are signed with local development credentials (Android debug key / macOS ad-hoc signatures) and are not notarized by Apple.*

---

## Setup Instructions

### 1. Android Notification Capture Setup

1. Transfer the APK to your Android device and install it. If using ADB, run:
   ```bash
   adb install -r dist/MiPopup-Android-0.1.5-network-test-debug.apk
   ```
2. Open the **"MiPopup 通知采集"** app, tap **"1. 打开通知使用权设置"**, and grant Notification Access to the app.
3. Verify that notifications for Meituan (美团) and Taobao (淘宝) are enabled in your Android system settings.
4. Once you receive delivery notifications, return to the app and tap **"刷新日志预览"** to see captured logs.
5. Tap **"3. 导出脱敏 JSONL"** to export the redacted notification logs using the Storage Access Framework, then transfer the `.jsonl` file to your Mac.
6. For another delivery app or a new notification phrasing, tap **"2. 扫描当前活动通知"** and copy its package name from the status card. Add a rule under **"自定义配送解析规则"**: select `auto`, `standard_notification`, or `hyperos_focus`, map matching wording to a delivery stage, and set `syncToMac` to control whether that rule updates the Mac island. The rule JSON example is built into the app.
7. To verify the complete data path without waiting for a real order, tap **"4. 发送测试配送状态到 Mac"**. The test event is written to the local log and sent through the same LAN and personal-relay outboxes as a real delivery update.

### 2. Optional Personal Relay

Generate credentials on a trusted Mac, upload only the server environment file, and deploy `services/relay/compose.yaml` on the VPS by following `services/relay/README.md`. Paste the local client JSON into Android. On macOS, click the **设置** gear to the left of **刷新**, scroll to **公网中继** (or choose **配置公网中继…** from the menu bar), paste the same JSON, and select **保存并连接**. The settings page also provides collapsed display density, screen position, and hover/click activation preferences, which save automatically.

### 3. macOS Client Setup

1. Install the macOS client using `dist/MiPopup-0.1.0-arm64.pkg` or drag the app from `dist/MiPopup-0.1.0-arm64.dmg` to your `/Applications` folder.
2. If blocked by macOS Gatekeeper on first launch, go to **System Settings → Privacy & Security** and select **"Open Anyway"**.
3. Upon launch, a black status capsule will appear around your MacBook's notch (or at the top-center of the screen for non-notch displays).
4. Hover your cursor over the notch to expand the interface and view your Codex and Antigravity quotas.
5. To import the Android log, select **"导入 Android 日志…"** from the status bar menu or simply drag-and-drop the `.jsonl` file onto the expanded notch window.

---

## Local Build Instructions

### Android Build
Requires JDK 17, Android SDK 36, and Build Tools 36:
```bash
cd apps/android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export GRADLE_USER_HOME="$PWD/.gradle-user-home"
./gradlew test assembleDebug
```

To build the simplified user-facing APK with a bundled personal Relay configuration, keep the
client JSON outside the repository and pass only its path to Gradle:

```bash
MIPOPUP_RELAY_CONFIG_FILE="$HOME/Library/Application Support/MiPopup/relay-config.json" \
  ./gradlew assembleUser
```

The output is `apps/android/app/build/outputs/apk/user/app-user.apk`. The user build hides log,
parser, package, test-message, and Relay credential editors. It is locally debug-signed for direct
installation and uses the same application ID as the debug-tools build, so it replaces that build.
Bundling credentials hides them from the UI but cannot prevent extraction from a decompiled APK;
only distribute this artifact to controlled devices and rotate the Relay token and content key if
the APK leaves that boundary.

### macOS Build
Requires Xcode 15+ (Swift 6 compatible toolchain):
```bash
cd apps/macos

# Run unit tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox

# Package the application (builds .dmg and .pkg)
./scripts/package.sh
```

To run the macOS app in development mode without packaging:
```bash
cd apps/macos
./scripts/dev.sh
```
*Note: Exit any installed Notchvisor / MiPopup instances before running in development mode to prevent window overlapping.*

---

## Directory Structure

- `PROJECT_DESIGN.md`: Architecture details, privacy rules, and parser design.
- `apps/android`: Kotlin-based Android notification collector.
- `apps/macos`: Swift-based AppKit/SwiftUI notch client.
- `services/relay`: Ciphertext-only Node.js/SQLite Relay with Caddy and Docker Compose deployment.
- `protocol/RELAY_PROTOCOL.md`: Cross-network E2EE wire contract.
- `docs/CAPTURE_SCHEMA.md`: Notification log field contract.
- `LICENSES/CodexBar-MIT.txt`: MIT License for the AI quota provider references.
- `samples/mipopup-sample.jsonl`: Test logs for macOS importer validation.
- `dist/`: Pre-built application binaries.
