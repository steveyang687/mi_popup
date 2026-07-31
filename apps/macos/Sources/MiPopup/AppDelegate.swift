import AppKit
import MiPopupCore
import MiPopupLAN

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var localDeliveryServer: LocalDeliveryServer?
    private var relayDeliveryClient: RelayDeliveryClient?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelController = NotchPanelController()
        panelController.onImportRequest = { [weak self] in self?.chooseLogFile() }
        panelController.onDismissDelivery = { [weak self] eventId in
            self?.localDeliveryServer?.dismiss(eventId: eventId)
        }
        panelController.onSaveRelayConfiguration = { [weak self] json in
            guard let self else { throw RelayLifecycleError.applicationUnavailable }
            try self.saveRelayConfiguration(json)
        }
        self.panelController = panelController
        let server = LocalDeliveryServer(
            onStateChange: { state in
                #if DEBUG
                print("MiPopup LAN server: \(state)")
                #endif
            },
            onDelivery: { [weak panelController] update in
                panelController?.receive(delivery: update)
            }
        )
        if let restored = server.restoredLatestDelivery {
            panelController.receive(delivery: restored, restoreOnly: true)
        }
        localDeliveryServer = server
        server.start()
        startRelayClient(using: server)
        buildStatusMenu()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        localDeliveryServer?.stop()
        relayDeliveryClient?.stop()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        panelController?.reposition()
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = StatusBarIcon.make()
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示灵动岛", action: #selector(showIsland), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "刷新当前数据", action: #selector(refreshQuotas), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "导入 Android 日志…", action: #selector(chooseLogFile), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "配置公网中继…", action: #selector(showRelayConfiguration), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MiPopup", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func startRelayClient(using server: LocalDeliveryServer) {
        do {
            guard let configuration = try RelayConfiguration.load() else {
                panelController?.updateRelayConfiguration(
                    configured: false,
                    detail: "尚未配置公网中继"
                )
                #if DEBUG
                print("MiPopup Relay: no config at \(RelayConfiguration.defaultFileURL.path)")
                #endif
                return
            }
            panelController?.updateRelayConfiguration(
                configured: true,
                detail: "正在连接公网中继…",
                json: try RelayConfiguration.readJSON()
            )
            activateRelayClient(configuration: configuration, using: server)
        } catch {
            panelController?.updateRelayConfiguration(
                configured: FileManager.default.fileExists(
                    atPath: RelayConfiguration.defaultFileURL.path
                ),
                detail: "中继配置无法加载",
                error: error.localizedDescription,
                json: try? RelayConfiguration.readJSON()
            )
            // Never print the configuration contents: it contains the bearer token and E2EE key.
            print("MiPopup Relay configuration error: \(error.localizedDescription)")
        }
    }

    private func saveRelayConfiguration(_ json: String) throws {
        guard let localDeliveryServer else {
            throw RelayLifecycleError.applicationUnavailable
        }
        let configuration = try RelayConfiguration.save(json: json)
        relayDeliveryClient?.stop()
        relayDeliveryClient = nil
        activateRelayClient(configuration: configuration, using: localDeliveryServer)
    }

    private func activateRelayClient(
        configuration: RelayConfiguration,
        using server: LocalDeliveryServer
    ) {
        panelController?.updateRelayConfiguration(
            configured: true,
            detail: "正在连接公网中继…"
        )
        let client = RelayDeliveryClient(
            configuration: configuration,
            onStateChange: { [weak self] state in
                self?.applyRelayClientState(state)
                #if DEBUG
                print("MiPopup Relay: \(state)")
                #endif
            },
            onDelivery: { update in
                _ = await server.ingest(update)
            }
        )
        relayDeliveryClient = client
        client.start()
    }

    private func applyRelayClientState(_ state: RelayDeliveryClientState) {
        let detail: String
        let error: String?
        switch state {
        case .stopped:
            detail = "中继连接已停止"
            error = nil
        case .connecting:
            detail = "正在连接公网中继…"
            error = nil
        case .connected:
            detail = "已连接公网中继"
            error = nil
        case .waitingToRetry(let message):
            detail = "连接中断，正在自动重试"
            error = message
        }
        panelController?.updateRelayConfiguration(
            configured: true,
            detail: detail,
            error: error
        )
    }

    @objc private func showIsland() {
        panelController?.show()
    }

    @objc private func refreshQuotas() {
        panelController?.refreshQuotas()
        panelController?.show()
    }

    @objc private func showRelayConfiguration() {
        panelController?.showRelayConfiguration()
    }

    @objc private func chooseLogFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择 MiPopup Android 导出的 JSONL"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        panelController?.importLog(at: url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private enum RelayLifecycleError: LocalizedError {
    case applicationUnavailable

    var errorDescription: String? {
        "应用尚未完成启动，请稍后重试。"
    }
}
