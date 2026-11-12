import Foundation

struct Configuration: Codable {
    static let intervalRange = 1...60
    var routerHost = "192.168.1.1"
    var pingHost = "1.1.1.1"
    var intervalMinutes = 30
    var enabled = false
    var routerEnabled = false
    var routerPaused = false
    var nextCheck: Date?

    static func parseInterval(_ input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber }),
              let minutes = Int(text), intervalRange.contains(minutes) else { return nil }
        return minutes
    }

    var scheduleSummary: String {
        guard enabled else { return "Automatic checks paused" }
        let next = nextCheck.map { " · next \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "Every \(intervalMinutes) min\(next)"
    }

    /// Turns scheduling on. No burst of overdue checks after launch or wake: the network gets 30 s to settle.
    mutating func resumeSchedule(at now: Date) {
        enabled = true
        nextCheck = max(nextCheck ?? .distantPast, now.addingTimeInterval(30))
    }

    static func nextDate(after date: Date, minutes: Int) -> Date {
        date.addingTimeInterval(Double(intervalRange.contains(minutes) ? minutes : 30) * 60)
    }
}

struct Radio: Codable {
    var rsrp: Double?
    var rsrq: Double?
    var snr: Double?
    var level: Double?
}

struct Sample: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var kind: String
    var ping: Double?
    var gatewayPing: Double?
    var loss: Double?
    var jitter: Double?
    var radio: Radio?
    var note = ""
}

/// Chart scale and approximate thresholds for one LTE measurement (TP-Link's LTE router guide; SNR, not SINR).
struct SignalScale {
    let name: String
    let unit: String
    let good: Double
    let excellent: Double
    /// Default visible range, chosen so the thresholds sit in the readable middle of the chart.
    let base: ClosedRange<Double>

    static func of(_ metric: String) -> SignalScale {
        switch metric {
        case "RSRQ": return SignalScale(name: "Quality (RSRQ)", unit: "dB", good: -15, excellent: -10, base: -25...0)
        case "SNR": return SignalScale(name: "Signal-to-noise (SNR)", unit: "dB", good: 4.5, excellent: 13, base: -10...30)
        default: return SignalScale(name: "Strength (RSRP)", unit: "dBm", good: -90, excellent: -80, base: -125 ... -60)
        }
    }

    /// Legend labels for the excellent, good and poor bands, e.g. "Excellent ≥ -80".
    var bandLabels: (excellent: String, good: String, poor: String) {
        let number = { (value: Double) in value.formatted(.number.precision(.fractionLength(0...1))) }
        return ("Excellent ≥ \(number(excellent))", "Good ≥ \(number(good))", "Poor < \(number(good))")
    }

    /// Widens the default range just enough to keep every reading visible.
    func domain(including values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return base }
        return Swift.min(base.lowerBound, low - 2)...Swift.max(base.upperBound, high + 2)
    }
}

/// One-line verdict for the latest observation, worst problem first.
enum ConnectionStatus: Equatable {
    case notChecked, good, slow, unstable, weakSignal, lteUnavailable, offline
    static let slowPingMs = 100.0
    static let weakRsrpDbm = -100.0

    init(_ sample: Sample?, routerEnabled: Bool) {
        guard let sample else { self = .notChecked; return }
        guard let ping = sample.ping, sample.loss != 100 else { self = .offline; return }
        if (sample.loss ?? 0) > 0 { self = .unstable }
        else if ping > Self.slowPingMs { self = .slow }
        else if let rsrp = sample.radio?.rsrp, rsrp < Self.weakRsrpDbm { self = .weakSignal }
        else if routerEnabled && sample.radio == nil { self = .lteUnavailable }
        else { self = .good }
    }

    var title: String {
        switch self {
        case .notChecked: return "Not Checked Yet"
        case .good: return "Connection Good"
        case .slow: return "Slow Connection"
        case .unstable: return "Unstable Connection"
        case .weakSignal: return "Weak LTE Signal"
        case .lteUnavailable: return "LTE Signal Unavailable"
        case .offline: return "No Connection"
        }
    }

    enum Level { case neutral, ok, warning, problem }
    var level: Level {
        switch self {
        case .notChecked: return .neutral
        case .good: return .ok
        case .slow, .unstable, .weakSignal, .lteUnavailable: return .warning
        case .offline: return .problem
        }
    }
}

struct Archive: Codable {
    var configuration = Configuration()
    var samples: [Sample] = []
}

struct AppFailure: LocalizedError {
    let message: String
    /// The router answered the login itself unsuccessfully; automatic logins pause until Settings are saved.
    let rejectedLogin: Bool
    var errorDescription: String? { message }
    init(_ message: String, rejectedLogin: Bool = false) { self.message = message; self.rejectedLogin = rejectedLogin }
}

func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

enum Parsers {
    static func ping(_ output: String) -> (average: Double?, loss: Double?, jitter: Double?) {
        let average = capture(#"(?:round-trip|rtt)[^=]*=\s*[\d.]+/([\d.]+)/"#, in: output).flatMap(Double.init)
        let loss = capture(#"([\d.]+)% packet loss"#, in: output).flatMap(Double.init)
        let jitter = capture(#"(?:round-trip|rtt)[^=]*=\s*[\d.]+/[\d.]+/[\d.]+/([\d.]+)"#, in: output).flatMap(Double.init)
        return (average, loss, jitter)
    }

    static func radio(_ text: String) throws -> Radio {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        func valid(_ name: String, _ range: ClosedRange<Double>) -> Double? {
            guard let raw = fields[name], let n = Double(raw), n.isFinite, range.contains(n) else { return nil }
            return n
        }
        let result = Radio(rsrp: valid("rfInfoRsrp", -150 ... -30),
                           rsrq: valid("rfInfoRsrq", -40 ... 0),
                           snr: valid("rfInfoSnr", -300 ... 600).map { $0 / 10 },
                           level: valid("sigLevel", 0 ... 100))
        guard result.rsrp != nil || result.rsrq != nil || result.snr != nil else {
            throw AppFailure("The router did not return usable LTE measurements. It may be offline or use a different firmware protocol.")
        }
        return result
    }

    static func privateIPv4(_ input: String) -> Bool {
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let nums = parts.compactMap { UInt8($0) }
        guard nums.count == 4, zip(parts, nums).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
        return nums[0] == 10 || (nums[0] == 192 && nums[1] == 168) || (nums[0] == 172 && (16...31).contains(nums[1]))
    }

    static func validPingHost(_ value: String) -> Bool {
        !value.isEmpty && value.count < 254 && value.first != "-" && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0)
        }
    }
}
