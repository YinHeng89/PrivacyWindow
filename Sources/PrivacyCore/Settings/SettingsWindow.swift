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

/// The root of the settings window: a floating sidebar of tabs, and a page that
/// renders them.
struct SettingsRootView: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var preferences: SettingsPreferences
    @Environment(\.colorScheme) var scheme

    @State private var selectedTab: SettingsTab = .general
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

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
                    withAnimation(PW.M.glass) { selectedTab = all[index] }
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
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.12))
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
            .shadow(color: .black.opacity(scheme == .dark ? 0.40 : 0.14), radius: 22, y: 10)
        )
        .padding(PW.S.s2)
    }

    private func sidebarItem(_ tab: SettingsTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            withAnimation(PW.M.glass) { selectedTab = tab }
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
                        RoundedRectangle(cornerRadius: PW.R.control)
                            .fill(Color.white.opacity(scheme == .dark ? 0.08 : 0.40))
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
        switch selectedTab {
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
    private var window: NSWindow?

    init(privacy: PrivacyController, preferences: SettingsPreferences) {
        self.privacy = privacy
        self.preferences = preferences
        super.init()
    }

    func open() {
        if window == nil {
            let view = SettingsRootView()
                .environmentObject(privacy)
                .environmentObject(preferences)
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
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Lets the next `open()` build a fresh window, which is also what drops the
    /// SwiftUI host if it is ever torn down.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
