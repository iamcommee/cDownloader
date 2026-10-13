import Foundation

/// Decides whether copied text should be offered as a download.
public final class ClipboardFilter: @unchecked Sendable {
    public var extensions: [String]
    private var lastText: String?

    public init(extensions: [String]) {
        self.extensions = extensions
    }

    /// The address to offer, or nil. The same copied text is offered only once.
    public func offer(_ text: String) -> URL? {
        guard text != lastText else { return nil }
        lastText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp"].contains(scheme), url.host?.isEmpty == false
        else { return nil }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, Wildcard.matchesAny(extensions, ext) else { return nil }
        return url
    }
}
