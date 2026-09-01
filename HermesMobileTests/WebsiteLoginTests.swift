import XCTest
import CryptoKit
@testable import HermesMobile

final class WebsiteLoginTests: APIClientTestCase {
    func testWebsiteLoginSSEEventDecodesSafeMetadataOnly() throws {
        let event = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"""
                {"request_id":"request_1234567890abcdef","origin":"HTTPS://Example.com/","display_name":" Example Site ","capabilities":["login"],"persistence":"non_persistent"}
                """#
        )

        guard case let .websiteLoginPending(request) = event else {
            return XCTFail("Expected a website-login pending event")
        }
        XCTAssertEqual(request.requestID, "request_1234567890abcdef")
        XCTAssertEqual(request.origin, "https://example.com")
        XCTAssertEqual(request.displayName, "Example Site")
        XCTAssertEqual(request.capabilities, ["login"])
        XCTAssertEqual(request.persistence, "non_persistent")
    }

    func testWebsiteLoginSSERejectsUnknownFieldsBeforeDecoding() {
        let futureField = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"{"request_id":"request_1234567890abcdef","origin":"https://example.com","future_field":"ignored"}"#
        )
        XCTAssertEqual(futureField, .ignored)

        let credentialField = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"{"request_id":"request_1234567890abcdef","origin":"https://example.com","password":"must-not-cross"}"#
        )
        XCTAssertEqual(credentialField, .ignored)
    }

    func testWebsiteLoginSSEAllowsAnyHTTPSOriginButRejectsInsecureSchemes() {
        let otherHTTPSOrigin = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"{"request_id":"request_1234567890abcdef","origin":"https://accounts.other.example:8443","display_name":"Other Site","capabilities":["login"],"persistence":"non_persistent"}"#
        )
        guard case let .websiteLoginPending(request) = otherHTTPSOrigin else {
            return XCTFail("Expected any exact HTTPS origin to be accepted")
        }
        XCTAssertEqual(request.origin, "https://accounts.other.example:8443")

        let insecure = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"{"request_id":"request_1234567890abcdef","origin":"http://example.com","capabilities":["login"],"persistence":"non_persistent"}"#
        )
        XCTAssertEqual(insecure, .ignored)

        let legacyAllowlist = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"{"request_id":"request_1234567890abcdef","origin":"https://example.com","allowed_origins":["https://example.com"],"capabilities":["login"],"persistence":"non_persistent"}"#
        )
        XCTAssertEqual(legacyAllowlist, .ignored)
    }

    func testWebsiteLoginRejectsCredentialShapedDisplayName() {
        let event = SSEEventDecoder.decode(
            eventType: "website_login",
            data: #"{"request_id":"request_1234567890abcdef","origin":"https://example.com","display_name":"password=must-not-cross"}"#
        )
        XCTAssertEqual(event, .ignored)
    }

    func testWebsiteLoginResultRejectsNonOpaqueRequestID() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WebsiteLoginResultResponse.self,
                from: Data("{\"request_id\":\"req_secret$123456789\",\"result\":\"completed\"}".utf8)
            )
        )
    }

    func testWebsiteLoginResultDecodesWireRequestIDWithDefaultDecoder() throws {
        let response = try JSONDecoder().decode(
            WebsiteLoginResultResponse.self,
            from: Data("{\"request_id\":\"request_1234567890abcdef\",\"result\":\"completed\"}".utf8)
        )
        XCTAssertEqual(response.requestID, "request_1234567890abcdef")
        XCTAssertEqual(response.result, .completed)
    }

    func testWebsiteLoginResultRejectsUnknownFields() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WebsiteLoginResultResponse.self,
                from: Data("{\"request_id\":\"request_1234567890abcdef\",\"result\":\"completed\",\"password\":\"must-not-cross\"}".utf8)
            )
        )
    }

    func testWebsiteLoginNavigationAllowsAnyHTTPSOriginButBlocksInsecureSchemes() {
        let policy = WebsiteLoginNavigationPolicy()

        XCTAssertTrue(policy.allowsMainFrame(URL(string: "https://example.com/login?next=%2Faccount#continue")!))
        XCTAssertTrue(policy.allowsMainFrame(URL(string: "https://accounts.other.example:8443/authorize")!))
        XCTAssertTrue(policy.allowsFrame(URL(string: "https://cdn.other.example/assets/auth-frame.html")!))
        XCTAssertFalse(policy.allowsMainFrame(URL(string: "http://example.com/login")!))
        XCTAssertFalse(policy.allowsMainFrame(URL(string: "javascript:alert(1)")!))
    }

    func testWebsiteLoginSupportsOIDCCrossOriginHTTPSRedirectChains() {
        let policy = WebsiteLoginNavigationPolicy()
        let oidcRedirectChain = [
            "https://app.example/authorize?client_id=mobile&response_type=code",
            "https://idp.example/authorize?client_id=mobile&redirect_uri=https%3A%2F%2Fapp.example%2Fcallback",
            "https://app.example/callback?code=opaque-code&state=opaque-state"
        ]

        for rawURL in oidcRedirectChain {
            XCTAssertTrue(
                policy.allowsOIDCRedirect(URL(string: rawURL)!),
                "OIDC HTTPS redirect should remain inside the user-directed WebView"
            )
        }
        XCTAssertFalse(policy.allowsOIDCRedirect(URL(string: "http://app.example/callback")!))
        XCTAssertFalse(policy.allowsOIDCRedirect(URL(string: "semreh://callback")!))
    }

    func testWebsiteLoginTreatsCancelledNavigationAsTransient() {
        XCTAssertFalse(
            WebsiteLoginNavigationPolicy.shouldReportNavigationFailure(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
        XCTAssertTrue(
            WebsiteLoginNavigationPolicy.shouldReportNavigationFailure(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )
        )
    }

    func testWebsiteLoginAllowsUnsupportedSubframeMIMEButBlocksMainFrameDownloads() {
        let policy = WebsiteLoginNavigationPolicy()

        XCTAssertFalse(
            policy.shouldBlockNavigationResponse(
                isForMainFrame: false,
                canShowMIMEType: false,
                mimeType: "application/octet-stream"
            )
        )
        XCTAssertFalse(
            policy.shouldBlockNavigationResponse(
                isForMainFrame: true,
                canShowMIMEType: true,
                mimeType: "text/html; charset=utf-8"
            )
        )
        XCTAssertTrue(
            policy.shouldBlockNavigationResponse(
                isForMainFrame: true,
                canShowMIMEType: true,
                mimeType: "application/octet-stream"
            )
        )
        XCTAssertTrue(
            policy.shouldBlockNavigationResponse(
                isForMainFrame: true,
                canShowMIMEType: false,
                mimeType: nil
            )
        )
    }

    func testWebsiteLoginUpgradesHTTPNavigationToHTTPSWithoutLoadingPlaintext() {
        let policy = WebsiteLoginNavigationPolicy()
        let httpURL = URL(string: "http://vercel.com/login?next=%2Fdashboard#continue")!

        XCTAssertEqual(
            policy.httpsUpgradeURL(httpURL)?.absoluteString,
            "https://vercel.com/login?next=%2Fdashboard#continue"
        )
        XCTAssertNil(policy.httpsUpgradeURL(URL(string: "https://vercel.com/login")!))
        XCTAssertNil(policy.httpsUpgradeURL(URL(string: "http://user:password@vercel.com/login")!))
        XCTAssertNil(policy.httpsUpgradeURL(URL(string: "javascript:alert(1)")!))
    }

    func testWebsiteLoginStatusURLCarriesOpaqueRequestAndSessionIDs() {
        let url = Endpoint.workLoginStatus(
            requestID: "request_1234567890abcdef",
            sessionID: "session_opaque"
        )
            .url(relativeTo: URL(string: "https://example.test")!)
        XCTAssertEqual(url.path, "/api/work/login/status")
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value) }
        )
        XCTAssertEqual(query["request_id"], "request_1234567890abcdef")
        XCTAssertEqual(query["session_id"], "session_opaque")
        XCTAssertNil(query["password"])
        XCTAssertNil(query["cookie"])
    }

    func testWebsiteLoginCompletionSendsOnlyOpaqueMetadata() async throws {
        let directDecoder = JSONDecoder()
        directDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let directResponse = try directDecoder.decode(
            WebsiteLoginResultResponse.self,
            from: Data("{\"request_id\":\"request_1234567890abcdef\",\"result\":\"completed\"}".utf8)
        )
        XCTAssertEqual(directResponse.requestID, "request_1234567890abcdef")

        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/work/login/result")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(Set(body.keys), Set(["request_id", "session_id", "result"]))
            XCTAssertEqual(body["request_id"] as? String, "request_1234567890abcdef")
            XCTAssertEqual(body["session_id"] as? String, "session_opaque")
            XCTAssertEqual(body["result"] as? String, "completed")
            for secretKey in ["password", "username", "cookie", "cookies", "storage", "token", "credential"] {
                XCTAssertNil(body[secretKey], "Unexpected credential-bearing field: \(secretKey)")
            }

            return apiTestJSONResponse(
                """
                {"request_id":"request_1234567890abcdef","result":"completed"}
                """,
                for: request
            )
        }

        let response = try await client.finishWebsiteLogin(
            requestID: "request_1234567890abcdef",
            sessionID: "session_opaque",
            result: .completed
        )
        XCTAssertEqual(response.requestID, "request_1234567890abcdef")
        XCTAssertEqual(response.result, .completed)
    }
}

