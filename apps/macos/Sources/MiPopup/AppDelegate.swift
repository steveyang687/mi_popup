import AppKit
import MiPopupCore
import MiPopupLAN

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var localDeliveryServer: LocalDeliveryServer?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelController = NotchPanelController()
        panelController.onImportRequest = { [weak self] in self?.chooseLogFile() }
        panelController.onDismissDelivery = { [weak self] eventId in
            self?.localDeliveryServer?.dismiss(eventId: eventId)
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
        buildStatusMenu()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        localDeliveryServer?.stop()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        panelController?.reposition()
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "shippingbox.fill",
                accessibilityDescription: "MiPopup"
            )
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示灵动岛", action: #selector(showIsland), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "刷新当前数据", action: #selector(refreshQuotas), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "导入 Android 日志…", action: #selector(chooseLogFile), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MiPopup", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showIsland() {
        panelController?.show()
    }

    @objc private func refreshQuotas() {
        panelController?.refreshQuotas()
        panelController?.show()
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
