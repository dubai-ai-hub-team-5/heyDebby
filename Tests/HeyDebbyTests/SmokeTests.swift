import AppKit
import XCTest
@testable import HeyDebby

final class SmokeTests: XCTestCase {
    func testAgentTaskParsing() {
        XCTAssertEqual(agentTask(from: "agent: clean up my desktop"), "clean up my desktop")
        XCTAssertNil(agentTask(from: "what does this button do"))
    }

    func testBackendResolution() {
        XCTAssertEqual(resolveBackend("", codex: true, claudeCLI: true), "codex")
        XCTAssertEqual(resolveBackend("", codex: false, claudeCLI: true), "claudecli")
        XCTAssertEqual(resolveBackend("openai", codex: true, claudeCLI: true), "openai")
    }

    func testMicrophoneLevelBounds() {
        XCTAssertEqual(micLevel(rms: 0), 0)
        XCTAssertEqual(micLevel(rms: 1), 1)

        let speakingLevel = micLevel(rms: 0.03)
        XCTAssertGreaterThan(speakingLevel, 0)
        XCTAssertLessThan(speakingLevel, 1)
    }

    func testTalkChordTransitionTracksHoldDuration() {
        let flags: NSEvent.ModifierFlags = [.control, .option]
        let pressed = transitionTalkChord(
            TalkChordTransitionState(), input: .flagsChanged(flags), at: 10
        )
        XCTAssertEqual(pressed.effects, [.talkChanged(down: true, heldFor: 0)])

        let released = transitionTalkChord(
            pressed.state, input: .flagsChanged([]), at: 10.75
        )
        XCTAssertEqual(released.effects, [.talkChanged(down: false, heldFor: 0.75)])
    }

    @MainActor
    func testProactiveKillChordDoesNotTriggerTalk() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        let result = transitionTalkChord(
            TalkChordTransitionState(),
            input: .keyDown(keyCode: TalkChordMonitor.proactiveKillKeyCode, flags: flags, isRepeat: false),
            at: 12
        )
        XCTAssertEqual(result.effects, [.proactiveKill])
        XCTAssertFalse(result.state.isTalkDown)
    }
}
