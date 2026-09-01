import Foundation
import CryptoKit

/// The only terminal states the native Work Mode boundary can report.
enum WebsiteLoginResult: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

enum WebsiteLoginSecurityError: Error, Equatable {
    case invalidOrigin
    case invalidRequestID
    case invalidPolicy
    case unexpectedField
}

struct WebsiteLoginNavigationPolicy: Equatable, Sendable {
    init() {}

    /// Website login is intentionally user-authorized rather than domain-
    /// allowlisted. The initial exact HTTPS origin is displayed to the user,
    /// and the user decides whether to continue/sign in in the native WebView.
    /// Navigation remains restricted to HTTPS URLs without embedded userinfo.
    /// Explicit OIDC/SSO redirect check. Standard web OIDC flows move between
    /// HTTPS authorization, identity-provider, and HTTPS callback URLs in this
    /// same user-directed WebView; no origin allowlist is consulted.
    func allowsOIDCRedirect(_ url: URL) -> Bool {
        allowsHTTPSNavigation(url)
    }

    func allowsMainFrame(_ url: URL) -> Bool {
        allowsOIDCRedirect(url)
    }

    func allowsFrame(_ url: URL) -> Bool {
        allowsOIDCRedirect(url)
    }

    func allowsHTTPSNavigation(_ url: URL) -> Bool {
        Self.navigationOrigin(url) != nil
    }

    /// Return an HTTPS equivalent for a plaintext navigation without ever
    /// allowing the original HTTP request onto the wire.
    func httpsUpgradeURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else {
            return nil
        }

        components.scheme = "https"
        if components.port == 80 {
            components.port = nil
        }
        return components.url
    }

    /// WebKit reports an intentional superseded/redirected load as
    /// `NSURLErrorCancelled` (`-999`). It is not a user-visible login failure;
    /// only real navigation errors should close the login surface.
    static func shouldReportNavigationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }

    /// MIME restrictions apply only to the visible top-level page. Login pages
    /// routinely load unsupported/opaque subframes and embedded identity
    /// provider resources; those must not terminate the user-directed flow.
    func shouldBlockNavigationResponse(
        isForMainFrame: Bool,
        canShowMIMEType: Bool,
        mimeType: String?
    ) -> Bool {
        guard isForMainFrame else { return false }
        guard canShowMIMEType else { return true }

        let normalizedMIMEType = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedMIMEType != "text/html" && normalizedMIMEType != "application/xhtml+xml"
    }

    /// Return the canonical HTTPS origin for a navigable URL. Unlike
    /// `canonicalOrigin(_:)`, this intentionally permits a path, query, and
    /// fragment because those are normal parts of a login flow; the returned
    /// value still normalizes only scheme/host/port.
    static func navigationOrigin(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil
        else {
            return nil
        }

        let host = rawHost.lowercased()
        let authorityHost = host.contains(":") ? "[\(host)]" : host
        if let parsedPort = components.port {
            guard parsedPort > 0, parsedPort <= 65_535 else { return nil }
            return "https://\(authorityHost)\(parsedPort == 443 ? "" : ":\(parsedPort)")"
        }
        return "https://\(authorityHost)"
    }

    static func canonicalOrigin(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }

        return navigationOrigin(url)
    }
}

struct WebsiteLoginRequest: Decodable, Equatable, Identifiable, Sendable {
    let requestID: String
    let origin: String
    let displayName: String
    let capabilities: [String]
    let persistence: String

    var id: String { requestID }
    var initialURL: URL { URL(string: origin)! }

    var navigationPolicy: WebsiteLoginNavigationPolicy { WebsiteLoginNavigationPolicy() }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case requestID = "request_id"
        case origin
        case displayName = "display_name"
        case capabilities
        case persistence
    }

    init(from decoder: Decoder) throws {
        try validateWebsiteLoginFields(
            decoder,
            allowed: [
                "request_id", "requestId",
                "origin",
                "display_name", "displayName",
                "capabilities",
                "persistence"
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawRequestID = try container.decode(String.self, forKey: .requestID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isOpaqueRequestID(rawRequestID) else {
            throw WebsiteLoginSecurityError.invalidRequestID
        }

        let rawOrigin = try container.decode(String.self, forKey: .origin)
        guard let originURL = URL(string: rawOrigin),
              let normalizedOrigin = WebsiteLoginNavigationPolicy.canonicalOrigin(originURL)
        else {
            throw WebsiteLoginSecurityError.invalidOrigin
        }

        let capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? ["login"]
        guard !capabilities.isEmpty, capabilities.allSatisfy({ $0 == "login" }) else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }

        let persistence = try container.decodeIfPresent(String.self, forKey: .persistence) ?? "non_persistent"
        guard persistence == "non_persistent" else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }

        let suppliedName = try container.decodeIfPresent(String.self, forKey: .displayName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.isSafeDisplayName(suppliedName) else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }

        requestID = rawRequestID
        origin = normalizedOrigin
        displayName = suppliedName.isEmpty ? (originURL.host ?? normalizedOrigin) : suppliedName
        self.capabilities = capabilities
        self.persistence = persistence
    }

    static func isOpaqueRequestID(_ value: String) -> Bool {
        guard (16...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func isSafeDisplayName(_ value: String) -> Bool {
        guard value.utf8.count <= 120,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7F
              })
        else { return false }

        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let sensitiveTerms = [
            "password", "passwd", "passcode", "otp", "token", "secret", "cookie",
            "credential", "bearer", "api key", "access key", "form field", "form value",
            "username", "user name"
        ]
        guard !sensitiveTerms.contains(where: { folded.localizedCaseInsensitiveContains($0) }) else {
            return false
        }
        return !value.contains(where: { "={}[]<>`\"".contains($0) })
    }

}

struct WebsiteLoginResultResponse: Decodable, Equatable, Sendable {
    let requestID: String
    let result: WebsiteLoginResult

