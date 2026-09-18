import AppKit

/// The app's delegate. Public because it is the one type the executable's entry
/// point has to reach across the module boundary; everything else stays inside
/// `PrivacyCore`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var hotKeyController: HotKeyController?
    private let privacy = PrivacyController()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        privacy.restoreSettings()
        statusController = StatusItemController(privacy: privacy)
        // Global ⌃⌥⌘B to toggle the blur from anywhere, no Accessibility grant.
        // `register()` reports whether Carbon accepted the key, so the menu only
        // advertises the shortcut when it really works.
        let hotKey = HotKeyController(action: { [weak self] in
            self?.statusController?.toggle()
        })
        hotKeyController = hotKey
        statusController?.setHotKeyRegistered(hotKey.register())
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
}
