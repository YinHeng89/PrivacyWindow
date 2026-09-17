import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let privacy: PrivacyController

    private var toggleItem: NSMenuItem!
    private var strengthItems: [NSMenuItem] = []

    private let levels: [(title: String, radius: Double)] = [
        ("轻度", 10),
        ("中度", 20),
        ("强度", 40),
    ]

    init(privacy: PrivacyController) {
        self.privacy = privacy
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐私窗口")
            button.imagePosition = .imageLeading
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        toggleItem = NSMenuItem(
            title: privacy.isEnabled ? "停用隐私模糊" : "启用隐私模糊",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let strength = NSMenuItem(title: "模糊强度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for level in levels {
            let item = NSMenuItem(title: level.title, action: #selector(setStrength(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.radius
            item.state = level.radius == privacy.currentBlurRadius ? .on : .off
            sub.addItem(item)
            strengthItems.append(item)
        }
        strength.submenu = sub
        menu.addItem(strength)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggle() {
        if privacy.isEnabled {
            privacy.disable()
        } else {
            privacy.enable()
        }
        toggleItem.title = privacy.isEnabled ? "停用隐私模糊" : "启用隐私模糊"
    }

    @objc private func setStrength(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        privacy.setBlurRadius(value)
        for item in strengthItems {
            item.state = item === sender ? .on : .off
        }
    }

    @objc private func quit() {
        privacy.disable()
        NSApp.terminate(nil)
    }
}
