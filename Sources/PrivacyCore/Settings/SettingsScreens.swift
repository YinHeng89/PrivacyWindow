import AppKit
import SwiftUI

/// Every screen takes the search string and renders **only** the sections that
/// match it. That is what lets the root view concatenate all of them while
/// searching: a screen with no matches contributes nothing, and the results
/// read as one page instead of as five.
///
/// Screens read the controller straight out of the environment. There is no
/// second copy of the settings: writing a value here is the same call the menu
/// makes, which is why the two can never disagree.

// MARK: - General

struct GeneralScreen: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var preferences: SettingsPreferences
    @EnvironmentObject var i18n: I18n
    @Environment(\.colorScheme) var scheme
    var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.isEmpty {
                PageHeader("通用", subtitle: "效果的开关，以及菜单栏图标的行为。")
            }

            if match("权限 屏幕录制 permission screen recording 授权") {
                SectionLabel(text: "权限")
                GlassPanel {
                    SettingsRow(
                        icon: "hand.raised",
                        iconTint: permissionTint,
                        title: "屏幕录制",
                        subtitle: permissionSubtitle,
                        isFirst: true,
                        trailing: { permissionTrailing }
                    )
                }
            }

            if match("效果 启用 停用 开关 enable disable blur") {
                SectionLabel(text: "效果")
                GlassPanel {
                    SettingsRow(
                        icon: "eye.slash",
                        title: "启用隐私模糊",
                        subtitle: "除当前焦点窗口与系统界面之外，屏幕上的其余部分全部模糊。",
                        isFirst: true,
                        trailing: { GlassSwitch(isOn: enabled) }
                    )
                }
            }

            if match("菜单栏 图标 点击 menu bar icon click") {
                SectionLabel(text: "菜单栏")
                GlassPanel {
                    SettingsRow(
                        icon: "menubar.rectangle",
                        title: "左键点击图标",
                        subtitle: "右键任何时候都打开菜单。",
                        isFirst: true,
                        trailing: {
                            GlassPicker(
                                selection: preferences.binding(\.menuBarClickAction),
                                items: MenuBarClickAction.allCases,
                                label: { $0.label }
                            )
                        }
                    )
                }
            }

            if match("登录 开机 自启 启动 后台 login startup boot launch 自动") {
                SectionLabel(text: "登录项")
                GlassPanel {
                    SettingsRow(
                        icon: "power",
                        title: "登录时启动",
                        subtitle: "登录 macOS 后自动在后台运行，隐私保护不中断。",
                        isFirst: true,
                        trailing: { GlassSwitch(isOn: preferences.binding(\.launchAtLogin)) },
                        below: {
                            if !LoginItem.canRegister {
                                Callout(
                                    title: "未从应用包运行",
                                    message: "当前不是从打包的 .app 启动，自启设置会在你从「应用程序」打开后自动生效。",
                                    systemImage: "exclamationmark.triangle",
                                    tint: PW.C.orange
                                )
                                .padding(.top, 6)
                            }
                        }
                    )
                }
            }

        }
    }

    /// Every route that flips the effect — menu, this switch — has to remember
    /// the choice too, or quitting while on would come back off.
    private var enabled: Binding<Bool> {
        Binding(
            get: { privacy.isEnabled },
            set: { on in
                if on { privacy.enable() } else { privacy.disable() }
                privacy.persistEnabled()
            }
        )
    }

    private var permissionTint: IconTile.Tint {
        if privacy.hasScreenRecordingPermission { return .neutral }
        // Missing permission is only a failure when there is no fallback
        // carrying the effect; on the vibrancy backend it is a downgrade, not
        // an outage.
        return privacy.runsOnVibrancyFallback ? .accent : .danger
    }

    private var permissionSubtitle: String {
        if privacy.hasScreenRecordingPermission {
            return "已授权。模糊由截图计算，强度精确可调。"
        }
        if privacy.runsOnVibrancyFallback {
            return "未授权，正在以「系统模糊」降级模式运行：效果可用，但强度只能近似。授权后 1 秒内自动切换回精确模糊。"
        }
        return "尚未授权。开启效果时会先以系统模糊运行，并向你请求授权。"
    }

    @ViewBuilder
    private var permissionTrailing: some View {
        if privacy.hasScreenRecordingPermission {
            HStack(spacing: 6) {
                Circle().fill(PW.C.green).frame(width: 8, height: 8)
                    .shadow(color: PW.C.green.opacity(0.6), radius: 4)
                Text(i18n.t("已授权")).font(PW.T.mono()).foregroundStyle(PW.C.text2(scheme))
            }
        } else {
            PrimaryButton(title: "打开系统设置", icon: "arrow.up.right") { openPrivacySettings() }
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func match(_ keywords: String) -> Bool { settingsSearchMatch(keywords, search: search) }
}

// MARK: - Appearance

struct AppearanceScreen: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var preferences: SettingsPreferences
    @Environment(\.colorScheme) var scheme
    var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.isEmpty {
                PageHeader("外观", subtitle: "模糊的强度、鼠标周围那块清晰区域，以及设置窗口的配色与语言。")
            }

            if match("模糊 强度 radius 半径 blur strength") {
                SectionLabel(text: "模糊")
                GlassPanel {
                    if privacy.runsOnVibrancyFallback {
                        // The slider still works in this mode — it picks the
                        // nearest of the system's materials — but pretending it
                        // means the same thing it means on captured pixels
                        // would be a lie about what the user is getting.
                        SettingsRow(
                            icon: "cpu",
                            title: "降级模式",
                            subtitle: "未授权屏幕录制，模糊由系统合成，强度只能近似。授权后自动恢复精确半径。",
                            isFirst: true
                        )
                    }
                    SettingsRow(
                        icon: "aperture",
                        title: "模糊",
                        subtitle: "关闭后不再做高斯模糊；颜色覆盖仍可单独生效。",
                        isFirst: !privacy.runsOnVibrancyFallback,
                        trailing: { GlassSwitch(isOn: blurEnabled) }
                    )
                    SettingsRow(
                        icon: "drop",
                        title: "模糊半径",
                        subtitle: privacy.runsOnVibrancyFallback
                            ? "当前按系统材质分档近似，无法逐点控制。"
                            : "越大越糊，也越费一帧的算力。",
                        isFirst: false,
                        trailing: {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(privacy.currentBlurRadius.rounded())) pt")
                                    .font(PW.T.mono())
                                    .foregroundStyle(PW.C.text1(scheme))
                                Text(I18n.shared.t(strengthName))
                                    .font(PW.T.footnote())
                                    .foregroundStyle(PW.C.text3(scheme))
                            }
                        },
                        below: {
                            GlassSlider(
                                value: blurRadius,
                                range: PrivacyController.smallestBlurRadius...PrivacyController.largestBlurRadius,
                                step: 1,
                                accessibilityLabel: "模糊半径"
                            )
                            .padding(.top, 6)
                            .opacity(blurEnabled.wrappedValue ? 1 : 0.4)
                            .allowsHitTesting(blurEnabled.wrappedValue)
                        }
                    )
                }
            }

            if match("模糊 颜色 调色 tint 背景色 背景 颜色 color background 着色 色温") {
                SectionLabel(text: "模糊颜色")
                GlassPanel {
                    SettingsRow(
                        icon: "paintpalette",
                        title: "模糊颜色",
                        subtitle: "给模糊背景叠加一层颜色。强度为 0 时保持原样（默认白色）。",
                        isFirst: true,
                        trailing: {
                            ColorPicker("", selection: blurTintColor)
                                .labelsHidden()
                                .frame(width: 44, height: 22)
                        }
                    )
                    SettingsRow(
                        icon: "slider.horizontal.3",
                        title: "颜色强度",
                        subtitle: "颜色覆盖背景的比例：0 为关闭，1 为纯色填充。",
                        trailing: {
                            Text("\(Int((blurTintAmount.wrappedValue * 100).rounded()))%")
                                .font(PW.T.mono())
                                .foregroundStyle(PW.C.text1(scheme))
                        },
                        below: {
                            GlassSlider(
                                value: blurTintAmount,
                                range: 0...1,
                                step: 0.05,
                                accessibilityLabel: "模糊颜色强度"
                            )
                            .padding(.top, 6)
                        }
                    )
                }
            }

            if match("鼠标 光标 圆盘 清晰 cursor halo reveal 指针") {
                SectionLabel(text: "鼠标周围")
                GlassPanel {
                    SettingsRow(
                        icon: "cursorarrow",
                        title: "鼠标周围保持清晰",
                        subtitle: "在模糊背景上以指针为圆心留一块清晰的圆盘。",
                        isFirst: true,
                        trailing: { GlassSwitch(isOn: revealCursor) }
                    )
                    if privacy.revealsCursor {
                        SettingsRow(
                            icon: "circle.dashed",
                            title: "清晰范围",
                            subtitle: "圆盘的半径。",
                            trailing: {
                                Text("\(Int(privacy.currentCursorRevealRadius.rounded())) pt")
                                    .font(PW.T.mono())
                                    .foregroundStyle(PW.C.text1(scheme))
                            },
                            below: {
                                GlassSlider(
                                    value: cursorRadius,
                                    range: 20...400,
                                    step: 10,
                                    accessibilityLabel: I18n.shared.t("鼠标清晰范围")
                                )
                                .padding(.top, 6)
                            }
                        )
                    }
                }
            }

            if match("外观 配色 浅色 深色 主题 appearance theme dark light") {
                SectionLabel(text: "外观")
                GlassPanel {
                    SettingsRow(
                        icon: "sun.max",
                        title: "设置窗口配色",
                        subtitle: "仅影响这个窗口，不影响模糊效果。",
                        isFirst: true,
                        trailing: {
                            GlassPicker(
                                selection: preferences.binding(\.colorScheme),
                                items: AppearancePreference.allCases,
                                label: { $0.label }
                            )
                        }
                    )
                }
            }

            if match("语言 language 界面 显示 英文 中文 切换") {
                SectionLabel(text: "语言")
                GlassPanel {
                    SettingsRow(
                        icon: "globe",
                        title: "语言",
                        subtitle: "设置界面与菜单显示的语言。",
                        isFirst: true,
                        trailing: {
                            GlassPicker(
                                selection: Binding(
                                    get: { I18n.shared.language },
                                    set: { I18n.shared.language = $0 }
                                ),
                                items: AppLanguage.allCases,
                                label: { $0.label }
                            )
                        }
                    )
                }
            }
        }
    }

    /// A name next to a number: "40" tells nobody anything about how it looks.
    private var strengthName: String {
        switch privacy.currentBlurRadius {
        case ..<14: return "轻度"
        case ..<26: return "中度"
        case ..<40: return "强度"
        default: return "极强"
        }
    }

    private var blurRadius: Binding<Double> {
        Binding(get: { privacy.currentBlurRadius }, set: { privacy.setBlurRadius($0) })
    }
    private var blurEnabled: Binding<Bool> {
        Binding(get: { privacy.currentBlurEnabled }, set: { privacy.setBlurEnabled($0) })
    }
    private var blurTintColor: Binding<Color> {
        Binding(
            get: { Color(privacy.currentBlurTintColor) },
            set: { privacy.setBlurTintColor(NSColor($0)) }
        )
    }
    private var blurTintAmount: Binding<Double> {
        Binding(get: { privacy.currentBlurTintAmount }, set: { privacy.setBlurTintAmount($0) })
    }
    private var cursorRadius: Binding<Double> {
        Binding(get: { privacy.currentCursorRevealRadius }, set: { privacy.setCursorRevealRadius($0) })
    }
    private var revealCursor: Binding<Bool> {
        Binding(get: { privacy.revealsCursor }, set: { privacy.setRevealCursor($0) })
    }

    private func match(_ keywords: String) -> Bool { settingsSearchMatch(keywords, search: search) }
}