final class NativeAuthComponentContractTests: XCTestCase {
    private let runtimePublicKey: String = {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return key.publicKey.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }()

    private func componentJSON(extraField: String = "") -> Data {
        let kinds = [
            "email", "username", "identifier", "phone", "organization", "tenant", "access_code",
            "password", "passcode", "pin", "secret", "totp_code", "sms_code", "email_code",
            "one_time_code", "verification_code", "recovery_code", "backup_code", "security_answer",
            "date_of_birth", "numeric", "text", "select", "radio", "checkbox", "consent"
        ]
        let fields = kinds.enumerated().map { index, kind in
            let secure = kind == "password" ? "true" : "false"
            return "{\"id\":\"field_\(index)\",\"kind\":\"\(kind)\",\"label\":\"\(kind)\",\"required\":false,\"secure\":\(secure),\"browser_field_handle\":\"fld_\(index)12345678\",\"target\":{\"strategy\":\"css\",\"value\":\"form input[name=field_\(index)]\"}}"
        }.joined(separator: ",")
        return Data("""
        {
          "schema":"semreh.native-component.v1",
          "component_id":"cmp_1234567890",
          "context_id":"ctx_1234567890",
          "browser_session_id":"bs_1234567890",
          "provider_origin":"https://example.com",
          "path":"/login",
          "flow":"password",
          "title":"Sign in",
          "instruction":"Enter the requested information.",
          "runtime_public_key":"\(runtimePublicKey)",
          "key_id":"rt_1234567890",
          "expires_at":4102444800,
          "fields":[\(fields)],
          "actions":[
            {"id":"submit","kind":"submit","label":"Sign in","target":{"strategy":"css","value":"form button[type=submit]"}},
            {"id":"sso","kind":"sso_continue","label":"Continue with SSO"},
            {"id":"magic","kind":"email_magic_link","label":"Send magic link"},
            {"id":"phone","kind":"phone_verification","label":"Verify phone"},
            {"id":"passkey","kind":"passkey","label":"Use a passkey"},
            {"id":"security_key","kind":"security_key","label":"Use security key"},
            {"id":"captcha","kind":"captcha","label":"Complete CAPTCHA"},
            {"id":"push","kind":"push_approval","label":"Approve on device"},
            {"id":"device","kind":"device_approval","label":"Approve device"},
            {"id":"cancel","kind":"cancel","label":"Cancel"}
          ]\(extraField)
        }
        """.utf8)
    }

