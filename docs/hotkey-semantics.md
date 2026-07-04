# Hex HotKey Semantics

## Overview

Hex uses **single-press toggle** recording:

- **Press hotkey** → start recording (locked, no holding required)
- **Press hotkey again** → stop and transcribe
- **Esc** while recording → cancel

---

## Quick Reference

```
Press Fn (or your hotkey)  →  START recording
... speak ...
Press Fn again             →  STOP, transcribe, paste
```

While recording:

- **Release hotkey** → ignored (recording continues)
- **Other keys/clicks** → ignored (recording continues)
- **Esc** → cancel (with sound)

---

## Edge Detection

Toggle fires on **press edges**, not while held:

1. First press while idle → start
2. Release → no action (arms next press)
3. Second press while recording → stop

Key repeat and held keys only trigger once per press.

---

## Key Interception

| Hotkey type | Intercepted? |
|-------------|--------------|
| Modifier-only (e.g., Fn, Option) | No — passes through to macOS |
| Key + modifier (e.g., Cmd+A) | Yes — blocked from other apps |

---

## Short Recording Discard

If total recording duration is below **0.2 seconds** (instant toggle-off), audio is silently discarded.

---

## Implementation Files

- **Core Logic**: `HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift`
- **Recording Decision**: `HexCore/Sources/HexCore/Logic/RecordingDecision.swift`
- **Feature Integration**: `Hex/Features/Transcription/TranscriptionFeature.swift`
- **Tests**: `HexCore/Tests/HexCoreTests/HotKeyProcessorTests.swift`

---

**Document Version:** 3.0  
**Last Updated:** 2026-07-04
