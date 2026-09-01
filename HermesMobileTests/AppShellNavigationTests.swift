import XCTest
@testable import HermesMobile

@MainActor
final class AppShellNavigationTests: XCTestCase {
    func testPrimarySurfacesHaveStableOrderAndLabels() {
        XCTAssertEqual(AppShellSurface.allCases, [.sessions, .control, .you])
        XCTAssertEqual(AppShellSurface.sessions.title, "Sessions")
        XCTAssertEqual(AppShellSurface.control.title, "Control")
        XCTAssertEqual(AppShellSurface.you.title, "You")
    }

    func testOnlySessionsOffersTheShellPrimaryAction() {
        XCTAssertTrue(AppShellSurface.sessions.showsPrimaryAction)
        XCTAssertFalse(AppShellSurface.control.showsPrimaryAction)
        XCTAssertFalse(AppShellSurface.you.showsPrimaryAction)
    }

    func testControlUsesTheProductTitleAndDoesNotUseAppleControlCenterName() {
        XCTAssertEqual(AppShellSurface.control.title, "Control")
        XCTAssertNotEqual(AppShellSurface.control.title, "Control Center")
    }

    func testNestedControlDestinationHidesBothShellBarsAndResetsOnReentry() {
        var navigationState = ControlNavigationState()

        XCTAssertFalse(navigationState.isNestedDestinationPresented)
        XCTAssertTrue(
            AppShellChromePolicy.showsTopBar(
                surface: .control,
                isSessionConversationPresented: false,
                isControlDestinationPresented: false
            )
        )
        XCTAssertTrue(
            AppShellChromePolicy.showsBottomBar(
                isConversationPresented: false,
                isControlDestinationPresented: false
            )
        )

        navigationState.select(.tasks)

        XCTAssertTrue(navigationState.isNestedDestinationPresented)
        XCTAssertFalse(
            AppShellChromePolicy.showsTopBar(
                surface: .control,
                isSessionConversationPresented: false,
                isControlDestinationPresented: true
            )
        )
        XCTAssertFalse(
            AppShellChromePolicy.showsBottomBar(
                isConversationPresented: false,
                isControlDestinationPresented: true
            )
        )

        navigationState.resetForSurfaceDeactivation()

        XCTAssertFalse(navigationState.isNestedDestinationPresented)
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
