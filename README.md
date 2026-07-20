# Notchvisor

Notchvisor is a lightweight "Dynamic Island" status panel running in the MacBook notch area. 

The application reads the local subscription quotas for OpenAI Codex and Google Antigravity, combining them with Codex Radar's public model IQ summaries to recommend the optimal Codex configuration on the fly. 

The Android companion application is currently in the notification sampling stage, capturing delivery notifications from Meituan and Taobao Flash Sale.

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

---

## Installation Packages

- **Android**: `dist/MiPopupCapture-0.1.1-debug.apk`
- **macOS Apple Silicon**: `dist/MiPopup-0.1.0-arm64.dmg` (drag into Applications) or `dist/MiPopup-0.1.0-arm64.pkg` (macOS Installer)

*Note: These packages are signed with local development credentials (Android debug key / macOS ad-hoc signatures) and are not notarized by Apple.*

---

## Setup Instructions

### 1. Android Notification Capture Setup

1. Transfer the APK to your Android device and install it. If using ADB, run:
   ```bash
   adb install -r dist/MiPopupCapture-0.1.1-debug.apk
   ```
2. Open the **"MiPopup 通知采集"** app, tap **"1. 打开通知使用权设置"**, and grant Notification Access to the app.
3. Verify that notifications for Meituan (美团) and Taobao (淘宝) are enabled in your Android system settings.
4. Once you receive delivery notifications, return to the app and tap **"刷新日志预览"** to see captured logs.
5. Tap **"3. 导出脱敏 JSONL"** to export the redacted notification logs using the Storage Access Framework, then transfer the `.jsonl` file to your Mac.

### 2. macOS Client Setup

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
- `docs/CAPTURE_SCHEMA.md`: Notification log field contract.
- `LICENSES/CodexBar-MIT.txt`: MIT License for the AI quota provider references.
- `samples/mipopup-sample.jsonl`: Test logs for macOS importer validation.
- `dist/`: Pre-built application binaries.
