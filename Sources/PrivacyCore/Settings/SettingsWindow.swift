import AppKit
import SwiftUI

// MARK: - Preferences that belong to the shell, not the effect

/// What a left click on the menu-bar icon does.
///
/// `showMenu` keeps the behaviour this app has always had, and is the default:
/// a menu-bar utility that answers a click with a menu is the least surprising
/// thing it can do. The other two are shortcuts for people who only ever click
/// it for one reason.
enum MenuBarClickAction: String, CaseIterable, Identifiable {
    case showMenu
    case toggleBlur
    case openSettings

    var id: String { rawValue }
    var label: String {
        switch self {
        case .showMenu: return "显示菜单"
        case .toggleBlur: return "开关模糊"
        case .openSettings: return "打开设置"
        }
    }
}

/// Appearance of the settings window only. The blur itself is a picture of the
/// screen and has no light or dark variant to choose from.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The settings that the effect itself has never heard of: how the icon
/// behaves, and what colour the settings window is. Kept apart from
/// `PrivacyController` deliberately — mixing them would drag window appearance
/// into the thing that drives overlays and captures.
@MainActor
final class SettingsPreferences: ObservableObject {
    static let shared = SettingsPreferences()

    private enum Key {
        static let menuBarClickAction = "settings.menuBarClickAction"
        static let colorScheme = "settings.colorScheme"
    }

    @Published var menuBarClickAction: MenuBarClickAction {
        didSet { UserDefaults.standard.set(menuBarClickAction.rawValue, forKey: Key.menuBarClickAction) }
    }
    @Published var colorScheme: AppearancePreference {
        didSet { UserDefaults.standard.set(colorScheme.rawValue, forKey: Key.colorScheme) }
    }

    private init() {
        let defaults = UserDefaults.standard
        menuBarClickAction = MenuBarClickAction(
            rawValue: defaults.string(forKey: Key.menuBarClickAction) ?? ""
        ) ?? .showMenu
        colorScheme = AppearancePreference(
            rawValue: defaults.string(forKey: Key.colorScheme) ?? ""
        ) ?? .system
    }

    /// A two-way binding to any stored preference, so controls can be written as
    /// `$preferences.something` without every screen growing a computed binding
    /// per property.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<SettingsPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, behavior, about

    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .behavior: return "行为"
        case .about: return "关于"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .behavior: return "switch.2"
        case .about: return "info.circle"
        }
    }
}