// MARK: - Behavior

struct BehaviorScreen: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var i18n: I18n
    @Environment(\.colorScheme) var scheme
    var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.isEmpty {
                PageHeader("行为", subtitle: "什么时候让位，以及让位给谁。")
            }

            if match("全屏 停止 暂停 full screen pause 视频") {
                SectionLabel(text: "全屏")
                GlassPanel {
                    SettingsRow(
                        icon: "rectangle.inset.filled",
                        title: "全屏时停止模糊",
                        subtitle: "窗口铺满整块屏幕时，屏幕上已经没有需要藏起来的东西 —— 既省电，也不会挡住全屏视频。",
                        isFirst: true,
                        trailing: { GlassSwitch(isOn: pauseFullScreen) }
                    )
                }
            }

            if match("菜单栏 dock 清晰 系统 ui chrome menu bar 保留") {
                SectionLabel(text: "系统界面")
                GlassPanel {
                    SettingsRow(
                        icon: "dock.rectangle",
                        title: "菜单栏与 Dock 保持清晰",
                        subtitle: "默认开启。覆盖层会降到系统界面之下 —— 代价是层级比菜单栏更高的东西（弹出菜单、通知、输入法候选栏）也一并糊不上。",
                        isFirst: true,
                        trailing: { GlassSwitch(isOn: keepChrome) }
                    )
                }
            }

            if match("排除 应用 排除应用 信任 白名单 前台 暂停 exclude app") {
                SectionLabel(text: "排除应用")
                if !privacy.excludedApps.isEmpty {
                    Callout(
                        title: "这些应用的窗口始终清晰",
                        message: "不管焦点在哪，它们的窗口都不会被模糊。切换到别的应用时，两边都是清晰的 —— 只有其余区域保持模糊。唯一例外是本应用的设置窗口在最前时：那时只有设置窗口和这些窗口是清晰的。",
                        systemImage: "eye"
                    )
                    // Breathes between the notice and the list below it. Without
                    // it the two read as one block and the notice looks like it
                    // is printed on top of the first row.
                    .padding(.bottom, PW.S.s4)
                }
                GlassPanel {
                    VStack(spacing: 0) {
                        if privacy.excludedApps.isEmpty {
                            SettingsRow(
                                icon: "tray",
                                iconTint: .neutral,
                                title: "还没有排除任何应用",
                                subtitle: "加入排除列表的应用，它的窗口始终保持清晰 —— 不管它是不是当前焦点。焦点窗口照常清晰，其余区域照常模糊。",
                                isFirst: true
                            )
                        } else {
                            ForEach(Array(displayedExcluded.enumerated()), id: \.element.bundleID) { index, app in
                                ExcludedAppRow(app: app, isFirst: index == 0) {
                                    privacy.removeExcludedApp(bundleID: app.bundleID)
                                }
                            }
                        }
                        ExcludedAppAddRow()
                    }
                }
            }

            if search.isEmpty {
                SectionLabel(text: "省电")
                GlassPanel {
                    ForEach(Array(PowerRows.all.enumerated()), id: \.offset) { index, row in
                        SettingsRow(
                            icon: row.icon,
                            iconTint: .neutral,
                            title: row.title,
                            subtitle: row.subtitle,
                            isFirst: index == 0,
                            trailing: {
                                Text(I18n.shared.t(row.detail))
                                    .font(PW.T.mono())
                                    .foregroundStyle(PW.C.text2(scheme))
                            }
                        )
                    }
                }
            }
        }
    }

    private var pauseFullScreen: Binding<Bool> {
        Binding(get: { privacy.pausesForFullScreenApps }, set: { privacy.setPauseForFullScreenApps($0) })
    }
    private var keepChrome: Binding<Bool> {
        Binding(get: { privacy.keepsChromeClear }, set: { privacy.setKeepChrome($0) })
    }

    /// Excluded apps as display rows, named and ordered by their app name
    /// rather than by the raw identifier the list is stored with.
    private var displayedExcluded: [ExcludedAppRow.App] {
        privacy.excludedApps.bundleIDs
            .map { ExcludedAppRow.App(bundleID: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func match(_ keywords: String) -> Bool { settingsSearchMatch(keywords, search: search) }
}

/// One excluded app: resolved to a name and a real icon where possible, with
/// the raw bundle identifier kept visible underneath — it is the identifier
/// that has to be unambiguous, not the name.
private struct ExcludedAppRow: View {
    struct App: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }

        /// Name and artwork, resolved once per identifier and then remembered.
        ///
        /// Both come from Launch Services, which goes to disk. Asking in
        /// `body` meant every re-render — including every keystroke in the
        /// search field, which re-renders all four pages — queried the disk
        /// about every excluded app again, on the main thread.
        ///
        /// Unsafe-by-declaration rather than isolated: this is a cache of
        /// immutable lookup results read and written only from the main thread,
        /// and `NSImage` is not `Sendable`, so the actor-safe spellings do not
        /// apply without a copy that would defeat the point.
        nonisolated(unsafe) private static var cache: [String: (name: String, icon: NSImage?)] = [:]

        init(bundleID: String) {
            self.bundleID = bundleID
            if let hit = Self.cache[bundleID] {
                self.name = hit.name
                self.icon = hit.icon
                return
            }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            Self.cache[bundleID] = (name, icon)
            self.name = name
            self.icon = icon
        }
    }

    let app: App
    let isFirst: Bool
    let onRemove: () -> Void
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 56)
                    Rectangle().fill(PW.C.hairline(scheme)).frame(height: 0.5)
                }
            }
            HStack(alignment: .center, spacing: PW.S.s3) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(PW.C.text2(scheme))
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(PW.T.title())
                        .foregroundStyle(PW.C.text1(scheme))
                    Text(app.bundleID)
                        .font(PW.T.footnote())
                        .foregroundStyle(PW.C.text3(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: PW.S.s3)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(PW.C.red.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("移出排除列表")
            }
            .padding(.horizontal, PW.S.s4)
            .padding(.vertical, PW.S.s3)
        }
    }
}

