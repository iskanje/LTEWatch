import Foundation
import Security

enum ProtocolChecks {
    static func parameterVariants() throws {
        let n = TestRSA.values[1]
        let variants = [
            "{\"nn\":\"\(n)\",\"ee\":\"010001\",\"seq\":123,\"ret\":0}",
            "{\"nn\":\"\(n)\",\"ee\":\"10001\",\"seq\":\"123\"}",
            "{\"modulus\":\"0x\(n)\",\"exponent\":\"10001\",\"seq\":123}",
            "var nn = '\(n)';\nvar ee = '010001';\nvar seq = 123;\n$.ret=0;",
            "{nn:'\(n)', ee:'10001', seq:123}"
        ]
        for text in variants {
            let parsed = try RouterLoginParameters(text)
            checkEqual(parsed.modulus, RouterCipher.hex(n)!)
            checkEqual(parsed.exponent, RouterCipher.hex("010001")!)
            checkEqual(parsed.sequence, 123)
            let cipher = try RouterCipher(password: "fixture-only", parameters: text)
            let payload = try cipher.encode("example")
            checkEqual(try cipher.decode(payload.data), "example")
        }
    }
    static func replyVariants() {
        checkEqual(RouterResponse.resultCode("{\"ret\":0}"), 0)
        checkEqual(RouterResponse.resultCode("{\"ret\":\"71233\"}"), 71233)
        checkEqual(RouterResponse.resultCode("$.ret=0;"), 0)
        checkNil(RouterResponse.resultCode("<html>Login</html>"))
        checkEqual(RouterResponse.token("<script>var tokenid = 'fixture-token';</script>"), "fixture-token")
        checkEqual(RouterResponse.token("{\"TokenID\":\"fixture-token\"}"), "fixture-token")
        checkEqual(RouterResponse.value(["isBusy"], in: "{\"isBusy\":0}"), "0")
    }
    static func badParameters() throws {
        for text in [
            "{\"nn\":\"badhex\",\"ee\":\"10001\",\"seq\":1}",
            "{\"nn\":\"\(TestRSA.values[1])\",\"ee\":\"10001\",\"seq\":1.5}",
            "{\"nn\":\"\(TestRSA.values[1])\",\"ee\":\"10001\",\"seq\":true}",
            "{\"nn\":\"\(TestRSA.values[1])\",\"ee\":\"10001\",\"seq\":1,\"ret\":71234}",
            "<html>Not the router endpoint</html>"
        ] { checkThrows(try RouterLoginParameters(text)) }
        let description = RouterResponse.unsupportedDescription("{\"eccPubKey_X_HEX\":\"secret-value\",\"seq\":100,\"unexpected\":\"private-value\"}")
        checkTrue(description.contains("[ECC]"))
        checkFalse(description.contains("secret-value"))
        checkFalse(description.contains("private-value"))
    }
    static func fullExchange(json: Bool, working: Int = 0) async throws {
        let mock = try MockRouter(json: json, working: working)
        let client = try RouterClient(host: "192.168.1.1", transport: { request in try await mock.respond(request) })
        try await client.login(password: "test-password")
        let radio = try await client.readRadio()
        checkEqual(radio.rsrp, -97)
        checkEqual(radio.snr, 14.5)
        await client.logout()
        let actions = await mock.actions
        checkEqual(actions.count, 3)
        checkTrue(actions[0].hasPrefix("5\r\n[WAN_COMMON_INTF_CFG#"))
        checkTrue(actions[1].hasPrefix("1\r\n[LTE_NET_STATUS#1,1,0,0,0,0#"))
        checkTrue(actions[2].hasPrefix("8\r\n[/cgi/logout#"))
    }
    static func busySession() async throws {
        for working in [0, 1] {
            let mock = try MockRouter(busy: true, working: working)
            let client = try RouterClient(host: "192.168.1.1", transport: { request in try await mock.respond(request) })
            do { try await client.login(password: "test-password"); preconditionFailure("Busy router should not allow login") }
            catch {
                checkTrue(error.localizedDescription.contains("another management session"))
                checkFalse((error as? AppFailure)?.rejectedLogin == true, "A busy router must not pause LTE logins")
            }
            await client.logout()
            let paths = await mock.paths
            checkFalse(paths.contains("/cgi/login"))
            checkFalse(paths.contains("/cgi_gdpr"))
        }
    }
    static func rejectedPassword() async throws {
        let mock = try MockRouter(reject: true)
        let client = try RouterClient(host: "192.168.1.1", transport: { request in try await mock.respond(request) })
        do { try await client.login(password: "test-password"); preconditionFailure("Rejected login should throw") }
        catch {
            checkTrue(error.localizedDescription.contains("71233"))
            checkTrue((error as? AppFailure)?.rejectedLogin == true, "A rejected password must pause LTE logins")
        }
        await client.logout()
        let paths = await mock.paths
        checkEqual(paths.filter { $0 == "/cgi/login" }.count, 1)
        checkFalse(paths.contains("/cgi_gdpr"))
    }
    // The router accepted the login but its reply was lost: logout must still release the session.
    static func lostLoginReply() async throws {
        let mock = try MockRouter(dropLoginReply: true)
        let client = try RouterClient(host: "192.168.1.1", transport: { request in try await mock.respond(request) })
        do { try await client.login(password: "test-password"); preconditionFailure("Lost login reply should throw") }
        catch { checkFalse((error as? AppFailure)?.rejectedLogin == true, "A lost reply is not a rejected password") }
        await client.logout()
        let actions = await mock.actions
        let authenticated = await mock.authenticated
        checkEqual(actions.count, 1)
        checkTrue(actions[0].hasPrefix("8\r\n[/cgi/logout#"))
        checkFalse(authenticated, "Router session should be released")
    }
    // The router password is read off the main thread, and Stop or Quit doesn't wait for a pending Keychain prompt.
    static func backgroundKeychainRead() async throws {
        let value = try await Credentials.readInBackground("192.168.1.1") { host in
            checkFalse(Thread.isMainThread, "Keychain read must not run on the main thread")
            return "fixture-for-\(host)"
        }
        checkEqual(value, "fixture-for-192.168.1.1")
        let prompt = DispatchSemaphore(value: 0)
        let pending = Task { try await Credentials.readInBackground("192.168.1.1") { _ in prompt.wait(); return "late" } }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = Date()
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled read should throw") }
        catch { checkTrue(error is CancellationError, "Expected CancellationError, got \(error)") }
        checkTrue(Date().timeIntervalSince(cancelled) < 1, "Cancelling must not wait for the Keychain prompt")
        prompt.signal()
    }
    // A cancelled URL request (Stop or sleep) surfaces as cancellation, not as an unreachable router.
    static func cancelledRequest() async throws {
        let mock = try MockRouter(cancelAt: "/cgi/getParm")
        let client = try RouterClient(host: "192.168.1.1", transport: { request in try await mock.respond(request) })
        do { try await client.login(password: "test-password"); preconditionFailure("Cancelled request should throw") }
        catch { checkTrue(error is CancellationError, "Expected CancellationError, got \(error)") }
        await client.logout()
        let paths = await mock.paths
        checkFalse(paths.contains("/cgi/login"))
    }
}

