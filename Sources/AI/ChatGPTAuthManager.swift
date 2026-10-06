import Foundation
import Network
import Security
import AppKit
import Combine
import CryptoKit

private struct ChatGPTCredentials: Codable {
    var clientID: String
    var subject: String
    var email: String?
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var scopes: [String]
    var expiresAt: Date
}

private struct DiscoveryDocument: Decodable {
    let issuer: String
    let authorization_endpoint: URL
    let token_endpoint: URL
    let jwks_uri: URL
}

@MainActor
final class ChatGPTAuthManager: ObservableObject {
    static let shared = ChatGPTAuthManager()
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountLabel = "Not signed in"
    @Published private(set) var authStatus = "ChatGPT account required"
    @Published private(set) var modelCatalog: [AvailableModel] = []
    @Published var selectedModel = "" { didSet { UserDefaults.standard.set(selectedModel, forKey: "selected_chatgpt_model") } }

    private let keychainService = "com.wechatreplycopilot.chatgpt"
    private let credentialAccount = "active-account"
    private let hostKey = "chatgpt_ext_agent_host_id_v1"
    private var credentials: ChatGPTCredentials?

    private init() {
        credentials = loadCredentials()
        updatePresentation()
    }

    func signIn() async {
        authStatus = "Opening ChatGPT sign-in…"
        do {
            let discovery = try await loadDiscovery()
            let attempt = try await authorize(discovery: discovery)
            let tokenSet = try await exchange(code: attempt.code, clientID: attempt.clientID, verifier: attempt.verifier, redirectURI: attempt.redirectURI, tokenEndpoint: discovery.token_endpoint)
            let identity = try await validateIDToken(tokenSet.idToken, expectedNonce: attempt.nonce, clientID: attempt.clientID, discovery: discovery)
            if let existing = credentials, existing.clientID == attempt.clientID, existing.subject != identity.subject {
                throw CopilotError.service("The selected ChatGPT account changed during sign-in. Existing credentials were kept.")
            }
            let scopes = tokenSet.scope.split(separator: " ").map(String.init)
            guard scopes.contains("chatgpt.tokens.use.direct") else { throw CopilotError.missingPermission }
            let value = ChatGPTCredentials(clientID: attempt.clientID, subject: identity.subject, email: identity.email,
                                           idToken: tokenSet.idToken, accessToken: tokenSet.accessToken,
                                           refreshToken: tokenSet.refreshToken, scopes: scopes,
                                           expiresAt: Date().addingTimeInterval(TimeInterval(tokenSet.expiresIn)))
            try saveCredentials(value)
            credentials = value
            isSignedIn = true
            accountLabel = value.email ?? "ChatGPT account"
            authStatus = "Signed in · loading account models…"
            try await refreshModels()
        } catch {
            authStatus = error.localizedDescription
        }
    }

    func refreshModels() async throws {
        modelCatalog = try await ChatGPTClient.shared.availableModels()
            .filter { !$0.slug.isEmpty && $0.visibility == "list" }
        guard !modelCatalog.isEmpty else { throw CopilotError.noModels }
        if !modelCatalog.contains(where: { $0.slug == selectedModel }) { selectedModel = modelCatalog[0].slug }
        authStatus = "Signed in · \(modelCatalog.count) models available"
    }