    enum CodingKeys: String, CodingKey, CaseIterable {
        case requestID = "request_id"
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WebsiteLoginAnyCodingKey.self)
        let allowedKeys = Set(["request_id", "requestId", "result"])
        guard container.allKeys.allSatisfy({ allowedKeys.contains($0.stringValue) }) else {
            throw WebsiteLoginSecurityError.unexpectedField
        }

        let requestKeys = container.allKeys.filter {
            $0.stringValue == "request_id" || $0.stringValue == "requestId"
        }
        guard requestKeys.count == 1, let requestKey = requestKeys.first,
              let resultKey = WebsiteLoginAnyCodingKey(stringValue: "result")
        else {
            throw WebsiteLoginSecurityError.unexpectedField
        }

        let id = try container.decode(String.self, forKey: requestKey)
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WebsiteLoginRequest.isOpaqueRequestID(normalizedID) else { throw WebsiteLoginSecurityError.invalidRequestID }
        requestID = normalizedID
        result = try container.decode(WebsiteLoginResult.self, forKey: resultKey)
    }
}

private struct WebsiteLoginAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func validateWebsiteLoginFields(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: WebsiteLoginAnyCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw WebsiteLoginSecurityError.unexpectedField
    }
}

// MARK: - Native auth component protocol

enum NativeAuthFieldKind: String, Codable, CaseIterable, Hashable, Sendable {
    case email
    case username
    case identifier
    case phone
    case organization
    case tenant
    case accessCode = "access_code"
    case password
    case passcode
    case pin
    case secret
    case totpCode = "totp_code"
    case smsCode = "sms_code"
    case emailCode = "email_code"
    case oneTimeCode = "one_time_code"
    case verificationCode = "verification_code"
    case recoveryCode = "recovery_code"
    case backupCode = "backup_code"
    case securityAnswer = "security_answer"
    case dateOfBirth = "date_of_birth"
    case numeric
    case text
    case select
    case radio
    case checkbox
    case consent
    case submit
    case ssoContinue = "sso_continue"
    case emailMagicLink = "email_magic_link"
    case phoneVerification = "phone_verification"
    case passkey
    case securityKey = "security_key"
    case captcha
    case pushApproval = "push_approval"
    case deviceApproval = "device_approval"
    case cancel

    var requiresTarget: Bool {
        !Self.browserOwnedKinds.contains(self) && self != .cancel
    }

    var usesSecureEntry: Bool {
        switch self {
        case .password, .passcode, .pin, .secret, .recoveryCode, .backupCode, .securityAnswer:
            return true
        default:
            return false
        }
    }

    var isBrowserOwned: Bool { Self.browserOwnedKinds.contains(self) }

    private static let browserOwnedKinds: Set<NativeAuthFieldKind> = [
        .ssoContinue, .emailMagicLink, .phoneVerification, .passkey,
        .securityKey, .captcha, .pushApproval, .deviceApproval
    ]
}

enum NativeAuthActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case submit
    case select
    case radio
    case checkbox
    case consent
    case ssoContinue = "sso_continue"
    case emailMagicLink = "email_magic_link"
    case phoneVerification = "phone_verification"
    case passkey
    case securityKey = "security_key"
    case captcha
    case pushApproval = "push_approval"
    case deviceApproval = "device_approval"
    case cancel

    var isBrowserOwned: Bool {
        switch self {
        case .ssoContinue, .emailMagicLink, .phoneVerification, .passkey,
             .securityKey, .captcha, .pushApproval, .deviceApproval:
            return true
        default:
            return false
        }
    }
}

enum NativeAuthComponentStateKind: String, Codable, Sendable {
    case presented
    case editing
    case accepted
    case filled
    case submitted
    case cancelled
    case expired
    case failed
}

private struct NativeAuthAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum NativeAuthDecoding {
    static let fieldIDPattern = try! Regex("^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
    static let opaquePattern = try! Regex("^[A-Za-z0-9_-]{8,128}$")
    static let refPattern = try! Regex("^@e[0-9]{1,8}$")

    static func key(_ value: String) -> NativeAuthAnyCodingKey {
        NativeAuthAnyCodingKey(stringValue: value)!
    }

    static func rejectUnknown(
        _ container: KeyedDecodingContainer<NativeAuthAnyCodingKey>,
        allowed: Set<String>
    ) throws {
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw WebsiteLoginSecurityError.unexpectedField
        }
    }

    static func requiredString(
        _ container: KeyedDecodingContainer<NativeAuthAnyCodingKey>,
        _ name: String
    ) throws -> String {
        try container.decode(String.self, forKey: key(name))
    }

    static func optionalString(
        _ container: KeyedDecodingContainer<NativeAuthAnyCodingKey>,
        _ name: String
    ) throws -> String? {
        try container.decodeIfPresent(String.self, forKey: key(name))
    }

