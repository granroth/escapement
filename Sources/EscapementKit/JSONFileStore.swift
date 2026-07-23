import Foundation

/// Serialises access to a file across every store instance pointing at it.
///
/// Correctness must not depend on callers remembering to serialise themselves:
/// two tasks appending to the history concurrently would otherwise race on a
/// read-modify-write and silently drop entries. A lock keyed by the file's
/// path guards every same-file access in this process, whichever store
/// instance issues it.
private final class FileLockRegistry: @unchecked Sendable {
    static let shared = FileLockRegistry()
    private let guardLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.path
        guardLock.lock()
        defer { guardLock.unlock() }
        if let existing = locks[key] { return existing }
        let created = NSLock()
        locks[key] = created
        return created
    }
}

/// A small atomic JSON file, the shared backing for the configuration and
/// history stores.
///
/// Coordination between the app and the agent is by file, not XPC (see
/// `ARCHITECTURE.md`), so both the write and the read paths have to be robust:
/// a write must never leave a half-written file, a read must treat a genuinely
/// missing file as empty, and concurrent callers must not clobber each other.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {

    private let url: URL
    private let defaultValue: Value

    public init(url: URL, default defaultValue: Value) {
        self.url = url
        self.defaultValue = defaultValue
    }

    /// The stored value, or the default if the file does not yet exist.
    ///
    /// Only a genuinely absent file yields the default. A file that exists but
    /// cannot be read — permissions, an I/O error — throws rather than masking
    /// the problem as emptiness, which would be indistinguishable from the
    /// user's data having been wiped. A present-but-corrupt file throws from
    /// the validating decoder.
    public func load() throws -> Value {
        try withFileLock { try unlockedLoad() }
    }

    /// Writes the value atomically: encode, write to a sibling temporary file,
    /// then replace. A crash between steps leaves the previous file intact.
    public func save(_ value: Value) throws {
        try withFileLock { try unlockedSave(value) }
    }

    /// Atomically reads, transforms, and writes back under a single lock, so a
    /// read-modify-write cannot interleave with another caller's and lose the
    /// intervening change.
    public func mutate(_ transform: (inout Value) -> Void) throws {
        try withFileLock {
            var value = try unlockedLoad()
            transform(&value)
            try unlockedSave(value)
        }
    }

    // MARK: - Unlocked primitives

    private func unlockedLoad() throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func unlockedSave(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        // `replaceItemAt` swaps the temp file into place and removes it; on
        // failure the temp file is cleaned up so it cannot accumulate.
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let lock = FileLockRegistry.shared.lock(for: url)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
