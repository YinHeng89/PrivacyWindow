import AppKit

/// The app's delegate. Public because it is the one type the executable's entry
/// point has to reach across the module boundary; everything else stays inside
/// `PrivacyCore`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private let privacy = PrivacyController()
    private let preferences = SettingsPreferences.shared

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        privacy.restoreSettings()
        // 按用户偏好把「登录时启动」对齐到系统：从开发态换成打包 .app 后这一步会让
        // 自启自愈，旧的失效登录项会被覆盖到当前 app 路径。
        preferences.reconcileLaunchItem()
        let window = SettingsWindowController(privacy: privacy, preferences: preferences)
        settingsWindow = window
        statusController = StatusItemController(
            privacy: privacy,
            preferences: preferences,
            openSettings: { window.open() }
        )
        installMainMenu()
        // The main menu is visible while Settings is open (the window makes the
        // app regular), so its "关于/退出" labels must follow the chosen language.
        NotificationCenter.default.addObserver(
            forName: I18n.languageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installMainMenu()
            }
        }
    }

    /// Tears the effect down on the way out.
    ///
    /// `PrivacyController` cannot reliably do this from its own `deinit`: that
    /// runs with the object already being destroyed, so a `[weak self]` captured
    /// there is always nil, and a Task scheduled from it would run after the
    /// teardown anyway. The termination hook is the point that actually releases
    /// the overlays, the observers and the display link — and it covers quitting
    /// in every way, not just the menu item.
    public func applicationWillTerminate(_ notification: Notification) {
        privacy.disable()
    }

    /// Mostly invisible, but not entirely: a main menu is still how standard key
    /// equivalents reach the responder chain. Without it ⌘A/⌘C/⌘V do nothing in
    /// the settings window's search field and ⌘W does not close the window.
    ///
    /// It is also on screen for real while Settings is open, because the window
    /// temporarily makes the app a regular one (see `SettingsWindowController`)
    /// — so it carries the application menu too, rather than showing a menu bar
    /// made only of "编辑" and "窗口".
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: I18n.shared.t("关于隐私窗口"),
            action: #selector(AppDelegate.showAbout),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: I18n.shared.t("退出隐私窗口"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // Spelled as strings because there is no `#selector` for them: unlike
        // `UIResponder`, AppKit's `NSResponder` exposes no `undo:`/`redo:` to
        // Swift. They are resolved against the responder chain at run time, so
        // a text field that handles undo claims them and anything else leaves
        // the item disabled.
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    /// The application menu's "about" item. Opens Settings on its About tab
    /// rather than AppKit's own panel, which would read from a `Credits.rtf`
    /// this app does not ship.
    @objc private func showAbout() {
        settingsWindow?.open(tab: .about)
    }
}
