import SwiftUI
import AppKit

@MainActor
final class Monitor: ObservableObject {
    let isPreview = ProcessInfo.processInfo.arguments.contains("--preview")
    @Published var configuration: Configuration
    @Published var samples: [Sample]
    @Published var busy = false
    @Published var status = "Ready when you are"
    @Published var message: String?
    @Published var saveError: String?
    @Published var exportNotice: String?
    private let storage = HistoryStore()
    private let saveQueue = DispatchQueue(label: "local.LTEWatch.history", qos: .utility)
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var loaded = true
    private var exportPanel: NSSavePanel?

    init() {
        do {
            let archive = try storage.load()
            configuration = archive.configuration
            samples = archive.samples
        } catch {
            configuration = Configuration(); samples = []; loaded = false
            saveError = "Saved history could not be read. The original file has been preserved."
        }
        if isPreview { configuration.enabled = false; loaded = false }
        // Automatic checks run whenever the app is running.
        else { configuration.resumeSchedule(at: Date()) }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 5
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.operation?.cancel() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                if self.configuration.enabled {
                    self.configuration.resumeSchedule(at: Date())
                    self.persist()
                }
            }
        })
    }

    var latest: Sample? { samples.last }
    var menuLabel: String {
        if let p = latest?.ping { return "\(Int(p.rounded())) ms" }
        return "LTEWatch"
    }

    func persist() {
        guard loaded else { return }
        // Encode and write a snapshot off the main thread; the serial queue keeps writes in order.
        let archive = Archive(configuration: configuration, samples: samples)
        let storage = storage
        saveQueue.async { [weak self] in
            let failed: Bool
            do { try storage.save(archive); failed = false } catch { failed = true }
            Task { @MainActor in self?.saveError = failed ? "Could not save history to disk. New results remain in memory." : nil }
        }
    }
    func tick() {
        guard configuration.enabled, !sleeping, !busy, let next = configuration.nextCheck, next <= Date() else { return }
        startCheck(kind: "scheduled")
    }
    func saveSettings(host: String, pingHost: String, interval: Int, routerEnabled: Bool, password: String) throws {
        guard !isPreview else { throw AppFailure("Settings are disabled in the example preview.") }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pingHost = pingHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Parsers.privateIPv4(host) else { throw AppFailure("Enter a local router IPv4 address, for example 192.168.1.1.") }
        guard Parsers.validPingHost(pingHost) else { throw AppFailure("Enter a valid ping hostname or IP address.") }
        guard Configuration.intervalRange.contains(interval) else { throw AppFailure("Enter a whole number from 1 to 60 minutes.") }
        let oldHost = configuration.routerHost
        if routerEnabled {
            if !password.isEmpty { try Credentials.save(password, host: host) }
            if try Credentials.read(host) == nil { throw AppFailure("Enter the local router administrator password to enable LTE readings.") }
        } else {
            // LTE readings are off, so no password needs to stay in Keychain.
            try Credentials.delete(host)
        }
        if oldHost != host { try? Credentials.delete(oldHost) }
        configuration.routerHost = host
        configuration.pingHost = pingHost
        configuration.routerEnabled = routerEnabled
        configuration.routerPaused = false
        configuration.intervalMinutes = interval
        if configuration.enabled { configuration.nextCheck = Configuration.nextDate(after: Date(), minutes: configuration.intervalMinutes) }
        persist()
        message = nil
    }

    private func connectRouter() async -> RouterClient? {
        guard !Task.isCancelled else { return nil }
        guard configuration.routerEnabled else { return nil }
        guard !configuration.routerPaused else { message = "LTE login paused. Verify your credentials and save Settings to retry."; return nil }
        var client: RouterClient?
        do {
            guard let password = try await Credentials.readInBackground(configuration.routerHost) else { throw AppFailure("No router password in Keychain. Open Settings to add it.") }
            client = try RouterClient(host: configuration.routerHost)
            try await client!.login(password: password)
            return client
        } catch {
            if (error as? AppFailure)?.rejectedLogin == true {
                configuration.routerPaused = true; persist()
            }
            if !(error is CancellationError) { message = error.localizedDescription }
            if let client { await Task { await client.logout() }.value }
            return nil
        }
    }

    private func readRadio(_ router: RouterClient?) async -> Radio? {
        guard let router else { return nil }
        do {
            return try await router.readRadio()
        } catch {
            if !(error is CancellationError) { message = error.localizedDescription }
            return nil
        }
    }

    func startCheck(kind: String = "manual") {
        guard !busy, !isPreview else { return }
        busy = true; message = nil; status = "Checking ping and LTE…"
        if kind == "scheduled" {
            configuration.nextCheck = Configuration.nextDate(after: Date(), minutes: configuration.intervalMinutes)
            persist()
        }
        operation = Task {
            let date = Date()
            async let internet = Measurements.ping(configuration.pingHost)
            async let gateway = Measurements.ping(configuration.routerHost)
            // Finish both latency samples before router authentication or LTE queries.
            let (ping, loss, jitter) = await internet
            let (gatewayPing, _, _) = await gateway
            let router = await connectRouter()
            let radio = await readRadio(router)
            if let router { await Task { await router.logout() }.value }
            if !Task.isCancelled {
                append(Sample(date: date, kind: kind, ping: ping, gatewayPing: gatewayPing, loss: loss, jitter: jitter, radio: radio, note: message ?? ""))
                status = "Check saved"
            } else { status = "Check cancelled" }
            busy = false; operation = nil
        }
    }

    func cancel() { operation?.cancel(); status = "Stopping and releasing router session…" }
    private func append(_ sample: Sample) {
        samples.append(sample)
        // Keep one year, including failures. No interpolation across missing observations.
        samples.removeAll { $0.date < Date().addingTimeInterval(-366 * 86400) }
        persist()
    }
    func exportCSV() {
        if let panel = exportPanel {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        exportNotice = nil
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LTEWatch-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        exportPanel = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            defer { self.exportPanel = nil }
            guard response == .OK, let url = panel?.url else { return }
            do {
                try HistoryStore.csv(self.samples).write(to: url, atomically: true, encoding: .utf8)
                self.exportNotice = "Exported \(self.samples.count) observations to \(url.lastPathComponent)."
            } catch {
                self.exportNotice = "Could not export CSV: \(error.localizedDescription)"
            }
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
    func quit() {
        operation?.cancel()
        Task {
            await operation?.value
            // Let any pending history write finish before quitting.
            await withCheckedContinuation { continuation in saveQueue.async { continuation.resume() } }
            NSApplication.shared.terminate(nil)
        }
    }
}
