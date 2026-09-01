import XCTest
@testable import HermesMobile

final class TeamsCollaborationTests: XCTestCase {
    func testHumanOnlyRouteDoesNotDispatchToAgents() {
        XCTAssertTrue(TeamRecipient.humans.targets.isEmpty)
    }

    func testAgentRoutesTargetTheExpectedAgents() {
        XCTAssertEqual(TeamRecipient.chabby.targets, [.chabby])
        XCTAssertEqual(TeamRecipient.goku.targets, [.goku])
    }

    func testBothRoutePreservesStableAgentOrderForReconciliation() {
        XCTAssertEqual(TeamRecipient.both.targets, [.chabby, .goku])
    }

    func testRoutingPlanDescribesJointReconciliation() {
        let plan = TeamRoutingPlan(recipient: .both)

        XCTAssertEqual(plan.targets, [.chabby, .goku])
        XCTAssertEqual(plan.phases, [.dispatched, .independentWork, .reconciling, .completed])
    }

    @MainActor
    func testLocalMockHumanOnlySendDoesNotCreateAgentWork() {
        let coordinator = LocalTeamsCoordinator()
        coordinator.recipient = .humans
        coordinator.draft = "Human-only check"

        coordinator.send()

        XCTAssertFalse(coordinator.isDispatching)
        XCTAssertEqual(coordinator.messages.filter { $0.kind == .agent }.count, 0)
        XCTAssertEqual(coordinator.activity.first?.title, "Human-only message")
    }

    @MainActor
    func testLocalMockBothSendCompletesAgentWorkAndReconciliation() async {
        let coordinator = LocalTeamsCoordinator()
        coordinator.recipient = .both
        coordinator.draft = "Run the local collaboration check"

        coordinator.send()
        XCTAssertTrue(coordinator.isDispatching)

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertFalse(coordinator.isDispatching)
        XCTAssertEqual(coordinator.messages.filter { $0.kind == .agent }.count, 2)
        XCTAssertTrue(coordinator.messages.contains { $0.sender == "Team coordinator" })
        XCTAssertEqual(coordinator.activity.first?.title, "Completed")
    }
}
