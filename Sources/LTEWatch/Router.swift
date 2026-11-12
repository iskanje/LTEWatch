import Foundation
import Security
import CryptoKit
import CommonCrypto

enum RouterResponse {
    static func object(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    // JSON is decoded as data; legacy JavaScript is matched without executing it.
    static func value(_ names: [String], in text: String) -> String? {
        if let object = object(text) {
            for name in names {
                if let value = object[name] as? String { return value }
                if let value = object[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
            }
            return nil
        }
        for name in names {
            let prefix = #"(?:^|[\s;,{])(?:var\s+|let\s+|const\s+)?["']?"# + NSRegularExpression.escapedPattern(for: name) + #"["']?\s*[:=]\s*"#
            if let value = capture(prefix + #"["']([^"'\r\n]*)["']"#, in: text) { return value }
            if let value = capture(prefix + #"(-?\d+)(?=\s*[,;}\r\n]|\s*$)"#, in: text) { return value }
        }
        return nil
    }

    static func resultCode(_ text: String) -> Int? {
        if let value = value(["ret"], in: text) { return Int(value) }
        return capture(#"\$\.ret\s*=\s*(-?\d+)\s*;?"#, in: text).flatMap(Int.init)
    }

    static func token(_ text: String) -> String? {
        let candidate = value(["token", "tokenid", "TokenID"], in: text)
            ?? capture(#"(?i)\b(?:token|tokenid)\s*=\s*["']([^"'\r\n]+)["']"#, in: text)
        guard let candidate, !candidate.isEmpty, candidate.count <= 256,
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        return candidate
    }

    static func unsupportedDescription(_ text: String) -> String {
        // Report only a fixed protocol classification. Never include router values or raw responses.
        if let object = object(text) {
            if object["eccPubKey_X_HEX"] != nil || object["eccPubKey_Y_HEX"] != nil {
                return "This firmware uses ECC login, which LTEWatch does not support yet. No login was attempted. [ECC]"
            }
            let fields = ["nn", "modulus", "ee", "exponent", "seq", "ret"].filter { object[$0] != nil }.joined(separator: ", ")
            return "Could not read the router's login parameters. No login was attempted. [JSON fields: \(fields.isEmpty ? "none recognized" : fields)]"
        }
        let kind = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? "HTML" : "legacy or unknown"
        return "Could not read the router's login parameters. No login was attempted. [\(kind)]"
    }
}

struct RouterLoginParameters {
    let modulus: Data
    let exponent: Data
    let sequence: Int

    init(_ response: String) throws {
        if let code = RouterResponse.resultCode(response), code != 0 {
            throw AppFailure("The router refused login-parameter retrieval (code \(code)). No login was attempted.")
        }
        func hexInteger(_ name: [String]) -> Data? {
            guard var value = RouterResponse.value(name, in: response)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            if value.lowercased().hasPrefix("0x") { value.removeFirst(2) }
            if value.count % 2 != 0 { value = "0" + value }
            guard value.count <= 1024, var bytes = RouterCipher.hex(value), !bytes.isEmpty else { return nil }
            while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
            return bytes
        }
        guard let modulus = hexInteger(["nn", "modulus"]), (64...512).contains(modulus.count),
              let exponent = hexInteger(["ee", "exponent"]), (1...8).contains(exponent.count), exponent.contains(where: { $0 != 0 }),
              let sequenceText = RouterResponse.value(["seq"], in: response),
              let sequence = Int(sequenceText), sequence >= 0, sequence <= Int.max - 1_000_000 else {
            throw AppFailure(RouterResponse.unsupportedDescription(response))
        }
        self.modulus = modulus; self.exponent = exponent; self.sequence = sequence
    }
}

// Native implementation of the MR-series local wire protocol. See README sources.
// Only login, read-only LTE queries, and logout are implemented.
struct RouterCipher {
    let key: Data
    let iv: Data
    let publicKey: SecKey
    let passwordHash: String
    let sequence: Int

    init(password: String, parameters: String) throws {
        let parsed = try RouterLoginParameters(parameters)
        self.sequence = parsed.sequence
        key = Data((0..<16).map { _ in UInt8.random(in: 48...57) })
        iv = Data((0..<16).map { _ in UInt8.random(in: 48...57) })
        passwordHash = Insecure.MD5.hash(data: Data(("admin" + password).utf8)).map { String(format: "%02x", $0) }.joined()
        let body = Self.derInteger(parsed.modulus) + Self.derInteger(parsed.exponent)
        let der = Data([0x30]) + Self.derLength(body.count) + body
        var error: Unmanaged<CFError>?
        guard let rsa = SecKeyCreateWithData(der as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: parsed.modulus.count * 8
        ] as CFDictionary, &error) else { throw AppFailure("Could not read the router's public key.") }
        publicKey = rsa
    }

    static func hex(_ value: String) -> Data? {
        guard value.count % 2 == 0 else { return nil }
        let chars = Array(value)
        var result = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
    static func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var n = count
        var bytes: [UInt8] = []
        while n > 0 { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func derInteger(_ bytes: Data) -> Data {
        let b = (bytes.first ?? 0) >= 128 ? Data([0]) + bytes : bytes
        return Data([2]) + derLength(b.count) + b
    }
    static func aes(_ data: Data, key: Data, iv: Data, decrypt: Bool) throws -> Data {
        guard key.count == 16, iv.count == 16, !decrypt || (!data.isEmpty && data.count % 16 == 0) else {
            throw AppFailure("The router returned an incomplete encrypted response.")
        }
        var result = Data(count: data.count + 16)
        let capacity = result.count
        var count = 0
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                                input.baseAddress, data.count, output.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw AppFailure("The router's encrypted response could not be read. Firmware compatibility needs checking.") }
        result.count = count
        return result
    }
    func encode(_ message: String, login: Bool = false) throws -> (data: String, sign: String) {
        let data = try Self.aes(Data(message.utf8), key: key, iv: iv, decrypt: false).base64EncodedString()
        var signature = "h=\(passwordHash)&s=\(sequence + data.count)"
        if login { signature = "key=\(String(decoding: key, as: UTF8.self))&iv=\(String(decoding: iv, as: UTF8.self))&" + signature }
        let bytes = Array(signature.utf8)
        let width = SecKeyGetBlockSize(publicKey)
        var encrypted = Data()
        for start in stride(from: 0, to: bytes.count, by: width) {
            var chunk = Data(bytes[start..<min(start + width, bytes.count)])
            chunk.append(Data(repeating: 0, count: width - chunk.count))
            var error: Unmanaged<CFError>?
            guard let block = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionRaw, chunk as CFData, &error) else {
                throw AppFailure("Could not encode the router login request.")
            }
            encrypted.append(block as Data)
        }
        return (data, encrypted.map { String(format: "%02x", $0) }.joined())
    }
    func decode(_ text: String) throws -> String {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AppFailure("The router returned an unexpected response. The management session may have expired.")
        }
        return String(decoding: try Self.aes(data, key: key, iv: iv, decrypt: true), as: UTF8.self)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor RouterClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let host: String
    private let session: URLSession
    private let transport: Transport?
    private var cipher: RouterCipher?
    private var token: String?
    private var signedIn = false
    private var stack = "2,1,0,0,0,0"

    init(host: String, configuration: URLSessionConfiguration? = nil, transport: Transport? = nil) throws {
        guard Parsers.privateIPv4(host) else { throw AppFailure("Enter the router's local IPv4 address, such as 192.168.1.1.") }
        self.host = host
        self.transport = transport
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        if let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "loginErrorShow", .value: "1"]) {
            config.httpCookieStorage?.setCookie(cookie)
        }
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func request(_ path: String, method: String = "POST", body: String? = nil, query: [URLQueryItem] = []) async throws -> String {
        var components = URLComponents(string: "http://\(host)/\(path)")!
        components.queryItems = query + [URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 LTEWatch/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue(token, forHTTPHeaderField: "TokenID") }
        do {
            let (data, response): (Data, URLResponse)
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await session.data(for: request) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 2_000_000 else {
                throw AppFailure("The router rejected a status request. Check its address and whether the web interface is available.")
            }
            if let t = response.value(forHTTPHeaderField: "TokenID") { token = t }
            return String(decoding: data, as: UTF8.self)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AppFailure { throw error }
        catch { throw AppFailure("Could not reach the router. Check Wi-Fi/Ethernet, the router address, and macOS Local Network permission.") }
    }

    func login(password: String) async throws {
        _ = try await request("", method: "GET")
        let parameters = try await request("cgi/getParm")
        let busy = try await request("cgi/getBusy")
        func flag(_ name: String) -> Int? {
            RouterResponse.value([name], in: busy).flatMap(Int.init)
        }
        guard let logged = flag("isLogined"), (0...1).contains(logged),
              let working = flag("isBusy"), (0...1).contains(working) else {
            throw AppFailure("Could not verify whether the router is busy. Login was skipped.")
        }
        // MR600 firmware permits login when isLogined == 0, even if isBusy == 1.
        // Its login page only consults isBusy after confirming a session takeover.
        // We never take over a session; isBusy alone does not identify one.
        guard logged == 0 else {
            throw AppFailure("Router check skipped: another management session is active. Log out of the router webpage or Tether and try again.")
        }
        cipher = try RouterCipher(password: password, parameters: parameters)
        let payload = try cipher!.encode("admin\n" + password, login: true)
        // From here the router may hold a session even if its reply is lost, so logout must be attempted.
        signedIn = true
        let reply = try await request("cgi/login", query: [
            URLQueryItem(name: "data", value: payload.data), URLQueryItem(name: "sign", value: payload.sign),
            URLQueryItem(name: "Action", value: "1"), URLQueryItem(name: "LoginStatus", value: "0"), URLQueryItem(name: "isMobile", value: "0")
        ])
        let ret = RouterResponse.resultCode(reply)
        guard ret == 0 else {
            if ret != nil { signedIn = false }
            throw AppFailure("Router login was not accepted (\(ret.map(String.init) ?? "unknown response")). Automatic LTE checks are paused; verify the password and firmware before saving settings again.", rejectedLogin: true)
        }
        let page = try await request("", method: "GET")
        token = RouterResponse.token(page) ?? token
        guard token != nil else { throw AppFailure("Login succeeded but no status token was returned. Firmware compatibility needs checking.") }
        // Discover which WAN stack belongs to LTE, without reading client lists or configuration backups.
        let discovery = try await action(type: 5, oid: "WAN_COMMON_INTF_CFG", stack: "0,0,0,0,0,0", attributes: ["WANAccessType"])
        var current: String?
        for line in discovery.components(separatedBy: .newlines) {
            if let found = capture(#"^\[([0-9,]+)\]"#, in: line) { current = found }
            if line == "WANAccessType=LTE", let current {
                var parts = current.split(separator: ",").map(String.init)
                if parts.count == 6 { parts[1] = "1"; stack = parts.joined(separator: ",") }
            }
        }
    }

    private func action(type: Int = 1, oid: String, stack: String, attributes: [String]) async throws -> String {
        guard let cipher else { throw AppFailure("Router is not connected.") }
        let plain = "\(type)\r\n[\(oid)#\(stack)#0,0,0,0,0,0]0,\(attributes.count)\r\n" + attributes.joined(separator: "\r\n") + "\r\n"
        let payload = try cipher.encode(plain)
        let response = try await request("cgi_gdpr", body: "sign=\(payload.sign)\r\ndata=\(payload.data)\r\n")
        let decoded = try cipher.decode(response)
        if let code = capture(#"\[error\](-?\d+)"#, in: decoded), code != "0" {
            throw AppFailure("The router could not supply LTE status (code \(code)).")
        }
        if let code = capture(#"\$\.ret\s*=\s*(-?\d+)"#, in: decoded), code != "0" {
            throw AppFailure("The router could not supply LTE status (code \(code)).")
        }
        return decoded
    }

    func readRadio() async throws -> Radio {
        try Parsers.radio(await action(oid: "LTE_NET_STATUS", stack: stack, attributes: ["sigLevel", "rfInfoRsrp", "rfInfoRsrq", "rfInfoSnr"]))
    }

    func logout() async {
        if signedIn, cipher != nil {
            if token == nil, let page = try? await request("", method: "GET") { token = RouterResponse.token(page) }
            _ = try? await action(type: 8, oid: "/cgi/logout", stack: "0,0,0,0,0,0", attributes: [])
        }
        token = nil
        signedIn = false
        cipher = nil
        session.invalidateAndCancel()
    }
}
