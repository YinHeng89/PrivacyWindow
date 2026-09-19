import XCTest
@testable import PrivacyCore

/// Guards the i18n contract: the app's source language is Chinese, so every
/// Chinese string shown to the user must exist as a key in `I18n`'s English
/// table — otherwise an English-speaking user sees the Chinese key verbatim.
///
/// `testEveryChineseUIStringIsTranslated` scans the production sources for every
/// Chinese string that reaches the UI through the app's i18n call sites and
/// component parameters, and fails if any of them is missing from the table. It
/// is the automated form of "顺便看看还有没有遗漏的": add a labelled string,
/// forget its English row, and this test goes red instead of a user doing.
final class I18nCoverageTests: XCTestCase {

    /// Keys the app actually knows how to translate.
    private var knownKeys: Set<String> { I18n.englishKeys }

    func testEveryChineseUIStringIsTranslated() {
        let sources = i18nSourceFiles()
        var missing: [String] = []
        var seen = Set<String>()
        for file in sources {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for key in chineseUIKeys(in: content) {
                seen.insert(key)
                if !knownKeys.contains(key) { missing.append(key) }
            }
        }
        // Guards against the scan silently reading nothing (e.g. a wrong path)
        // and then passing vacuously.
        XCTAssert(seen.contains("通用"), "i18n scanner found no sources to read")
        if !missing.isEmpty {
            XCTFail("Missing English translation for \(missing.count) key(s): \(missing.sorted().joined(separator: ", "))")
        }
    }

    /// The Appearance colour strings added with the tint feature, pinned so a
    /// future edit that drops their English entry is caught even if the scanner
    /// above is somehow bypassed. Runs in English and asserts the exact output.
    func testNewAppearanceTranslationsRenderInEnglish() {
        let previous = I18n.shared.language
        I18n.shared.language = .en
        defer { I18n.shared.language = previous }

        let cases: [(key: String, english: String)] = [
            ("模糊颜色", "Blur Color"),
            ("给模糊背景叠加一层颜色。强度为 0 时保持原样（默认白色）。",
             "Lays a color over the blurred background. At zero strength it stays unchanged (white by default)."),
            ("颜色强度", "Color Strength"),
            ("颜色覆盖背景的比例：0 为关闭，1 为纯色填充。",
             "How much of the background the color covers: 0 is off, 1 is a solid fill."),
            ("关闭后不再做高斯模糊；颜色覆盖仍可单独生效。",
             "When off, no Gaussian blur is applied; the color overlay still works on its own."),
            ("模糊颜色强度", "Blur Color Strength"),
            ("模糊的强度、鼠标周围那块清晰区域，以及设置窗口的配色与语言。",
             "Blur strength, the clear area around the cursor, and the settings window's theme and language."),
        ]
        for `case` in cases {
            XCTAssertEqual(I18n.shared.t(`case`.key), `case`.english, "key: \(`case`.key)")
        }
    }

    // MARK: - source scanning

    /// All `.swift` files under `Sources/PrivacyCore`, except `Localization.swift`
    /// itself — that file *defines* the table, so its Chinese literals are the
    /// keys, not usages, and would otherwise read as false positives.
    private func i18nSourceFiles() -> [String] {
        for root in candidateRoots() {
            let core = root.appendingPathComponent("Sources/PrivacyCore")
            let fm = FileManager.default
            guard fm.fileExists(atPath: core.path),
                  let subs = try? fm.subpathsOfDirectory(atPath: core.path) else { continue }
            // `subpathsOfDirectory` is recursive, so the `Settings/` and
            // `Localization/` subfolders are included; we only skip the file that
            // *defines* the table (its Chinese literals are keys, not usages).
            let swift = subs
                .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Localization.swift") }
                .map { core.appendingPathComponent($0).path }
            if !swift.isEmpty { return swift }
        }
        return []
    }

    /// Where the package root might be: the current working directory (under
    /// `swift test` this is the package root) and every ancestor of this source
    /// file, widest first.
    private func candidateRoots() -> [URL] {
        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            roots.append(dir)
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return roots
    }

    /// Chinese string literals passed to the app's i18n call sites and the
    /// components that localise their own text. The literal must contain at least
    /// one CJK character to count.
    private func chineseUIKeys(in content: String) -> [String] {
        // Prefixes that introduce a localisation key. `\.t\(` catches
        // `I18n.shared.t("…")` and `i18n.t("…")`; the rest catch the plain
        // Chinese arguments handed to the wrapping components (PageHeader,
        // SectionLabel, SettingsRow, Callout, GlassSwitch/Button, alerts,
        // accessibility labels, direct Text). Search-keyword strings like
        // `match("模糊 强度…")` are deliberately excluded: they contain no
        // `title:`/`text:`/`\.t(` prefix, so they never match.
        let prefix = #"(?:\.t\(\s*|title:\s*|subtitle:\s*|text:\s*|message:\s*|help:\s*|accessibilityLabel:\s*|PageHeader\(\s*|Text\(\s*)"#
        let pattern = prefix + #""([^"]*[\x{4e00}-\x{9fff}][^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[r])
        }
    }
}