/// Which tab is showing, held outside the view so the window can be opened
/// *on* a tab — the application menu's "关于" item lands on About — without the
/// view having to be rebuilt from scratch.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The root of the settings window: a floating sidebar of tabs, and a page that
/// renders them.
struct SettingsRootView: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var preferences: SettingsPreferences
    @EnvironmentObject var selection: SettingsTabSelection
    @Environment(\.colorScheme) var scheme

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            SettingsBackdrop()
            HStack(spacing: 0) {
                sidebar
                content
            }
        }
        .preferredColorScheme(preferences.colorScheme.colorScheme)
        .frame(minWidth: 900, minHeight: 620)
        .background(
            KeyboardShortcutsCatcher(
                onTab: { index in
                    let all = SettingsTab.allCases
                    guard all.indices.contains(index) else { return }
                    withAnimation(PW.M.glass) { selection.tab = all[index] }
                },
                onSearch: { searchFocused = true },
                onEscape: {
                    guard !searchText.isEmpty || searchFocused else { return false }
                    searchText = ""
                    searchFocused = false
                    return true
                }
            )
        )
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: PW.S.s2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("隐私窗口")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.16)
                    Text(versionString)
                        .font(PW.T.footnote())
                        .tracking(0.4)
                        .foregroundStyle(PW.C.text3(scheme))
                }
                Spacer()
            }
            .padding(.horizontal, PW.S.s3)
            .padding(.top, PW.S.s3)
            .padding(.bottom, PW.S.s5)

            ForEach(SettingsTab.allCases) { tab in
                sidebarItem(tab)
            }

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PW.C.text2(scheme))
                    .frame(width: 22, height: 22)
                TextField("搜索…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(PW.T.body())
                    .focused($searchFocused)
                KeyCap(text: "⌘K")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .padding(PW.S.s3)
        .frame(width: 216)
        .background(
            ZStack {
                Rectangle().fill(.thinMaterial)
                Rectangle().fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.30))
            }
            .clipShape(RoundedRectangle(cornerRadius: PW.R.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PW.R.card, style: .continuous)
                    .strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PW.R.card, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [PW.C.edgeTop(scheme), .clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.10), radius: 22, y: 10)
        )
        .padding(PW.S.s2)
    }

    private func sidebarItem(_ tab: SettingsTab) -> some View {
        let selected = selection.tab == tab
        return Button {
            withAnimation(PW.M.glass) { selection.tab = tab }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(selected ? PW.C.accent : PW.C.text2(scheme))
                Text(tab.label)
                    .font(PW.T.body())
                    .foregroundStyle(selected ? PW.C.text1(scheme) : PW.C.text2(scheme))
                Spacer()
                KeyCap(text: "⌘\(Self.shortcutNumber(for: tab))")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: PW.R.control).fill(.ultraThinMaterial)
                        // Tinted with the accent rather than washed white: the
                        // selected tab should read as "this app's colour", not
                        // as a generic highlight.
                        RoundedRectangle(cornerRadius: PW.R.control)
                            .fill(PW.C.accent.opacity(scheme == .dark ? 0.22 : 0.13))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: PW.R.control)
                    .strokeBorder(selected ? PW.C.edgeTop(scheme).opacity(0.5) : .clear, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: PW.R.control))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if searchText.isEmpty {
                    currentScreen
                } else {
                    // Search spans every tab, not just the visible one. Each
                    // screen renders only its matching sections, and screens
                    // with no matches contribute nothing.
                    PageHeader("搜索", subtitle: "全部设置中匹配「\(searchText)」的结果。按 ⎋ 清除。")
                    GeneralScreen(search: searchText)
                    AppearanceScreen(search: searchText)
                    BehaviorScreen(search: searchText)
                    AboutScreen(search: searchText)
                }
            }
            .padding(.horizontal, PW.S.s7)
            .padding(.top, PW.S.s6)
            .padding(.bottom, PW.S.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch selection.tab {
        case .general: GeneralScreen()
        case .appearance: AppearanceScreen()
        case .behavior: BehaviorScreen()
        case .about: AboutScreen()
        }
    }

    /// Which ⌘number belongs to a tab, counting from 1 in sidebar order.
    private static func shortcutNumber(for tab: SettingsTab) -> Int {
        (SettingsTab.allCases.firstIndex(of: tab) ?? 0) + 1
    }

    private var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}

// MARK: - Keyboard

/// ⌘1…⌘4 to switch tabs, ⌘K to jump to the search field, ⎋ to clear it.
///
/// A local key-down monitor on a zero-size view, rather than `NSMenuItem`s with
/// key equivalents: this app has no menu bar of its own, and the equivalents
/// have to work whichever control currently has focus.
struct KeyboardShortcutsCatcher: NSViewRepresentable {
    let onTab: (Int) -> Void
    let onSearch: () -> Void
    var onEscape: () -> Bool = { false }

    func makeNSView(context: Context) -> NSView { CatcherView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let catcher = view as? CatcherView else { return }
        catcher.onTab = onTab
        catcher.onSearch = onSearch
        catcher.onEscape = onEscape
    }

