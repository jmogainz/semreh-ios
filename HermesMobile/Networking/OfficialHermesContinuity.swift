import Foundation
import os

enum HermesContinuityTransport: Equatable {
  case official
  case webUI
}

enum OfficialHermesContinuityError: LocalizedError, Equatable {
  case unsupportedAttachments
  case missingPayload
  var errorDescription: String? {
    switch self {
    case .unsupportedAttachments:
      return String(
        localized: "Attachments are not supported by the official Hermes continuity API yet.")
    case .missingPayload:
      return String(localized: "The official Hermes server returned an incomplete session.")
    }
  }
}

struct OfficialHermesCapabilities: Decodable, Equatable {
  let features: [String: JSONValue]?
  let endpoints: [String: EndpointDescription]?
  struct EndpointDescription: Decodable, Equatable {
    let method: String?
    let path: String?
  }
  var supportsSessionContinuity: Bool {
    ["session_resources", "session_chat", "session_chat_streaming"].allSatisfy { feature($0) }
      && endpoint("sessions", "GET", "/api/sessions")
      && endpoint("session_create", "POST", "/api/sessions")
      && endpoint("session", "GET", "/api/sessions/{session_id}")
      && endpoint("session_messages", "GET", "/api/sessions/{session_id}/messages")
      && endpoint("session_chat_stream", "POST", "/api/sessions/{session_id}/chat/stream")
  }
  private func endpoint(_ name: String, _ method: String, _ path: String) -> Bool {
    endpoints?[name]?.method?.uppercased() == method && endpoints?[name]?.path == path
  }
  private func feature(_ name: String) -> Bool {
    guard let value = features?[name] else { return false }
    if case .bool(true) = value { return true }
    return false
  }
}

private struct OfficialSessionDTO: Decodable {
  let id: String?
  let source: String?
  let model: String?
  let title: String?
  let startedAt: Double?
  let lastActive: Double?
  let messageCount: Int?
  let inputTokens: Int?
  let outputTokens: Int?
  let estimatedCostUsd: Double?
  let parentSessionId: String?
  let pinned: Bool?
  let archived: Bool?
}
private struct OfficialSessionList: Decodable { let data: [OfficialSessionDTO]? }
private struct OfficialSessionEnvelope: Decodable { let session: OfficialSessionDTO? }
private struct OfficialMessage: Decodable {
  let id: String?
  let role: String?
  let content: JSONValue?
  let sessionId: String?
  let toolCallId: String?
  let toolCalls: [JSONValue]?
  let toolName: String?
  let timestamp: Double?
  let reasoning: String?
  let reasoningContent: String?
  var domain: ChatMessage {
    ChatMessage(
      role: role,
      content: content.flatMap {
        if case .string(let v) = $0 { return v }
        return nil
      }, timestamp: timestamp, messageId: id, name: toolName, toolCallId: toolCallId,
      toolCalls: toolCalls, reasoning: reasoning ?? reasoningContent)
  }
}
private struct OfficialMessages: Decodable { let data: [OfficialMessage]? }
private struct OfficialCreateBody: Encodable { let model: String? }
private struct OfficialChatBody: Encodable {
  let input: String
  let model: String?
  let provider: String?
}

extension SessionDetail {
  fileprivate init(official s: OfficialSessionDTO, messages: [ChatMessage]?) {
    sessionId = s.id
    title = s.title
    workspace = nil
    model = s.model
    modelProvider = nil
    reasoningEffort = nil
    messageCount = s.messageCount ?? messages?.count
    createdAt = s.startedAt
    updatedAt = s.lastActive
    lastMessageAt = s.lastActive
    pinned = s.pinned
    archived = s.archived
    projectId = nil
    profile = nil
    inputTokens = s.inputTokens
    outputTokens = s.outputTokens
    estimatedCost = s.estimatedCostUsd
    activeStreamId = nil
    pendingUserMessage = nil
    pendingAttachments = nil
    pendingStartedAt = nil
    worktreePath = nil
    contextLength = nil
    thresholdTokens = nil
    lastPromptTokens = nil
    isCliSession = nil
    sourceTag = s.source
    rawSource = s.source
    sessionSource = s.source
    sourceLabel = s.source
    parentSessionId = s.parentSessionId
    relationshipType = nil
    readOnly = nil
    isReadOnly = nil
    self.messages = messages
    toolCalls = nil
    messagesTruncated = nil
    messagesOffset = nil
    compressionAnchorVisibleIdx = nil
    compressionAnchorMessageKey = nil
    compressionAnchorSummary = nil
  }
}

