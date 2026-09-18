import AppKit
import SwiftUI

/// Design tokens for the settings window.
///
/// The window is a bordered AppKit window with transparent chrome and SwiftUI
/// content, so nothing here can be inherited from `NSColor`/`NSFont`: every
/// value has to be stated once, here, and named for its job rather than for the
/// colour it happens to be. Two reasons that matters more than usual here:
///
/// 1. The window can be asked to stay in dark or light mode regardless of the
///    system, so almost every colour is a *function* of the scheme rather than a
///    constant.
/// 2. The app has exactly one accent. Anything tinted is tinted with it, so
///    changing the accent later is a change to one line.
enum PW {

    // MARK: Spacing (4pt base)

    enum S {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s7: CGFloat = 32
        static let s8: CGFloat = 40
        static let s9: CGFloat = 48
        static let s10: CGFloat = 64
    }

    // MARK: Radii

    enum R {
        static let control: CGFloat = 9
        static let cardSm: CGFloat = 12
        static let card: CGFloat = 18
        static let cardLg: CGFloat = 24
    }

    // MARK: Typography

    enum T {
        static func pageTitle() -> Font { .system(size: 26, weight: .semibold) }
        static func title() -> Font { .system(size: 15, weight: .semibold) }
        static func body() -> Font { .system(size: 13, weight: .medium) }
        static func bodyRegular() -> Font { .system(size: 13, weight: .regular) }
        static func footnote() -> Font { .system(size: 11, weight: .medium) }
        static func caption() -> Font { .system(size: 11, weight: .semibold) }
        static func mono() -> Font { .system(size: 12, weight: .medium, design: .monospaced) }
    }

    // MARK: Motion

    enum M {
        /// The house curve: fast out of the gate, settles without overshoot.
        static let glass = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.22)
        static let quick = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.12)
    }

    // MARK: Palette

    enum C {
        /// The one accent. Everything interactive and everything selected uses
        /// it, so it reads as "the app" rather than as decoration.
        ///
        /// Taken from the app icon: the cornflower blue of the one sharp
        /// window's toolbar, sitting on the icon's periwinkle blur. Deliberately
        /// not the violet other apps in this genre use.
        static var accent: Color { Color(hex: "#4C7DF3") ?? .accentColor }
        /// A darker stop of the same hue, for gradients that need to hold up on
        /// a light background without turning into pastel.
        static var accentDeep: Color { Color(hex: "#3557C7") ?? accent }
        static var accentGlow: Color { accent.opacity(0.45) }
        static var accentSoft: Color { accent.opacity(0.12) }

        static func text1(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.92)
        }
        static func text2(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.58)
        }
        static func text3(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.38) : Color.black.opacity(0.40)
        }

        /// A translucent control surface: pills, buttons, chips.
        static func control(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.70)
        }
        static func controlHovered(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.92)
        }
        /// Divider between rows inside a panel.
        static func hairline(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
        }
        /// The lit top edge of a card — what makes glass read as an object
        /// rather than as a flat tint.
        static func edgeTop(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.95)
        }
        static func edgeRing(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
        }

        static let green = Color(hex: "#26C485") ?? .green
        static let orange = Color(hex: "#FF9F0A") ?? .orange
        static let red = Color(hex: "#FF453A") ?? .red
    }
}

extension Color {
    /// `#RRGGBB` only. Anything malformed falls out as `nil` rather than as
    /// black, so a typo in a token is a compile-time lookup failure to fix,
    /// not a shape quietly turning invisible.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
