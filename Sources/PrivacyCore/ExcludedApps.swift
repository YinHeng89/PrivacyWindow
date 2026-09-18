import Foundation

/// The set of apps the effect stands down for, keyed by bundle identifier.
///
/// A value type rather than a `Set<String>` on the controller for two reasons:
/// the matching rules (trim, case-insensitivity, "empty is not an app") live in
/// one testable place, and the controller keeps no knowledge of how a raw string
/// becomes a key.
///
/// Matching is deliberately lenient about case and whitespace because the
/// identifiers come from at least two sources — `NSApplication` at runtime and
/// whatever the settings UI round-trips through `UserDefaults` — and a rule
/// that silently fails on `"Com.Apple.Safari "` is worse than no rule.
struct ExcludedApps: Equatable {
    private(set) var bundleIDs: Set<String> = []

    init(_ rawIDs: any Sequence<String> = []) {
        for raw in rawIDs where Self.normalized(raw) != nil {
            bundleIDs.insert(Self.normalized(raw)!)
        }
    }

    /// The canonical form of a bundle identifier, or `nil` when the string
    /// cannot name an app at all.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    mutating func insert(_ raw: String?) {
        guard let id = Self.normalized(raw) else { return }
        bundleIDs.insert(id)
    }

    mutating func remove(_ raw: String) {
        guard let id = Self.normalized(raw) else { return }
        bundleIDs.remove(id)
    }

    /// Whether `raw` names an excluded app. Anything that cannot be normalized
    /// — including `nil`, which is what an app without a bundle identifier
    /// reports — never matches: an unidentifiable app gets the blur, which is
    /// the safe direction for a privacy tool.
    func contains(_ raw: String?) -> Bool {
        guard let id = Self.normalized(raw) else { return false }
        return bundleIDs.contains(id)
    }

    var isEmpty: Bool { bundleIDs.isEmpty }
}