    static func safeText(_ value: String, maximum: Int, allowEmpty: Bool = true) throws -> String {
        guard value.utf8.count <= maximum,
              (allowEmpty || !value.isEmpty),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func opaque(_ value: String) -> Bool {
        value.firstMatch(of: opaquePattern) != nil
    }

    static func fieldID(_ value: String) -> Bool {
        value.firstMatch(of: fieldIDPattern) != nil
    }

    static func base64URL(_ value: String, minimum: Int = 1, maximum: Int = 131_072) -> Bool {
        guard (minimum...maximum).contains(value.utf8.count), !value.isEmpty else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func origin(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        let authority = host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            guard (1...65_535).contains(port) else { return nil }
            return "https://\(authority)\(port == 443 ? "" : ":\(port)")"
        }
        return "https://\(authority)"
    }

    static func path(_ raw: String) -> String? {
        guard raw.utf8.count <= 512 else { return nil }
        let components = URLComponents(string: raw)
        let value = components?.path ?? raw
        guard value.isEmpty || (value.hasPrefix("/") && !value.contains("\\") && !value.split(separator: "/").contains("..")),
              !value.contains("?") && !value.contains("#"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return value.isEmpty ? "/" : value
    }
}

struct NativeAuthTarget: Codable, Equatable, Sendable {
    let strategy: String
    let value: String
    let framePath: [String]?
    let targetID: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["strategy", "value", "frame_path", "target_id"])
        let strategy = try NativeAuthDecoding.requiredString(container, "strategy")
        let value = try NativeAuthDecoding.requiredString(container, "value")
        guard ["css", "xpath", "role", "label", "ref", "cdp"].contains(strategy),
              value.utf8.count <= 2_048,
              !value.isEmpty,
              !value.localizedCaseInsensitiveContains("javascript:"),
              !value.localizedCaseInsensitiveContains("<script"),
              !value.localizedCaseInsensitiveContains("innerhtml"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        if strategy == "ref" {
            guard value.firstMatch(of: NativeAuthDecoding.refPattern) != nil else {
                throw WebsiteLoginSecurityError.invalidPolicy
            }
        }
        let frames = try container.decodeIfPresent([String].self, forKey: NativeAuthDecoding.key("frame_path"))
        guard (frames ?? []).count <= 8,
              (frames ?? []).allSatisfy({ $0.utf8.count <= 160 && !$0.isEmpty })
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        let targetID = try NativeAuthDecoding.optionalString(container, "target_id")
        if let targetID, !NativeAuthDecoding.opaque(targetID) {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        self.strategy = strategy
        self.value = value
        framePath = frames
        self.targetID = targetID
    }

    init(strategy: String, value: String, framePath: [String]? = nil, targetID: String? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "strategy": strategy,
            "value": value,
            "frame_path": framePath as Any,
            "target_id": targetID as Any
        ])
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case strategy
        case value
        case framePath = "frame_path"
        case targetID = "target_id"
    }
}

struct NativeAuthOption: Codable, Equatable, Sendable {
    let id: String
    let label: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["id", "label"])
        let id = try NativeAuthDecoding.requiredString(container, "id")
        guard NativeAuthDecoding.fieldID(id) else { throw WebsiteLoginSecurityError.invalidPolicy }
        self.id = id
        label = try NativeAuthDecoding.safeText(
            NativeAuthDecoding.requiredString(container, "label"), maximum: 120, allowEmpty: false
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
    }
}

struct NativeAuthField: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: NativeAuthFieldKind
    let label: String
    let required: Bool
    let secure: Bool
    let browserFieldHandle: String
    let target: NativeAuthTarget?
    let keyboard: String?
    let format: String?
    let placeholder: String?
    let options: [NativeAuthOption]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(
            container,
            allowed: ["id", "kind", "label", "required", "secure", "browser_field_handle", "target", "keyboard", "format", "placeholder", "options"]
        )
        let id = try NativeAuthDecoding.requiredString(container, "id")
        let kind = try container.decode(NativeAuthFieldKind.self, forKey: NativeAuthDecoding.key("kind"))
        let label = try NativeAuthDecoding.safeText(
            NativeAuthDecoding.requiredString(container, "label"), maximum: 120, allowEmpty: false
        )
        let required = try container.decodeIfPresent(Bool.self, forKey: NativeAuthDecoding.key("required")) ?? false
        let secure = try container.decodeIfPresent(Bool.self, forKey: NativeAuthDecoding.key("secure")) ?? kind.usesSecureEntry
        let handle = try NativeAuthDecoding.requiredString(container, "browser_field_handle")
        guard NativeAuthDecoding.fieldID(id), NativeAuthDecoding.opaque(handle) else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        let target = try container.decodeIfPresent(NativeAuthTarget.self, forKey: NativeAuthDecoding.key("target"))
        if kind.requiresTarget && target == nil {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        self.id = id
        self.kind = kind
        self.label = label
        self.required = required
        self.secure = secure
        browserFieldHandle = handle
        self.target = target
        keyboard = try NativeAuthDecoding.optionalString(container, "keyboard")
        format = try NativeAuthDecoding.optionalString(container, "format")
        placeholder = try NativeAuthDecoding.optionalString(container, "placeholder")
        options = try container.decodeIfPresent([NativeAuthOption].self, forKey: NativeAuthDecoding.key("options"))
        for value in [keyboard, format, placeholder].compactMap({ $0 }) {
            _ = try NativeAuthDecoding.safeText(value, maximum: 120)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case required
        case secure
        case browserFieldHandle = "browser_field_handle"
        case target
        case keyboard
        case format
        case placeholder
        case options
    }
}

struct NativeAuthAction: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: NativeAuthActionKind
    let label: String
    let target: NativeAuthTarget?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["id", "kind", "label", "target"])
        let id = try NativeAuthDecoding.requiredString(container, "id")
        let kind = try container.decode(NativeAuthActionKind.self, forKey: NativeAuthDecoding.key("kind"))
        guard NativeAuthDecoding.fieldID(id) else { throw WebsiteLoginSecurityError.invalidPolicy }
        self.id = id
        self.kind = kind
        label = try NativeAuthDecoding.safeText(
            NativeAuthDecoding.requiredString(container, "label"), maximum: 120, allowEmpty: false
        )
        target = try container.decodeIfPresent(NativeAuthTarget.self, forKey: NativeAuthDecoding.key("target"))
        if !kind.isBrowserOwned && kind != .cancel && target == nil {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case target
    }
}

struct NativeAuthComponent: Codable, Equatable, Sendable, Identifiable {
    let schema: String
    let componentID: String
    let contextID: String
    let browserSessionID: String
    let streamID: String?
    let providerOrigin: String
    let path: String
    let flow: String
    let title: String
    let instruction: String
    let fields: [NativeAuthField]
    let actions: [NativeAuthAction]
    let runtimePublicKey: String
    let keyID: String
    let expiresAt: TimeInterval

