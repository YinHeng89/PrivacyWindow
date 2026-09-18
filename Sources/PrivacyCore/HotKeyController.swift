import Carbon
import Foundation

/// Registers a single global keyboard shortcut — ⌃⌥⌘B (Control+Option+Command+B)
/// — that toggles the privacy blur on and off from anywhere, without the app
/// becoming the key application or asking for the Accessibility permission.
///
/// `NSMenuItem.keyEquivalent` is ruled out because this app is an `.accessory`
/// and is never the active app, so menu shortcuts only fire while the menu is
/// open. A Carbon `RegisterEventHotKey` is global and needs no extra TCC grant.
final class HotKeyController {
    /// Invoked on the main actor whenever the hotkey is pressed.
    private let action: @MainActor () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// ⌃⌥⌘B: the Carbon modifier bits for Command, Option and Control, plus the
    /// virtual key code of the physical B key. The key code is positional, so
    /// the shortcut stays on the same physical key under any keyboard layout.
    private static let modifiers = UInt32(cmdKey | optionKey | controlKey)
    private static let keyCode = UInt32(kVK_ANSI_B)

    /// Carbon four-char codes that the SDK no longer exposes as named constants.
    private static let eventClassHotKey: UInt32 = 0x686F746B // 'hotk'
    private static let eventHotKeyPressed: UInt32 = 1
    private static let paramDirectObject = EventParamName(0x2D2D2D2D) // '----'
    private static let typeHotKeyID = EventParamType(0x686B6964) // 'hkid'

    /// Registers the shortcut. Returns `false` when Carbon refuses it — which
    /// happens when another app already owns ⌃⌥⌘B — so the caller can avoid
    /// advertising a shortcut that does nothing.
    @discardableResult
    func register() -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052574E), id: 1)
        // Install on the event *dispatcher* target, not the application target:
        // an `.accessory` app is never the active application, so the app target
        // never receives hot-key events while it is in the background. The
        // dispatcher target sits above it in the chain and catches them anyway.
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else { return false }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(eventClass: Self.eventClassHotKey, eventKind: Self.eventHotKeyPressed)
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.handler,
            1,
            &spec,
            selfPtr,
            &eventHandlerRef
        )
        return installed == noErr
    }

    private static let handler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            HotKeyController.paramDirectObject,
            HotKeyController.typeHotKeyID,
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        if status == noErr, hotKeyID.id == 1 {
            let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            // The dispatcher-target handler may run off the main thread, so hop
            // onto the main actor instead of assuming we are already there.
            Task { @MainActor in controller.action() }
        }
        return noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
