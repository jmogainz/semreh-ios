import AVFoundation
import XCTest
@testable import HermesMobile

final class ComposerVoiceNoteRecorderTests: XCTestCase {
    // MARK: - Filename

    func testGenerateFilenameIsM4AVoiceNote() {
        let uuid = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let name = VoiceNoteFilename.generate(uuid: uuid)

        XCTAssertTrue(name.hasPrefix("voice-note-"))
        XCTAssertTrue(name.hasSuffix(".m4a"))
        XCTAssertEqual(name, "voice-note-abcdef01.m4a")
        XCTAssertTrue(VoiceNoteFilename.isVoiceNote(name))
    }

    func testTwoGeneratedFilenamesDiffer() {
        XCTAssertNotEqual(VoiceNoteFilename.generate(), VoiceNoteFilename.generate())
    }

    func testIsVoiceNoteRejectsOtherFiles() {
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("photo.jpg"))
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("voice-note-123.wav"))
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("note.m4a"))
    }

    // MARK: - Gesture

    func testCancelArmsOnlyWhenSlidUpPastThreshold() {
        let threshold = ComposerVoiceNoteGesture.cancelTranslationThreshold

        XCTAssertFalse(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: 0))
        XCTAssertFalse(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: -10))
        // Sliding down (positive height) never cancels.
        XCTAssertFalse(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: 200))
        XCTAssertTrue(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: -threshold))
        XCTAssertTrue(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: -200))
    }

    // MARK: - Policy

    func testMaximumDurationStaysWellUnderUploadCap() {
        XCTAssertEqual(ComposerVoiceNoteRecorder.maximumDuration, 300)
        XCTAssertLessThan(ComposerVoiceNoteRecorder.minimumDuration, 1)

        let approxBytesAt32kbps = 32_000 / 8 * Int(ComposerVoiceNoteRecorder.maximumDuration)
        XCTAssertGreaterThan(approxBytesAt32kbps, 0)
    }

    func testRecordingSettingsAreMonoAAC() {
        let settings = ComposerVoiceNoteRecorder.recordingSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
    }
}
