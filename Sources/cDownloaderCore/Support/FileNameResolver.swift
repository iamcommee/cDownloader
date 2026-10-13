import Foundation
import UniformTypeIdentifiers

/// Picks the local file name for a download.
public enum FileNameResolver {
    /// Content-Disposition name first, then the URL's last path part, then "download".
    /// An extension is added from the MIME type when the name has none.
    public static func fileName(contentDisposition: String?, url: URL, mimeType: String?) -> String {
        var name = contentDisposition.flatMap(parseContentDisposition).map(sanitize) ?? ""
        if name.isEmpty {
            let last = url.lastPathComponent
            name = last == "/" ? "" : sanitize(last)
        }
        if name.isEmpty { name = "download" }
        if (name as NSString).pathExtension.isEmpty, let ext = preferredExtension(forMIMEType: mimeType) {
            name += "." + ext
        }
        return name
    }

    static func preferredExtension(forMIMEType mimeType: String?) -> String? {
        guard let base = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              !base.isEmpty, base != "application/octet-stream"
        else { return nil }
        return UTType(mimeType: base)?.preferredFilenameExtension
    }

    /// Extracts the file name from a Content-Disposition header; `filename*` wins over `filename`.
    public static func parseContentDisposition(_ header: String) -> String? {
        var plain: String?
        var extended: String?
        for parameter in splitParameters(header) {
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = parameter[parameter.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                extended = decodeExtendedValue(rawValue)
            } else if key == "filename" {
                plain = repairLatin1(unquote(rawValue))
            }
        }
        let name = extended ?? plain
        return name?.isEmpty == false ? name : nil
    }

    /// Splits on semicolons that are outside double quotes.
    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in header {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && inQuotes {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == ";" && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// RFC 5987: charset'language'percent-encoded-bytes.
    private static func decodeExtendedValue(_ value: String) -> String? {
        let parts = unquote(value).split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = parts[0].lowercased()
        var bytes: [UInt8] = []
        var iterator = Array(parts[2].utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        let encoding: String.Encoding = charset == "iso-8859-1" ? .isoLatin1 : .utf8
        return String(bytes: bytes, encoding: encoding)
    }

    /// Header values arrive as Latin-1; servers that send raw UTF-8 bytes are decoded properly here.
    private static func repairLatin1(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value > 0x7F }),
              value.unicodeScalars.allSatisfy({ $0.value <= 0xFF })
        else { return value }
        let bytes = value.unicodeScalars.map { UInt8($0.value) }
        return String(bytes: bytes, encoding: .utf8) ?? value
    }

    /// Removes path parts and characters that are unsafe in a macOS file name.
    public static func sanitize(_ name: String) -> String {
        let lastPart = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(lastPart.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        cleaned = cleaned.replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.utf8.count > 255 { cleaned.removeFirst() }
        return cleaned
    }

    /// Returns `url` or, when taken, "name (1).ext", "name (2).ext", ...
    public static func uniqueURL(for url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        guard exists(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            index += 1
        }
    }
}
