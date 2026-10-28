import Foundation

public enum Paths {
    public static let bundleIdentifier = "co.curry.blktxt"

    /// The database file. `BLKTXT_DB` overrides it (tests, benchmarks).
    public static var databaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["BLKTXT_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("blktxt", isDirectory: true).appendingPathComponent("blktxt.sqlite")
    }

    /// Held by the running app; tells the CLI whether to route edits through it.
    public static func lockURL(for database: URL) -> URL {
        database.deletingLastPathComponent().appendingPathComponent(database.lastPathComponent + ".applock")
    }
}

enum Compression {
    /// Bodies smaller than this are stored as-is.
    static let threshold = 512

    static func pack(_ text: String) -> (data: Data, compressed: Bool) {
        let raw = Data(text.utf8)
        guard raw.count >= threshold,
              let packed = try? (raw as NSData).compressed(using: .lzfse) as Data,
              packed.count < raw.count
        else { return (raw, false) }
        return (packed, true)
    }

    static func unpack(_ data: Data, compressed: Bool) -> String {
        guard compressed else { return String(decoding: data, as: UTF8.self) }
        guard let raw = try? (data as NSData).decompressed(using: .lzfse) as Data else { return "" }
        return String(decoding: raw, as: UTF8.self)
    }
}