/// The "add an app" row: a menu of everything running, so the list can be
/// built without typing bundle identifiers.
private struct ExcludedAppAddRow: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var i18n: I18n
    @Environment(\.colorScheme) var scheme

    /// Running apps with a Dock presence, minus this one. Menu-bar-only agents
    /// are left out on purpose: an app without windows in front is not a state
    /// the exclusion rule can observe.
    @State private var candidates: [NSRunningApplication] = []

    private static func runningCandidates() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
    }

    var body: some View {
        HStack(spacing: PW.S.s3) {
            IconTile(systemName: "plus", tint: .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(I18n.shared.t("添加应用"))
                    .font(PW.T.title())
                    .foregroundStyle(PW.C.text1(scheme))
                Text(I18n.shared.t(candidates.isEmpty ? "没有正在运行的常规应用可添加。" : "从正在运行的应用中选择。"))
                    .font(PW.T.bodyRegular())
                    .foregroundStyle(PW.C.text2(scheme))
            }
            Spacer(minLength: PW.S.s3)
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates, id: \.processIdentifier) { app in
                        Button {
                            if let id = app.bundleIdentifier { privacy.addExcludedApp(bundleID: id) }
                        } label: {
                            HStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                }
                                Text(app.localizedName ?? app.bundleIdentifier ?? I18n.shared.t("未知应用"))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text(i18n.t("添加"))
                    }
                    .font(PW.T.body())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(PW.C.control(scheme))
                    )
                    .overlay(Capsule().strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
            }
        }
        .padding(.horizontal, PW.S.s4)
        .padding(.vertical, PW.S.s3)
        .frame(minHeight: 52)
        // Filled when the row appears rather than on every evaluation of
        // `body`. An app launched since then is missing from the menu until the
        // page is shown again, which is a smaller fault than an IPC round trip
        // on every keystroke typed into the search field.
        .task { candidates = Self.runningCandidates() }
        .overlay(alignment: .top) {
            Rectangle().fill(PW.C.hairline(scheme)).frame(height: 0.5)
        }
    }
}