    func validAccessToken() async throws -> String {
        guard let current = credentials else { throw CopilotError.notSignedIn }
        guard current.expiresAt.timeIntervalSinceNow < 60 else { return current.accessToken }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "grant_type": "refresh_token", "client_id": current.clientID,
            "refresh_token": current.refreshToken, "resource": "https://api.openai.com/v1"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CopilotError.service("Could not refresh ChatGPT authorization. Please try again.") }
        guard (200..<300).contains(http.statusCode), let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            if http.statusCode == 400, String(data: data, encoding: .utf8)?.contains("invalid_grant") == true {
                credentials = nil; deleteCredentials()
                throw CopilotError.notSignedIn
            }
            throw CopilotError.service("Could not refresh ChatGPT authorization (HTTP \(http.statusCode)). Please try again.")
        }
        var updated = current
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken.isEmpty ? current.refreshToken : token.refreshToken
        updated.idToken = token.idToken.isEmpty ? current.idToken : token.idToken
        updated.expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        if !token.scope.isEmpty { updated.scopes = token.scope.split(separator: " ").map(String.init) }
        try saveCredentials(updated)
        credentials = updated
        return updated.accessToken
    }

    private struct AuthorizationAttempt { let code, clientID, verifier, nonce, redirectURI: String }
    private struct TokenResponse: Decodable {
        let accessToken: String; let refreshToken: String; let idToken: String; let expiresIn: Int; let scope: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token", expiresIn = "expires_in", scope }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
            idToken = try c.decodeIfPresent(String.self, forKey: .idToken) ?? ""
            expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 3600
            scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        }
    }

    private func authorize(discovery: DiscoveryDocument) async throws -> AuthorizationAttempt {
        let state = randomString(), nonce = randomString(), verifier = randomString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let hostID: String
        if let existing = UserDefaults.standard.string(forKey: hostKey) { hostID = existing }
        else { hostID = "urn:uuid:\(UUID().uuidString.lowercased())"; UserDefaults.standard.set(hostID, forKey: hostKey) }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: CopilotError.service("Could not start the local sign-in callback.")) }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        let redirect = "http://127.0.0.1:\(port.rawValue)/auth/callback"
        let old = credentials
        let requestedClient = old?.clientID ?? "dynamic_agent_client"
        var items = [URLQueryItem(name: "client_id", value: requestedClient),
                     URLQueryItem(name: "ext_agent_host_id", value: hostID),
                     URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: redirect),
                     URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
                     URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
                     URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
                     URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: challenge)]
        if old == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "WeChat Reply Copilot")) }
        var components = URLComponents(url: discovery.authorization_endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else { listener.cancel(); throw CopilotError.service("Could not start ChatGPT sign-in.") }
        let result: [String: String] = try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    guard let data, error == nil, let requestText = String(data: data, encoding: .utf8),
                          let line = requestText.components(separatedBy: "\r\n").first,
                          line.hasPrefix("GET "),
                          let path = line.split(separator: " ").dropFirst().first,
                          let callback = URLComponents(string: "http://127.0.0.1\(path)"),
                          callback.path == "/auth/callback" else {
                        continuation.resume(throwing: CopilotError.service("Invalid local sign-in callback.")); return
                    }
                    let values = Dictionary((callback.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, latest in latest })
                    guard values["state"] == state else {
                        let body = Data("Invalid sign-in callback".utf8)
                        var response = Data("HTTP/1.1 400 Bad Request\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
                        response.append(body)
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    let html = "<html><head><meta name=\"referrer\" content=\"no-referrer\"></head><body><h2>WeChat Reply Copilot</h2><p>You can return to the app.</p><script>history.replaceState(null, \"\", \"/auth/callback\")</script></body></html>"
                    let body = Data(html.utf8)
                    var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
                    response.append(body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    continuation.resume(returning: values)
                }
            }
            NSWorkspace.shared.open(url)
        }
        listener.cancel()
        guard result["state"] == state else { throw CopilotError.service("ChatGPT sign-in state check failed.") }
        if let error = result["error"] { throw CopilotError.service("ChatGPT sign-in was not completed (\(error)).") }
        guard let code = result["code"] else { throw CopilotError.service("ChatGPT did not return an authorization code.") }
        let returnedClient = result["client_id"] ?? old?.clientID
        guard let clientID = returnedClient, clientID != "dynamic_agent_client" else { throw CopilotError.service("ChatGPT did not return a registered client ID.") }
        if let old, result["client_id"] != nil, clientID != old.clientID { throw CopilotError.service("ChatGPT returned a different registered client. Existing credentials were kept.") }
        return AuthorizationAttempt(code: code, clientID: clientID, verifier: verifier, nonce: nonce, redirectURI: redirect)
    }

    private func exchange(code: String, clientID: String, verifier: String, redirectURI: String, tokenEndpoint: URL) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["grant_type": "authorization_code", "client_id": clientID, "code": code,
                                 "code_verifier": verifier, "redirect_uri": redirectURI, "resource": "https://api.openai.com/v1"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CopilotError.service("ChatGPT sign-in token exchange failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func loadDiscovery() async throws -> DiscoveryDocument {
        let url = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(DiscoveryDocument.self, from: data)
    }

    private struct Identity { let subject: String; let email: String? }
    private func validateIDToken(_ token: String, expectedNonce: String, clientID: String, discovery: DiscoveryDocument) async throws -> Identity {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let headerData = Data(base64URL: String(parts[0])),
              let claimsData = Data(base64URL: String(parts[1])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let kid = header["kid"] as? String, let algorithm = header["alg"] as? String,
              let subject = claims["sub"] as? String, let issuer = claims["iss"] as? String,
              let expiry = claims["exp"] as? TimeInterval, let nonce = claims["nonce"] as? String,
              let audience = claims["aud"] as? String ?? (claims["aud"] as? [String])?.first(where: { $0 == clientID }),
              audience == clientID, issuer == discovery.issuer, expiry > Date().timeIntervalSince1970,
              nonce == expectedNonce else { throw CopilotError.service("ChatGPT identity validation failed.") }
        let (keyData, _) = try await URLSession.shared.data(from: discovery.jwks_uri)
        let jwks = try JSONSerialization.jsonObject(with: keyData) as? [String: Any]
        let keys = jwks?["keys"] as? [[String: Any]] ?? []
        guard let jwk = keys.first(where: { $0["kid"] as? String == kid }),
              let publicKey = makePublicKey(jwk, algorithm: algorithm),
              let signature = Data(base64URL: String(parts[2])),
              verify(signature: signature, data: Data("\(parts[0]).\(parts[1])".utf8), key: publicKey, algorithm: algorithm) else {
            throw CopilotError.service("ChatGPT identity signature validation failed.")
        }
        return Identity(subject: subject, email: claims["email"] as? String)
    }

    private func makePublicKey(_ jwk: [String: Any], algorithm: String) -> SecKey? {
        if algorithm == "RS256", let n = jwk["n"] as? String, let e = jwk["e"] as? String,
           let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) {
            let der = rsaPublicKeyDER(modulus: modulus, exponent: exponent)
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
        }
        if algorithm == "ES256", let x = jwk["x"] as? String, let y = jwk["y"] as? String,
           let xb = Data(base64URL: x), let yb = Data(base64URL: y) {
            var point = Data([0x04]); point.append(xb); point.append(yb)
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 256]
            return SecKeyCreateWithData(point as CFData, attrs as CFDictionary, nil)
        }
        return nil
    }

    private func verify(signature: Data, data: Data, key: SecKey, algorithm: String) -> Bool {
        let secAlgorithm: SecKeyAlgorithm = algorithm == "RS256" ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
        let encoded = algorithm == "ES256" ? joseECDSASignatureToDER(signature) : signature
        return SecKeyVerifySignature(key, secAlgorithm, data as CFData, encoded as CFData, nil)
    }

    private func updatePresentation() {
        isSignedIn = credentials != nil
        accountLabel = credentials?.email ?? (credentials == nil ? "Not signed in" : "ChatGPT account")
        authStatus = credentials == nil ? "Sign in with ChatGPT to begin" : "ChatGPT account connected"
        if let model = UserDefaults.standard.string(forKey: "selected_chatgpt_model") { selectedModel = model }
        if isSignedIn { Task { try? await refreshModels() } }
    }

    private func loadCredentials() -> ChatGPTCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: credentialAccount, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }

    private func saveCredentials(_ value: ChatGPTCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: credentialAccount]
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CopilotError.service("Could not save ChatGPT credentials to Keychain.") }
    }

    private func deleteCredentials() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: credentialAccount] as CFDictionary)
        isSignedIn = false; accountLabel = "Not signed in"; authStatus = "Sign in with ChatGPT to begin"
    }
}

