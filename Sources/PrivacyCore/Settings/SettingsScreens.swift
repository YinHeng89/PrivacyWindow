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
                        iconTint: privacy.hasScreenRecordingPermission ? .neutral : .danger,
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

    private var permissionSubtitle: String {
        privacy.hasScreenRecordingPermission
            ? "已授权。模糊通过截图实现，没有它就没有效果。"
            : "尚未授权。效果看起来是开着的，但不会有任何模糊。"
    }

    @ViewBuilder
    private var permissionTrailing: some View {
        if privacy.hasScreenRecordingPermission {
            HStack(spacing: 6) {
                Circle().fill(PW.C.green).frame(width: 8, height: 8)
                    .shadow(color: PW.C.green.opacity(0.6), radius: 4)
                Text("已授权").font(PW.T.mono()).foregroundStyle(PW.C.text2(scheme))
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
    @Environment(\.colorScheme) var scheme
    var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.isEmpty {
                PageHeader("外观", subtitle: "模糊的强度，以及鼠标周围那块清晰区域。")
            }

            if match("模糊 强度 radius 半径 blur strength") {
                SectionLabel(text: "模糊")
                GlassPanel {
                    SettingsRow(
                        icon: "drop",
                        title: "模糊半径",
                        subtitle: "越大越糊，也越费一帧的算力。",
                        isFirst: true,
                        trailing: {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(privacy.currentBlurRadius.rounded())) pt")
                                    .font(PW.T.mono())
                                    .foregroundStyle(PW.C.text1(scheme))
                                Text(strengthName)
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
                                    accessibilityLabel: "鼠标清晰范围"
                                )
                                .padding(.top, 6)
                            }
                        )
                    }
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
                                Text(row.detail)
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

    private func match(_ keywords: String) -> Bool { settingsSearchMatch(keywords, search: search) }
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
                        Text("隐私窗口")
                            .font(.system(size: 22, weight: .semibold))
                        Text("只有当前窗口是清晰的")
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
                            Text(privacy.hasScreenRecordingPermission ? "已授权" : "未授权")
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
        return "版本 \(short)（\(build)）"
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
