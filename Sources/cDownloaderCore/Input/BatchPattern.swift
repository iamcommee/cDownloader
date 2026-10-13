import Foundation

/// Expands a URL template such as `https://site/img*.jpg` into a numbered or lettered series.
public enum BatchPattern {
    public enum Range: Sendable, Equatable {
        /// `width` pads with zeros (1 -> "001" for width 3); 0 means no padding.
        case numbers(from: Int, to: Int, width: Int)
        case letters(from: Character, to: Character)
    }

    public enum BatchError: Error, Equatable {
        case noWildcard
        case multipleWildcards
        case reversedRange
        case invalidAddress(String)
    }

    public static func expand(_ template: String, range: Range) throws -> [URL] {
        let stars = template.filter { $0 == "*" }.count
        guard stars > 0 else { throw BatchError.noWildcard }
        guard stars == 1 else { throw BatchError.multipleWildcards }
        let parts = template.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        let (prefix, suffix) = (String(parts[0]), String(parts[1]))

        let values: [String]
        switch range {
        case .numbers(let from, let to, let width):
            guard from <= to else { throw BatchError.reversedRange }
            values = (from...to).map { number in
                let digits = String(number)
                return digits.count < width ? String(repeating: "0", count: width - digits.count) + digits : digits
            }
        case .letters(let from, let to):
            guard let low = from.unicodeScalars.first?.value, let high = to.unicodeScalars.first?.value else { throw BatchError.reversedRange }
            guard low <= high else { throw BatchError.reversedRange }
            values = (low...high).compactMap { Unicode.Scalar($0).map { String(Character($0)) } }
        }
        return try values.map { value in
            let address = prefix + value + suffix
            guard let url = URL(string: address), url.scheme != nil else { throw BatchError.invalidAddress(address) }
            return url
        }
    }
}
