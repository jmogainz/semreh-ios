import XCTest
@testable import HermesMobile

@MainActor
final class AppShellNavigationTests: XCTestCase {
    func testPrimarySurfacesHaveStableOrderAndLabels() {
        XCTAssertEqual(AppShellSurface.allCases, [.sessions, .teams, .you])
        XCTAssertEqual(AppShellSurface.sessions.title, "Sessions")
        XCTAssertEqual(AppShellSurface.teams.title, "Teams")
        XCTAssertEqual(AppShellSurface.you.title, "You")
    }

    func testMenuAndPrimaryActionAreLimitedToSessionsAndTeams() {
        XCTAssertTrue(AppShellSurface.sessions.showsMenu)
        XCTAssertTrue(AppShellSurface.sessions.showsPrimaryAction)
        XCTAssertTrue(AppShellSurface.teams.showsMenu)
        XCTAssertTrue(AppShellSurface.teams.showsPrimaryAction)
        XCTAssertFalse(AppShellSurface.you.showsMenu)
        XCTAssertFalse(AppShellSurface.you.showsPrimaryAction)
    }

    func testSessionNavigationStateMarksOnlyConversationDestinationsAsConversation() {
        var state = SessionNavigationState()
        XCTAssertFalse(state.isConversationPresented)

        state.select(SessionSummary(sessionId: "session-1", title: "One"))
        XCTAssertTrue(state.isConversationPresented)

        state.clearDestination()
        state.select(.settings(nil))
        XCTAssertFalse(state.isConversationPresented)

        state.resetForShellSurfaceSwitch()
        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testMessagesStyleUsesShellOnlyAsAnOptIn() {
        let session = SessionSummary(sessionId: "session-1", title: "One")
        let standard = SessionListRowsSection(
            viewModel: SessionListViewModel(server: URL(staticString: "https://example.test")),
            sessions: [session],
            emptyTitle: "Empty",
            emptyDescription: nil,
            isSearchActive: false,
            showsMessageCount: true,
            showsWorkspace: true,
            selectedSessionID: nil,
            actions: Self.noopActions
        )
        let shell = SessionListRowsSection(
            viewModel: SessionListViewModel(server: URL(staticString: "https://example.test")),
            sessions: [session],
            emptyTitle: "Empty",
            emptyDescription: nil,
            isSearchActive: false,
            showsMessageCount: true,
            showsWorkspace: true,
            selectedSessionID: nil,
            actions: Self.noopActions,
            useMessagesStyle: true,
            showsSectionHeader: false
        )

        XCTAssertFalse(standard.useMessagesStyle)
        XCTAssertTrue(shell.useMessagesStyle)
        XCTAssertTrue(standard.showsSectionHeader)
        XCTAssertFalse(shell.showsSectionHeader)
    }

    private static var noopActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: {},
            open: { _ in },
            togglePinned: { _ in },
            archive: { _ in },
            delete: { _ in },
            rename: { _ in },
            duplicate: { _ in },
            move: { _, _ in },
            createProject: { _ in },
            refreshProjects: {},
            export: { _, _ in }
        )
    }
}
