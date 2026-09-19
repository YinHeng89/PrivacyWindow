import AppKit
import Combine
import Foundation
import SwiftUI

/// The languages the app can run in.
///
/// `system` follows macOS's preferred languages and is the default: a fresh
/// launch on a Chinese Mac shows Chinese, on an English Mac English. `zhHans`
/// is the source language: its strings *are* the localization keys, so the
/// table lookup for it is the identity and a missing English translation can
/// never leave a Chinese user seeing a key. `en` overrides keys it knows and
/// falls back to the (Chinese) key otherwise.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    var id: String { rawValue }

    /// The name shown in the picker. The two concrete language names are fixed
    /// and never translated — you pick a language by reading its own name — but
    /// 「跟随系统」 is a mode, not a language, so it does translate.
    var label: String {
        switch self {
        case .system: return I18n.shared.t("跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

/// The live localization store.
///
/// Not `@MainActor`: the strings it hands out are read on the main actor (SwiftUI
/// bodies, AppKit menu builds, alert construction) but also from the occasional
/// background tick, and `UserDefaults`/`NotificationCenter` are safe off-actor.
/// The only writer is the UI, which is on the main actor, so the published
/// `language` never changes off the main thread.
final class I18n: ObservableObject {
    /// Posted on the main thread after `language` changes, so AppKit surfaces
    /// built once (the main menu, the settings window title) can rebuild. SwiftUI
    /// views re-render through `ObservableObject` observation on their own.
    static let languageDidChange = Notification.Name("I18n.languageDidChange")

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
        }
    }

    static let shared = I18n()

    private static let defaultsKey = "app.language"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        language = AppLanguage(rawValue: raw ?? "") ?? .system
        // While 「跟随系统」 is selected, a change to the system's preferred
        // languages has to reach every surface the same way a manual switch
        // does: repost the change notification so AppKit menus rebuild and the
        // SwiftUI views re-read `t(...)`.
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.language == .system else { return }
            NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
        }
    }

    /// The language actually used for lookups: the explicit choice, or — for
    /// `.system` — the first of the user's preferred languages the app speaks.
    /// `Locale.preferredLanguages` is ordered by the user's own ranking, so the
    /// first match is the honest answer.
    var resolved: AppLanguage {
        switch language {
        case .zhHans, .en:
            return language
        case .system:
            for preferred in Locale.preferredLanguages {
                if preferred.hasPrefix("zh") { return .zhHans }
                if preferred.hasPrefix("en") { return .en }
            }
            return .zhHans
        }
    }

    /// The localized form of `key`.
    ///
    /// For `zhHans` the key *is* the string. For `en` the override table is
    /// consulted and a missing entry falls back to the key, so Chinese is always
    /// correct and an untranslated phrase degrades to Chinese rather than to a
    /// placeholder.
    func t(_ key: String) -> String {
        switch resolved {
        case .zhHans, .system: return key
        case .en: return Self.en[key] ?? key
        }
    }

    /// The localized form of `key`, with `%@`/`%d` tokens filled from `args`.
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    // MARK: - English overrides

    /// Keys are the Chinese source strings. Values are the English translation.
    private static let en: [String: String] = [
        // --- SettingsWindow: enums ---
        "显示菜单": "Show Menu",
        "开关模糊": "Toggle Blur",
        "打开设置": "Open Settings",
        "跟随系统": "Follow System",
        "浅色": "Light",
        "深色": "Dark",
        "通用": "General",
        "外观": "Appearance",
        "行为": "Behavior",
        "关于": "About",

        // --- SettingsWindow: chrome ---
        "隐私窗口": "Privacy Window",
        "隐私窗口设置": "Privacy Window Settings",
        "搜索…": "Search…",
        "全部设置中匹配「%@」的结果。按 ⎋ 清除。":
            "Results across all settings matching “%@”. Press ⎋ to clear.",

        // --- General ---
        "效果的开关，以及菜单栏图标的行为。":
            "Turn the effect on or off, and how the menu-bar icon behaves.",
        "权限": "Permission",
        "屏幕录制": "Screen Recording",
        "效果": "Effect",
        "启用隐私模糊": "Enable Privacy Blur",
        "除当前焦点窗口与系统界面之外，屏幕上的其余部分全部模糊。":
            "Everything on screen except the current focus window and system UI is blurred.",
        "菜单栏": "Menu Bar",
        "左键点击图标": "Left-Click the Icon",
        "右键任何时候都打开菜单。": "Right-click always opens the menu.",
        "登录项": "Login Item",
        "登录时启动": "Launch at Login",
        "登录 macOS 后自动在后台运行，隐私保护不中断。":
            "Starts automatically in the background after you log in, so privacy protection is never interrupted.",
        "未从应用包运行": "Not Running from an App Bundle",
        "当前不是从打包的 .app 启动，自启设置会在你从「应用程序」打开后自动生效。":
            "This build is not a packaged .app, so the setting takes effect once you open the app from Applications.",
        "设置窗口配色": "Settings Window Theme",
        "仅影响这个窗口，不影响模糊效果。":
            "Affects only this window, not the blur effect.",
        "已授权。模糊由截图计算，强度精确可调。":
            "Granted. Blur is computed from captures, with precise strength control.",
        "未授权，正在以「系统模糊」降级模式运行：效果可用，但强度只能近似。授权后 1 秒内自动切换回精确模糊。":
            "Not granted. Running in the “System Blur” fallback: the effect works, but strength is only approximate. Switches back to precise blur within 1 second of granting.",
        "尚未授权。开启效果时会先以系统模糊运行，并向你请求授权。":
            "Not granted yet. Enabling the effect runs System Blur first and asks you for permission.",
        "已授权": "Granted",
        "打开系统设置": "Open System Settings",

        // --- Language ---
        "语言": "Language",
        "设置界面与菜单显示的语言。": "The language of the interface and menus.",

        // --- Appearance ---
        "模糊的强度、鼠标周围那块清晰区域，以及设置窗口的配色与语言。":
            "Blur strength, the clear area around the cursor, and the settings window's theme and language.",
        "模糊": "Blur",
        "降级模式": "Fallback Mode",
        "未授权屏幕录制，模糊由系统合成，强度只能近似。授权后自动恢复精确半径。":
            "Screen Recording is not granted, so blur is composited by the system and only approximate. The precise radius returns once granted.",
        "模糊半径": "Blur Radius",
        "当前按系统材质分档近似，无法逐点控制。":
            "Currently approximated by system materials; no per-point control.",
        "越大越糊，也越费一帧的算力。":
            "Higher is blurrier and costs more per frame.",
        "鼠标周围": "Around Cursor",
        "鼠标周围保持清晰": "Keep Clear Around Cursor",
        "在模糊背景上以指针为圆心留一块清晰的圆盘。":
            "On the blurred background, leave a clear disc centered on the pointer.",
        "清晰范围": "Reveal Radius",
        "圆盘的半径。": "The radius of the disc.",
        "鼠标清晰范围": "Cursor Reveal Radius",
        "轻度": "Light",
        "中度": "Medium",
        "强度": "Strong",
        "极强": "Extreme",

        // --- Appearance: blur color (added with the tint feature) ---
        "模糊颜色": "Blur Color",
        "给模糊背景叠加一层颜色。强度为 0 时保持原样（默认白色）。":
            "Lays a color over the blurred background. At zero strength it stays unchanged (white by default).",
        "颜色强度": "Color Strength",
        "颜色覆盖背景的比例：0 为关闭，1 为纯色填充。":
            "How much of the background the color covers: 0 is off, 1 is a solid fill.",
        "关闭后不再做高斯模糊；颜色覆盖仍可单独生效。":
            "When off, no Gaussian blur is applied; the color overlay still works on its own.",
        "模糊颜色强度": "Blur Color Strength",

        // --- Behavior ---
        "什么时候让位，以及让位给谁。": "When to stand down, and to whom.",
        "全屏": "Full Screen",
        "全屏时停止模糊": "Pause Blur in Full Screen",
        "窗口铺满整块屏幕时，屏幕上已经没有需要藏起来的东西 —— 既省电，也不会挡住全屏视频。":
            "When a window fills the whole screen there is nothing left to hide — it also saves power and won't block full-screen video.",
        "系统界面": "System UI",
        "菜单栏与 Dock 保持清晰": "Keep Menu Bar & Dock Clear",
        "默认开启。覆盖层会降到系统界面之下 —— 代价是层级比菜单栏更高的东西（弹出菜单、通知、输入法候选栏）也一并糊不上。":
            "On by default. The overlay drops below system UI — at the cost of anything above the menu bar (pop-up menus, notifications, the input-method candidate bar) also staying sharp.",
        "排除应用": "Excluded Apps",
        "这些应用的窗口始终清晰": "These apps' windows stay clear",
        "不管焦点在哪，它们的窗口都不会被模糊。切换到别的应用时，两边都是清晰的 —— 只有其余区域保持模糊。唯一例外是本应用的设置窗口在最前时：那时只有设置窗口和这些窗口是清晰的。":
            "No matter where the focus is, their windows are never blurred. When you switch to another app, both stay clear — only the rest is blurred. The one exception is when this app's settings window is in front: then only the settings window and these windows are clear.",
        "还没有排除任何应用": "No apps excluded yet",
        "加入排除列表的应用，它的窗口始终保持清晰 —— 不管它是不是当前焦点。焦点窗口照常清晰，其余区域照常模糊。":
            "An app added to the exclusion list keeps its windows clear at all times — whether or not it has focus. The focus window stays clear as usual; everything else blurs as usual.",
        "省电": "Power Saving",
        "停止": "Stop",
        "有窗口在动": "A window is moving",
        "截图与窗口查询全速运行，跟手优先。":
            "Captures and window queries run at full speed; responsiveness first.",
        "桌面静止约 0.75 秒": "Desktop idle ~0.75s",
        "截图降到 ~30fps，窗口查询降到一半。":
            "Captures drop to ~30fps, window queries to half.",
        "长时间完全静止（约 15 秒）": "Fully idle for a long time (~15s)",
        "截图降到 ~4fps；鼠标不动时也不重建掩膜。":
            "Captures drop to ~4fps; the mask is not rebuilt while the cursor is still.",
        "没有洞的副屏": "A side screen with no hole",
        "整屏模糊，看不出帧率差别。":
            "The whole screen is blurred; no visible frame-rate difference.",
        "没有可聚焦的窗口": "No focusable window",
        "覆盖层清空，截图循环完全停止。":
            "The overlay clears and the capture loop stops entirely.",

        // --- About ---
        "版本、实现方式与权限。": "Version, how it works, and permissions.",
        "只有当前窗口是清晰的": "Only the current window is clear",
        "实现方式": "How It Works",
        "找焦点窗口": "Find the focus window",
        "每帧向窗口服务器查询一次当前该看的那个窗口，按层级与所属 app 挑选。":
            "Each frame, ask the window server for the window to watch, chosen by layer and owning app.",
        "截图并降采样": "Capture & downsample",
        "ScreenCaptureKit 按窗口 ID 排除焦点窗口，最多降到原像素的 1/4。":
            "ScreenCaptureKit excludes the focus window by ID, down to 1/4 of the original pixels.",
        "高斯模糊 + 补色": "Gaussian blur + fill",
        "模糊后把洞口补上，避免桌面的亮色从边缘渗出去。":
            "After blurring, the hole is filled so the desktop's bright color doesn't bleed in from the edges.",
        "挖洞并提交": "Cut the hole & commit",
        "图片与掩膜在同一个事务里提交，所以洞永远和背景是同一帧。":
            "The image and mask are committed in the same transaction, so the hole is always on the same frame as the background.",
        "模糊由截图得来，这是唯一需要的权限 —— 没有读取输入、没有辅助功能权限。":
            "Blur is derived from captures; this is the only permission needed — no input access, no Accessibility permission.",
        "未授权": "Not Granted",
        "版本 %@（%@）": "Version %@ (%@)",

        // --- SettingsComponents ---
        "打开": "On",
        "关闭": "Off",
        "滑块": "Slider",
        "移出排除列表": "Remove from exclusion list",
        "未知应用": "Unknown App",
        "添加应用": "Add App",
        "没有正在运行的常规应用可添加。": "No regular apps are running to add.",
        "从正在运行的应用中选择。": "Choose from the running apps.",
        "添加": "Add",

        // --- StatusItemController (menu) ---
        "停用隐私模糊": "Disable Privacy Blur",
        "模糊强度": "Blur Strength",
        "光标清晰范围": "Cursor Reveal Radius",
        "设置…": "Settings…",
        "退出": "Quit",

        // --- AppDelegate (main menu) ---
        "关于隐私窗口": "About Privacy Window",
        "退出隐私窗口": "Quit Privacy Window",

        // --- PrivacyController (alerts) ---
        "需要「屏幕录制」权限": "Screen Recording permission required",
        "隐私模糊通过截图来实现。请在「系统设置 › 隐私与安全性 › 屏幕录制」中打开「PrivacyWindow」，然后重新打开效果。":
            "Privacy Blur works by capturing the screen. Please open PrivacyWindow under System Settings › Privacy & Security › Screen Recording, then re-enable the effect.",
        "稍后": "Later",
        "需要重启隐私窗口": "Restart Privacy Window required",
        "「屏幕录制」权限已生效，但 macOS 只在应用启动时读取一次该授权——当前进程拿不到画面，所以模糊不会有变化。重新打开应用即可。":
            "The Screen Recording permission is now in effect, but macOS only reads it once at launch — the current process can't get any frames, so the blur won't change. Just reopen the app.",
        "重新打开": "Reopen",
    ]

    /// Every Chinese source string the app can translate to English. Exposed for
    /// tests that guard against a UI string silently losing its translation.
    static var englishKeys: Set<String> { Set(en.keys) }
}