    func testDecodesExtensiveAuthFieldTaxonomyAndBrowserOwnedActions() throws {
        let component = try JSONDecoder().decode(NativeAuthComponent.self, from: componentJSON())
        XCTAssertGreaterThanOrEqual(component.fields.count, 26)
        XCTAssertTrue(component.fields.contains { $0.kind == .email })
        XCTAssertTrue(component.fields.contains { $0.kind == .password })
        XCTAssertTrue(component.fields.contains { $0.kind == .passcode })
        XCTAssertTrue(component.fields.contains { $0.kind == .totpCode })
        XCTAssertTrue(component.fields.contains { $0.kind == .smsCode })
        XCTAssertTrue(component.fields.contains { $0.kind == .emailCode })
        XCTAssertTrue(component.fields.contains { $0.kind == .recoveryCode })
        XCTAssertTrue(component.fields.contains { $0.kind == .securityAnswer })
        XCTAssertTrue(component.fields.contains { $0.kind == .select })
        XCTAssertEqual(component.providerOrigin, "https://example.com")
        XCTAssertEqual(component.actions.first?.target?.strategy, "css")
    }

    func testRejectsCredentialBearingOrExecutableComponentMetadata() {
        for raw in [
            "\"value\":\"synthetic-secret\"",
            "\"password\":\"synthetic-secret\"",
            "\"selector\":\"input#evil\"",
            "\"javascript\":\"alert(1)\""
        ] {
            let data = componentJSON(extraField: ",\(raw)")
            XCTAssertThrowsError(try JSONDecoder().decode(NativeAuthComponent.self, from: data), raw)
        }
    }