struct OfficialStreamFrame {
  let event: String
  let data: String
}
/// The official transport has its own URLSession, auth provider, capability state, and stream registry.
final class OfficialHermesContinuityClient: @unchecked Sendable {
  nonisolated let baseURL: URL
  private let session: URLSession
  private let headers: @Sendable () -> [CustomHeader]
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let lock = NSLock()
  private var capability: Bool?
  private var requests: [String: URLRequest] = [:]
  private var streamTasks: [String: Task<Void, Never>] = [:]
  init(
    baseURL: URL, session: URLSession,
    customHeaderProvider: @escaping @Sendable () -> [CustomHeader]
  ) {
    self.baseURL = baseURL
    self.session = session
    headers = customHeaderProvider
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    encoder.keyEncodingStrategy = .convertToSnakeCase
  }
  convenience init(
    baseURL: URL,
    customHeaderProvider: @escaping @Sendable () -> [CustomHeader]
  ) {
    self.init(baseURL: baseURL, session: URLSession(configuration: .default), customHeaderProvider: customHeaderProvider)
  }
  func isCapabilityValid() async -> Bool {
    lock.lock()
    if let capability {
      lock.unlock()
      return capability
    }
    lock.unlock()
    do {
      let c: OfficialHermesCapabilities = try await send(.officialCapabilities, method: "GET")
      lock.lock()
      capability = c.supportsSessionContinuity
      lock.unlock()
    } catch {
      lock.lock()
      capability = false
      lock.unlock()
    }
    return capability == true
  }
  func probeSessionContinuity() async throws {
    let health: HealthResponse = try await send(.health, method: "GET")
    guard health.status == "ok" else { throw APIError.http(statusCode: 200, body: "Unexpected health status.") }
    guard await isCapabilityValid() else { throw OfficialHermesContinuityError.missingPayload }
  }
  func validate(attachments: [JSONValue]?) async throws {
    guard attachments?.isEmpty == false, await isCapabilityValid() else { return }
    throw OfficialHermesContinuityError.unsupportedAttachments
  }
  func sessions() async throws -> SessionsResponse {
    let r: OfficialSessionList = try await send(.officialSessions, method: "GET")
    return SessionsResponse(
      sessions: r.data?.map { SessionSummary(from: SessionDetail(official: $0, messages: nil)) },
      cliCount: nil, archivedCount: nil, serverTime: nil, serverTz: nil)
  }
  func session(id: String, includeMessages: Bool, limit: Int?) async throws -> SessionResponse {
    let e: OfficialSessionEnvelope = try await send(.officialSession(id: id), method: "GET")
    guard let s = e.session else { throw OfficialHermesContinuityError.missingPayload }
    var m: [ChatMessage]?
    if includeMessages {
      let r: OfficialMessages = try await send(
        .officialSessionMessages(id: id, limit: limit), method: "GET")
      m = r.data?.map(\.domain)
    }
    return SessionResponse(session: SessionDetail(official: s, messages: m))
  }
  func createSession(model: String?) async throws -> SessionResponse {
    let e: OfficialSessionEnvelope = try await send(
      .officialCreateSession, method: "POST", body: OfficialCreateBody(model: model))
    guard let s = e.session else { throw OfficialHermesContinuityError.missingPayload }
    return SessionResponse(session: SessionDetail(official: s, messages: nil))
  }
  func startChat(sessionID: String, message: String, model: String?, provider: String?) throws
    -> ChatStartResponse
  {
    let id = "official_" + UUID().uuidString
    var r = URLRequest(
      url: Endpoint.officialSessionChatStream(id: sessionID).url(relativeTo: baseURL))
    r.httpMethod = "POST"
    headers().apply(to: &r)
    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try encoder.encode(
      OfficialChatBody(input: message, model: model, provider: provider))
    lock.lock()
    requests[id] = r
    lock.unlock()
    return ChatStartResponse(streamId: id, sessionId: sessionID, error: nil)
  }
  func streamURL(id: String) -> URL {
    var c = URLComponents(
      url: baseURL.appending(path: "/api/official-stream"), resolvingAgainstBaseURL: false)!
    c.queryItems = [URLQueryItem(name: "stream_id", value: id)]
    return c.url!
  }
  func events(id: String) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        defer { self.finish(id: id) }
        do {
          guard let request = self.request(id) else {
            throw APIError.http(statusCode: 404, body: nil)
          }
          let (bytes, response) = try await self.session.bytes(for: request)
          guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
          else {
            throw APIError.http(
              statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: nil)
          }
          var p = OfficialHermesSSEParser()
          for try await line in bytes.lines {
            if let f = p.consume(line: line) {
              continuation.yield(OfficialHermesSSEEventMapper.map(eventType: f.event, data: f.data))
            }
          }
          if let f = p.finish() {
            continuation.yield(OfficialHermesSSEEventMapper.map(eventType: f.event, data: f.data))
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      lock.lock()
      streamTasks[id] = task
      lock.unlock()
      continuation.onTermination = { _ in self.cancel(id: id) }
    }
  }
  func cancel(id: String) {
    lock.lock()
    let task = streamTasks.removeValue(forKey: id)
    requests.removeValue(forKey: id)
    lock.unlock()
    task?.cancel()
  }
  func isActive(id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return requests[id] != nil
  }
  private func request(_ id: String) -> URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return requests[id]
  }
  private func finish(id: String) {
    lock.lock()
    requests.removeValue(forKey: id)
    streamTasks.removeValue(forKey: id)
    lock.unlock()
  }
  private func send<R: Decodable>(_ endpoint: Endpoint, method: String, body: Encodable? = nil)
    async throws -> R
  {
    var r = URLRequest(url: endpoint.url(relativeTo: baseURL))
    r.httpMethod = method
    headers().apply(to: &r)
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
      r.httpBody = try encoder.encode(AnyEncodable(body))
    }
    let (d, response) = try await session.data(for: r)
    guard let http = response as? HTTPURLResponse else {
      throw APIError.http(statusCode: -1, body: nil)
    }
    if http.statusCode == 401 { throw APIError.unauthorized }
    guard (200..<300).contains(http.statusCode) else {
      throw APIError.http(statusCode: http.statusCode, body: String(data: d, encoding: .utf8))
    }
    return try decoder.decode(R.self, from: d)
  }
}

