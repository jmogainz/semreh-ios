import XCTest
@testable import HermesMobile

final class SessionHapticsTests: XCTestCase {
    @MainActor
    func testHapticsRespectEnabledSetting() {
        var feedback: [SessionHapticFeedback] = []

        SessionHaptics.sessionCreated(isEnabled: false) { feedback.append($0) }
        SessionHaptics.pinStateChanged(isEnabled: false) { feedback.append($0) }
        SessionHaptics.archiveStateChanged(isEnabled: false) { feedback.append($0) }
        SessionHaptics.sessionDeleted(isEnabled: false) { feedback.append($0) }
        SessionHaptics.sessionRenamed(isEnabled: false) { feedback.append($0) }

        XCTAssertTrue(feedback.isEmpty)
    }

    @MainActor
    func testSessionActionHapticLanguage() {
        var feedback: [SessionHapticFeedback] = []

        SessionHaptics.sessionCreated(isEnabled: true) { feedback.append($0) }
        SessionHaptics.pinStateChanged(isEnabled: true) { feedback.append($0) }
        SessionHaptics.archiveStateChanged(isEnabled: true) { feedback.append($0) }
        SessionHaptics.sessionDeleted(isEnabled: true) { feedback.append($0) }
        SessionHaptics.sessionRenamed(isEnabled: true) { feedback.append($0) }

        XCTAssertEqual(feedback, [
            .lightImpact,
            .lightImpact,
            .lightImpact,
            .warning,
            .selection
        ])
    }

    @MainActor
    func testSessionDeletionHapticFiresBeforeDeletionOperation() async {
        var events: [String] = []

        await SessionHaptics.commitSessionDeletion(
            isEnabled: true,
            performer: { feedback in
                events.append("haptic:\(feedback)")
            },
            operation: {
                events.append("operation")
                await Task.yield()
            }
        )

        XCTAssertEqual(events, ["haptic:warning", "operation"])
    }

    @MainActor
    func testDisabledSessionDeletionRunsOperationWithoutHaptic() async {
        var events: [String] = []

        await SessionHaptics.commitSessionDeletion(
            isEnabled: false,
            performer: { feedback in events.append("haptic:\(feedback)") },
            operation: { events.append("operation") }
        )

        XCTAssertEqual(events, ["operation"])
    }

    @MainActor
    func testSessionDeletionOperationAndHapticEachRunOnce() async {
        var hapticCount = 0
        var operationCount = 0

        await SessionHaptics.commitSessionDeletion(
            isEnabled: true,
            performer: { _ in hapticCount += 1 },
            operation: { operationCount += 1 }
        )

        XCTAssertEqual(hapticCount, 1)
        XCTAssertEqual(operationCount, 1)
    }
}
