import CoreGraphics
import Foundation
import SwiftUI

/// Pure decision rules for the chat transcript's auto-scroll behavior.
///
/// The transcript keeps app-owned follow-bottom intent separate from
/// user-owned manual scrolling, and a short cooldown after any user
/// interaction prevents streaming layout growth from yanking the viewport
/// while a manual scroll is still settling.
enum ChatScrollPolicy {
    /// Existing transcripts should enter at their latest content as part of the
    /// scroll view's first layout, before the destination becomes visible.
    static let initialTranscriptAnchor = UnitPoint.bottom

    /// Rich Markdown can finish measuring after the scroll view's initial
    /// layout. Keep those size changes bottom-pinned only while the app still
    /// owns follow-latest intent; return nil as soon as the reader scrolls away.
    static func sizeChangeAnchor(
        shouldFollowLatestMessage: Bool,
        isComposerResizing: Bool = false
    ) -> UnitPoint? {
        guard !isComposerResizing else { return nil }
        return shouldFollowLatestMessage ? .bottom : nil
    }

    /// A composer resize is a viewport change, not new transcript content. Preserve
    /// a reader's position during the resize; only re-pin a user who was already
    /// following the latest content and is not actively dragging the transcript.
    static func shouldFollowAfterComposerResize(
        wasFollowingLatest: Bool,
        isUserInteracting: Bool
    ) -> Bool {
        wasFollowingLatest && !isUserInteracting
    }

    /// Distance (pt) from the bottom within which we treat the transcript as
    /// pinned to the latest content while idle.
    static let bottomDetectionThreshold: CGFloat = 80

    /// Looser bottom threshold while a response is streaming, so small layout
    /// jitter from incoming tokens does not flip follow state off.
    static let streamingBottomDetectionThreshold: CGFloat = 160

    /// Extra distance past the bottom threshold required before the composer
    /// chrome collapses into its compact "reading older" presentation.
    static let readingOlderHysteresis: CGFloat = 64

    /// How long automatic follow-scroll stays paused after the user last
    /// interacted with the scroll view.
    static let userScrollCooldown: TimeInterval = 0.25

    static func bottomThreshold(isStreaming: Bool) -> CGFloat {
        isStreaming ? streamingBottomDetectionThreshold : bottomDetectionThreshold
    }

    static func isNearBottom(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom <= bottomThreshold(isStreaming: isStreaming)
    }

    /// True once the user has scrolled far enough above the bottom that the
    /// composer chrome should collapse. The hysteresis keeps the chrome stable
    /// when hovering right around the bottom threshold.
    static func shouldEnterReadingOlder(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom > bottomThreshold(isStreaming: isStreaming) + readingOlderHysteresis
    }

    static func cooldownDeadline(after date: Date = Date()) -> Date {
        date.addingTimeInterval(userScrollCooldown)
    }

    /// Automatic follow-scroll is paused while the user is actively touching the
    /// scroll view and for a brief cooldown window afterward. Explicit user
    /// actions (tapping scroll-to-bottom, sending a message) bypass this.
    static func isAutoScrollPaused(
        isUserInteracting: Bool,
        cooldownUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        if isUserInteracting {
            return true
        }

        guard let cooldownUntil else {
            return false
        }

        return now < cooldownUntil
    }

    /// Streaming follow is owned by `defaultScrollAnchor(..., for: .sizeChanges)`.
    /// Extra `scrollTo` on every token is what lags when the user flicks back down.
    static func shouldProgrammaticallyFollowStreamTokens(shouldFollowLatestMessage: Bool) -> Bool {
        _ = shouldFollowLatestMessage
        return false
    }

    /// Token/reasoning flushes must not bump `streamingScrollTrigger`. That Int is
    /// passed into `ChatTranscriptView`, so incrementing it re-evaluates every row
    /// while the user is reading older messages — the iMessage-level hitch.
    static func shouldBumpScrollTriggerForStreamingFlush() -> Bool {
        false
    }

    /// Keep the active row's height changes unanimated. MarkdownUI already
    /// performs expensive measurement; animating every token makes UIKit's
    /// scroll view chase a moving target under the user's finger.
    static func shouldAnimateStreamingBubbleHeight(
        shouldFollowLatestMessage: Bool,
        isUserInteracting: Bool
    ) -> Bool {
        _ = shouldFollowLatestMessage
        _ = isUserInteracting
        return false
    }

    static func shouldSnapWhenRejoiningLatest(
        wasFollowingLatest: Bool,
        isNearBottom: Bool
    ) -> Bool {
        isNearBottom && !wasFollowingLatest
    }
}

/// Keeps transcript reconciliation and other state-heavy startup work out of
/// the system navigation transition. Cache preparation remains synchronous so
/// an available transcript can participate in the destination's first layout.
enum ChatInitialAppearancePolicy {
    static func shouldBeginAsyncWork(hasCompletedAppearance: Bool) -> Bool {
        hasCompletedAppearance
    }

    static func shouldReloadTranscriptOnAppear(hasPreservedTranscript: Bool) -> Bool {
        !hasPreservedTranscript
    }

    /// A newly created view model may paint cached rows before its first
    /// authoritative network load. Those rows are not proof that the model is
    /// warm; only a model reused from `OpenChatSessionStore` can skip the cold
    /// open reconciliation.
    static func shouldReloadTranscriptOnAppear(
        hasPreservedTranscript: Bool,
        wasReusedFromOpenSessionStore: Bool
    ) -> Bool {
        if wasReusedFromOpenSessionStore {
            return !hasPreservedTranscript
        }

        return true
    }
}

enum ChatTranscriptRestoreTarget: Equatable {
    case latest
    case message(id: String)
}

/// Leave/reopen must land at latest or the last-read message.
/// `defaultScrollAnchor(.bottom)` plus LazyVStack often paints mid-list first.
enum ChatTranscriptRestorePolicy {
    static func target(
        wasFollowingLatest: Bool,
        lastVisibleMessageID: String?
    ) -> ChatTranscriptRestoreTarget {
        if wasFollowingLatest {
            return .latest
        }

        let trimmed = lastVisibleMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return .latest
        }
        return .message(id: trimmed)
    }

    static func shouldProgrammaticallyRestoreOnAppear(hasMessages: Bool) -> Bool {
        hasMessages
    }
}

enum ChatLiveReconcilePolicy {
    /// A live SSE owner already has in-progress tools/reasoning in RAM.
    /// A later `/api/session` page must not wipe that chrome — that is the
    /// "everything dumps in after a wait" hitch.
    static func shouldPreserveLiveRunChrome(
        loadedActiveStreamID: String?,
        localActiveStreamID: String?
    ) -> Bool {
        func present(_ value: String?) -> Bool {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty
        }
        return present(loadedActiveStreamID) || present(localActiveStreamID)
    }
}