    var id: String { componentID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(
            container,
            allowed: ["schema", "component_id", "context_id", "browser_session_id", "stream_id", "provider_origin", "path", "flow", "title", "instruction", "fields", "actions", "runtime_public_key", "key_id", "expires_at"]
        )
        schema = try NativeAuthDecoding.requiredString(container, "schema")
        guard schema == "semreh.native-component.v1" else { throw WebsiteLoginSecurityError.invalidPolicy }
        componentID = try NativeAuthDecoding.requiredString(container, "component_id")
        contextID = try NativeAuthDecoding.requiredString(container, "context_id")
        browserSessionID = try NativeAuthDecoding.requiredString(container, "browser_session_id")
        streamID = try NativeAuthDecoding.optionalString(container, "stream_id")
        guard NativeAuthDecoding.opaque(componentID), NativeAuthDecoding.opaque(contextID), NativeAuthDecoding.opaque(browserSessionID) else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        guard let origin = NativeAuthDecoding.origin(try NativeAuthDecoding.requiredString(container, "provider_origin")),
              let path = NativeAuthDecoding.path(try NativeAuthDecoding.requiredString(container, "path"))
        else { throw WebsiteLoginSecurityError.invalidOrigin }
        providerOrigin = origin
        self.path = path
        flow = try NativeAuthDecoding.safeText(
            NativeAuthDecoding.requiredString(container, "flow"), maximum: 64, allowEmpty: false
        )
        title = try NativeAuthDecoding.safeText(
            NativeAuthDecoding.requiredString(container, "title"), maximum: 160, allowEmpty: false
        )
        instruction = try NativeAuthDecoding.safeText(
            NativeAuthDecoding.requiredString(container, "instruction"), maximum: 320
        )
        fields = try container.decode([NativeAuthField].self, forKey: NativeAuthDecoding.key("fields"))
        actions = try container.decode([NativeAuthAction].self, forKey: NativeAuthDecoding.key("actions"))
        guard fields.count <= 32, actions.count <= 16,
              Set(fields.map(\.id)).count == fields.count,
              Set(actions.map(\.id)).count == actions.count
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        runtimePublicKey = try NativeAuthDecoding.requiredString(container, "runtime_public_key")
        keyID = try NativeAuthDecoding.requiredString(container, "key_id")
        guard NativeAuthDecoding.opaque(runtimePublicKey), NativeAuthDecoding.opaque(keyID) else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        expiresAt = try container.decode(TimeInterval.self, forKey: NativeAuthDecoding.key("expires_at"))
        guard expiresAt > Date().timeIntervalSince1970 else { throw WebsiteLoginSecurityError.invalidPolicy }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case componentID = "component_id"
        case contextID = "context_id"
        case browserSessionID = "browser_session_id"
        case streamID = "stream_id"
        case providerOrigin = "provider_origin"
        case path
        case flow
        case title
        case instruction
        case fields
        case actions
        case runtimePublicKey = "runtime_public_key"
        case keyID = "key_id"
        case expiresAt = "expires_at"
    }
}

struct NativeAuthComponentState: Codable, Equatable, Sendable {
    let schema: String
    let componentID: String
    let state: NativeAuthComponentStateKind
    let sessionID: String?
    let streamID: String?
    let fieldIDs: [String]?
    let actionID: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["schema", "component_id", "state", "session_id", "stream_id", "field_ids", "action_id"])
        schema = try NativeAuthDecoding.requiredString(container, "schema")
        guard schema == "semreh.native-component-state.v1" else { throw WebsiteLoginSecurityError.invalidPolicy }
        componentID = try NativeAuthDecoding.requiredString(container, "component_id")
        guard NativeAuthDecoding.opaque(componentID) else { throw WebsiteLoginSecurityError.invalidPolicy }
        state = try container.decode(NativeAuthComponentStateKind.self, forKey: NativeAuthDecoding.key("state"))
        sessionID = try NativeAuthDecoding.optionalString(container, "session_id")
        streamID = try NativeAuthDecoding.optionalString(container, "stream_id")
        fieldIDs = try container.decodeIfPresent([String].self, forKey: NativeAuthDecoding.key("field_ids"))
        if let fieldIDs, fieldIDs.count > 32 || !fieldIDs.allSatisfy(NativeAuthDecoding.fieldID) {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        actionID = try NativeAuthDecoding.optionalString(container, "action_id")
        if let actionID, !NativeAuthDecoding.fieldID(actionID) {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case componentID = "component_id"
        case state
        case sessionID = "session_id"
        case streamID = "stream_id"
        case fieldIDs = "field_ids"
        case actionID = "action_id"
    }
}

struct NativeAuthEnvelope: Codable, Equatable, Sendable {
    let schema: String
    let componentID: String
    let sequence: Int
    let keyID: String
    let clientPublicKey: String
    let nonce: String
    let ciphertext: String
    let tag: String

    static func encrypt(
        component: NativeAuthComponent,
        values: [String: String],
        actionID: String,
        sequence: Int = 1
    ) throws -> NativeAuthEnvelope {
        guard sequence == 1,
              NativeAuthDecoding.fieldID(actionID),
              values.count <= 32,
              values.keys.allSatisfy(NativeAuthDecoding.fieldID),
              values.values.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") })
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        guard let publicData = Data(base64URL: component.runtimePublicKey) else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
        let runtimePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicData)
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: runtimePublicKey)
        let info = Data(("semreh.native-auth.v1:\(component.keyID)").utf8)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        let plaintext = try JSONSerialization.data(
            withJSONObject: ["fields": values, "action_id": actionID],
            options: []
        )
        let aad = Data("\(component.componentID):\(sequence):\(component.keyID)".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: aad)
        return NativeAuthEnvelope(
            schema: "semreh.native-secret-envelope.v1",
            componentID: component.componentID,
            sequence: sequence,
            keyID: component.keyID,
            clientPublicKey: sealed.base64URLPublicKey(from: clientPrivateKey.publicKey.rawRepresentation),
            nonce: Data(sealed.nonce).base64URLString,
            ciphertext: sealed.ciphertext.base64URLString,
            tag: sealed.tag.base64URLString
        )
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case componentID = "component_id"
        case sequence
        case keyID = "key_id"
        case clientPublicKey = "client_public_key"
        case nonce
        case ciphertext
        case tag
    }
}

