import AppKit
import Combine

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let privacy: PrivacyController
    private let preferences: SettingsPreferences
    private let openSettings: () -> Void

    // All optional: the menu is built when it is first shown, and the icon can
    // also answer a click with a toggle (see `menuBarClickAction`) without ever
    // having shown one. Touching a row that does not exist would crash on a
    // click that has nothing to do with the menu.
    private var toggleItem: NSMenuItem?
    /// Combine lifetime for the click-action observer that (re)assigns the menu.
    private var cancellables: [AnyCancellable] = []
    private var strengthItems: [NSMenuItem] = []
    private var chromeItem: NSMenuItem?
    private var autoPauseItem: NSMenuItem?
    private var cursorItem: NSMenuItem?
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

    init(privacy: PrivacyController, preferences: SettingsPreferences, openSettings: @escaping () -> Void) {
        self.privacy = privacy
        self.preferences = preferences
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageLeading
            // Both left and right clicks reach the button; `reconcileMenuAssignment`
            // decides whether the system owns the click (showMenu → native menu)
            // or we do (toggle / open settings → our action).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // The on/off flip has exactly one broadcaster and this is its one
        // listener: the state can be changed from the settings window while
        // this icon sits in the menu bar the whole time, and from a menu that
        // is already open when the window's master switch is used.
        privacy.onEnabledChanged = { [weak self] on in
            self?.reflectEnabled(on)
        }
        reflectEnabled(privacy.isEnabled)

        // The left-click action decides whether the status bar shows the menu
        // natively (cap-free) or hands the click back to our button. Rebuild
        // whenever the action or the UI language flips so the menu stays current.
        NotificationCenter.default.addObserver(
            forName: I18n.languageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileMenuAssignment()
            }
        }
        preferences.$menuBarClickAction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcileMenuAssignment()
                }
            }
            .store(in: &cancellables)
        reconcileMenuAssignment()
    }

    /// Routes the status-bar click according to `menuBarClickAction`.
    ///
    /// When the action is `showMenu`, the menu is handed to the system via
    /// `statusItem.menu` — the one presentation AppKit draws with *no* upward
    /// cap, which is what the user objected to. The button's action is cleared
    /// so the system owns the click (both left and right reveal the menu). For
    /// the other two actions the menu is removed and our button handles the
    /// click; a right-click still opens the menu through `showMenu()`.
    private func reconcileMenuAssignment() {
        guard let button = statusItem.button else { return }
        if preferences.menuBarClickAction == .showMenu {
            statusItem.menu = buildMenu()
            button.target = nil
            button.action = nil
        } else {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(statusBarClicked(_:))
        }
    }

    /// Reflects the on/off state: the toggle item's title for a menu that may
    /// already be open, and the icon's weight for every moment in between — a
    /// dimmed eye reads as "not watching" without inventing a second glyph.
    private func reflectEnabled(_ on: Bool) {
        toggleItem?.title = I18n.shared.t(on ? "停用隐私模糊" : "启用隐私模糊")
        statusItem.button?.alphaValue = on ? 1 : 0.45
    }

    /// Rebuilt on every open, so items that mirror state — the on/off label,
    /// the checked strength — can never be stale.
    ///
    /// Blur Strength and Cursor Reveal Radius are nested submenus: hover (or
    /// press → / Enter) to reveal the level/radius choices, keeping the
    /// top-level menu short.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Both collections are rebuilt from scratch: the menu is, and stale
        // items would keep their state from a previous open.
        strengthItems = []
        cursorRadiusItems = []

        let toggle = NSMenuItem(
            title: I18n.shared.t(privacy.isEnabled ? "停用隐私模糊" : "启用隐私模糊"),
            action: #selector(toggle),
            keyEquivalent: ""
        )
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        let strength = NSMenuItem(title: I18n.shared.t("模糊强度"), action: nil, keyEquivalent: "")
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

        let chrome = NSMenuItem(
            title: I18n.shared.t("菜单栏与 Dock 保持清晰"),
            action: #selector(toggleChrome),
            keyEquivalent: ""
        )
        chrome.target = self
        chrome.state = privacy.keepsChromeClear ? .on : .off
        chromeItem = chrome
        menu.addItem(chrome)

        let autoPause = NSMenuItem(
            title: I18n.shared.t("全屏时停止模糊"),
            action: #selector(toggleAutoPause),
            keyEquivalent: ""
        )
        autoPause.target = self
        autoPause.state = privacy.pausesForFullScreenApps ? .on : .off
        autoPauseItem = autoPause
        menu.addItem(autoPause)

        let cursor = NSMenuItem(
            title: I18n.shared.t("鼠标周围保持清晰"),
            action: #selector(toggleCursorReveal),
            keyEquivalent: ""
        )
        cursor.target = self
        cursor.state = privacy.revealsCursor ? .on : .off
        cursorItem = cursor
        menu.addItem(cursor)

        // Kept as its own row rather than as a submenu of the toggle: clicking
        // an item that owns a submenu is its own corner of AppKit, and this is a
        // choice that has to feel certain. Picking a radius turns the effect on
        // — the only reason to be choosing one.
        let cursorSize = NSMenuItem(title: I18n.shared.t("光标清晰范围"), action: nil, keyEquivalent: "")
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

        let settings = NSMenuItem(title: I18n.shared.t("设置…"), action: #selector(openSettingsWindow), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: I18n.shared.t("退出"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showMenu()
            return
        }
        switch preferences.menuBarClickAction {
        case .showMenu: showMenu()
        case .toggleBlur: toggle()
        case .openSettings: openSettingsWindow()
        }
    }

    /// Pops the menu up under the icon. Deliberately not `performClick`, which
    /// would re-enter `statusBarClicked` and pop it up again.
    ///
    /// Presented as a *context menu* on the status button. Every other route —
    /// anchored `popUp(positioning:at:in: button)` and even a detached
    /// `popUp(positioning:at:in: nil)` — makes Tahoe's Liquid Glass draw the
    /// little upward cap/arrow at the top of the menu, which reads as an arrow
    /// sitting above the first item (启用/停止). Context-menu presentation is
    /// the one route that renders the menu with no cap.
    private func showMenu() {
        let menu = buildMenu()
        guard let button = statusItem.button else { return }
        let event: NSEvent
        if let current = NSApp.currentEvent {
            event = current
        } else if let synthesized = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: button.window.map({ $0.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)) }) ?? NSEvent.mouseLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: button.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            event = synthesized
        } else {
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func openSettingsWindow() {
        openSettings()
    }

    @objc private func toggle() {
        if privacy.isEnabled {
            privacy.disable()
        } else {
            privacy.enable()
        }
        privacy.persistEnabled()
        // The title patch lives in `reflectEnabled`, reached through
        // `onEnabledChanged` — the same route a change from the settings
        // window takes. Patching here as well would be a second, competing
        // writer for no coverage this one does not have.
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
        chromeItem?.state = privacy.keepsChromeClear ? .on : .off
    }

    @objc private func toggleAutoPause() {
        privacy.setPauseForFullScreenApps(!privacy.pausesForFullScreenApps)
        autoPauseItem?.state = privacy.pausesForFullScreenApps ? .on : .off
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
        cursorItem?.state = privacy.revealsCursor ? .on : .off
        for item in cursorRadiusItems {
            let radius = item.representedObject as? Double
            item.state = privacy.revealsCursor && radius == privacy.currentCursorRevealRadius ? .on : .off
        }
    }

    @objc private func quit() {
        privacy.disable()
        NSApp.terminate(nil)
    }

    /// The menu bar glyph: the app icon's own scene, in template form — one
    /// crisp window in focus, one defocused window losing itself behind it.
    ///
    /// Drawn rather than taken from SF Symbols so the mark stays ours: the
    /// symbol face changes between macOS releases, and this one is the identity
    /// of the app. The crisp window is a *solid* shape with its details (traffic
    /// lights, title-bar seam, content lines) punched out as holes, which keeps
    /// it legible at 18 pt where an outline-and-dots drawing turns to mud; the
    /// ghost behind is the opposite — a soft multi-pass stroke that reads as
    /// out of focus. Solid against soft is the whole product in one glyph.
    ///
    /// Rendered into a 4× bitmap tagged at point size, so Retina menu bars get
    /// real pixels instead of an upscaled 1× image.
    private static func menuBarIcon() -> NSImage {
        let side: CGFloat = 18
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side * scale),
            pixelsHigh: Int(side * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.cgContext.scaleBy(x: scale, y: scale)

        // The world behind, out of focus: a rounded rect that fades at its own
        // edge — fill, then two strokes of decreasing weight and opacity, which
        // the eye reads as defocus rather than as decoration.
        let ghostRect = NSRect(x: 1.5, y: 8.1, width: 8.6, height: 8.5)
        let ghost = NSBezierPath(roundedRect: ghostRect, xRadius: 2.1, yRadius: 2.1)
        for (width, alpha) in [(CGFloat(2.6), CGFloat(0.08)), (CGFloat(1.6), CGFloat(0.14)), (CGFloat(0.9), CGFloat(0.30))] {
            let ring = NSBezierPath(roundedRect: ghostRect, xRadius: 2.1, yRadius: 2.1)
            ring.lineWidth = width
            NSColor.black.withAlphaComponent(alpha).setStroke()
            ring.stroke()
        }
        NSColor.black.withAlphaComponent(0.10).setFill()
        ghost.fill()

        // The window in focus: solid, with the details knocked out. Everything
        // that is a hole lives strictly inside the frame and never overlaps
        // another hole — the path is one even-odd fill, so a second crossing
        // would turn a hole back into ink.
        let frame = NSRect(x: 4.6, y: 2.4, width: 11.6, height: 9.6)
        let glyph = NSBezierPath()
        glyph.windingRule = .evenOdd
        glyph.append(NSBezierPath(roundedRect: frame, xRadius: 2.4, yRadius: 2.4))

        // Traffic lights, on the title bar's centre line.
        for x: CGFloat in [6.5, 8.2, 9.9] {
            glyph.append(NSBezierPath(ovalIn: NSRect(x: x - 0.62, y: 10.13, width: 1.24, height: 1.24)))
        }
        // The seam under the title bar, inset from the sides so the title bar
        // stays attached to the body instead of floating off as a pill.
        glyph.append(NSBezierPath(
            roundedRect: NSRect(x: 5.8, y: 8.75, width: 9.2, height: 0.95),
            xRadius: 0.45, yRadius: 0.45
        ))
        // Content, two lines of it — three turns to noise at this size.
        glyph.append(NSBezierPath(
            roundedRect: NSRect(x: 6.3, y: 6.45, width: 7.8, height: 1.0),
            xRadius: 0.5, yRadius: 0.5
        ))
        glyph.append(NSBezierPath(
            roundedRect: NSRect(x: 6.3, y: 4.55, width: 5.4, height: 1.0),
            xRadius: 0.5, yRadius: 0.5
        ))

        NSColor.black.setFill()
        glyph.fill()

        NSGraphicsContext.restoreGraphicsState()

        // Only *after* drawing: a bitmap rep that already carries a point size
        // hands the context a DPI scale of its own, and the CTM set below then
        // composes with it — the ink lands a factor of `scale` away from where
        // the geometry says, which in practice means nowhere at all.
        rep.size = NSSize(width: side, height: side)

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = I18n.shared.t("隐私窗口")
        return image
    }
}
