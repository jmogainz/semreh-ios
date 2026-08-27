import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    func testExistingTranscriptUsesBottomAsItsInitialLayoutAnchor() {
        XCTAssertEqual(ChatScrollPolicy.initialTranscriptAnchor, .bottom)
    }

    func testTranscriptSizeChangesStayBottomAnchoredOnlyWhileFollowingLatest() {
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true),
            .bottom
        )
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
        XCTAssertNil(
            ChatScrollPolicy.sizeChangeAnchor(
                shouldFollowLatestMessage: true,
                isComposerResizing: true
            )
        )
    }

    func testVisibleTranscriptPolicyChoosesTopmostPartiallyVisibleRow() {
        let frames = [
            "row-above": CGRect(x: 0, y: -120, width: 300, height: 80),
            "row-visible": CGRect(x: 0, y: -20, width: 300, height: 100),
            "row-later": CGRect(x: 0, y: 90, width: 300, height: 100),
            "row-below": CGRect(x: 0, y: 420, width: 300, height: 100)
        ]

        XCTAssertEqual(
            ChatTranscriptVisibilityPolicy.firstVisibleMessageID(
                frames: frames,
                viewportHeight: 400
            ),
            "row-visible"
        )
    }

    func testVisibleTranscriptPolicyReturnsNilWhenNoRowIntersectsViewport() {
        let frames = [
            "row-above": CGRect(x: 0, y: -120, width: 300, height: 80),
            "row-below": CGRect(x: 0, y: 420, width: 300, height: 100)
        ]

        XCTAssertNil(
            ChatTranscriptVisibilityPolicy.firstVisibleMessageID(
                frames: frames,
                viewportHeight: 400
            )
        )
    }

    func testComposerResizeOnlyRejoinsLatestWhenReaderStillFollowsBottom() {
        XCTAssertTrue(
            ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: true,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: false,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: true,
                isUserInteracting: true
            )
        )
    }

    func testInitialAsyncWorkWaitsForNavigationAppearanceCompletion() {
        XCTAssertFalse(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: false))
        XCTAssertTrue(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: true))
    }

    func testWarmLiveReopenSkipsBlockingTranscriptReload() {
        XCTAssertFalse(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(hasPreservedTranscript: true)
        )
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(hasPreservedTranscript: false)
        )
    }

    func testKnownStreamIDWithoutTranscriptStillReloadsHistory() {
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(hasPreservedTranscript: false)
        )
    }

    func testNewViewModelStillReconcilesAfterPaintingCachedRows() {
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: true,
                wasReusedFromOpenSessionStore: false
            )
        )
    }

    func testReusedWarmViewModelCanSkipColdOpenReload() {
        XCTAssertFalse(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: true,
                wasReusedFromOpenSessionStore: true
            )
        )
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: false,
                wasReusedFromOpenSessionStore: true
            )
        )
    }

    func testLeavingAChatKeepsTheLiveStreamAttached() {
        XCTAssertTrue(ChatNavigationLifecyclePolicy.shouldKeepLiveStreamOnDisappear)
    }

    func testBottomThresholdLoosensWhileStreaming() {
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: false),
            ChatScrollPolicy.bottomDetectionThreshold
        )
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.streamingBottomDetectionThreshold
        )
        XCTAssertGreaterThan(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.bottomThreshold(isStreaming: false)
        )
    }

    func testIsNearBottomUsesIdleThresholdWhenNotStreaming() {
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 80, isStreaming: false))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 81, isStreaming: false))
    }

    func testIsNearBottomUsesLooserThresholdWhileStreaming() {
        // 120pt is past the idle threshold but still "near bottom" while streaming.
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: false))
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: true))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 161, isStreaming: true))
    }

    func testShouldEnterReadingOlderRequiresHysteresisPastThreshold() {
        let threshold = ChatScrollPolicy.bottomThreshold(isStreaming: false)
        let hysteresis = ChatScrollPolicy.readingOlderHysteresis

        XCTAssertFalse(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis,
                isStreaming: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis + 1,
                isStreaming: false
            )
        )
    }

    func testAutoScrollPausedWhileUserInteracting() {
        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: true,
                cooldownUntil: nil
            )
        )
    }

    func testAutoScrollPausedDuringCooldownWindow() {
        let now = Date()
        let future = now.addingTimeInterval(0.1)

        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: future,
                now: now
            )
        )
    }

    func testAutoScrollResumesAfterCooldownExpires() {
        let now = Date()
        let past = now.addingTimeInterval(-0.1)

        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: past,
                now: now
            )
        )
    }

    func testAutoScrollNotPausedWithoutInteractionOrCooldown() {
        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: nil
            )
        )
    }

    func testCooldownDeadlineIsUserScrollCooldownInFuture() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let deadline = ChatScrollPolicy.cooldownDeadline(after: base)

        XCTAssertEqual(
            deadline.timeIntervalSince(base),
            ChatScrollPolicy.userScrollCooldown,
            accuracy: 0.0001
        )
    }

    func testStreamingTokensDoNotEmitProgrammaticFollowScroll() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldProgrammaticallyFollowStreamTokens(
                shouldFollowLatestMessage: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldProgrammaticallyFollowStreamTokens(
                shouldFollowLatestMessage: false
            )
        )
    }

    func testReadingOlderKeepsTranscriptViewportStableDuringMarkdownResize() {
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
        XCTAssertFalse(ChatScrollPolicy.shouldBumpScrollTriggerForStreamingFlush())
    }


    func testFollowRejoinShouldSnapWithoutAnimation() {
        XCTAssertTrue(
            ChatScrollPolicy.shouldSnapWhenRejoiningLatest(
                wasFollowingLatest: false,
                isNearBottom: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldSnapWhenRejoiningLatest(
                wasFollowingLatest: true,
                isNearBottom: true
            )
        )
    }

    func testFirstEnterWithNoSavedPointRestoresLatest() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: true,
                lastVisibleMessageID: nil
            ),
            .latest
        )
    }

    func testLeaveWhileFollowingLatestRestoresLatestEvenIfAMessageIDExists() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: true,
                lastVisibleMessageID: "msg-mid"
            ),
            .latest
        )
    }

    func testLeaveWhileReadingOlderRestoresThatMessage() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: false,
                lastVisibleMessageID: "msg-where-i-left"
            ),
            .message(id: "msg-where-i-left")
        )
    }

    func testBlankSavedMessageFallsBackToLatest() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: false,
                lastVisibleMessageID: "   "
            ),
            .latest
        )
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: false,
                lastVisibleMessageID: nil
            ),
            .latest
        )
    }

    func testAppearMustProgrammaticallyRestoreWhenTheTranscriptHasRows() {
        XCTAssertTrue(ChatTranscriptRestorePolicy.shouldProgrammaticallyRestoreOnAppear(hasMessages: true))
        XCTAssertFalse(ChatTranscriptRestorePolicy.shouldProgrammaticallyRestoreOnAppear(hasMessages: false))
    }


    func testStreamingFlushMustNotInvalidateTheTranscriptView() {
        XCTAssertFalse(ChatScrollPolicy.shouldBumpScrollTriggerForStreamingFlush())
    }

    func testLiveSessionReconcileKeepsInProgressChrome() {
        XCTAssertTrue(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: "stream-live",
                localActiveStreamID: nil
            )
        )
        XCTAssertTrue(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: nil,
                localActiveStreamID: "stream-live"
            )
        )
        XCTAssertFalse(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: nil,
                localActiveStreamID: nil
            )
        )
        XCTAssertFalse(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: "   ",
                localActiveStreamID: ""
            )
        )
    }

    func testStreamingBubbleHeightMustNotImplicitlyAnimateUnderTheFinger() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldAnimateStreamingBubbleHeight(
                shouldFollowLatestMessage: false,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldAnimateStreamingBubbleHeight(
                shouldFollowLatestMessage: true,
                isUserInteracting: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldAnimateStreamingBubbleHeight(
                shouldFollowLatestMessage: true,
                isUserInteracting: false
            )
        )
    }

}
