import Foundation

/// JSON files on disk. `my.json` holds my data, `cache.json` holds friends/groups caches.
/// Writes are atomic; the platform layer debounces calls.
public final class FilePersistence {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var myURL: URL { directory.appendingPathComponent("my.json") }
    var cacheURL: URL { directory.appendingPathComponent("cache.json") }
    var myBackupURL: URL { directory.appendingPathComponent("my.backup.json") }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public func loadMy() -> MyState {
        for url in [myURL, myBackupURL] {
            if let data = try? Data(contentsOf: url), let s = try? FilePersistence.decoder().decode(MyState.self, from: data) {
                return s
            }
        }
        return MyState()
    }

    public func loadCache() -> CacheState {
        guard let data = try? Data(contentsOf: cacheURL),
              let s = try? FilePersistence.decoder().decode(CacheState.self, from: data) else { return CacheState() }
        return s
    }

    public func save(my: MyState) throws {
        let data = try FilePersistence.encoder().encode(my)
        if FileManager.default.fileExists(atPath: myURL.path) {
            try? FileManager.default.removeItem(at: myBackupURL)
            try? FileManager.default.copyItem(at: myURL, to: myBackupURL)
        }
        try data.write(to: myURL, options: [.atomic])
    }

    public func save(cache: CacheState) throws {
        let data = try FilePersistence.encoder().encode(cache)
        try data.write(to: cacheURL, options: [.atomic])
    }

    public func wipe() {
        for url in [myURL, cacheURL, myBackupURL] { try? FileManager.default.removeItem(at: url) }
    }
}
