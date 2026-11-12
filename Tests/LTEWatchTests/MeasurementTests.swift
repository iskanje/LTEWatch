import Foundation
import Security

final class MeasurementTests {
    func testPingLossAndStandardDeviation() {
        let p = Parsers.ping("4 packets transmitted, 3 packets received, 25.0% packet loss\nround-trip min/avg/max/stddev = 22.100/34.500/61.200/8.100 ms")
        checkEqual(p.average, 34.5)
        checkEqual(p.loss, 25)
        checkEqual(p.jitter, 8.1)
        let offline = Parsers.ping("4 packets transmitted, 0 packets received, 100.0% packet loss")
        checkNil(offline.average)
        checkEqual(offline.loss, 100)
    }
    // History saved by builds with speed tests still loads; the old speed fields are ignored and not exported.
    func testHistoryWithOldSpeedTestFieldsStillLoads() throws {
        let old = #"{"configuration":{"routerHost":"192.168.1.1","pingHost":"1.1.1.1","intervalMinutes":5,"enabled":true,"routerEnabled":true,"routerPaused":false},"samples":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":700000000,"kind":"speed test","ping":25,"download":52.5,"upload":9.1,"note":""}]}"#
        let archive = try JSONDecoder().decode(Archive.self, from: Data(old.utf8))
        checkEqual(archive.samples.count, 1)
        checkEqual(archive.samples[0].ping, 25)
        let csv = HistoryStore.csv(archive.samples)
        checkFalse(csv.contains("download") || csv.contains("upload") || csv.contains("52.500"), "CSV must not include speed columns")
        let resaved = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        checkFalse(resaved.contains("download") || resaved.contains("upload"), "Re-saved history must not keep speed fields")
    }
    func testRadioUnitsAndSentinelValues() throws {
        let radio = try Parsers.radio("[2,1,0,0,0,0]0\r\nsigLevel=75\r\nrfInfoRsrp=-97\r\nrfInfoRsrq=-11\r\nrfInfoSnr=145\r\n[error]0")
        checkEqual(radio.rsrp, -97)
        checkEqual(radio.rsrq, -11)
        checkEqual(radio.snr, 14.5)
        checkThrows(try Parsers.radio("rfInfoRsrp=-999\nrfInfoRsrq=-999\nrfInfoSnr=-999"))
    }
    func testRouterAddressBoundaries() {
        for host in ["192.168.1.1", "10.0.0.1", "172.16.0.1", "172.31.255.254"] { checkTrue(Parsers.privateIPv4(host), host) }
        for host in ["1.1.1.1", "172.32.0.1", "172.15.0.1", "192.168.1.1@evil.com", "192.168.1.256", "192.168.01.1", "127.0.0.1"] { checkFalse(Parsers.privateIPv4(host), host) }
        checkFalse(Parsers.validPingHost("-f"))
        checkFalse(Parsers.validPingHost("a;echo hello"))
    }
    func testScheduleAndHistoryPersistence() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for minutes in [1, 7, 20, 25, 30, 45, 60] {
            checkEqual(Configuration.parseInterval(String(minutes)), minutes)
            checkEqual(Configuration.nextDate(after: now, minutes: minutes).timeIntervalSince(now), Double(minutes * 60))
        }
        checkEqual(Configuration.parseInterval(" 17 "), 17)
        for invalid in ["", "0", "61", "-1", "1.5", "abc", "999999999999999999999"] {
            checkNil(Configuration.parseInterval(invalid))
        }
        var configuration = Configuration()
        configuration.intervalMinutes = 7
        let archive = Archive(configuration: configuration, samples: [Sample(date: now, kind: "scheduled", ping: 22), Sample(date: now.addingTimeInterval(600), kind: "manual", ping: 25, radio: Radio(rsrp: -86))])
        let restored = try JSONDecoder().decode(Archive.self, from: JSONEncoder().encode(archive))
        checkNil(restored.samples[0].radio)
        checkEqual(restored.samples[1].ping, 25)
        checkEqual(restored.samples[1].date, now.addingTimeInterval(600))
        checkFalse(restored.configuration.enabled)
        checkEqual(restored.configuration.intervalMinutes, 7)
        let csv = HistoryStore.csv(restored.samples)
        checkTrue(csv.hasPrefix("timestamp,kind,internet_ping_ms,router_ping_ms,packet_loss_percent,ping_stddev_ms,rsrp_dbm,rsrq_db,snr_db,note\n"))
        checkTrue(csv.contains(",manual,25.000,,,,-86.000,,,\"\""))
    }
    func testScheduleSummary() {
        var configuration = Configuration()
        configuration.intervalMinutes = 5
        checkEqual(configuration.scheduleSummary, "Automatic checks paused")
        configuration.enabled = true
        checkEqual(configuration.scheduleSummary, "Every 5 min")
        configuration.nextCheck = Date(timeIntervalSince1970: 1_700_000_000)
        checkTrue(configuration.scheduleSummary.hasPrefix("Every 5 min · next "), configuration.scheduleSummary)
    }
    func testConnectionStatusVerdicts() {
        let radio = Radio(rsrp: -86, rsrq: -10, snr: 12)
        func status(_ ping: Double?, loss: Double? = 0, radio: Radio? = radio, router: Bool = true) -> ConnectionStatus {
            ConnectionStatus(Sample(kind: "scheduled", ping: ping, loss: loss, radio: radio), routerEnabled: router)
        }
        checkEqual(ConnectionStatus(nil, routerEnabled: true), .notChecked)
        checkEqual(status(21), .good)
        checkEqual(status(nil, loss: 100), .offline)
        checkEqual(status(nil, loss: nil), .offline)
        checkEqual(status(30, loss: 25), .unstable)
        checkEqual(status(150), .slow)
        checkEqual(status(21, radio: Radio(rsrp: -105)), .weakSignal)
        checkEqual(status(21, radio: nil), .lteUnavailable)
        checkEqual(status(21, radio: nil, router: false), .good)
        checkEqual(status(150, loss: 25, radio: nil), .unstable)
        checkEqual(ConnectionStatus.offline.title, "No Connection")
    }
    func testSignalScalesKeepThresholdsAndReadingsVisible() {
        for metric in ["RSRP", "RSRQ", "SNR"] {
            let scale = SignalScale.of(metric)
            checkTrue(scale.good < scale.excellent, metric)
            checkTrue(scale.base.contains(scale.good) && scale.base.contains(scale.excellent), metric)
            checkEqual(scale.domain(including: []), scale.base)
        }
        let rsrp = SignalScale.of("RSRP")
        checkEqual(rsrp.excellent, -80)
        checkEqual(rsrp.domain(including: [-97, -86]), rsrp.base)
        let wide = rsrp.domain(including: [-140, -45])
        checkTrue(wide.contains(-140) && wide.contains(-45), "Out-of-range readings must stay visible")
        checkEqual(SignalScale.of("SNR").good, 4.5)
        checkEqual(SignalScale.of("RSRQ").unit, "dB")
    }
    func testScheduleResumesOnLaunchWithoutBurst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var stale = Configuration()
        stale.nextCheck = now.addingTimeInterval(-3600)
        stale.resumeSchedule(at: now)
        checkTrue(stale.enabled, "Checks must run whenever the app runs")
        checkEqual(stale.nextCheck, now.addingTimeInterval(30))
        var fresh = Configuration()
        fresh.nextCheck = now.addingTimeInterval(240)
        fresh.resumeSchedule(at: now)
        checkEqual(fresh.nextCheck, now.addingTimeInterval(240))
    }
    func testHistoryIsSavedCompactlyAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LTEWatch-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.json"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(Archive(samples: [Sample(date: now, kind: "scheduled", ping: 22), Sample(date: now, kind: "manual", ping: 30)]))
        let text = try String(contentsOf: store.url, encoding: .utf8)
        checkFalse(text.contains("\n"), "History should be written without pretty-printing")
        let restored = try store.load()
        checkEqual(restored.samples.count, 2)
        checkEqual(restored.samples[0].ping, 22)
        checkEqual(restored.samples[1].ping, 30)
    }
    func testAESCBCNISTVectorAndRoundTrip() throws {
        let key = RouterCipher.hex("2b7e151628aed2a6abf7158809cf4f3c")!
        let iv = RouterCipher.hex("000102030405060708090a0b0c0d0e0f")!
        let plaintext = RouterCipher.hex("6bc1bee22e409f96e93d7e117393172a")!
        let encoded = try RouterCipher.aes(plaintext, key: key, iv: iv, decrypt: false)
        checkEqual(encoded.prefix(16), RouterCipher.hex("7649abac8119b246cee98e9b12e9197d")!)
        checkEqual(try RouterCipher.aes(encoded, key: key, iv: iv, decrypt: true), plaintext)
        checkThrows(try RouterCipher.aes(encoded.dropLast(), key: key, iv: iv, decrypt: true))
    }
    func testNativeRSARawRouterSignature() throws {
        // Public, deterministic test-only RSA fixture. No Keychain or key generation.
        let values = TestRSA.values
        let privateKey = try TestRSA.privateKey()
        var error: Unmanaged<CFError>?
        let cipher = try RouterCipher(password: "test-only-password", parameters: "var nn=\"\(values[1])\"; var ee=\"010001\"; var seq=\"100\";")
        let payload = try cipher.encode("admin\ntest-only-password", login: true)
        checkEqual(try cipher.decode(payload.data), "admin\ntest-only-password")
        let encrypted = RouterCipher.hex(payload.sign)!
        var plain = Data()
        for start in stride(from: 0, to: encrypted.count, by: 64) {
            let block = encrypted.subdata(in: start..<start+64)
            guard let decrypted = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionRaw, block as CFData, &error) else { throw AppFailure("Test RSA decryption failed") }
            plain.append(decrypted as Data)
        }
        let signature = String(decoding: plain, as: UTF8.self)
        checkTrue(signature.hasPrefix("key="))
        checkTrue(signature.contains("&s=\(100 + payload.data.count)"))
        checkFalse(signature.contains("test-only-password"))
    }
    func testUnknownLoginFormatDoesNotCreateCipher() {
        checkThrows(try RouterCipher(password: "not-sent", parameters: #"{"eccPubKey_X_HEX":"abc"}"#))
    }
}

enum TestRSA {
    static let values = ["00", "a4ac6235b90521ecad790d5fc4e2e9c0963c70ee96abf496feb0fc393814c429ef37f4c88266bb2918ba45071caf301e828d03d2213a706676cdf35e9215f049", "010001", "8b9593a9f62b63963b7560e0cd038b20b4388781b6360c1df1c614066c832dc2fbb536c2d209035865c2e3744b2a14cae9d9838f895190d3b3a394f902d791", "a9fdd0040c47861eb8a67beab9a496b34ef2cc2ef62dd8c2423a8cd98c11808d", "f7fdbec20fb9f286f10ebab32d395895ad89326f33731b9945b8d127203095ad", "6a4d7d82ba8713b92c7177f65e272dd26da169cc48487d4f658925c179550c95", "1d0ea74e57c762ea7ace4e03f69594929d2dc9320c663d629d2fc599ff049255", "49b57d316f4502d90c6a0f29b2d2e42807c9adc84f1e1c759cfa02082de48014"]
    static func privateKey() throws -> SecKey {
        let body = values.reduce(Data()) { data, hex in
            data + RouterCipher.derInteger(RouterCipher.hex(hex.count % 2 == 0 ? hex : "0" + hex)!)
        }
        let der = Data([0x30]) + RouterCipher.derLength(body.count) + body
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 512] as CFDictionary, &error) else {
            throw AppFailure("Could not import the test-only RSA fixture")
        }
        return key
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func checkNil<T>(_ actual: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == nil, "Expected nil", file: file, line: line)
}
func checkTrue(_ actual: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(actual, message, file: file, line: line)
}
func checkFalse(_ actual: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(!actual, message, file: file, line: line)
}
func checkThrows<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try operation(); preconditionFailure("Expected an error", file: file, line: line) } catch {}
}
@main struct MeasurementChecks {
    static func main() async throws {
        let tests = MeasurementTests()
        tests.testPingLossAndStandardDeviation()
        try tests.testHistoryWithOldSpeedTestFieldsStillLoads()
        try tests.testRadioUnitsAndSentinelValues()
        tests.testRouterAddressBoundaries()
        try tests.testScheduleAndHistoryPersistence()
        try tests.testHistoryIsSavedCompactlyAndReloads()
        tests.testScheduleSummary()
        tests.testScheduleResumesOnLaunchWithoutBurst()
        tests.testConnectionStatusVerdicts()
        tests.testSignalScalesKeepThresholdsAndReadingsVisible()
        try tests.testAESCBCNISTVectorAndRoundTrip()
        try tests.testNativeRSARawRouterSignature()
        tests.testUnknownLoginFormatDoesNotCreateCipher()
        try ProtocolChecks.parameterVariants()
        ProtocolChecks.replyVariants()
        try ProtocolChecks.badParameters()
        try await ProtocolChecks.fullExchange(json: true)
        try await ProtocolChecks.fullExchange(json: false)
        try await ProtocolChecks.fullExchange(json: true, working: 1)
        try await ProtocolChecks.fullExchange(json: false, working: 1)
        try await ProtocolChecks.busySession()
        try await ProtocolChecks.rejectedPassword()
        try await ProtocolChecks.lostLoginReply()
        try await ProtocolChecks.cancelledRequest()
        try await ProtocolChecks.backgroundKeychainRead()
        print("PASS: 25 checks, including idle isBusy=1, active-session protection and lost-login-reply logout")
    }
}
