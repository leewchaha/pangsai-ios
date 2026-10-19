import Foundation

/// Minimal ZIP reader for importing a previous export straight from its .zip. Reads the central
/// directory (so archives re-zipped with data descriptors still work), handles STORE natively and
/// DEFLATE through an injected inflater (the app passes Apple's Compression; Core stays portable).
public enum ZipReader {
    public enum ZipError: Error, Equatable {
        case notAZip, entryMissing, unsupportedMethod, corrupt
    }

    public struct EntryInfo: Equatable {
        public var path: String
        public var method: Int
        public var compressedSize: Int
        public var uncompressedSize: Int
        public var localHeaderOffset: Int
    }

    /// True when the bytes start with a ZIP local file header ("PK\u{3}\u{4}").
    public static func looksLikeZip(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        return b == [0x50, 0x4b, 0x03, 0x04]
    }

    static func u16(_ d: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 1 < d.count else { return nil }
        return Int(d[i]) | Int(d[i + 1]) << 8
    }

    static func u32(_ d: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 3 < d.count else { return nil }
        return Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
    }

    public static func entries(_ data: Data) throws -> [EntryInfo] {
        let b = [UInt8](data)
        guard b.count >= 22 else { throw ZipError.notAZip }
        // End of central directory: the last signature within the final 64 KiB (+ record size).
        var eocd = -1
        var i = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while i >= lowest {
            if b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 0x05 && b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0, let count = u16(b, eocd + 10), let directory = u32(b, eocd + 16) else { throw ZipError.notAZip }
        var out: [EntryInfo] = []
        var p = directory
        for _ in 0..<count {
            guard u32(b, p) == 0x02014b50,
                  let method = u16(b, p + 10),
                  let compressed = u32(b, p + 20),
                  let uncompressed = u32(b, p + 24),
                  let nameLength = u16(b, p + 28),
                  let extraLength = u16(b, p + 30),
                  let commentLength = u16(b, p + 32),
                  let local = u32(b, p + 42),
                  p + 46 + nameLength <= b.count else { throw ZipError.corrupt }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            out.append(EntryInfo(path: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: local))
            p += 46 + nameLength + extraLength + commentLength
        }
        return out
    }

    /// The bytes of the first entry named `name` (at the root or inside any folder).
    /// macOS "__MACOSX" resource-fork copies are ignored.
    public static func file(named name: String, in data: Data, inflate: ((Data, Int) -> Data?)? = nil) throws -> Data {
        let b = [UInt8](data)
        let all = try entries(data)
        guard let entry = all.first(where: { e in
            !e.path.hasPrefix("__MACOSX/") && (e.path == name || e.path.hasSuffix("/" + name))
        }) else { throw ZipError.entryMissing }
        let h = entry.localHeaderOffset
        guard u32(b, h) == 0x04034b50,
              let nameLength = u16(b, h + 26),
              let extraLength = u16(b, h + 28) else { throw ZipError.corrupt }
        let start = h + 30 + nameLength + extraLength
        guard start >= 0, start + entry.compressedSize <= b.count else { throw ZipError.corrupt }
        let payload = Data(b[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflate else { throw ZipError.unsupportedMethod }
            guard let out = inflate(payload, entry.uncompressedSize) else { throw ZipError.corrupt }
            return out
        default:
            throw ZipError.unsupportedMethod
        }
    }
}

extension ZipReader.ZipError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAZip, .corrupt: return "That file isn't a readable ShittyFriends export."
        case .entryMissing: return "No poop-history.json inside that .zip. Pick a ShittyFriends export."
        case .unsupportedMethod: return "That .zip is compressed in a way we can't read. Pick the original export."
        }
    }
}