    final class CatcherView: NSView {
        var onTab: ((Int) -> Void)?
        var onSearch: (() -> Void)?
        var onEscape: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.keyCode == 53 { return self.onEscape?() == true ? nil : event }
                guard event.modifierFlags.contains(.command),
                      let character = event.charactersIgnoringModifiers else { return event }
                if let number = Int(character), (1...9).contains(number) {
                    self.onTab?(number - 1)
                    return nil
                }
                if character == "k" || character == "K" {
                    self.onSearch?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Window

/// Owns the settings window.
///
/// The window stays at the normal level on purpose. Putting it above the
/// overlay would make it visible without any help, but windows at that level
/// are invisible to macOS's own screenshot tool and behave oddly in Mission
/// Control — instead, `PrivacyController` cuts our own windows out of the blur,
/// which is the same result without moving anything in the system's z-order.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let privacy: PrivacyController
    private let preferences: SettingsPreferences
    private let selection = SettingsTabSelection()
    private var window: NSWindow?
    /// Whether this controller is the one that raised the activation policy,
    /// and so the one that has to put it back.
    ///
    /// The app may already be regular — some launch paths leave it that way —
    /// and dropping a policy we never set would take away a Dock tile that
    /// belongs to someone else.
    private var raisedActivationPolicy = false
    /// The pending "put the policy back" work, so a window closed and
    /// immediately reopened does not get its activation pulled out from under
    /// it by a restore that was scheduled before the reopen.
    private var policyRestoreWork: DispatchWorkItem?
    /// The pending "make it key again" work. See `assertFocus` — bringing a
    /// window up from a status item is a race, not a single call.
    private var focusWork: DispatchWorkItem?
    private var focusAttempt = 0

    init(privacy: PrivacyController, preferences: SettingsPreferences) {
        self.privacy = privacy
        self.preferences = preferences
        super.init()
    }

    /// Opens the window, optionally on a particular tab.
    func open(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let view = SettingsRootView()
                .environmentObject(privacy)
                .environmentObject(preferences)
                .environmentObject(selection)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "隐私窗口设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView, .resizable]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 940, height: 640))
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Kept on release so closing it is hiding it: the window is rebuilt
            // from scratch otherwise, and a SwiftUI host is not cheap to throw
            // away and re-create every time someone peeks at a slider.
            window.isReleasedWhenClosed = false
            // AppKit briefly deactivates us while the status-item menu closes,
            // and a window that hides on deactivation would blink out mid-open.
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // An `LSUIElement` app is an **accessory**: no Dock tile, and — the part
        // that actually bites — no right to own the keyboard. Showing a window
        // from one and calling `activate` brings it up with an inactive title
        // bar and dead text fields: the window is never made key, so keystrokes
        // keep going to whatever app was in front before.
        //
        // The only dependable fix is to be a regular app for as long as the
        // window is open. The cost is a Dock tile and a place in ⌘-Tab while
        // Settings is up; `windowWillClose` takes both back, so the rest of the
        // time this stays a menu-bar utility with no Dock presence at all.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            raisedActivationPolicy = true
        }
        // A close schedules the restore a quarter second out; an open inside
        // that window has to cancel it, or the restore fires with the window
        // back on screen and the keyboard dies mid-session.
        policyRestoreWork?.cancel()
        policyRestoreWork = nil
        focusAttempt = 0
        scheduleFocusWork(delay: 0)
    }

    // MARK: Getting the keyboard

    /// Brings the window up, and keeps at it until it actually holds the
    /// keyboard.
    ///
    /// One `activate` + `makeKeyAndOrderFront` pair is not enough, and both
    /// reasons produce the same symptom: a window on screen with a grey title
    /// bar that swallows every keystroke.
    ///
    /// * The click that got here came from a status item. AppKit re-activates
    ///   whichever app was in front the moment that menu finishes closing,
    ///   which is *after* the action returns. Activating before that is
    ///   activating into a race, and losing it looks exactly like no focus at
    ///   all — the window is up, the keyboard belongs to someone else.
    /// * An app whose activation policy is `.accessory` cannot be key at all.
    ///   Switching to `.regular` is what grants it, and the window server needs
    ///   a turn of the run loop to catch up with the switch.
    ///
    /// So: raise the policy, wait a turn, ask, then check whether the asking
    /// took and ask again if it did not. `isKeyWindow` is the only honest
    /// answer here — `activate` returns nothing.
    ///
    /// Note there is no `orderFrontRegardless()` after `makeKeyAndOrderFront`.
    /// It orders the window up without touching key status, which is precisely
    /// the state that reads as "visible but dead" — and once the app is
    /// activated, its windows come forward at their own level anyway.
    private func assertFocus() {
        guard let window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        // The same ask through the modern API, which goes to the window server
        // directly instead of through AppKit's idea of the active app. It is
        // the one that actually lands on an `LSUIElement` app that has only
        // just been promoted to regular.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        guard !window.isKeyWindow else { focusAttempt = 0; return }
        guard focusAttempt < 2 else { return }
        focusAttempt += 1
        scheduleFocusWork(delay: focusAttempt == 1 ? 0.08 : 0.25)
    }

    private func scheduleFocusWork(delay: TimeInterval) {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.focusWork = nil
            self?.assertFocus()
        }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Lets the next `open()` build a fresh window, which is also what drops the
    /// SwiftUI host if it is ever torn down.
    func windowWillClose(_ notification: Notification) {
        window = nil
        guard raisedActivationPolicy else { return }
        raisedActivationPolicy = false
        // Not in the same tick as the close. Dropping the policy while the
        // window is still on its way out flickers the Dock tile, and can leave
        // the app that was in front before without a focus of its own.
        let restore = DispatchWorkItem { NSApp.setActivationPolicy(.accessory) }
        policyRestoreWork = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: restore)
    }
}
