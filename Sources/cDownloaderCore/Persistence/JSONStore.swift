import Foundation

/// Loads and saves one Codable value as a JSON file.
/// Saves are atomic; a file that cannot be read is moved aside and defaults are used.
public final class JSONStore<Value: Codable & Sendable>: @unchecked Sendable {
    public let fileURL: URL
    private let makeDefault: @Sendable () -> Value
    private let lock = NSLock()
    /// Where the last unreadable file was moved, if any.
    public private(set) var lastBackupURL: URL?

    public init(fileURL: URL, defaultValue: @escaping @Sendable () -> Value) {
        self.fileURL = fileURL
        self.makeDefault = defaultValue
    }

    public func load() -> Value {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else { return makeDefault() }
            do {
                return try Self.decoder.decode(Value.self, from: data)
            } catch {
                lastBackupURL = moveAside()
                return makeDefault()
            }
        }
    }

    public func save(_ value: Value) throws {
        let data = try Self.encoder.encode(value)
        try lock.withLock {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    /// Renames the unreadable file to `<name>.corrupt-<n>` using the first free number.
    private func moveAside() -> URL? {
        let fileManager = FileManager.default
        var index = 1
        var target: URL
        repeat {
            target = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(index)")
            index += 1
        } while fileManager.fileExists(atPath: target.path)
        return (try? fileManager.moveItem(at: fileURL, to: target)) != nil ? target : nil
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