/// The throttles, stated rather than left to be discovered. Numbers, because
/// "automatically reduces work" is what every app claims and none of them prove.
private struct PowerRows {
    struct Row {
        let icon: String
        let title: String
        let subtitle: String
        let detail: String
    }
    static let all: [Row] = [
        Row(icon: "hare", title: "有窗口在动", subtitle: "截图与窗口查询全速运行，跟手优先。", detail: "~8ms"),
        Row(icon: "tortoise", title: "桌面静止约 0.75 秒", subtitle: "截图降到 ~30fps，窗口查询降到一半。", detail: "~33ms"),
        Row(icon: "moon.zzz", title: "长时间完全静止（约 15 秒）", subtitle: "截图降到 ~4fps；鼠标不动时也不重建掩膜。", detail: "~250ms"),
        Row(icon: "display", title: "没有洞的副屏", subtitle: "整屏模糊，看不出帧率差别。", detail: "~15fps"),
        Row(icon: "pause", title: "没有可聚焦的窗口", subtitle: "覆盖层清空，截图循环完全停止。", detail: "停止"),
    ]
}

// MARK: - About

struct AboutScreen: View {
    @EnvironmentObject var privacy: PrivacyController
    @EnvironmentObject var i18n: I18n
    @Environment(\.colorScheme) var scheme
    var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.isEmpty {
                PageHeader("关于", subtitle: "版本、实现方式与权限。")
            }

