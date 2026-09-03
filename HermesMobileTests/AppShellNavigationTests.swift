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

    func testCapsuleMotionProvidesResponsiveIgnitionAndCriticallyDampedProgression() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 2, startedAt: start)

        XCTAssertEqual(motion.position(at: start), 0, accuracy: 0.001)
        XCTAssertEqual(motion.position(at: start.addingTimeInterval(0.06)) / 2, 0.32, accuracy: 0.08)
        XCTAssertEqual(motion.position(at: start.addingTimeInterval(0.14)) / 2, 0.70, accuracy: 0.08)
        XCTAssertEqual(motion.position(at: start.addingTimeInterval(0.22)) / 2, 0.94, accuracy: 0.08)
        XCTAssertEqual(motion.position(at: start.addingTimeInterval(0.28)) / 2, 1.0, accuracy: 0.001)
    }

    func testCapsuleMotionFormsAnAsymmetricBridgeAndSettlesSmoothly() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 1, startedAt: start)
        let tabWidth: CGFloat = 100

        let midpoint = motion.frame(at: start.addingTimeInterval(0.12), tabWidth: tabWidth)
        XCTAssertGreaterThan(midpoint.width, tabWidth * 1.25)
        XCTAssertGreaterThan(midpoint.right - (midpoint.left + tabWidth), 0)

        let settled = motion.frame(at: start.addingTimeInterval(0.28), tabWidth: tabWidth)
        XCTAssertTrue(settled.isSettled)
        XCTAssertEqual(settled.width, tabWidth, accuracy: 0.01)
        XCTAssertEqual(motion.position(at: start.addingTimeInterval(0.28)), 1, accuracy: 0.001)
    }

    func testCapsuleMotionRetargetsContinuouslyAndReduceMotionCanSettleImmediately() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 2, startedAt: start)
        let interruptionTime = start.addingTimeInterval(0.12)
        let current = motion.position(at: interruptionTime)
        let currentDeformation = motion.deformation(at: interruptionTime)
        let retargeted = motion.retargeted(to: 1, at: interruptionTime)

        XCTAssertEqual(retargeted.start, current, accuracy: 0.001)
        XCTAssertEqual(retargeted.initialDeformation, currentDeformation, accuracy: 0.001)
        XCTAssertEqual(retargeted.position(at: interruptionTime), current, accuracy: 0.001)
        XCTAssertEqual(retargeted.frame(at: interruptionTime, tabWidth: 100).travel, 0, accuracy: 0.001)

        let reduceMotion = AppShellCapsuleMotion(settledAt: 1)
        let immediate = reduceMotion.frame(at: start, tabWidth: 100)
        XCTAssertEqual(reduceMotion.position(at: start), 1, accuracy: 0.001)
        XCTAssertEqual(immediate.width, 100, accuracy: 0.001)
    }

    func testCapsuleMotionNormalReversePreservesTheRenderedFrameAtRetarget() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 2, startedAt: start)
        let retargetTime = start.addingTimeInterval(0.12)
        let before = motion.frame(at: retargetTime, tabWidth: 100)
        let reversed = motion.retargeted(to: 1, at: retargetTime)
        let after = reversed.frame(at: retargetTime, tabWidth: 100)

        assertRenderedFramesMatch(before, after)
    }

    func testCapsuleMotionRapidRepeatedRetargetPreservesEachRenderedFrame() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 2, startedAt: start)
        let firstRetargetTime = start.addingTimeInterval(0.10)
        let first = motion.retargeted(to: 1, at: firstRetargetTime)
        let secondRetargetTime = firstRetargetTime.addingTimeInterval(0.05)
        let before = first.frame(at: secondRetargetTime, tabWidth: 100)
        let second = first.retargeted(to: 0, at: secondRetargetTime)
        let after = second.frame(at: secondRetargetTime, tabWidth: 100)

        assertRenderedFramesMatch(before, after)
    }

    func testCapsuleMotionReconcilesAnExternalSurfaceChange() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 0, startedAt: start)

        let reconciled = motion.reconciled(
            to: 2,
            reduceMotion: false,
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(reconciled.start, 0, accuracy: 0.001)
        XCTAssertEqual(reconciled.target, 2, accuracy: 0.001)
        XCTAssertEqual(reconciled.position(at: start.addingTimeInterval(1)), 0, accuracy: 0.001)
    }

    func testCapsuleMotionReconciliationDoesNotRestartMatchingInternalTarget() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 2, startedAt: start)
        let date = start.addingTimeInterval(0.12)

        let reconciled = motion.reconciled(to: 2, reduceMotion: false, at: date)

        XCTAssertEqual(reconciled, motion)
    }

    func testCapsuleMotionSettlesWhenReduceMotionTurnsOnMidGlide() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let motion = AppShellCapsuleMotion(start: 0, target: 2, startedAt: start)

        let settled = motion.reconciled(
            to: 2,
            reduceMotion: true,
            at: start.addingTimeInterval(0.12)
        )

        XCTAssertEqual(settled.start, 2, accuracy: 0.001)
        XCTAssertEqual(settled.target, 2, accuracy: 0.001)
        XCTAssertEqual(settled.position(at: start.addingTimeInterval(0.12)), 2, accuracy: 0.001)
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

    private func assertRenderedFramesMatch(
        _ before: AppShellCapsuleMotionFrame,
        _ after: AppShellCapsuleMotionFrame,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.left, before.left, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(after.right, before.right, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(after.width, before.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(
            after.center,
            before.center,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(after.position, before.position, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(
            after.highlight,
            before.highlight,
            accuracy: 0.001,
            file: file,
            line: line
        )
    }
}
