import Foundation

/// Client-side composer drafts, keyed by server + session.
///
/// ChatView owns `@State draftMessage`, so leave/reopen and process death
/// used to wipe whatever Jacob had typed. This store is the durable copy.
@MainActor
final class ComposerDraftStore {
    static let shared = ComposerDraftStore()

    static let visibilityKeyPrefix = "semreh.composerDraft."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, sessionID: String) -> String {
        let raw = defaults.string(forKey: key(server: server, sessionID: sessionID)) ?? ""
        return Self.restorableDraft(raw)
    }

    func save(_ draft: String, server: URL, sessionID: String) {
        let key = key(server: server, sessionID: sessionID)
        let restorable = Self.restorableDraft(draft)
        if restorable.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(restorable, forKey: key)
        }
    }

    func clear(server: URL, sessionID: String) {
        defaults.removeObject(forKey: key(server: server, sessionID: sessionID))
    }

    func resetForTesting() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.visibilityKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static func resolvedDraft(initialDraft: String, storedDraft: String) -> String {
        let initial = initialDraft
        if !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return initial
        }
        return restorableDraft(storedDraft)
    }

    private static func restorableDraft(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft
    }

    private func key(server: URL, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Self.visibilityKeyPrefix)\(serverKey)|\(sessionKey)"
    }
}

struct TranscriptRestorePoint: Equatable {
    var followingLatest: Bool
    var visibleMessageID: String?

    static let followingLatest = TranscriptRestorePoint(followingLatest: true, visibleMessageID: nil)
}

@MainActor
final class TranscriptRestoreStore {
    static let shared = TranscriptRestoreStore()
    static let visibilityKeyPrefix = "semreh.transcriptRestore."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, sessionID: String) -> TranscriptRestorePoint {
        guard let data = defaults.data(forKey: key(server: server, sessionID: sessionID)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .followingLatest
        }
        return TranscriptRestorePoint(
            followingLatest: payload.followingLatest,
            visibleMessageID: payload.visibleMessageID
        )
    }

    func save(_ point: TranscriptRestorePoint, server: URL, sessionID: String) {
        let key = key(server: server, sessionID: sessionID)
        if point.followingLatest {
            defaults.removeObject(forKey: key)
            return
        }
        let payload = Payload(followingLatest: false, visibleMessageID: point.visibleMessageID)
        defaults.set(try? JSONEncoder().encode(payload), forKey: key)
    }

    func resetForTesting() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.visibilityKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private struct Payload: Codable {
        var followingLatest: Bool
        var visibleMessageID: String?
    }

    private func key(server: URL, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Self.visibilityKeyPrefix)\(serverKey)|\(sessionKey)"
    }
}

struct LiveRunBookmark: Equatable, Codable {
    var streamID: String
    var lastEventID: String?
    var liveReasoningText: String
    var streamingAssistantMessageID: String?
    var liveToolCalls: [ToolCall]

    init(
        streamID: String,
        lastEventID: String?,
        liveReasoningText: String,
        streamingAssistantMessageID: String?,
        liveToolCalls: [ToolCall] = []
    ) {
        self.streamID = streamID
        self.lastEventID = lastEventID
        self.liveReasoningText = liveReasoningText
        self.streamingAssistantMessageID = streamingAssistantMessageID
        self.liveToolCalls = liveToolCalls
    }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case lastEventID
        case liveReasoningText
        case streamingAssistantMessageID
        case liveToolCalls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(String.self, forKey: .streamID)
        lastEventID = try container.decodeIfPresent(String.self, forKey: .lastEventID)
        liveReasoningText = try container.decodeIfPresent(String.self, forKey: .liveReasoningText) ?? ""
        streamingAssistantMessageID = try container.decodeIfPresent(String.self, forKey: .streamingAssistantMessageID)
        liveToolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .liveToolCalls) ?? []
    }
}

@MainActor
final class LiveRunBookmarkStore {
    static let shared = LiveRunBookmarkStore()
    static let visibilityKeyPrefix = "semreh.liveRunBookmark."
    static let maxReasoningCharacters = 8_192

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, sessionID: String) -> LiveRunBookmark? {
        guard let data = defaults.data(forKey: key(server: server, sessionID: sessionID)) else {
            return nil
        }
        return try? JSONDecoder().decode(LiveRunBookmark.self, from: data)
    }

    func save(_ bookmark: LiveRunBookmark, server: URL, sessionID: String) {
        var trimmed = bookmark
        if trimmed.liveReasoningText.count > Self.maxReasoningCharacters {
            trimmed.liveReasoningText = String(trimmed.liveReasoningText.suffix(Self.maxReasoningCharacters))
        }
        defaults.set(try? JSONEncoder().encode(trimmed), forKey: key(server: server, sessionID: sessionID))
    }

    func remove(server: URL, sessionID: String) {
        defaults.removeObject(forKey: key(server: server, sessionID: sessionID))
    }

    func resetForTesting() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.visibilityKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(server: URL, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Self.visibilityKeyPrefix)\(serverKey)|\(sessionKey)"
    }
}