private extension AES.GCM.SealedBox {
    func base64URLPublicKey(from data: Data) -> String { data.base64URLString }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

// MARK: - Strict v1 wire models

enum NativeAuthWireFieldKind: String, Codable, CaseIterable, Sendable {
    case identifier
    case secret
    case oneTimeCode = "one_time_code"
    case recoveryCode = "recovery_code"
    case submit
    case ssoContinue = "sso_continue"
    case emailMagicLink = "email_magic_link"
    case phoneVerification = "phone_verification"
    case passkey
    case securityKey = "security_key"
    case captcha
    case pushApproval = "push_approval"
    case deviceApproval = "device_approval"
    case cancel

    var isBrowserOwned: Bool {
        switch self {
        case .ssoContinue, .emailMagicLink, .phoneVerification, .passkey,
             .securityKey, .captcha, .pushApproval, .deviceApproval, .cancel:
            return true
        default:
            return false
        }
    }

    var requiresEditableBinding: Bool {
        switch self {
        case .secret, .oneTimeCode, .recoveryCode:
            return true
        default:
            return false
        }
    }

    var usesSecureEntry: Bool {
        self == .secret || self == .recoveryCode
    }
}

enum NativeAuthWireActionKind: String, Codable, CaseIterable, Sendable {
    case submit
    case ssoContinue = "sso_continue"
    case passkey
    case captcha
    case pushApproval = "push_approval"
    case cancel
}

enum NativeAuthWireStatus: String, Codable, Sendable {
    case available
    case focused
    case awaitingBrowser = "awaiting_browser"
    case completed
    case cancelled
    case blocked
    case unavailable
}

enum NativeAuthWireFlowKind: String, Codable, Sendable {
    case oidc
    case passkey
    case captcha
}

enum NativeAuthWireFlowPhase: String, Codable, Sendable {
    case awaitingRedirect = "awaiting_redirect"
    case awaitingUser = "awaiting_user"
    case awaitingChallenge = "awaiting_challenge"
    case approved
    case completed
    case blocked
}

enum NativeAuthWireCancelReason: String, Codable, Sendable {
    case userCancelled = "user_cancelled"
    case browserCancelled = "browser_cancelled"
    case expired
    case navigationCancelled = "navigation_cancelled"
}

struct NativeAuthWireTargetRef: Codable, Equatable, Sendable {
    let issuedBy: String
    let immutable: Bool
    let refID: String
    let strategy: String
    let selector: String?
    let role: String?
    let label: String?
    let frameHandle: String?
    let cdpHandle: String?
    let locatorHandle: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        let common = ["issued_by", "immutable", "ref_id", "strategy"]
        let allowed = Set(common + ["selector", "role", "label", "frame_handle", "cdp_handle", "locator_handle"])
        try NativeAuthDecoding.rejectUnknown(container, allowed: allowed)
        issuedBy = try NativeAuthDecoding.requiredString(container, "issued_by")
        immutable = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("immutable"))
        refID = try NativeAuthDecoding.requiredString(container, "ref_id")
        strategy = try NativeAuthDecoding.requiredString(container, "strategy")
        guard issuedBy == "browser", immutable, NativeAuthDecoding.opaque(refID),
              ["css", "xpath", "role", "label", "frame", "cdp", "playwright"].contains(strategy)
        else { throw WebsiteLoginSecurityError.invalidPolicy }

        selector = try NativeAuthDecoding.optionalString(container, "selector")
        role = try NativeAuthDecoding.optionalString(container, "role")
        label = try NativeAuthDecoding.optionalString(container, "label")
        frameHandle = try NativeAuthDecoding.optionalString(container, "frame_handle")
        cdpHandle = try NativeAuthDecoding.optionalString(container, "cdp_handle")
        locatorHandle = try NativeAuthDecoding.optionalString(container, "locator_handle")

        switch strategy {
        case "css":
            guard let selector, NativeAuthWireTargetRef.isSafeCSS(selector) else { throw WebsiteLoginSecurityError.invalidPolicy }
        case "xpath":
            guard let selector, selector.hasPrefix("//"), selector.utf8.count <= 160,
                  !selector.localizedCaseInsensitiveContains("javascript:") else { throw WebsiteLoginSecurityError.invalidPolicy }
        case "role":
            guard let role, ["textbox", "button", "link", "combobox", "checkbox", "radio", "image", "option", "menuitem", "switch"].contains(role),
                  let label, (try? NativeAuthDecoding.safeText(label, maximum: 80, allowEmpty: false)) != nil
            else { throw WebsiteLoginSecurityError.invalidPolicy }
        case "label":
            guard let label, (try? NativeAuthDecoding.safeText(label, maximum: 80, allowEmpty: false)) != nil else { throw WebsiteLoginSecurityError.invalidPolicy }
        case "frame":
            guard let frameHandle, NativeAuthDecoding.opaque(frameHandle) else { throw WebsiteLoginSecurityError.invalidPolicy }
        case "cdp":
            guard let cdpHandle, NativeAuthDecoding.opaque(cdpHandle) else { throw WebsiteLoginSecurityError.invalidPolicy }
        case "playwright":
            guard let locatorHandle, NativeAuthDecoding.opaque(locatorHandle) else { throw WebsiteLoginSecurityError.invalidPolicy }
        default:
            throw WebsiteLoginSecurityError.invalidPolicy
        }
    }

    private static func isSafeCSS(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160,
              !value.localizedCaseInsensitiveContains("javascript:"),
              !value.localizedCaseInsensitiveContains("<script"),
              !value.localizedCaseInsensitiveContains("innerhtml"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }
        return value.allSatisfy { $0.isASCII && ( $0.isLetter || $0.isNumber || "_.#:[\\]= '()>+~,*()-".contains($0)) }
    }

    enum CodingKeys: String, CodingKey {
        case issuedBy = "issued_by"
        case immutable
        case refID = "ref_id"
        case strategy
        case selector
        case role
        case label
        case frameHandle = "frame_handle"
        case cdpHandle = "cdp_handle"
        case locatorHandle = "locator_handle"
    }
}

