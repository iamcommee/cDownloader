import Foundation

/// Builds small zip archives byte by byte so tests control every field.
struct TestZipBuilder {
    struct Entry {
        var name: String
        var data: Data
        var method: UInt16 = 0
        var encrypted = false
    }

    var entries: [Entry] = []
    var comment = ""

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    func build() -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let payload = entry.method == 8 ? (try! (entry.data as NSData).compressed(using: .zlib) as Data) : entry.data
            let crc = Self.crc32(entry.data)
            let name = Data(entry.name.utf8)
            let flags: UInt16 = (1 << 11) | (entry.encrypted ? 1 : 0)
            let offset = UInt32(out.count)
            out.le32(0x0403_4B50); out.le16(20); out.le16(flags); out.le16(entry.method); out.le16(0); out.le16(0)
            out.le32(crc); out.le32(UInt32(payload.count)); out.le32(UInt32(entry.data.count))
            out.le16(UInt16(name.count)); out.le16(0); out.append(name); out.append(payload)

            central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(flags); central.le16(entry.method)
            central.le16(0); central.le16(0); central.le32(crc); central.le32(UInt32(payload.count)); central.le32(UInt32(entry.data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0)
            central.le32(offset); central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        let commentData = Data(comment.utf8)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0); out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(centralOffset); out.le16(UInt16(commentData.count)); out.append(commentData)
        return out
    }

    /// A listing-only archive whose single entry claims sizes and offsets beyond 4 GB via ZIP64 fields.
    static func zip64Listing(name: String, size: UInt64, offset: UInt64) -> Data {
        var out = Data(count: 64) // filler where local data would be
        let nameData = Data(name.utf8)
        var central = Data()
        central.le32(0x0201_4B50); central.le16(45); central.le16(45); central.le16(1 << 11); central.le16(0)
        central.le16(0); central.le16(0); central.le32(0); central.le32(0xFFFF_FFFF); central.le32(0xFFFF_FFFF)
        central.le16(UInt16(nameData.count)); central.le16(28); central.le16(0); central.le16(0); central.le16(0); central.le32(0)
        central.le32(0xFFFF_FFFF); central.append(nameData)
        central.le16(0x0001); central.le16(24); central.le64(size); central.le64(size); central.le64(offset)
        let centralOffset = UInt64(out.count)
        out.append(central)
        let zip64Offset = UInt64(out.count)
        out.le32(0x0606_4B50); out.le64(44); out.le16(45); out.le16(45); out.le32(0); out.le32(0)
        out.le64(1); out.le64(1); out.le64(UInt64(central.count)); out.le64(centralOffset)
        out.le32(0x0706_4B50); out.le32(0); out.le64(zip64Offset); out.le32(1)
        out.le32(0x0605_4B50); out.le16(0xFFFF); out.le16(0xFFFF); out.le16(0xFFFF); out.le16(0xFFFF)
        out.le32(0xFFFF_FFFF); out.le32(0xFFFF_FFFF); out.le16(0)
        return out
    }
}

extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
