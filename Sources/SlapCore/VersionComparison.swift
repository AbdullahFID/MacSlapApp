import Foundation

/// Compares release tags like "v2.00", "3.0", "v3.1.2-beta".
public enum VersionComparison {
    /// Numeric components, ignoring a leading "v" and any "-suffix".
    /// Returns nil if the string has no leading number.
    public static func components(_ version: String) -> [Int]? {
        var s = version.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let dash = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// True only if both parse and `candidate` is strictly greater.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
