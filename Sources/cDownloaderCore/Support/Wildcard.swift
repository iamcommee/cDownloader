import Foundation

/// Case-insensitive pattern matching where `*` stands for any run of characters.
/// Every other character, including regex symbols, matches itself.
public enum Wildcard {
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var starIndex = -1, starText = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi
                starText = ti
                pi += 1
            } else if starIndex >= 0 {
                pi = starIndex + 1
                starText += 1
                ti = starText
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// True when any pattern in the list matches.
    public static func matchesAny(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { matches($0.trimmingCharacters(in: .whitespaces), text) }
    }
}
