import Foundation
import Security

enum Credentials {
    static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.LTEWatch.router",
         kSecAttrAccount as String: host]
    }
    static func read(_ host: String) throws -> String? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AppFailure("Could not read the router password from Keychain.")
        }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, host: String) throws {
        let q = query(host)
        let values = [kSecValueData as String: Data(password.utf8)]
        let update = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AppFailure("Could not update the password in Keychain.") }
        var entry = q.merging(values) { _, new in new }
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw AppFailure("Could not save the password in Keychain.") }
    }
    /// Reads on a background thread so a pending Keychain permission prompt can't freeze the app.
    /// Cancelling the caller returns immediately; the abandoned read finishes on its own and is ignored.
    static func readInBackground(_ host: String, reader: @escaping @Sendable (String) throws -> String? = { try Credentials.read($0) }) async throws -> String? {
        try Task.checkCancellation()
        let once = ResumeOnce<String?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                DispatchQueue.global(qos: .utility).async { once.resume(with: Result { try reader(host) }) }
            }
        } onCancel: { once.resume(with: .failure(CancellationError())) }
    }
    static func delete(_ host: String) throws {
        let status = SecItemDelete(query(host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("Could not remove the password from Keychain.") }
    }
}

/// Resumes a continuation exactly once, whether the result or a cancellation arrives first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early { finished = true; lock.unlock(); continuation.resume(with: early); return }
        self.continuation = continuation
        lock.unlock()
    }
    func resume(with result: Result<T, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let continuation else { if early == nil { early = result }; lock.unlock(); return }
        finished = true; self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

final class CommandJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if let process = self.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        lock.unlock()
    }

    func run(_ executable: String, _ arguments: [String], timeout: Double) async throws -> (Data, Int32) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: executable)
                    p.arguments = arguments
                    p.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
                    let pipe = Pipe()
                    p.standardOutput = pipe
                    p.standardError = FileHandle.nullDevice
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    do { try p.run(); self.process = p; self.lock.unlock() }
                    catch { self.lock.unlock(); continuation.resume(throwing: AppFailure("The measurement tool could not start.")); return }
                    let deadline = DispatchWorkItem { self.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    deadline.cancel()
                    self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                    if wasCancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(returning: (data, p.terminationStatus)) }
                }
            }
        }, onCancel: { self.cancel() })
    }
}

enum Measurements {
    static func ping(_ host: String) async -> (Double?, Double?, Double?) {
        guard Parsers.validPingHost(host) else { return (nil, nil, nil) }
        do {
            let (data, _) = try await CommandJob().run("/sbin/ping", ["-n", "-c", "4", "-W", "1500", host], timeout: 10)
            let result = Parsers.ping(String(decoding: data, as: UTF8.self))
            return (result.average, result.loss, result.jitter)
        } catch { return (nil, nil, nil) }
    }
}

struct HistoryStore {
    let url: URL
    init(url: URL) { self.url = url }
    init() {
        if let path = ProcessInfo.processInfo.environment["LTEWATCH_DATA_DIR"] {
            url = URL(fileURLWithPath: path).appendingPathComponent("history.json")
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LTEWatch/history.json")
        }
    }
    func load() throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else { return Archive() }
        return try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
    }
    func save(_ archive: Archive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Compact output: the whole year of history is rewritten after every observation.
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
    static func csv(_ samples: [Sample]) -> String {
        let formatter = ISO8601DateFormatter()
        func n(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        let rows = samples.map { s in
            [formatter.string(from: s.date), s.kind, n(s.ping), n(s.gatewayPing), n(s.loss), n(s.jitter),
             n(s.radio?.rsrp), n(s.radio?.rsrq), n(s.radio?.snr),
             "\"" + s.note.replacingOccurrences(of: "\"", with: "\"\"") + "\""].joined(separator: ",")
        }
        return "timestamp,kind,internet_ping_ms,router_ping_ms,packet_loss_percent,ping_stddev_ms,rsrp_dbm,rsrq_db,snr_db,note\n" + rows.joined(separator: "\n") + "\n"
    }
}
