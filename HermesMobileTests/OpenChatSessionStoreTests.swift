import XCTest
@testable import HermesMobile

@MainActor
final class OpenChatSessionStoreTests: XCTestCase {
    override func tearDown() {
        OpenChatSessionStore.shared.resetForTesting()
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testStoreReusesTheSameViewModelForTheSameServerAndSession() throws {
        let first = try makeViewModel(sessionID: "session-abc")
        let reused = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: try XCTUnwrap(URL(string: "https://example.test")),
            creating: first
        )
        let second = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: try XCTUnwrap(URL(string: "https://example.test"))
        )

        XCTAssertTrue(reused === first)
        XCTAssertTrue(second === first)
        XCTAssertTrue(second.wasReusedFromOpenSessionStore)
    }

    @MainActor
    func testStoreRetentionDoesNotStartSessionEventSync() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let viewModel = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            sessionEventStreamClient: streamClient
        )

        // Store retention alone must not open a background event stream.
        // Always-on streams for every retained chat caused main-thread disk
        // I/O and transcript reloads (build 19 lag regression).
        XCTAssertEqual(streamClient.startedURLs.count, 0)

        // ChatView owns the lifecycle: appearing starts, disappearing stops.
        viewModel.startSessionEventSync()
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/sessions/session-abc/events")

        viewModel.stopSessionEventSync()
        XCTAssertEqual(streamClient.stopCount, 1)

        // Re-appearing restarts the stream after an explicit stop.
        viewModel.startSessionEventSync()
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testCursorPersistenceIsDebouncedAcrossStreamingBursts() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "goku.session-event-debounce-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let cursorStore = SessionEventCursorStore(defaults: defaults)
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )

        coordinator.start()
        let connection = streamClient.startedURLs.count - 1
        // Burst of events: in-memory dedupe advances immediately, but no
        // synchronous UserDefaults write happens per event.
        for index in 0..<10 {
            streamClient.emit(.token("chunk \(index)"), lastEventID: "session-abc:\(10 + index)", onConnection: connection)
        }
        XCTAssertNil(cursorStore.load(server: server, profile: nil, sessionID: "session-abc"))

        // Stop flushes the coalesced state once.
        coordinator.stop()
        XCTAssertEqual(
            cursorStore.load(server: server, profile: nil, sessionID: "session-abc"),
            "session-abc:19"
        )
        let seenIDs = cursorStore.loadSeenEventIDs(server: server, profile: nil, sessionID: "session-abc")
        XCTAssertEqual(seenIDs.last, "session-abc:19")
    }

    @MainActor
    func testSidebarRefreshReconcilesOpenTranscriptFromCanonicalServer() async throws {
        var sessionFetches = 0
        let viewModel = try makeViewModel(sessionID: "session-abc") { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionFetches += 1
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Sent from TUI", "message_id": "tui-1", "timestamp": 1770000000},
                  {"role": "assistant", "content": "Canonical response", "message_id": "assistant-1", "timestamp": 1770000001}
                ]
              }
            }
            """, for: request)
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let refreshed = await OpenChatSessionStore.shared.refreshOpenSessions(for: server)

        XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(sessionFetches, 1)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Sent from TUI", "Canonical response"])
    }

    @MainActor
    func testStoreKeepsDistinctViewModelsForDifferentSessions() throws {
        let alpha = try makeViewModel(sessionID: "session-alpha")
        let beta = try makeViewModel(sessionID: "session-beta")
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-alpha"),
            server: server,
            creating: alpha
        )
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-beta"),
            server: server,
            creating: beta
        )

        XCTAssertFalse(alpha === beta)
        XCTAssertEqual(
            OpenChatSessionStore.shared.viewModel(
                session: SessionSummary(sessionId: "session-alpha"),
                server: server
            ) === alpha,
            true
        )
    }

    @MainActor
    func testStoreBoundsInactiveConversationRetentionByRecency() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let first = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-0"),
            server: server
        )

        for index in 1...12 {
            _ = OpenChatSessionStore.shared.viewModel(
                session: SessionSummary(sessionId: "session-\(index)"),
                server: server
            )
        }

        XCTAssertEqual(
            OpenChatSessionStore.shared.retainedSessionCountForTesting,
            OpenChatSessionStore.maxRetainedIdleSessionCount
        )
        let reopenedFirst = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-0"),
            server: server
        )
        XCTAssertFalse(reopenedFirst === first, "The least-recent inactive model should be evicted")
    }

    @MainActor
    func testLeaveDoesNotSuspendALiveRunAndReopenDoesNotNeedSessionFetch() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionFetchCount = 0
        let viewModel = try makeViewModel(sessionID: "session-abc", streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                sessionFetchCount += 1
                XCTFail("Warm reopen must not wait on /api/session to know the run is live.")
                return apiTestJSONResponse("{}", for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial live answer."), lastEventID: "session-abc:4")
        streamClient.emit(
            .toolStarted(ToolStreamEvent(
                eventType: "tool.started",
                name: "search_files",
                preview: "searching",
                args: nil,
                duration: nil,
                isError: nil,
                stableID: "tool-1"
            )),
            lastEventID: "session-abc:5"
        )
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertFalse(viewModel.liveToolCalls.isEmpty)

        ChatNavigationLifecycle.applyViewDisappear(to: viewModel)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)

        let reopened = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server
        )
        XCTAssertTrue(reopened === viewModel)
        XCTAssertTrue(reopened.hasPreservedLiveRun)
        XCTAssertTrue(reopened.hasPreservedTranscript)
        XCTAssertFalse(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: reopened.hasPreservedTranscript
            )
        )
        XCTAssertEqual(reopened.activeStreamID, "stream-123")
        XCTAssertEqual(reopened.liveToolCalls.first?.id, "tool-1")
        XCTAssertEqual(sessionFetchCount, 0)
    }

    @MainActor
    func testSidebarPulseUsesLiveOwnerEvenWhenListPayloadIsIdle() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(sessionID: "session-abc", streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let idleListRow = SessionSummary(sessionId: "session-abc", isStreaming: false)
        XCTAssertTrue(
            SessionRowView.isActiveStreaming(
                idleListRow,
                liveOwnerSessionIDs: OpenChatSessionStore.shared.liveSessionIDs(for: server)
            )
        )
        XCTAssertEqual(
            OpenChatSessionStore.shared.liveStreamIDs(for: server),
            ["stream-123"]
        )
    }

    func testColdOpenAdoptsListStreamIDBeforeSessionFetch() throws {
        let viewModel = try makeViewModel(
            sessionID: "session-abc",
            activeStreamID: "stream-from-list"
        )

        XCTAssertEqual(viewModel.activeStreamID, "stream-from-list")
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertTrue(viewModel.hasPreservedLiveRun)
        XCTAssertFalse(viewModel.hasPreservedTranscript)
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: viewModel.hasPreservedTranscript
            )
        )
        XCTAssertFalse(viewModel.isEstablishingConnection)
    }

    func testColdOpenWithoutKnownStreamDoesNotFlashConnectingOnCachePaint() throws {
        let viewModel = try makeViewModel(sessionID: "session-abc")
        viewModel.markConversationConnectionInProgress()

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isEstablishingConnection)

        viewModel.markConnectionVisiblySlowForTesting()
        XCTAssertTrue(viewModel.isEstablishingConnection)
    }

    func testKnownListStreamReconnectsWithoutWaitingOnSessionFetch() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionFetchCount = 0
        var statusFetchCount = 0
        let viewModel = try makeViewModel(
            sessionID: "session-abc",
            activeStreamID: "stream-from-list",
            streamClient: streamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                statusFetchCount += 1
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "replay_available": true
                }
                """, for: request)
            case "/api/session":
                sessionFetchCount += 1
                XCTFail("Known list stream must attach before /api/session.")
                return apiTestJSONResponse("{}", for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(statusFetchCount, 1)
        XCTAssertEqual(sessionFetchCount, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.activeStreamID, "stream-from-list")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
    }

    @MainActor
    func testKnownListStreamAttachesBeforeTranscriptReloadWhenReplayIsUnavailable() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionFetchCount = 0
        let viewModel = try makeViewModel(
            sessionID: "session-abc",
            activeStreamID: "stream-from-list",
            streamClient: streamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "replay_available": false
                }
                """, for: request)
            case "/api/session":
                sessionFetchCount += 1
                XCTAssertEqual(
                    streamClient.startedURLs.count,
                    1,
                    "The live SSE must attach before a lock-bound transcript reload."
                )
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(sessionFetchCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.activeStreamID, "stream-from-list")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
    }

    @MainActor
    func testRememberedRestorePointSurvivesLeaveAndReopen() throws {
        let viewModel = try makeViewModel(sessionID: "session-abc")
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        viewModel.rememberTranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: "msg-where-i-left"
        )

        let reopened = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server
        )

        XCTAssertTrue(reopened === viewModel)
        XCTAssertEqual(
            reopened.transcriptRestoreTarget,
            .message(id: "msg-where-i-left")
        )
        XCTAssertFalse(reopened.savedFollowingLatest)
    }

    @MainActor
    func testSessionEventCoordinatorUsesIndependentDurableCursor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-tests-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test/"))
        let streamClient = SpySSEStreamingClient()
        let cursorStore = SessionEventCursorStore(defaults: defaults)
        cursorStore.save(
            eventID: "stream-A:9",
            server: server,
            profile: "work",
            sessionID: "session-abc"
        )
        var appliedSnapshots = 0
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: "work",
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.onSnapshot = { snapshot in
            appliedSnapshots += 1
            XCTAssertEqual(snapshot.sessionId, "session-abc")
            return true
        }

        coordinator.start()
        XCTAssertEqual(streamClient.startedURLs.last?.path, "/api/sessions/session-abc/events")
        XCTAssertEqual(streamClient.resumeEventIDs.last ?? nil, "stream-A:9")

        streamClient.emit(.token("journal event"), lastEventID: "stream-A:10")
        // Persistence is debounced: the in-memory cursor advanced but the disk
        // mirror has not been written yet.
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "stream-A:9"
        )

        // A reconnect prefers the fresher in-memory cursor over the stale disk row.
        coordinator.start()
        XCTAssertEqual(streamClient.resumeEventIDs.last ?? nil, "stream-A:10")

        streamClient.emit(.token("duplicate event"), lastEventID: "stream-A:10", onConnection: streamClient.startedURLs.count - 1)
        coordinator.stop()
        // Stop flushes the coalesced cursor once.
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "stream-A:10"
        )

        coordinator.start()
        let liveConnection = streamClient.startedURLs.count - 1
        streamClient.emit(.token("new stream event"), lastEventID: "stream-B:1", onConnection: liveConnection)
        streamClient.emit(.token("old stream replay"), lastEventID: "stream-A:10", onConnection: liveConnection)
        streamClient.emit(.token("opaque one"), lastEventID: "opaque-1", onConnection: liveConnection)
        streamClient.emit(.token("opaque two"), lastEventID: "opaque-2", onConnection: liveConnection)
        streamClient.emit(.token("opaque replay"), lastEventID: "opaque-1", onConnection: liveConnection)
        // Dedupe state is in-memory; the disk mirror still holds the flushed value.
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "stream-A:10"
        )
        coordinator.stop()
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "opaque-2"
        )

        // Reconnect, then receive a snapshot (recovery boundary): the stale
        // cursor and dedupe state are discarded and must not be re-persisted.
        coordinator.start()
        let recoveryConnection = streamClient.startedURLs.count - 1
        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc", title: "Updated")),
            lastEventID: nil,
            onConnection: recoveryConnection
        )

        XCTAssertEqual(appliedSnapshots, 1)
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            nil
        )
        coordinator.stop()
        coordinator.start()
        XCTAssertNil(streamClient.resumeEventIDs.last ?? nil)
        XCTAssertNil(
            cursorStore.load(server: server, profile: "other", sessionID: "session-abc")
        )
    }

    @MainActor
    func testSessionEventCoordinatorReconnectsAfterTerminalAndStopCancelsRetry() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-reconnect-tests-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        var delivered: [SSEEvent] = []
        coordinator.onEvent = { delivered.append($0) }

        coordinator.start()
        streamClient.emit(.streamEnd, lastEventID: "stream-A:10")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.resumeEventIDs.last ?? nil, "stream-A:10")
        XCTAssertEqual(delivered, [.streamEnd])

        coordinator.stop()
        streamClient.emit(.transportError("late"), lastEventID: nil, onConnection: 1)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testSyntheticSessionDoesNotStartSessionEventSync() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: nil),
            server: server,
            sessionEventStreamClient: streamClient
        )

        viewModel.startSessionEventSync()

        XCTAssertTrue(streamClient.startedURLs.isEmpty)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testSessionEventCoordinatorDropsCallbackFromReplacedConnection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-stale-tests-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        var appliedSnapshots = 0
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.onSnapshot = { _ in
            appliedSnapshots += 1
            return true
        }

        coordinator.start()
        coordinator.start()
        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc")),
            lastEventID: "stale",
            onConnection: 0
        )
        XCTAssertEqual(appliedSnapshots, 0)

        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc")),
            lastEventID: "current",
            onConnection: 1
        )
        XCTAssertEqual(appliedSnapshots, 1)
    }

    @MainActor
    func makeViewModel(
        sessionID: String,
        activeStreamID: String? = nil,
        streamClient: SSEStreamingClient? = nil,
        handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) throws -> ChatViewModel {
        if let handler {
            MockURLProtocol.requestHandler = handler
        } else {
            MockURLProtocol.requestHandler = { request in
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)
        let resolvedStreamClient = streamClient ?? SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, activeStreamId: activeStreamID),
            server: server,
            client: client,
            streamClient: resolvedStreamClient,
            approvalStreamClient: SpySSEStreamingClient(),
            clarifyStreamClient: SpySSEStreamingClient(),
            sessionEventStreamClient: SpySSEStreamingClient(),
            listenAudioSession: SpyListenAudioSession(),
            listenRemoteControlCenter: SpyListenRemoteControlCenter()
        )
        if let spy = resolvedStreamClient as? SpySSEStreamingClient {
            spy.flushPendingStreamingContent = { [weak viewModel] in
                viewModel?.flushPendingStreamingContent()
            }
        }
        return viewModel
    }
}

private final class SpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var resumeEventIDs: [String?] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private var eventHandlers: [@MainActor (SSEEvent, String?) -> Void] = []
    var automaticallyFlushPendingStreamingContent = true
    var flushPendingStreamingContent: (() -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        start(url: url, resumeFrom: nil, onEvent: onEvent)
    }

    func start(
        url: URL,
        resumeFrom eventID: String?,
        onEvent: @escaping @MainActor (SSEEvent) -> Void
    ) {
        start(url: url, resumeFrom: eventID) { event, _ in
            onEvent(event)
        }
    }

    func start(
        url: URL,
        resumeFrom eventID: String?,
        onEventWithID onEvent: @escaping @MainActor (SSEEvent, String?) -> Void
    ) {
        startedURLs.append(url)
        resumeEventIDs.append(eventID)
        lastEventID = eventID
        eventHandlers.append(onEvent)
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(
        _ event: SSEEvent,
        lastEventID: String? = nil,
        onConnection index: Int? = nil
    ) {
        self.lastEventID = lastEventID
        let handler = index.flatMap { eventHandlers.indices.contains($0) ? eventHandlers[$0] : nil }
            ?? eventHandlers.last
        handler?(event, lastEventID)
        if automaticallyFlushPendingStreamingContent {
            flushPendingStreamingContent?()
        }
    }
}

private final class SpyListenAudioSession: ListenAudioSessionControlling {
    func activate() {}
    func deactivate() {}
}

@MainActor
private final class SpyListenRemoteControlCenter: ListenRemoteControlControlling {
    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    ) {}

    func update(_ snapshot: ListenNowPlayingSnapshot) {}
    func clear() {}
}