struct NativeAuthWireBinding: Codable, Equatable, Sendable {
    let issuedBy: String
    let immutable: Bool
    let tabHandle: String
    let frameHandle: String
    let documentGeneration: String
    let visibility: String
    let editability: String
    let matchCount: Int
    let targetRef: NativeAuthWireTargetRef

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["issued_by", "immutable", "tab_handle", "frame_handle", "document_generation", "visibility", "editability", "match_count", "target_ref"])
        issuedBy = try NativeAuthDecoding.requiredString(container, "issued_by")
        immutable = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("immutable"))
        tabHandle = try NativeAuthDecoding.requiredString(container, "tab_handle")
        frameHandle = try NativeAuthDecoding.requiredString(container, "frame_handle")
        documentGeneration = try NativeAuthDecoding.requiredString(container, "document_generation")
        visibility = try NativeAuthDecoding.requiredString(container, "visibility")
        editability = try NativeAuthDecoding.requiredString(container, "editability")
        matchCount = try container.decode(Int.self, forKey: NativeAuthDecoding.key("match_count"))
        targetRef = try container.decode(NativeAuthWireTargetRef.self, forKey: NativeAuthDecoding.key("target_ref"))
        guard issuedBy == "browser", immutable, NativeAuthDecoding.opaque(tabHandle),
              NativeAuthDecoding.opaque(frameHandle), NativeAuthDecoding.opaque(documentGeneration),
              visibility == "visible", ["editable", "not_editable"].contains(editability), matchCount == 1
        else { throw WebsiteLoginSecurityError.invalidPolicy }
    }

    enum CodingKeys: String, CodingKey {
        case issuedBy = "issued_by"
        case immutable
        case tabHandle = "tab_handle"
        case frameHandle = "frame_handle"
        case documentGeneration = "document_generation"
        case visibility
        case editability
        case matchCount = "match_count"
        case targetRef = "target_ref"
    }
}

struct NativeAuthWireComponent: Codable, Equatable, Sendable, Identifiable {
    let type: String
    let issuedBy: String
    let immutable: Bool
    let contextID: String
    let browserSessionID: String
    let componentID: String
    let field: String
    let actionHandle: String
    let kind: NativeAuthWireFieldKind
    let label: String
    let providerOrigin: String
    let path: String
    /// The WebUI projection intentionally withholds the internal target binding.
    /// Hermes retains and revalidates that binding when the opaque envelope is
    /// submitted; iOS accepts the safe projection without receiving selectors.
    let binding: NativeAuthWireBinding?
    let runtimePublicKey: String
    let keyID: String
    let expiresAt: String

    var id: String { componentID }
    var isExpired: Bool {
        guard let date = ISO8601DateFormatter().date(from: expiresAt) else { return true }
        return date <= Date()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["type", "issued_by", "immutable", "context_id", "browser_session_id", "component_id", "field", "action_handle", "kind", "label", "provider_origin", "path", "binding", "runtime_public_key", "key_id", "expires_at"])
        type = try NativeAuthDecoding.requiredString(container, "type")
        issuedBy = try NativeAuthDecoding.requiredString(container, "issued_by")
        immutable = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("immutable"))
        contextID = try NativeAuthDecoding.requiredString(container, "context_id")
        browserSessionID = try NativeAuthDecoding.requiredString(container, "browser_session_id")
        componentID = try NativeAuthDecoding.requiredString(container, "component_id")
        field = try NativeAuthDecoding.requiredString(container, "field")
        actionHandle = try NativeAuthDecoding.requiredString(container, "action_handle")
        kind = try container.decode(NativeAuthWireFieldKind.self, forKey: NativeAuthDecoding.key("kind"))
        label = try NativeAuthDecoding.safeText(NativeAuthDecoding.requiredString(container, "label"), maximum: 80, allowEmpty: false)
        guard type == "semreh.native-component.v1", issuedBy == "browser", immutable,
              NativeAuthDecoding.opaque(contextID), NativeAuthDecoding.opaque(browserSessionID),
              NativeAuthDecoding.opaque(componentID), NativeAuthDecoding.opaque(field), NativeAuthDecoding.opaque(actionHandle),
              let origin = NativeAuthDecoding.origin(try NativeAuthDecoding.requiredString(container, "provider_origin")),
              let path = NativeAuthDecoding.path(try NativeAuthDecoding.requiredString(container, "path"))
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        providerOrigin = origin
        self.path = path
        binding = try container.decodeIfPresent(
            NativeAuthWireBinding.self,
            forKey: NativeAuthDecoding.key("binding")
        )
        runtimePublicKey = try NativeAuthDecoding.requiredString(container, "runtime_public_key")
        keyID = try NativeAuthDecoding.requiredString(container, "key_id")
        expiresAt = try NativeAuthDecoding.requiredString(container, "expires_at")
        guard NativeAuthDecoding.base64URL(runtimePublicKey, minimum: 32, maximum: 128),
              NativeAuthDecoding.opaque(keyID),
              Self.isISO8601(expiresAt),
              !kind.requiresEditableBinding || binding == nil || binding?.editability == "editable"
        else { throw WebsiteLoginSecurityError.invalidPolicy }
    }

    private static func isISO8601(_ value: String) -> Bool {
        value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression) != nil
    }

    enum CodingKeys: String, CodingKey {
        case type
        case issuedBy = "issued_by"
        case immutable
        case contextID = "context_id"
        case browserSessionID = "browser_session_id"
        case componentID = "component_id"
        case field
        case actionHandle = "action_handle"
        case kind
        case label
        case providerOrigin = "provider_origin"
        case path
        case binding
        case runtimePublicKey = "runtime_public_key"
        case keyID = "key_id"
        case expiresAt = "expires_at"
    }
}

