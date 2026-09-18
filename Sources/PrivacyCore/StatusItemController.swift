import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let privacy: PrivacyController

    private var toggleItem: NSMenuItem!
    private var strengthItems: [NSMenuItem] = []
    private var chromeItem: NSMenuItem!
    private var autoPauseItem: NSMenuItem!
    private var cursorItem: NSMenuItem!
    private var cursorRadiusItems: [NSMenuItem] = []

    /// Blur strength as a percentage of the maximum the app ships. The engine
    /// works in a Gaussian blur *radius* (points), so each step uses
    /// `radius = percent * 0.5`. That keeps the three familiar strengths exactly
    /// where they were — 轻度/中度/强度 are now 20 % / 40 % / 80 % — and slots
    /// four extra steps in between, so the whole 20 %–80 % band is reachable.
    private let levels: [(title: String, radius: Double)] = [
        ("20%", 10),
        ("30%", 15),
        ("40%", 20),
        ("50%", 25),
        ("60%", 30),
        ("70%", 35),
        ("80%", 40),
    ]

    /// Radii (points) of the disc kept sharp around the cursor.
    private let cursorRadii: [(title: String, radius: Double)] = [
        ("60 pt", 60),
        ("120 pt", 120),
        ("200 pt", 200),
    ]

    init(privacy: PrivacyController) {
        self.privacy = privacy
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
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

        chromeItem = NSMenuItem(
            title: "菜单栏与 Dock 保持清晰",
            action: #selector(toggleChrome),
            keyEquivalent: ""
        )
        chromeItem.target = self
        chromeItem.state = privacy.keepsChromeClear ? .on : .off
        menu.addItem(chromeItem)

        autoPauseItem = NSMenuItem(
            title: "全屏时停止模糊",
            action: #selector(toggleAutoPause),
            keyEquivalent: ""
        )
        autoPauseItem.target = self
        autoPauseItem.state = privacy.pausesForFullScreenApps ? .on : .off
        menu.addItem(autoPauseItem)

        cursorItem = NSMenuItem(
            title: "鼠标周围保持清晰",
            action: #selector(toggleCursorReveal),
            keyEquivalent: ""
        )
        cursorItem.target = self
        cursorItem.state = privacy.revealsCursor ? .on : .off
        menu.addItem(cursorItem)

        // Kept as its own row rather than as a submenu of the toggle: clicking
        // an item that owns a submenu is its own corner of AppKit, and this is a
        // choice that has to feel certain. Picking a radius turns the effect on
        // — the only reason to be choosing one.
        let cursorSize = NSMenuItem(title: "光标清晰范围", action: nil, keyEquivalent: "")
        let cursorSub = NSMenu()
        for option in cursorRadii {
            let item = NSMenuItem(title: option.title, action: #selector(setCursorRadius(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.radius
            item.state = privacy.revealsCursor && option.radius == privacy.currentCursorRevealRadius ? .on : .off
            cursorSub.addItem(item)
            cursorRadiusItems.append(item)
        }
        cursorSize.submenu = cursorSub
        menu.addItem(cursorSize)

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
        privacy.persistEnabled()
        toggleItem.title = privacy.isEnabled ? "停用隐私模糊" : "启用隐私模糊"
    }

    @objc private func setStrength(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        privacy.setBlurRadius(value)
        for item in strengthItems {
            item.state = item === sender ? .on : .off
        }
    }

    @objc private func toggleChrome() {
        privacy.setKeepChrome(!privacy.keepsChromeClear)
        chromeItem.state = privacy.keepsChromeClear ? .on : .off
    }

    @objc private func toggleAutoPause() {
        privacy.setPauseForFullScreenApps(!privacy.pausesForFullScreenApps)
        autoPauseItem.state = privacy.pausesForFullScreenApps ? .on : .off
    }

    @objc private func toggleCursorReveal() {
        privacy.setRevealCursor(!privacy.revealsCursor)
        syncCursorItems()
    }

    @objc private func setCursorRadius(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        privacy.setCursorRevealRadius(value)
        // Choosing a size is asking for the disc; nobody picks a radius and then
        // waits for it to appear.
        if !privacy.revealsCursor { privacy.setRevealCursor(true) }
        syncCursorItems()
    }

    /// One place that reflects the setting, whichever route changed it.
    private func syncCursorItems() {
        cursorItem.state = privacy.revealsCursor ? .on : .off
        for item in cursorRadiusItems {
            let radius = item.representedObject as? Double
            item.state = privacy.revealsCursor && radius == privacy.currentCursorRevealRadius ? .on : .off
        }
    }

    @objc private func quit() {
        privacy.disable()
        NSApp.terminate(nil)
    }

    /// The menu bar glyph: the same eye-with-a-slash as the app icon, drawn as
    /// a template so macOS tints it to match the menu bar and turns it white
    /// when the item is highlighted.
    ///
    /// Drawn rather than taken from SF Symbols so the two icons are visibly the
    /// same mark — the symbol face changes between macOS releases, and this one
    /// is the identity of the app.
    private static func menuBarIcon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let ink = NSColor.black
            ink.set()

            let eye = eyePath(size: side)
            eye.lineWidth = 1.5
            eye.lineCapStyle = .round
            eye.lineJoinStyle = .round
            eye.stroke()

            NSBezierPath(ovalIn: NSRect(
                x: side * 0.405,
                y: side * 0.405,
                width: side * 0.19,
                height: side * 0.19
            )).fill()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: side * 0.20, y: side * 0.73))
            slash.line(to: NSPoint(x: side * 0.80, y: side * 0.27))
            slash.lineWidth = 1.7
            slash.lineCapStyle = .round
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "隐私窗口"
        return image
    }

    /// The almond outline of the eye, in a square of the given side length.
    /// Kept in step with the same shape in `Tools/generate-app-icon.swift`.
    private static func eyePath(size: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let left = NSPoint(x: size * 0.16, y: size * 0.50)
        let right = NSPoint(x: size * 0.84, y: size * 0.50)
        path.move(to: left)
        path.curve(
            to: right,
            controlPoint1: NSPoint(x: size * 0.30, y: size * 0.27),
            controlPoint2: NSPoint(x: size * 0.70, y: size * 0.27)
        )
        path.curve(
            to: left,
            controlPoint1: NSPoint(x: size * 0.70, y: size * 0.73),
            controlPoint2: NSPoint(x: size * 0.30, y: size * 0.73)
        )
        path.close()
        return path
    }
}
