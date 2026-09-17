import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let privacy = PrivacyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(privacy: privacy)
    }
}