struct NativeAuthWireBrowserFlow: Codable, Equatable, Sendable {
    let owner: String
    let flowKind: NativeAuthWireFlowKind
    let phase: NativeAuthWireFlowPhase
    let flowHandle: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["owner", "flow_kind", "phase", "flow_handle"])
        owner = try NativeAuthDecoding.requiredString(container, "owner")
        flowKind = try container.decode(NativeAuthWireFlowKind.self, forKey: NativeAuthDecoding.key("flow_kind"))
        phase = try container.decode(NativeAuthWireFlowPhase.self, forKey: NativeAuthDecoding.key("phase"))
        flowHandle = try NativeAuthDecoding.requiredString(container, "flow_handle")
        guard owner == "browser", NativeAuthDecoding.opaque(flowHandle) else { throw WebsiteLoginSecurityError.invalidPolicy }
    }

    enum CodingKeys: String, CodingKey {
        case owner
        case flowKind = "flow_kind"
        case phase
        case flowHandle = "flow_handle"
    }
}

struct NativeAuthWireState: Codable, Equatable, Sendable {
    let type: String
    let issuedBy: String
    let immutable: Bool
    let contextID: String
    let browserSessionID: String
    let componentID: String
    let actionHandle: String
    let kind: NativeAuthWireFieldKind
    let providerOrigin: String
    let path: String
    let status: NativeAuthWireStatus
    let browserFlow: NativeAuthWireBrowserFlow?
    let binding: NativeAuthWireBinding?
    let cancelReason: NativeAuthWireCancelReason?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["type", "issued_by", "immutable", "context_id", "browser_session_id", "component_id", "action_handle", "kind", "provider_origin", "path", "status", "browser_flow", "binding", "cancel_reason"])
        type = try NativeAuthDecoding.requiredString(container, "type")
        issuedBy = try NativeAuthDecoding.requiredString(container, "issued_by")
        immutable = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("immutable"))
        contextID = try NativeAuthDecoding.requiredString(container, "context_id")
        browserSessionID = try NativeAuthDecoding.requiredString(container, "browser_session_id")
        componentID = try NativeAuthDecoding.requiredString(container, "component_id")
        actionHandle = try NativeAuthDecoding.requiredString(container, "action_handle")
        kind = try container.decode(NativeAuthWireFieldKind.self, forKey: NativeAuthDecoding.key("kind"))
        guard type == "semreh.native-component-state.v1", issuedBy == "browser", immutable,
              NativeAuthDecoding.opaque(contextID), NativeAuthDecoding.opaque(browserSessionID),
              NativeAuthDecoding.opaque(componentID), NativeAuthDecoding.opaque(actionHandle),
              let origin = NativeAuthDecoding.origin(try NativeAuthDecoding.requiredString(container, "provider_origin")),
              let path = NativeAuthDecoding.path(try NativeAuthDecoding.requiredString(container, "path"))
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        providerOrigin = origin
        self.path = path
        status = try container.decode(NativeAuthWireStatus.self, forKey: NativeAuthDecoding.key("status"))
        browserFlow = try container.decodeIfPresent(NativeAuthWireBrowserFlow.self, forKey: NativeAuthDecoding.key("browser_flow"))
        binding = try container.decodeIfPresent(NativeAuthWireBinding.self, forKey: NativeAuthDecoding.key("binding"))
        cancelReason = try container.decodeIfPresent(NativeAuthWireCancelReason.self, forKey: NativeAuthDecoding.key("cancel_reason"))
        if status == .cancelled {
            guard cancelReason != nil else { throw WebsiteLoginSecurityError.invalidPolicy }
        } else if cancelReason != nil {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case issuedBy = "issued_by"
        case immutable
        case contextID = "context_id"
        case browserSessionID = "browser_session_id"
        case componentID = "component_id"
        case actionHandle = "action_handle"
        case kind
        case providerOrigin = "provider_origin"
        case path
        case status
        case browserFlow = "browser_flow"
        case binding
        case cancelReason = "cancel_reason"
    }
}

