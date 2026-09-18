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
        let window = SettingsWindowController(privacy: privacy, preferences: preferences)
        settingsWindow = window
        statusController = StatusItemController(
            privacy: privacy,
            preferences: preferences,
            openSettings: { window.open() }
        )
        installMainMenu()
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

    /// The menu is never shown — this is an `LSUIElement` app with no menu bar
    /// of its own — but a main menu is still how standard key equivalents reach
    /// the responder chain. Without it ⌘A/⌘C/⌘V do nothing in the settings
    /// window's search field and ⌘W does not close the window.
    private func installMainMenu() {
        let main = NSMenu()

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
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
}
