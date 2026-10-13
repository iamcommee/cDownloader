import Foundation

public enum NativeMessagingError: Error, Equatable {
    case emptyMessage
    case tooLarge(Int)
    case invalidJSON
    case truncated
}

/// Chrome native messaging framing: a 4-byte little-endian length, then UTF-8 JSON.
public enum NativeMessagingCodec {
    /// Limit for messages from the browser (Chrome allows more; larger ones are refused here).
    public static let maxIncomingLength = 8 * 1024 * 1024
    /// Chrome's limit for messages sent to the browser.
    public static let maxOutgoingLength = 1024 * 1024

    public static func encode(_ json: Data) throws -> Data {
        guard !json.isEmpty else { throw NativeMessagingError.emptyMessage }
        guard json.count <= maxOutgoingLength else { throw NativeMessagingError.tooLarge(json.count) }
        var frame = Data()
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        return frame
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encode(JSONEncoder().encode(value))
    }

    /// Accumulates bytes and returns complete JSON messages.
    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var messages: [Data] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = buffer[start..<start + 4].withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length > 0 else { throw NativeMessagingError.emptyMessage }
                guard length <= NativeMessagingCodec.maxIncomingLength else { throw NativeMessagingError.tooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let payload = buffer.subdata(in: (start + 4)..<(start + 4 + length))
                buffer.removeSubrange(start..<(start + 4 + length))
                guard String(data: payload, encoding: .utf8) != nil,
                      (try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])) != nil
                else { throw NativeMessagingError.invalidJSON }
                messages.append(payload)
            }
            return messages
        }

        /// Call at end of input; throws when a message was cut off.
        public func finish() throws {
            if !buffer.isEmpty { throw NativeMessagingError.truncated }
        }
    }
}