struct NativeAuthWireContext: Codable, Equatable, Sendable {
    let type: String
    let issuedBy: String
    let immutable: Bool
    let contextID: String
    let browserSessionID: String
    let providerOrigin: String
    let path: String
    let label: String
    let componentIDs: [String]
    let actionHandles: [String]
    let runtimePublicKey: String?
    let keyID: String?
    let expiresAt: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(container, allowed: ["type", "issued_by", "immutable", "context_id", "browser_session_id", "provider_origin", "path", "label", "component_ids", "action_handles", "runtime_public_key", "key_id", "expires_at"])
        type = try NativeAuthDecoding.requiredString(container, "type")
        issuedBy = try NativeAuthDecoding.requiredString(container, "issued_by")
        immutable = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("immutable"))
        contextID = try NativeAuthDecoding.requiredString(container, "context_id")
        browserSessionID = try NativeAuthDecoding.requiredString(container, "browser_session_id")
        guard type == "hermes.auth-context.v1", issuedBy == "browser", immutable,
              NativeAuthDecoding.opaque(contextID), NativeAuthDecoding.opaque(browserSessionID),
              let origin = NativeAuthDecoding.origin(try NativeAuthDecoding.requiredString(container, "provider_origin")),
              let path = NativeAuthDecoding.path(try NativeAuthDecoding.requiredString(container, "path"))
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        providerOrigin = origin
        self.path = path
        label = try NativeAuthDecoding.safeText(NativeAuthDecoding.requiredString(container, "label"), maximum: 80, allowEmpty: false)
        componentIDs = try container.decode([String].self, forKey: NativeAuthDecoding.key("component_ids"))
        actionHandles = try container.decode([String].self, forKey: NativeAuthDecoding.key("action_handles"))
        guard !componentIDs.isEmpty, componentIDs.count <= 32, componentIDs.allSatisfy(NativeAuthDecoding.opaque),
              !actionHandles.isEmpty, actionHandles.count <= 32, actionHandles.allSatisfy(NativeAuthDecoding.opaque),
              Set(componentIDs).count == componentIDs.count, Set(actionHandles).count == actionHandles.count
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        runtimePublicKey = try NativeAuthDecoding.optionalString(container, "runtime_public_key")
        keyID = try NativeAuthDecoding.optionalString(container, "key_id")
        expiresAt = try NativeAuthDecoding.optionalString(container, "expires_at")
        if let runtimePublicKey { guard NativeAuthDecoding.base64URL(runtimePublicKey, minimum: 32, maximum: 128) else { throw WebsiteLoginSecurityError.invalidPolicy } }
        if let keyID { guard NativeAuthDecoding.opaque(keyID) else { throw WebsiteLoginSecurityError.invalidPolicy } }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case issuedBy = "issued_by"
        case immutable
        case contextID = "context_id"
        case browserSessionID = "browser_session_id"
        case providerOrigin = "provider_origin"
        case path
        case label
        case componentIDs = "component_ids"
        case actionHandles = "action_handles"
        case runtimePublicKey = "runtime_public_key"
        case keyID = "key_id"
        case expiresAt = "expires_at"
    }
}

struct NativeAuthWireEnvelope: Codable, Equatable, Sendable {
    let type: String
    let issuedBy: String
    let immutable: Bool
    let contextID: String
    let browserSessionID: String
    let envelopeID: String
    let providerOrigin: String
    let path: String
    let cipherSuite: String
    let keyID: String
    let clientPublicKey: String
    let nonce: String
    let ciphertext: String
    let tag: String
    let journalPolicy: String
    let expiresAt: String

    static func encrypt(
        component: NativeAuthWireComponent,
        values: [String: String],
        actionHandle: String
    ) throws -> NativeAuthWireEnvelope {
        guard !component.isExpired,
              !values.isEmpty,
              values.count <= 8,
              values.keys.allSatisfy(NativeAuthDecoding.opaque),
              values.values.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }),
              NativeAuthDecoding.opaque(actionHandle),
              let runtimeData = Data(base64URL: component.runtimePublicKey)
        else { throw WebsiteLoginSecurityError.invalidPolicy }
        let runtimePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: runtimeData)
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: runtimePublicKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(("semreh.native-auth.v1:\(component.keyID)").utf8),
            outputByteCount: 32
        )
        let plaintext = try JSONSerialization.data(
            withJSONObject: ["fields": values, "action_handle": actionHandle],
            options: []
        )
        let envelopeID = "env_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let aad = Data("\(component.contextID):\(envelopeID):\(component.keyID)".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: aad)
        return NativeAuthWireEnvelope(
            type: "semreh.native-secret-envelope.v1",
            issuedBy: "semreh-native",
            immutable: true,
            contextID: component.contextID,
            browserSessionID: component.browserSessionID,
            envelopeID: envelopeID,
            providerOrigin: component.providerOrigin,
            path: component.path,
            cipherSuite: "AES-256-GCM",
            keyID: component.keyID,
            clientPublicKey: clientPrivateKey.publicKey.rawRepresentation.base64URLString,
            nonce: Data(sealed.nonce).base64URLString,
            ciphertext: sealed.ciphertext.base64URLString,
            tag: sealed.tag.base64URLString,
            journalPolicy: "never",
            expiresAt: component.expiresAt
        )
    }

}

struct NativeAuthControlResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let state: String
    let code: String
    let stage: String
    let retryable: Bool
    let requiresRemint: Bool

    var expectedHTTPStatus: Int {
        switch code {
        case "submitted", "cancelled": 200
        case "replay", "busy", "owner_mismatch", "rejected": 409
        case "expired", "context_lost": 410
        case "target_changed", "unsupported": 422
        case "transient_runtime": 503
        default: -1
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAuthAnyCodingKey.self)
        try NativeAuthDecoding.rejectUnknown(
            container,
            allowed: ["ok", "state", "code", "stage", "retryable", "requires_remint"]
        )
        ok = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("ok"))
        state = try NativeAuthDecoding.requiredString(container, "state")
        code = try NativeAuthDecoding.requiredString(container, "code")
        stage = try NativeAuthDecoding.requiredString(container, "stage")
        retryable = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("retryable"))
        requiresRemint = try container.decode(Bool.self, forKey: NativeAuthDecoding.key("requires_remint"))

        let specifications: [String: (stage: String, retryable: Bool, requiresRemint: Bool, ok: Bool)] = [
            "submitted": ("complete", false, false, true),
            "cancelled": ("cancel", false, false, true),
            "replay": ("validate", false, true, false),
            "busy": ("runtime", true, false, false),
            "owner_mismatch": ("ownership", false, false, false),
            "rejected": ("request", false, true, false),
            "expired": ("validate", false, true, false),
            "context_lost": ("ownership", false, true, false),
            "target_changed": ("preflight", false, true, false),
            "unsupported": ("preflight", false, false, false),
            "transient_runtime": ("runtime", true, false, false)
        ]
        guard state == code,
              let specification = specifications[code],
              stage == specification.stage,
              retryable == specification.retryable,
              requiresRemint == specification.requiresRemint,
              ok == specification.ok
        else {
            throw WebsiteLoginSecurityError.invalidPolicy
        }
    }
}

struct NativeAuthControlError: Error, Equatable, Sendable {
    let outcome: NativeAuthControlResponse
    let statusCode: Int
}

