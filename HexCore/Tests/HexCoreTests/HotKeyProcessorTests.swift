//
//  HotKeyProcessorTests.swift
//  HexCoreTests
//
//  Created by Kit Langton on 1/27/25.
//

import Dependencies
import Foundation
@testable import HexCore
import Sauce
import Testing

struct HotKeyProcessorTests {
    @Test
    func toggle_startsOnFirstPress_standard() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true, expectedState: .recording),
            ]
        )
    }

    @Test
    func toggle_startsOnFirstPress_modifierOnly() {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true, expectedState: .recording),
            ]
        )
    }

    @Test
    func toggle_ignoresReleaseWhileRecording() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true, expectedState: .recording),
            ]
        )
    }

    @Test
    func toggle_stopsOnSecondPress_standard() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 0.4, key: .a, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false, expectedState: .idle),
            ]
        )
    }

    @Test
    func toggle_stopsOnSecondPress_modifierOnly() {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 0.4, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false, expectedState: .idle),
            ]
        )
    }

    @Test
    func toggle_ignoresHoldWhileRecording() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.5, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 1.0, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 2.0, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 2.1, key: .a, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func toggle_escCancels() {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.5, key: .escape, modifiers: [], expectedOutput: .cancel, expectedIsMatched: false, expectedState: .idle),
            ]
        )
    }

    @Test
    func toggle_multiModifierRequiresFullChord() {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
                ScenarioStep(time: 0.1, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 0.3, key: nil, modifiers: [.option, .command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func toggle_keyRepeatIgnored() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.05, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 0.1, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func toggle_ignoresOtherKeysWhileRecording() {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 0.3, key: .a, modifiers: [.option], expectedOutput: nil, expectedIsMatched: true),
                ScenarioStep(time: 0.4, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func toggle_escIgnoredWhileIdle() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .escape, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func toggle_requiresReleaseBeforeSecondPress() {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.1, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
            ]
        )
    }
}

struct ScenarioStep {
    let time: TimeInterval
    let key: Key?
    let modifiers: Modifiers
    let expectedOutput: HotKeyProcessor.Output?
    let expectedIsMatched: Bool?
    let expectedState: HotKeyProcessor.State?

    init(
        time: TimeInterval,
        key: Key? = nil,
        modifiers: Modifiers = [],
        expectedOutput: HotKeyProcessor.Output? = nil,
        expectedIsMatched: Bool? = nil,
        expectedState: HotKeyProcessor.State? = nil
    ) {
        self.time = time
        self.key = key
        self.modifiers = modifiers
        self.expectedOutput = expectedOutput
        self.expectedIsMatched = expectedIsMatched
        self.expectedState = expectedState
    }
}

func runScenario(
    hotkey: HotKey,
    steps: [ScenarioStep]
) {
    let sortedSteps = steps.sorted { $0.time < $1.time }
    var currentTime: TimeInterval = 0

    var processor = withDependencies {
        $0.date.now = Date(timeIntervalSince1970: currentTime)
    } operation: {
        HotKeyProcessor(hotkey: hotkey)
    }

    for step in sortedSteps {
        currentTime = step.time
        withDependencies {
            $0.date.now = Date(timeIntervalSince1970: currentTime)
        } operation: {
            let keyEvent = KeyEvent(key: step.key, modifiers: step.modifiers)
            let actualOutput = processor.process(keyEvent: keyEvent)

            if let expected = step.expectedOutput {
                #expect(
                    actualOutput == expected,
                    "\(step.time)s: expected output \(expected), got \(String(describing: actualOutput))"
                )
            } else {
                #expect(
                    actualOutput == nil,
                    "\(step.time)s: expected no output, got \(String(describing: actualOutput))"
                )
            }

            if let expMatch = step.expectedIsMatched {
                #expect(
                    processor.isMatched == expMatch,
                    "\(step.time)s: expected isMatched=\(expMatch), got \(processor.isMatched)"
                )
            }

            if let expState = step.expectedState {
                #expect(
                    processor.state == expState,
                    "\(step.time)s: expected state=\(expState), got \(processor.state)"
                )
            }
        }
    }
}

// MARK: - Recording Decision Tests

struct RecordingDecisionTests {
    @Test
    func shortRecordingIsDiscarded() {
        #expect(RecordingDecisionEngine.decide(elapsed: 0.1) == .discardShortRecording)
    }

    @Test
    func longRecordingProceeds() {
        #expect(RecordingDecisionEngine.decide(elapsed: 0.3) == .proceedToTranscription)
    }

    @Test
    func recordingAtThresholdProceeds() {
        #expect(RecordingDecisionEngine.decide(elapsed: RecordingDecisionEngine.minimumRecordingDuration) == .proceedToTranscription)
    }
}

// MARK: - Mouse Click Tests

struct MouseClickTests {
    @Test
    func mouseClick_ignoredWhileRecording() {
        var processor = HotKeyProcessor(hotkey: HotKey(key: nil, modifiers: [.option]))

        _ = processor.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]))
        #expect(processor.processMouseClick() == nil)
        #expect(processor.state == .recording)
    }
}
