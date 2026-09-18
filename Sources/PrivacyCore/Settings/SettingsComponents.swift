import AppKit
import SwiftUI

// MARK: - Search

/// Whether a section matches what is being searched for.
///
/// Token-based on purpose: every whitespace-separated token typed in the search
/// field has to appear somewhere in the section's keywords, so "模糊 dock"
/// finds the row tagged with both words even though they sit far apart in the
/// text (and in different languages — the keywords carry both).
func settingsSearchMatch(_ keywords: String, search: String) -> Bool {
    guard !search.isEmpty else { return true }
    let haystack = keywords.lowercased()
    return search.lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .allSatisfy { haystack.contains($0) }
}

// MARK: - Surfaces

/// The window's backdrop: a quiet wash so the floating panels have something to
/// float over, in both appearances.
struct SettingsBackdrop: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(hue: 0.66, saturation: 0.22, brightness: 0.17),
                   Color(hue: 0.72, saturation: 0.20, brightness: 0.13)]
                : [Color(hue: 0.66, saturation: 0.14, brightness: 0.97),
                   Color(hue: 0.72, saturation: 0.12, brightness: 0.94)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(PW.C.accent.opacity(scheme == .dark ? 0.35 : 0.45))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: -140, y: -200)
        }
        .ignoresSafeArea()
    }
}

/// A card made of the screensaver-thin material, with a lit top edge.
///
/// Rows live inside these; the material is what lets the backdrop through
/// instead of sitting on top of it as a flat grey block.
struct GlassPanel<Content: View>: View {
    @Environment(\.colorScheme) var scheme
    let radius: CGFloat
    @ViewBuilder var content: Content

    init(radius: CGFloat = PW.R.card, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.10))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [PW.C.edgeTop(scheme), .clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 18, y: 8)
    }
}

struct SectionLabel: View {
    @Environment(\.colorScheme) var scheme
    let text: String
    var body: some View {
        Text(text)
            .font(PW.T.caption())
            .tracking(0.9)
            .foregroundStyle(PW.C.text3(scheme))
            .padding(.top, PW.S.s6)
            .padding(.bottom, PW.S.s3)
            .padding(.horizontal, PW.S.s2)
    }
}

struct PageHeader<Trailing: View>: View {
    @Environment(\.colorScheme) var scheme
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: PW.S.s4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PW.T.pageTitle())
                    .tracking(-0.4)
                    .foregroundStyle(PW.C.text1(scheme))
                if let subtitle {
                    Text(subtitle)
                        .font(PW.T.bodyRegular())
                        .foregroundStyle(PW.C.text2(scheme))
                }
            }
            Spacer()
            trailing
        }
        .padding(.bottom, PW.S.s6)
    }
}

struct IconTile: View {
    let systemName: String
    var tint: Tint = .accent
    enum Tint { case accent, neutral, danger }
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch tint {
        case .accent: return PW.C.accentSoft
        case .neutral: return scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
        case .danger: return PW.C.red.opacity(0.12)
        }
    }
    private var foreground: Color {
        switch tint {
        case .accent: return PW.C.accent
        case .neutral: return PW.C.text2(scheme)
        case .danger: return PW.C.red
        }
    }
}

// MARK: - Rows

/// One line of a panel: icon, title, optional subtitle, a control, and optional
/// content below (a slider under its label).
///
/// `isFirst` suppresses the hairline above, which is how rows read as belonging
/// to one card rather than as a stack of separate ones; the hairline starts at
/// the icon's right edge so it never crosses the icon column.
struct SettingsRow<Trailing: View, Below: View>: View {
    @Environment(\.colorScheme) var scheme
    let icon: String?
    let iconTint: IconTile.Tint
    let title: String
    let subtitle: String?
    let isFirst: Bool
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var below: Below

    init(icon: String? = nil,
         iconTint: IconTile.Tint = .accent,
         title: String,
         subtitle: String? = nil,
         isFirst: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.isFirst = isFirst
        self.trailing = trailing()
        self.below = below()
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 56)
                    Rectangle().fill(PW.C.hairline(scheme)).frame(height: 0.5)
                }
            }
            HStack(alignment: .center, spacing: PW.S.s3) {
                if let icon { IconTile(systemName: icon, tint: iconTint) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PW.T.title())
                        .foregroundStyle(PW.C.text1(scheme))
                    if let subtitle {
                        Text(subtitle)
                            .font(PW.T.bodyRegular())
                            .foregroundStyle(PW.C.text2(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: PW.S.s3)
                trailing
            }
            .padding(.horizontal, PW.S.s4)
            .padding(.vertical, PW.S.s3)
            .frame(minHeight: 52)

            if !(below is EmptyView) {
                below
                    .padding(.leading, 56)
                    .padding(.trailing, PW.S.s4)
                    .padding(.bottom, PW.S.s3)
            }
        }
        // A row with nothing under it reads as one VoiceOver element
        // ("启用隐私模糊, 打开, 开关"). A row carrying a slider keeps its
        // children exposed so the slider's own adjustable action still works.
        .accessibilityElement(children: below is EmptyView ? .combine : .contain)
    }
}