private func randomString(length: Int = 48) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64URLEncodedString()
}

private func form(_ values: [String: String]) -> Data {
    var components = URLComponents(); components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    return Data((components.percentEncodedQuery ?? "").utf8)
}

private extension Data {
    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
    func integer(_ bytes: Data) -> Data {
        var value = Data([0x02]); var body = bytes
        if body.first.map({ $0 & 0x80 != 0 }) == true { body.insert(0, at: 0) }
        value.append(derLength(body.count)); value.append(body); return value
    }
    let payload = integer(modulus) + integer(exponent)
    return Data([0x30]) + derLength(payload.count) + payload
}

private func joseECDSASignatureToDER(_ signature: Data) -> Data {
    guard signature.count == 64 else { return signature }
    func integer(_ bytes: Data) -> Data {
        var body = bytes.drop { $0 == 0 }
        if body.isEmpty { body = Data([0]) }
        var out = Data([0x02]); out.append(derLength(body.count)); out.append(body); return out
    }
    let payload = integer(signature.prefix(32)) + integer(signature.suffix(32))
    return Data([0x30]) + derLength(payload.count) + payload
}

private func derLength(_ length: Int) -> Data {
    if length < 128 { return Data([UInt8(length)]) }
    var value = length; var bytes: [UInt8] = []
    while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
}