actor MockRouter {
    let json: Bool
    let busy: Bool
    let working: Int
    let reject: Bool
    let dropLoginReply: Bool
    let cancelAt: String?
    let rsa: SecKey
    var key = Data()
    var iv = Data()
    var authenticated = false
    var paths: [String] = []
    var actions: [String] = []
    init(json: Bool = true, busy: Bool = false, working: Int = 0, reject: Bool = false, dropLoginReply: Bool = false, cancelAt: String? = nil) throws {
        self.json = json; self.busy = busy; self.working = working; self.reject = reject
        self.dropLoginReply = dropLoginReply; self.cancelAt = cancelAt; rsa = try TestRSA.privateKey()
    }
    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        paths.append(url.path)
        if url.path == cancelAt { throw URLError(.cancelled) }
        var text: String
        switch url.path {
        case "/": text = authenticated ? "<script>var tokenid='fixture-token';</script>" : "<html>Router</html>"
        case "/cgi/getParm":
            text = json ? "{\"nn\":\"\(TestRSA.values[1])\",\"ee\":\"10001\",\"seq\":100,\"ret\":0}"
                : "var nn='\(TestRSA.values[1])';var ee='010001';var seq='100';$.ret=0;"
        case "/cgi/getBusy": text = "{\"isLogined\":\(busy ? 1 : 0),\"isBusy\":\(working)}"
        case "/cgi/login":
            checkEqual(request.httpMethod, "POST")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let encrypted = RouterCipher.hex(query["sign"]!)!
            var decoded = Data()
            for offset in stride(from: 0, to: encrypted.count, by: 64) {
                var error: Unmanaged<CFError>?
                let block = encrypted.subdata(in: offset..<offset+64)
                guard let raw = SecKeyCreateDecryptedData(rsa, .rsaEncryptionRaw, block as CFData, &error) else { throw AppFailure("Test signature was invalid") }
                decoded.append(raw as Data)
            }
            let sign = String(decoding: decoded.filter { $0 != 0 }, as: UTF8.self)
            let fields = Dictionary(uniqueKeysWithValues: sign.split(separator: "&").map { field -> (String, String) in
                let pair = field.split(separator: "=", maxSplits: 1); return (String(pair[0]), String(pair[1]))
            })
            key = Data(fields["key"]!.utf8); iv = Data(fields["iv"]!.utf8)
            checkEqual(fields["s"], String(100 + query["data"]!.count))
            let login = try RouterCipher.aes(Data(base64Encoded: query["data"]!)!, key: key, iv: iv, decrypt: true)
            checkEqual(String(decoding: login, as: UTF8.self), "admin\ntest-password")
            authenticated = !reject
            if dropLoginReply { throw URLError(.timedOut) }
            let result = reject ? 71233 : 0
            text = json ? "{\"ret\":\(result)}" : "$.ret=\(result);"
        case "/cgi_gdpr":
            checkTrue(authenticated)
            checkEqual(request.value(forHTTPHeaderField: "TokenID"), "fixture-token")
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            let encoded = capture(#"(?:^|\r\n)data=([^\r\n]+)"#, in: body)!
            let plain = try RouterCipher.aes(Data(base64Encoded: encoded)!, key: key, iv: iv, decrypt: true)
            let action = String(decoding: plain, as: UTF8.self)
            actions.append(action)
            if action.hasPrefix("5\r\n[WAN_COMMON_INTF_CFG#") { text = "[1,0,0,0,0,0]0\r\nWANAccessType=LTE\r\n[error]0" }
            else if action.hasPrefix("1\r\n[LTE_NET_STATUS#1,1,0,0,0,0#") { text = "[1,1,0,0,0,0]0\r\nsigLevel=75\r\nrfInfoRsrp=-97\r\nrfInfoRsrq=-11\r\nrfInfoSnr=145\r\n[error]0" }
            else if action.hasPrefix("8\r\n[/cgi/logout#") { authenticated = false; text = "$.ret=0;" }
            else { throw AppFailure("Unexpected router action in test") }
            text = try RouterCipher.aes(Data(text.utf8), key: key, iv: iv, decrypt: false).base64EncodedString()
        default: throw AppFailure("Unexpected router endpoint in test")
        }
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