// MARK: - Controls

struct GlassSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Button {
            withAnimation(PW.M.glass) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? PW.C.accent : (scheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.18)))
                    .shadow(color: isOn ? PW.C.accentGlow : .clear, radius: 8)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5).padding(2))
            }
            .frame(width: 44, height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "打开" : "关闭")
    }
}

/// A slider built from scratch rather than from `Slider`: it has to sit inside a
/// row's "below" slot at a width the row dictates, and its thumb needs to be
/// draggable from anywhere on the track (including directly onto a value).
struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var accessibilityLabel: String = "滑块"
    @Environment(\.colorScheme) var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbX = CGFloat(fraction) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(PW.C.accent)
                    .frame(width: thumbX, height: 4)
                    .shadow(color: PW.C.accentGlow, radius: 6)
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .offset(x: max(0, min(width - 18, thumbX - 9)))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { update(at: $0.location.x, width: width) }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(round(fraction * 100)))%")
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + delta)
            case .decrement: value = max(range.lowerBound, value - delta)
            @unknown default: break
            }
        }
    }

    private var fraction: Double {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func update(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let percent = max(0, min(1, x / width))
        var next = range.lowerBound + Double(percent) * (range.upperBound - range.lowerBound)
        if let step { next = (next / step).rounded() * step }
        value = max(range.lowerBound, min(range.upperBound, next))
    }
}

struct GlassSegmented<T: Hashable & Identifiable>: View {
    @Binding var selection: T
    let items: [T]
    let label: (T) -> String
    var accent: Bool = false
    @Environment(\.colorScheme) var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = selection == item
                Button {
                    withAnimation(PW.M.quick) { selection = item }
                } label: {
                    Text(label(item))
                        .font(PW.T.body())
                        .foregroundStyle(selected ? (accent ? Color.white : PW.C.text1(scheme)) : PW.C.text2(scheme))
                        .padding(.horizontal, PW.S.s4)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            ZStack {
                                if selected {
                                    if accent {
                                        Capsule()
                                            .fill(PW.C.accent)
                                            .shadow(color: PW.C.accentGlow, radius: 8)
                                    } else {
                                        Capsule()
                                            .fill(.ultraThinMaterial)
                                            .overlay(
                                                Capsule().strokeBorder(PW.C.edgeTop(scheme).opacity(0.4), lineWidth: 0.5)
                                            )
                                            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 3, y: 1)
                                    }
                                }
                            }
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial).opacity(0.35))
        .overlay(Capsule().strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5))
    }
}

/// A dropdown that looks right inside a row, instead of AppKit's default popup
/// with its own chrome and its own opinion about padding.
struct GlassPicker<T: Hashable & Identifiable>: View {
    @Binding var selection: T
    let items: [T]
    let label: (T) -> String
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(label(item)) { selection = item }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(selection)).font(PW.T.body())
                VStack(spacing: 0) {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(PW.C.text3(scheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: PW.R.control).fill(PW.C.control(scheme)))
            .overlay(RoundedRectangle(cornerRadius: PW.R.control).strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5))
            .foregroundStyle(PW.C.text1(scheme))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A key equivalent, or the honest statement that there isn't one.
struct KeyCap: View {
    let text: String
    @Environment(\.colorScheme) var scheme
    var body: some View {
        Text(text)
            .font(PW.T.mono())
            .foregroundStyle(PW.C.text3(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(PW.C.control(scheme)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5)
            )
    }
}

// MARK: - Buttons

struct GhostButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: PW.R.control, style: .continuous)
                    .fill(hovered ? PW.C.controlHovered(scheme) : PW.C.control(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PW.R.control, style: .continuous)
                    .strokeBorder(PW.C.edgeRing(scheme), lineWidth: 0.5)
            )
            .foregroundStyle(PW.C.text1(scheme))
            .contentShape(RoundedRectangle(cornerRadius: PW.R.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: PW.R.control, style: .continuous)
                    .fill(PW.C.accent)
                    .shadow(color: PW.C.accentGlow, radius: 12, y: 4)
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: PW.R.control))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notices

/// A banner for something that needs saying before it needs a setting.
struct Callout: View {
    let title: String
    let message: String
    let systemImage: String
    var tint: Color = PW.C.accent
    @Environment(\.colorScheme) var scheme

    var body: some View {
        HStack(alignment: .top, spacing: PW.S.s3) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PW.C.text1(scheme))
                Text(message)
                    .font(PW.T.bodyRegular())
                    .foregroundStyle(PW.C.text2(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PW.S.s3)
        }
        .padding(PW.S.s4)
        .background(RoundedRectangle(cornerRadius: PW.R.cardSm, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: PW.R.cardSm, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 0.5)
        )
    }
}
