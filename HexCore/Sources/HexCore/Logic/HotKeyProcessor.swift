//
//  HotKeyProcessor.swift
//  Hex
//
//  Created by Kit Langton on 1/28/25.
//
import Dependencies
import Foundation
import SwiftUI

private let hotKeyLogger = HexLog.hotKey

/// A state machine that processes keyboard events for single-press toggle recording.
///
/// # Behavior
///
/// - **Press hotkey** while idle → start recording (locked, no holding required)
/// - **Press hotkey again** while recording → stop and transcribe
/// - **Release hotkey** while recording → ignored (recording continues)
/// - **ESC** while recording → cancel
///
/// # Architecture
///
/// The processor maintains two states:
/// - `.idle`: Waiting for hotkey activation
/// - `.recording`: Recording active until the hotkey is pressed again or ESC is pressed
///
/// Edge detection via `isHotkeyHeld` ensures key repeat and held keys only trigger once per press.
public struct HotKeyProcessor {
    @Dependency(\.date.now) var now

    // MARK: - Configuration

    /// The hotkey combination to detect (key + modifiers)
    public var hotkey: HotKey

    // MARK: - State

    /// Current state of the processor
    public private(set) var state: State = .idle

    /// Whether the hotkey chord is currently held down (for edge detection)
    private var isHotkeyHeld: Bool = false

    /// When true, all input is ignored until full keyboard release
    private var isDirty: Bool = false

    // MARK: - Initialization

    public init(hotkey: HotKey) {
        self.hotkey = hotkey
    }

    // MARK: - Public API

    /// Returns true if recording is currently active
    public var isMatched: Bool {
        state == .recording
    }

    /// Processes a keyboard event and returns an action to take, if any.
    public mutating func process(keyEvent: KeyEvent) -> Output? {
        if keyEvent.key == .escape, state != .idle {
            let currentState = state
            hotKeyLogger.notice("ESC pressed while state=\(String(describing: currentState))")
            isDirty = true
            resetToIdle()
            return .cancel
        }

        if isDirty {
            if chordIsFullyReleased(keyEvent) {
                isDirty = false
            } else {
                return nil
            }
        }

        if chordMatchesHotkey(keyEvent) {
            return handleHotkeyPress()
        }

        if isHotkeyHeld, isReleaseForActiveHotkey(keyEvent) {
            isHotkeyHeld = false
        }

        return nil
    }

    /// Mouse clicks never affect toggle recording; only ESC stops an active session.
    public mutating func processMouseClick() -> Output? {
        nil
    }
}

// MARK: - State & Output

public extension HotKeyProcessor {
    enum State: Equatable {
        case idle
        case recording
    }

    enum Output: Equatable {
        case startRecording
        case stopRecording
        case cancel
    }
}

// MARK: - Core Logic

extension HotKeyProcessor {
    private mutating func handleHotkeyPress() -> Output? {
        guard !isHotkeyHeld else { return nil }
        isHotkeyHeld = true

        switch state {
        case .idle:
            state = .recording
            return .startRecording
        case .recording:
            resetToIdle()
            return .stopRecording
        }
    }

    private func chordMatchesHotkey(_ e: KeyEvent) -> Bool {
        if hotkey.key != nil {
            return e.key == hotkey.key && e.modifiers.matchesExactly(hotkey.modifiers)
        } else {
            return e.key == nil && e.modifiers.matchesExactly(hotkey.modifiers)
        }
    }

    private func chordIsFullyReleased(_ e: KeyEvent) -> Bool {
        e.key == nil && e.modifiers.isEmpty
    }

    private func isReleaseForActiveHotkey(_ e: KeyEvent) -> Bool {
        if hotkey.key != nil {
            let requiredModifiers = hotkey.modifiers
            let keyReleased = e.key == nil
            let modifiersAreSubset = e.modifiers.isSubset(of: requiredModifiers)

            if keyReleased {
                return modifiersAreSubset
            }

            return false
        } else {
            return e.key == nil && !hotkey.modifiers.isSubset(of: e.modifiers)
        }
    }

    private mutating func resetToIdle() {
        state = .idle
        isHotkeyHeld = false
    }
}
