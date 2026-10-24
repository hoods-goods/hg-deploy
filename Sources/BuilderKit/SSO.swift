import Foundation
import Security

/// HG SSO (sso.hgcellular.com) for a native app: password login through
/// /api/app-login, re-checked with /api/verify. The app's SSO secret is put
/// into Info.plist (HGSSOAppSecret) by CI from the HGDEPLOY_SSO_SECRET secret;
/// it isn't in the source.
public struct SSOUser: Codable, Equatable, Sendable {
    public let id: Int
    public let username: String
    public let display_name: String?
    public let is_sso_admin: Bool?
    public var name: String { (display_name?.isEmpty == false ? display_name : nil) ?? username }
}

public enum SSOError: LocalizedError, Equatable {
    case notConfigured
    case rejected(String)
    case server(Int)
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "This copy of HG Deploy Builder isn't set up for HG SSO. Install an official release."
        case .rejected(let m): return m
        case .server(let c): return "HG SSO answered HTTP \(c). Try again in a minute."
        }
    }
}

public struct SSOClient: Sendable {
    public static let defaultURL = URL(string: "https://sso.hgcellular.com")!
    public static let slug = "hgdeploy"

    public let baseURL: URL
    public let appSecret: String?
    let session: URLSession

    public init(baseURL: URL = SSOClient.defaultURL, appSecret: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appSecret = appSecret?.isEmpty == false ? appSecret : nil
        self.session = session
    }

    /// Reads the secret CI baked into Info.plist.
    public static func fromBundle(_ bundle: Bundle = .main) -> SSOClient {
        let secret = bundle.object(forInfoDictionaryKey: "HGSSOAppSecret") as? String
        let url = (bundle.object(forInfoDictionaryKey: "HGSSOURL") as? String).flatMap(URL.init(string:)) ?? defaultURL
        return SSOClient(baseURL: url, appSecret: secret)
    }

    public var isConfigured: Bool { appSecret != nil }

    struct LoginResponse: Decodable {
        let success: Bool?
        let token: String?
        let user: SSOUser?
        let error: String?
    }

    struct VerifyResponse: Decodable {
        let valid: Bool?
        let user: SSOUser?
        let error: String?
    }

    public func login(username: String, password: String) async throws -> (token: String, user: SSOUser) {
        guard let appSecret else { throw SSOError.notConfigured }
        let (data, code) = try await post("/api/app-login", ["username": username, "password": password,
                                                             "app_slug": Self.slug, "app_secret": appSecret])
        let r = try? JSONDecoder().decode(LoginResponse.self, from: data)
        if code == 200, r?.success == true, let token = r?.token, let user = r?.user { return (token, user) }
        if code >= 500 { throw SSOError.server(code) }
        throw SSOError.rejected(Self.friendly(r?.error, code: code))
    }

    /// The user for a stored token, or an error when it's no longer valid.
    public func verify(token: String) async throws -> SSOUser {
        guard let appSecret else { throw SSOError.notConfigured }
        let (data, code) = try await post("/api/verify", ["token": token, "app_secret": appSecret])
        let r = try? JSONDecoder().decode(VerifyResponse.self, from: data)
        if code == 200, r?.valid == true, let user = r?.user { return user }
        if code >= 500 { throw SSOError.server(code) }
        throw SSOError.rejected(Self.friendly(r?.error, code: code))
    }

    static func friendly(_ error: String?, code: Int) -> String {
        guard let error, !error.isEmpty else { return "Sign-in failed (HTTP \(code))." }
        if error.localizedCaseInsensitiveContains("access to this app") {
            return "Your HG account doesn't have access to HG Deploy. Ask an SSO admin to grant it."
        }
        if error.localizedCaseInsensitiveContains("too many") { return error }
        if code == 401 && error.localizedCaseInsensitiveContains("expired") { return "Your session ended. Sign in again." }
        return error
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("HG Deploy Builder", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// `exp` from a JWT without checking its signature (only used to allow
    /// working offline until the token would have expired anyway).
    public static func expiry(ofToken token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}

/// The SSO token in the login keychain.
public enum TokenStore {
    static let service = "com.hgcellular.deploybuilder.sso"
    static let account = "token"

    public static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func save(_ token: String) {
        clear()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    public static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