            if match("版本 version 关于 about 图标") {
                GlassPanel {
                    VStack(spacing: PW.S.s4) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 112, height: 112)
                            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                        Text(I18n.shared.t("隐私窗口"))
                            .font(.system(size: 22, weight: .semibold))
                        Text(I18n.shared.t("只有当前窗口是清晰的"))
                            .font(PW.T.bodyRegular())
                            .foregroundStyle(PW.C.text2(scheme))
                        HStack(spacing: 6) {
                            Circle()
                                .fill(privacy.isEnabled ? PW.C.green : PW.C.text3(scheme))
                                .frame(width: 8, height: 8)
                                .shadow(color: PW.C.green.opacity(privacy.isEnabled ? 0.6 : 0), radius: 4)
                            Text(versionText)
                                .font(PW.T.mono())
                                .foregroundStyle(PW.C.text2(scheme))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(PW.C.control(scheme)))
                        .overlay(Capsule().strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PW.S.s7)
                }
                .padding(.top, PW.S.s6)
            }

            if match("实现 原理 技术 screencapturekit 截图 模糊 how it works") {
                SectionLabel(text: "实现方式")
                GlassPanel {
                    ForEach(Array(Implementation.rows.enumerated()), id: \.offset) { index, row in
                        SettingsRow(
                            icon: row.icon,
                            iconTint: .neutral,
                            title: row.title,
                            subtitle: row.subtitle,
                            isFirst: index == 0
                        )
                    }
                }
            }

            if match("权限 屏幕录制 辅助功能 privacy permission") {
                SectionLabel(text: "权限")
                GlassPanel {
                    SettingsRow(
                        icon: "hand.raised",
                        title: "屏幕录制",
                        subtitle: "模糊由截图得来，这是唯一需要的权限 —— 没有读取输入、没有辅助功能权限。",
                        isFirst: true,
                        trailing: {
                            Text(i18n.t(privacy.hasScreenRecordingPermission ? "已授权" : "未授权"))
                                .font(PW.T.mono())
                                .foregroundStyle(privacy.hasScreenRecordingPermission ? PW.C.green : PW.C.orange)
                        }
                    )
                }
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "—"
        let build = (info["CFBundleVersion"] as? String) ?? "—"
        return I18n.shared.t("版本 %@（%@）", short, build)
    }

    private func match(_ keywords: String) -> Bool { settingsSearchMatch(keywords, search: search) }
}

/// What the app actually does, in the order it does it. Worth stating here: a
/// tool that covers your screen with a blur has to be able to explain itself in
/// four lines.
private enum Implementation {
    struct Row {
        let icon: String
        let title: String
        let subtitle: String
    }
    static let rows: [Row] = [
        Row(icon: "macwindow", title: "找焦点窗口", subtitle: "每帧向窗口服务器查询一次当前该看的那个窗口，按层级与所属 app 挑选。"),
        Row(icon: "camera.viewfinder", title: "截图并降采样", subtitle: "ScreenCaptureKit 按窗口 ID 排除焦点窗口，最多降到原像素的 1/4。"),
        Row(icon: "circle.and.line.horizontal", title: "高斯模糊 + 补色", subtitle: "模糊后把洞口补上，避免桌面的亮色从边缘渗出去。"),
        Row(icon: "square.on.circle", title: "挖洞并提交", subtitle: "图片与掩膜在同一个事务里提交，所以洞永远和背景是同一帧。"),
    ]
}
