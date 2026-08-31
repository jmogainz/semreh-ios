import XCTest

@testable import HermesMobile

final class OfficialHermesContinuityTests: APIClientTestCase {
  private let capabilities =
    #"{"features":{"session_resources":true,"session_chat":true,"session_chat_streaming":true},"endpoints":{"sessions":{"method":"GET","path":"/api/sessions"},"session_create":{"method":"POST","path":"/api/sessions"},"session":{"method":"GET","path":"/api/sessions/{session_id}"},"session_messages":{"method":"GET","path":"/api/sessions/{session_id}/messages"},"session_chat_stream":{"method":"POST","path":"/api/sessions/{session_id}/chat/stream"}}}"#

  func testNoSidecarDoesNotProbeAndUsesWebUIEndpoint() async throws {
    var paths: [String] = []
    let session = makeSession()
    MockURLProtocol.requestHandler = { request in
      paths.append(request.url?.absoluteString ?? "")
      XCTAssertEqual(request.url?.host, "example.test")
      XCTAssertEqual(request.url?.path, "/api/sessions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer webui-secret")
      return self.response(#"{"sessions":[{"session_id":"webui-id"}]}"#, request)
    }
    let client = APIClient(
      baseURL: URL(string: "https://example.test")!, session: session,
      customHeaderProvider: { [CustomHeader(name: "Authorization", value: "Bearer webui-secret")] })
    _ = try await client.sessions()
    XCTAssertEqual(paths, ["https://example.test/api/sessions"])
  }

  func testInjectedSidecarUsesOwnURLAndAuthWhileWebUIEndpointStaysWebUI() async throws {
    let headers = [CustomHeader(name: "Authorization", value: "Bearer sidecar-secret")]
    let webUI = makeSession()
    let sidecar = OfficialHermesContinuityClient(
      baseURL: URL(string: "https://official.test")!, session: webUI,
      customHeaderProvider: { headers })
    var seen: [(String, String?, String?)] = []
    MockURLProtocol.requestHandler = { request in
      seen.append(
        (
          request.url!.absoluteString, request.value(forHTTPHeaderField: "Authorization"),
          request.httpMethod
        ))
      if request.url?.host == "official.test" && request.url?.path == "/v1/capabilities" {
        return self.response(self.capabilities, request)
      }
      if request.url?.host == "official.test" {
        return self.response(#"{"data":[{"id":"official-id"}]}"#, request)
      }
      return self.response(#"{"sessions":[{"session_id":"webui-id"}]}"#, request)
    }
    let client = APIClient(
      baseURL: URL(string: "https://webui.test")!, session: webUI,
      customHeaderProvider: { [CustomHeader(name: "Authorization", value: "Cookie-webui")] },
      officialContinuityClient: sidecar)
    let official = try await client.sessions()
    _ = try await client.searchSessions(query: "x")
    XCTAssertEqual(official.sessions?.first?.sessionId, "official-id")
    XCTAssertEqual(seen[0].0, "https://official.test/v1/capabilities")
    XCTAssertEqual(seen[0].1, "Bearer sidecar-secret")
    XCTAssertEqual(seen[1].0, "https://official.test/api/sessions")
    XCTAssertEqual(seen.last?.0, "https://webui.test/api/sessions/search?q=x&content=1&depth=5")
    XCTAssertEqual(seen.last?.1, "Cookie-webui")
  }

  func testOfficialCancellationRemovesRegistryEntryWithoutWebUICancel() async throws {
    let session = makeSession()
    let sidecar = OfficialHermesContinuityClient(
      baseURL: URL(string: "https://official.test")!, session: session, customHeaderProvider: { [] }
    )
    var paths: [String] = []
    MockURLProtocol.requestHandler = { request in
      paths.append(request.url?.absoluteString ?? "")
      return self.response(self.capabilities, request)
    }
    let client = APIClient(
      baseURL: URL(string: "https://webui.test")!, session: session,
      officialContinuityClient: sidecar)
    _ = try await client.officialCapabilityValid()
    let start = try await client.officialChatStartResponse(
      sessionID: "exact", message: "hi", model: nil, provider: nil)
    let id = try XCTUnwrap(start.streamId)
    let activeBeforeCancel = await client.officialChatIsActive(streamID: id)
    XCTAssertEqual(activeBeforeCancel, true)
    _ = try await client.cancelChat(streamID: id)
    let activeAfterCancel = await client.officialChatIsActive(streamID: id)
    XCTAssertEqual(activeAfterCancel, false)
    XCTAssertFalse(paths.contains { $0.contains("/api/chat/cancel") })
  }

  func testOfficialAttachmentsAreRejectedBeforeWireSend() async throws {
    let session = makeSession()
    let sidecar = OfficialHermesContinuityClient(
      baseURL: URL(string: "https://official.test")!, session: session, customHeaderProvider: { [] }
    )
    MockURLProtocol.requestHandler = { request in self.response(self.capabilities, request) }
    let client = APIClient(
      baseURL: URL(string: "https://webui.test")!, session: session,
      officialContinuityClient: sidecar)
    do {
      try await client.validateChatAttachments([.object(["type": .string("image")])])
      XCTFail("expected explicit rejection")
    } catch let error as OfficialHermesContinuityError {
      XCTAssertEqual(error, .unsupportedAttachments)
    }
  }

  func testOfficialDetailPreservesCanonicalSessionID() async throws {
    let session = makeSession()
    let sidecar = OfficialHermesContinuityClient(
      baseURL: URL(string: "https://official.test")!, session: session, customHeaderProvider: { [] }
    )
    MockURLProtocol.requestHandler = { request in
      if request.url?.path == "/v1/capabilities" {
        return self.response(self.capabilities, request)
      }
      return self.response(#"{"session":{"id":"canonical-α","title":"Exact"}}"#, request)
    }
    let client = APIClient(
      baseURL: URL(string: "https://webui.test")!, session: session,
      officialContinuityClient: sidecar)
    let result = try await client.session(id: "canonical-α", includeMessages: false)
    XCTAssertEqual(result.session?.sessionId, "canonical-α")
  }

  func testOfficialMapperKeepsTerminalLifecycleEventsDistinct() {
    XCTAssertEqual(
      OfficialHermesSSEEventMapper.map(eventType: "assistant.delta", data: #"{"delta":"hello"}"#),
      .token("hello"))
    XCTAssertEqual(
      OfficialHermesSSEEventMapper.map(eventType: "assistant.completed", data: "{}"),
      .done(DoneStreamEvent()))
    XCTAssertEqual(
      OfficialHermesSSEEventMapper.map(eventType: "run.completed", data: "{}"), .streamEnd)
  }

  func testParserFlushesFrameWhenNextEventBegins() {
    var parser = OfficialHermesSSEParser()
    XCTAssertNil(parser.consume(line: "event: assistant.delta"))
    XCTAssertNil(parser.consume(line: "data: {\"delta\":\"x\"}"))
    XCTAssertEqual(parser.consume(line: "event: run.completed")?.event, "assistant.delta")
  }

  private func makeSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: c)
  }
  private func response(_ body: String, _ request: URLRequest) -> (HTTPURLResponse, Data) {
    (
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      Data(body.utf8)
    )
  }
}