    func testCryptoKitEnvelopeDoesNotContainPlaintextValues() throws {
        let component = try JSONDecoder().decode(NativeAuthComponent.self, from: componentJSON())
        let envelope = try NativeAuthEnvelope.encrypt(
            component: component,
            values: [
                "field_0": "jacob@example.test",
                "field_7": "synthetic-password"
            ],
            actionID: "submit"
        )
        let encoded = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("jacob@example.test"))
        XCTAssertFalse(encoded.contains("synthetic-password"))
        XCTAssertEqual(envelope.componentID, component.componentID)
        XCTAssertEqual(envelope.sequence, 1)
        XCTAssertFalse(envelope.clientPublicKey.isEmpty)
    }

    func testEveryExpandedKindHasExplicitRenderingClassification() {
        let expected: Set<NativeAuthFieldKind> = [
            .email, .username, .identifier, .phone, .organization, .tenant, .accessCode,
            .password, .passcode, .pin, .secret, .totpCode, .smsCode, .emailCode,
            .oneTimeCode, .verificationCode, .recoveryCode, .backupCode, .securityAnswer,
            .dateOfBirth, .numeric, .text, .select, .radio, .checkbox, .consent,
            .ssoContinue, .emailMagicLink, .phoneVerification, .passkey, .securityKey,
            .captcha, .pushApproval, .deviceApproval
        ]
        XCTAssertTrue(expected.isSubset(of: Set(NativeAuthFieldKind.allCases)))
    }
}

