import Foundation

/// Minimal ZIP writer (STORE method, no compression). Enough for a user-owned export the
/// Files app and every desktop OS can open. No third-party dependencies.
public struct ZipWriter {
    public struct Entry {
        public var path: String
        public var data: Data
        public var modified: Date

        public init(path: String, data: Data, modified: Date = Date()) {
            self.path = path
            self.data = data
            self.modified = modified
        }
    }

    public init() {}

    public func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let (dosTime, dosDate) = ZipWriter.dosDateTime(entry.modified)
            let offset = UInt32(out.count)

            // Local file header
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))            // version needed
            out.appendLE(UInt16(0x0800))        // flags: UTF-8 names
            out.appendLE(UInt16(0))             // method: store
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(crc)
            out.appendLE(size)
            out.appendLE(size)
            out.appendLE(UInt16(name.count))
            out.appendLE(UInt16(0))
            out.append(name)
            out.append(entry.data)

            // Central directory header
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(0x0314))    // made by: UNIX, 2.0
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))         // extra
            central.appendLE(UInt16(0))         // comment
            central.appendLE(UInt16(0))         // disk
            central.appendLE(UInt16(0))         // internal attrs
            central.appendLE(UInt32(0o100644) << 16) // external attrs: regular file 0644
            central.appendLE(offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, c.year ?? 1980)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let dayOfMonth: Int = c.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = ((year - 1980) << 9) | (month << 5) | dayOfMonth
        return (UInt16(truncatingIfNeeded: timeBits), UInt16(truncatingIfNeeded: dateBits))
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8(v >> 24))
    }
}