/// Process-wide official sidecar configurations, indexed by the normalized
/// primary WebUI URL. Secrets are held only in memory after Keychain hydration.
final class OfficialContinuityConfigurationStore: @unchecked Sendable {
  static let shared = OfficialContinuityConfigurationStore()
  private let storage = OSAllocatedUnfairLock(initialState: [String: OfficialHermesContinuityClient]())
  private let factory: @Sendable (URL, String) -> OfficialHermesContinuityClient

  private func key(for primaryURL: URL) -> String {
    (try? AuthManager.normalizedServerURL(from: primaryURL.absoluteString))?.absoluteString
      ?? primaryURL.absoluteString
  }

  init(factory: @escaping @Sendable (URL, String) -> OfficialHermesContinuityClient = { url, key in
    OfficialHermesContinuityClient(baseURL: url, customHeaderProvider: {
      [CustomHeader(name: "Authorization", value: "Bearer \(key)")]
    })
  }) { self.factory = factory }

  func client(for primaryURL: URL) -> OfficialHermesContinuityClient? {
    storage.withLock { $0[key(for: primaryURL)] }
  }
  func configure(primaryURL: URL, officialURL: URL, bearerKey: String) {
    let client = factory(officialURL, bearerKey)
    storage.withLock { $0[key(for: primaryURL)] = client }
  }
  func remove(primaryURL: URL) { storage.withLock { $0.removeValue(forKey: key(for: primaryURL)) } }
}
private struct AnyEncodable: Encodable {
  let value: Encodable
  init(_ value: Encodable) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension APIClient {
  func continuityTransport() async -> HermesContinuityTransport {
    guard officialContinuityClient != nil else { return .webUI }
    return await officialCapabilityValid() ? .official : .webUI
  }
  func officialCapabilityValid() async -> Bool {
    await officialContinuityClient?.isCapabilityValid() == true
  }
  func validateChatAttachments(_ attachments: [JSONValue]?) async throws {
    try await officialContinuityClient?.validate(attachments: attachments)
  }
  func officialSessionResponse(id: String, includeMessages: Bool, messageLimit: Int?) async throws
    -> SessionResponse
  {
    try await officialContinuityClient!.session(
      id: id, includeMessages: includeMessages, limit: messageLimit)
  }
  func officialSessionsResponse() async throws -> SessionsResponse {
    try await officialContinuityClient!.sessions()
  }
  func officialCreateSessionResponse(model: String?) async throws -> SessionResponse {
    try await officialContinuityClient!.createSession(model: model)
  }
  func officialChatStartResponse(
    sessionID: String, message: String, model: String?, provider: String?
  ) throws -> ChatStartResponse {
    try officialContinuityClient!.startChat(
      sessionID: sessionID, message: message, model: model, provider: provider)
  }
  func officialChatEvents(streamID: String) -> AsyncThrowingStream<SSEEvent, Error> {
    officialContinuityClient!.events(id: streamID)
  }
  func officialChatIsActive(streamID: String) -> Bool? {
    streamID.hasPrefix("official_") ? officialContinuityClient?.isActive(id: streamID) : nil
  }
  func cancelOfficialChat(streamID: String) { officialContinuityClient?.cancel(id: streamID) }
}

struct OfficialHermesSSEParser {
  private var event = "message"
  private var data: [String] = []
  mutating func consume(line: String) -> OfficialStreamFrame? {
    if line.isEmpty { return flush() }
    if line.hasPrefix(":") { return nil }
    if line.hasPrefix("event:") {
      let n = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      if !data.isEmpty {
        let f = flush()
        event = n
        return f
      }
      event = n
    } else if line.hasPrefix("data:") {
      data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }
  mutating func finish() -> OfficialStreamFrame? { flush() }
  private mutating func flush() -> OfficialStreamFrame? {
    guard !data.isEmpty else {
      event = "message"
      return nil
    }
    let f = OfficialStreamFrame(event: event, data: data.joined(separator: "\n"))
    event = "message"
    data.removeAll()
    return f
  }
}
@MainActor
final class OfficialHermesStreamClient: SSEStreamingClient {
  private let client: APIClient
  private let fallback: SSEClient
  private var task: Task<Void, Never>?
  private(set) var lastEventID: String?