#if DEBUG
@MainActor
final class NativeAuthE2EAutoSubmitControllerTests: XCTestCase {
    private let fixtureRuntimePublicKey = Curve25519.KeyAgreement.PrivateKey()
        .publicKey.rawRepresentation.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    func testLaunchGateRequiresExplicitFlagAndDirectLoopbackWebUI() throws {
        let flag = NativeAuthE2EAutoSubmitController.launchFlag

        XCTAssertNil(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [],
                serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8787"))
            )
        )
        XCTAssertNil(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [flag],
                serverURL: try XCTUnwrap(URL(string: "https://example.test"))
            )
        )
        XCTAssertNil(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [flag],
                serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8787/proxied"))
            )
        )
        XCTAssertNotNil(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [flag],
                serverURL: try XCTUnwrap(URL(string: "http://127.31.2.9:8787"))
            )
        )
        XCTAssertNotNil(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [flag],
                serverURL: try XCTUnwrap(URL(string: "https://[::1]:8787"))
            )
        )
    }

    func testProcessControllerNeverCarriesLoopbackAuthorizationIntoRemoteServer() throws {
        let flag = NativeAuthE2EAutoSubmitController.launchFlag
        let loopback = try XCTUnwrap(URL(string: "http://127.0.0.1:18888"))
        let remote = try XCTUnwrap(URL(string: "https://example.test"))

        NativeAuthE2EAutoSubmitController.resetProcessControllerForTesting()
        defer { NativeAuthE2EAutoSubmitController.resetProcessControllerForTesting() }

        XCTAssertNil(
            NativeAuthE2EAutoSubmitController.processController(
                serverURL: remote,
                arguments: [flag]
            )
        )
        let loopbackController = try XCTUnwrap(
            NativeAuthE2EAutoSubmitController.processController(
                serverURL: loopback,
                arguments: [flag]
            )
        )
        XCTAssertNil(
            NativeAuthE2EAutoSubmitController.processController(
                serverURL: remote,
                arguments: [flag]
            )
        )
        XCTAssertTrue(
            loopbackController === NativeAuthE2EAutoSubmitController.processController(
                serverURL: loopback,
                arguments: [flag]
            )
        )
    }

    func testWaitsForCompleteAvailableFillableLoopbackPrompt() async throws {
        let incomplete = try makePrompt(
            components: [makeComponent(kind: "identifier")],
            state: nil
        )
        let unavailable = try makePrompt(
            components: [makeComponent(kind: "identifier"), makeComponent(kind: "submit", ordinal: 2)],
            state: makeState(kind: "submit", ordinal: 2, status: "focused")
        )
        let remoteProvider = try makePrompt(
            components: [
                makeComponent(kind: "identifier", providerOrigin: "https://example.test"),
                makeComponent(kind: "submit", ordinal: 2, providerOrigin: "https://example.test")
            ],
            state: makeState(kind: "submit", ordinal: 2, providerOrigin: "https://example.test")
        )
        let browserOwned = try makePrompt(
            components: [
                makeComponent(kind: "identifier"),
                makeComponent(kind: "passkey", ordinal: 2),
                makeComponent(kind: "submit", ordinal: 3)
            ],
            state: makeState(kind: "submit", ordinal: 3)
        )
        let conflicting = try makePrompt(
            components: [
                makeComponent(kind: "identifier"),
                makeComponent(kind: "secret", ordinal: 2, contextID: "ctx_conflict_123456"),
                makeComponent(kind: "submit", ordinal: 3)
            ],
            state: makeState(kind: "submit", ordinal: 3)
        )

        for prompt in [incomplete, unavailable, remoteProvider, browserOwned, conflicting] {
            let controller = try makeController()
            var submissionCount = 0
            await controller.submitIfEligible(prompt: prompt) { _, _, _ in
                submissionCount += 1
                return true
            }
            XCTAssertEqual(submissionCount, 0)
            XCTAssertFalse(controller.hasPendingValues)
            XCTAssertFalse(controller.isSpent)
        }
    }

    func testGeneratesDisposableValuesInternallyAndNeverRetriesAfterFailure() async throws {
        let forbiddenProbe = UUID().uuidString
        let controller = try makeController(additionalArguments: ["--ignored-e2e-input", forbiddenProbe])
        let prompt = try makePrompt(
            components: [
                makeComponent(kind: "identifier"),
                makeComponent(kind: "secret", ordinal: 2),
                makeComponent(kind: "one_time_code", ordinal: 3),
                makeComponent(kind: "recovery_code", ordinal: 4),
                makeComponent(kind: "submit", ordinal: 5)
            ],
            state: makeState(kind: "submit", ordinal: 5)
        )
        var submissionCount = 0

        await controller.submitIfEligible(prompt: prompt) { values, component, actionHandle in
            submissionCount += 1
            XCTAssertTrue(controller.hasPendingValues)
            XCTAssertEqual(Set(values.keys), Set(prompt.inputComponents.map(\.field)))
            XCTAssertTrue(values.values.allSatisfy { !$0.isEmpty && !$0.contains(forbiddenProbe) })
            XCTAssertEqual(component.kind, .submit)
            XCTAssertEqual(actionHandle, component.actionHandle)
            return false
        }

        XCTAssertEqual(submissionCount, 1)
        XCTAssertFalse(controller.hasPendingValues)
        XCTAssertTrue(controller.isSpent)
        XCTAssertEqual(controller.attemptCount, 1)

        await controller.submitIfEligible(prompt: prompt) { _, _, _ in
            submissionCount += 1
            return true
        }
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(controller.attemptCount, 1)
        XCTAssertFalse(controller.hasPendingValues)
    }

    private func makeController(additionalArguments: [String] = []) throws -> NativeAuthE2EAutoSubmitController {
        try XCTUnwrap(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [NativeAuthE2EAutoSubmitController.launchFlag] + additionalArguments,
                serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8787"))
            )
        )
    }

    private func makePrompt(
        components: [NativeAuthWireComponent],
        state: NativeAuthWireState?
    ) throws -> NativeAuthPromptState {
        let anchor = try XCTUnwrap(components.first)
        return NativeAuthPromptState(
            contextID: anchor.contextID,
            ownerSessionID: "session_opaque",
            streamID: "stream_opaque",
            components: components,
            state: state
        )
    }

    private func makeComponent(
        kind: String,
        ordinal: Int = 1,
        contextID: String = "ctx_loopback_123456",
        providerOrigin: String = "https://127.0.0.1:9443"
    ) throws -> NativeAuthWireComponent {
        let object: [String: Any] = [
            "type": "semreh.native-component.v1",
            "issued_by": "browser",
            "immutable": true,
            "context_id": contextID,
            "browser_session_id": "bs_loopback_123456",
            "component_id": "cmp_loopback_\(ordinal)_123456",
            "field": "fld_loopback_\(ordinal)_123456",
            "action_handle": "act_loopback_\(ordinal)_123456",
            "kind": kind,
            "label": "Field \(ordinal)",
            "provider_origin": providerOrigin,
            "path": "/login",
            "runtime_public_key": fixtureRuntimePublicKey,
            "key_id": "rt_loopback_123456",
            "expires_at": "2099-01-01T00:00:00Z",
            "binding": [
                "issued_by": "browser",
                "immutable": true,
                "tab_handle": "tab_loopback_123456",
                "frame_handle": "frame_loopback_123456",
                "document_generation": "doc_loopback_123456",
                "visibility": "visible",
                "editability": kind == "submit" ? "not_editable" : "editable",
                "match_count": 1,
                "target_ref": [
                    "issued_by": "browser",
                    "immutable": true,
                    "ref_id": "ref_loopback_\(ordinal)_123456",
                    "strategy": "css",
                    "selector": kind == "submit" ? "button[type=submit]" : "input[name=fixture]"
                ]
            ]
        ]
        return try JSONDecoder().decode(
            NativeAuthWireComponent.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func makeState(
        kind: String,
        ordinal: Int,
        providerOrigin: String = "https://127.0.0.1:9443",
        status: String = "available"
    ) throws -> NativeAuthWireState {
        let object: [String: Any] = [
            "type": "semreh.native-component-state.v1",
            "issued_by": "browser",
            "immutable": true,
            "context_id": "ctx_loopback_123456",
            "browser_session_id": "bs_loopback_123456",
            "component_id": "cmp_loopback_\(ordinal)_123456",
            "action_handle": "act_loopback_\(ordinal)_123456",
            "kind": kind,
            "provider_origin": providerOrigin,
            "path": "/login",
            "status": status
        ]
        return try JSONDecoder().decode(
            NativeAuthWireState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
#endif