  convenience init(client: APIClient) {
    self.init(client: client, fallback: SSEClient())
  }

  init(client: APIClient, fallback: SSEClient) {
    self.client = client
    self.fallback = fallback
  }

  func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
    start(url: url, resumeFrom: nil, onEvent: onEvent)
  }

  func start(
    url: URL, resumeFrom eventID: String?, onEvent: @escaping @MainActor (SSEEvent) -> Void
  ) {
    stop()
    lastEventID = eventID
    guard
      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "stream_id" })?.value,
      id.hasPrefix("official_")
    else {
      fallback.start(url: url, resumeFrom: eventID, onEvent: onEvent)
      return
    }
    task = Task { [weak self] in
      guard let self else { return }
      do {
        for try await event in await client.officialChatEvents(streamID: id) {
          if Task.isCancelled { return }
          onEvent(event)
        }
      } catch {
        if !Task.isCancelled {
          onEvent(.transportError(error.localizedDescription))
        }
      }
    }
  }

  func start(
    url: URL,
    resumeFrom eventID: String?,
    onEventWithID: @escaping @MainActor (SSEEvent, String?) -> Void
  ) {
    start(url: url, resumeFrom: eventID) { onEventWithID($0, nil) }
  }

  func stop() {
    task?.cancel()
    task = nil
    fallback.stop()
  }
}
enum OfficialHermesSSEEventMapper {
  static func map(eventType: String, data: String) -> SSEEvent {
    guard let o = try? JSONDecoder().decode([String: JSONValue].self, from: Data(data.utf8)) else {
      return eventType == "run.completed" ? .streamEnd : .ignored
    }
    switch eventType {
    case "assistant.delta": if case .string(let v) = o["delta"] { return .token(v) }
    case "tool.progress": if case .string(let v) = o["delta"] { return .reasoning(v) }
    case "tool.started", "tool.completed", "tool.failed":
      let t = ToolStreamEvent(
        eventType: eventType, name: o["tool_name"]?.stringValue, preview: o["preview"]?.stringValue,
        args: o["args"]?.objectValue, duration: o["duration"]?.doubleValue,
        isError: eventType == "tool.failed", stableID: o["tool_call_id"]?.stringValue)
      return eventType == "tool.started" ? .toolStarted(t) : .toolCompleted(t)
    case "assistant.completed": return .done(DoneStreamEvent())
    case "run.completed": return .streamEnd
    case "error":
      if case .string(let v) = o["message"] { return .error(v) }
      return .error("The stream returned an error.")
    default: break
    }
    return .ignored
  }
}
extension JSONValue {
  fileprivate var stringValue: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  fileprivate var objectValue: [String: JSONValue]? {
    if case .object(let v) = self { return v }
    return nil
  }
  fileprivate var doubleValue: Double? {
    if case .number(let v) = self { return v }
    return nil
  }
}
