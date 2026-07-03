# In-Memory Transcription Plan

Send recorded audio directly to the OpenAI transcription endpoint as an in-memory buffer. **No disk writes** for recordings, transcripts, or history during normal operation.

**Status:** Implemented.

---

## Decisions (locked)

| # | Topic | Decision |
|---|--------|----------|
| 1 | Retention | **Zero retention.** No history files, no in-memory “last transcript,” no History tab, no “Copy last transcript” menu item. |
| 2 | Recording backends | **Both in-memory.** Primary `SuperFastCaptureController` and `AVAudioRecorder` fallback accumulate PCM in RAM; neither writes a temp WAV. |
| 3 | Legacy on-disk data | **Leave alone.** Stop writing new data; do not delete existing `transcription_history.json` or `Recordings/` on upgrade. |
| 4 | Paste failure | **Clipboard fallback only.** If Cmd+V / menu / accessibility paste fails, leave the transcript on the system clipboard. No notification. |
| 5 | Paste success + clipboard | **No restore.** Do not snapshot or restore the user’s prior clipboard. After paste, the transcript remains on the clipboard. Remove the “Copy to clipboard” setting. User manages clipboard externally. |

---

## Goals

1. **Eliminate temp audio files** between `stopRecording` and `OpenAITranscriptionClient.transcribe`.
2. **Remove all transcription history** — UI, settings, shared state, persistence client, and on-disk JSON.
3. **Simplify pasteboard flow** — clipboard + Cmd+V only; no snapshot/restore dance.
4. **Keep** cloud transcription (`OpenAITranscriptionClient`), hotkey semantics, word remappings/removals, and paste orchestration fallbacks.

## Non-Goals

- Streaming audio to OpenAI while still recording (API expects a complete file in one multipart request).
- Deleting legacy history/audio files from existing installs.
- Changing OpenAI model, API key storage, or hotkey recording modes.
- Adding notifications for paste failure.

---

## Current Flow (disk-backed)

```
stopRecording
  → grace sleep (~20–80 ms)
  → AVAudioFile.finish → temp .wav on disk
  → Data(contentsOf: url)           // read back into RAM
  → multipart POST to OpenAI
  → word remappings
  → transcriptPersistence.save      // move wav to Application Support (if history on)
  → pasteboard.paste
  → delete temp file
```

The upload path already uses in-memory `Data`; the recording layer is what forces disk I/O.

---

## Target Flow (in-memory)

```
stopRecording
  → finalize in-memory PCM buffer
  → encode WAV header + PCM → Data
  → multipart POST to OpenAI (Data directly)
  → word remappings
  → pasteboard.paste
  → discard Data (no files)
```

```mermaid
sequenceDiagram
    participant HK as HotKey
    participant Rec as RecordingClient
    participant Cap as CaptureController
    participant OAI as OpenAI API
    participant Paste as PasteboardClient

    HK->>Rec: stopRecording()
    Rec->>Cap: finishRecording() → PCM buffer
    Cap->>Rec: encode WAV in memory
    Rec-->>HK: CapturedAudio(data)
    HK->>OAI: POST multipart(audio Data)
    OAI-->>HK: text
    HK->>Paste: paste(text)
    Note over Paste: Set clipboard → Cmd+V<br/>No restore; transcript stays on clipboard
```

---

## Phase 1 — Core types

### `CapturedAudio` (new, HexCore or Hex/Clients)

```swift
public struct CapturedAudio: Sendable, Equatable {
  public let wavData: Data
  public let duration: TimeInterval
}
```

- **Format:** 16 kHz, mono, 32-bit float PCM wrapped in a standard WAV container (same as today’s capture settings).
- **Encoding:** Add `WAVEncoder` (or similar) in HexCore that writes a WAV header + interleaved/le PCM bytes into `Data`. Used at stop time by both backends.

### API signature changes

| Client | Today | Target |
|--------|-------|--------|
| `RecordingClient.stopRecording` | `async -> URL` | `async -> CapturedAudio` |
| `TranscriptionClient.transcribe` | `(URL, …) async throws -> String` | `(Data, …) async throws -> String` |
| `OpenAITranscriptionClient.transcribe` | `url: URL` | `audioData: Data, filename: String` |

`TranscriptionFeature` actions:

- Replace `transcriptionResult(String, URL, TimeInterval)` with `transcriptionResult(String, TimeInterval)`.
- Remove all `audioURL` cleanup `defer` blocks and `FileManager.removeItem` calls in the transcription path.

---

## Phase 2 — In-memory capture engine

### `SuperFastCaptureController`

**Today:** `ActiveRecording` holds `AVAudioFile` + `url`; buffers written via `file.write(from:)`.

**Target:**

- Replace `AVAudioFile` with an in-memory accumulator (e.g. `FloatRingBuffer`-style growable `[Float]` or append-only `Data`).
- `beginRecording` no longer takes a `URL`.
- `finishRecording()` returns accumulated samples (or pre-encoded `Data`); drop `url` from `ActiveRecording`.
- Pre-roll: unchanged logic — prepend ring-buffer samples into the accumulator.
- **Stop grace period:** Revisit after in-memory switch. May reduce or remove the grace sleep if there is no file flush; keep a minimal buffer-drain wait if the processing queue can still be mid-write.

### `RecordingClient` — capture-engine path

- Remove `makeCaptureRecordingURL()`, temp `hex-capture-*.wav` paths, and `duplicateCurrentRecording()`.
- `stopRecording()` returns `CapturedAudio(wavData:encoded, duration:)`.

### `RecordingClient` — AVAudioRecorder fallback

**Today:** Records to `recordingURL` (`temporaryDirectory/recording.wav`), copies on stop.

**Target:**

- Option A (preferred): Stop using `AVAudioRecorder` file URL entirely; tap/delegate into the same in-memory accumulator + `WAVEncoder`. *If too invasive:* record to `NSMutableData` via a custom `AVAudioRecorder` isn’t supported — use `AVAudioEngine` tap for fallback too, or accumulate via `AudioBuffer` from recorder’s meter API.
- Option B (pragmatic): On fallback only, record to RAM using `AVAudioEngine` duplicate path (reuse capture controller’s converter pipeline without ring-buffer warm mode).
- **Do not** leave a disk fallback; both paths must return `CapturedAudio`.

---

## Phase 3 — OpenAI client

### `OpenAITranscriptionClient`

- Add `transcribe(audioData: Data, filename: String, model:language:apiKey:)`.
- Remove `Data(contentsOf: url)`; caller passes encoded WAV `Data`.
- `filename` can be a constant like `"recording.wav"` (API needs a filename in multipart disposition, not a real path).

### `TranscriptionClient` / `TranscriptionClientLive`

- Thread `Data` through; log byte count instead of `lastPathComponent`.

---

## Phase 4 — Remove history & persistence

### Delete or gut

| Item | Action |
|------|--------|
| `Hex/Features/History/HistoryFeature.swift` | **Delete** |
| `HexCore/.../TranscriptPersistenceClient.swift` | **Delete** |
| `HexCore/.../TranscriptionHistory.swift` (`Transcript`, `TranscriptionHistory`) | **Delete** |
| `Hex/Features/Settings/HistorySectionView.swift` | **Delete** |
| `Hex/App/MenuBarCopyLastTranscriptButton.swift` | **Delete** |
| `HexTests/HistoryPlaybackTests.swift` | **Delete** |

### `AppFeature`

- Remove `history` tab from `ActiveTab`, sidebar `List`, and `NavigationSplitView` detail.
- Remove `HistoryFeature` scope from reducer.
- Remove `copyLastTranscript` (or equivalent) menu action that reads `transcriptionHistory`.

### `TranscriptionFeature`

- Remove `@Shared(.transcriptionHistory)`, `transcriptPersistence` dependency.
- Replace `finalizeRecordingAndStoreTranscript` with `finalizeAndPaste(result:)` — paste + sound only.
- Remove `sourceAppBundleID` / `sourceAppName` capture if only used for history (verify no other consumers).

### `HexSettings` (HexCore)

Remove fields and `SettingsField` entries:

- `saveTranscriptionHistory`
- `maxHistoryEntries`
- `copyToClipboard`

Keep `useClipboardPaste` unless we collapse to clipboard-only paste (see Phase 5).

### Shared keys

- Remove `@Shared(.transcriptionHistory)` / `FileStorageKey` for `transcription_history.json`.

---

## Phase 5 — Simplify pasteboard

### `PasteboardClient.pasteWithClipboard`

**Remove:**

- `PasteboardSnapshot` struct and restore logic.
- Post-paste `Task.sleep(500ms)` + `snapshot.restore`.
- Branching on `hexSettings.copyToClipboard`.

**Keep:**

1. Write transcript to `NSPasteboard.general`.
2. `waitForPasteboardCommit` (short poll).
3. `performPaste` — try Cmd+V, menu item, accessibility in order.
4. On failure: transcript already on clipboard; log at notice level. No user notification.

### Settings UI

- Remove “Copy to clipboard” toggle from `GeneralSectionView`.
- Consider removing “Use clipboard to insert” if AppleScript typing fallback is no longer desired; **default recommendation:** keep the toggle for users who prefer keystroke simulation without touching clipboard first (orthogonal to restore removal).

---

## Phase 6 — Tests & cleanup

### Update

- `HexTests/RecordingRaceTests.swift` — `stopRecording` returns `CapturedAudio`; remove `transcriptPersistence` mocks.
- `HexCore` settings migration tests — drop assertions for removed keys; add fixture without history fields.
- Any transcription integration tests — pass `Data` instead of file URLs.

### Verify manually

- [ ] Press-and-hold hotkey → transcript appears in frontmost app.
- [ ] Double-tap lock → second tap stops → transcript appears.
- [ ] Paste into TextEdit (success path).
- [ ] Paste into a field that rejects paste (e.g. password field) → transcript on clipboard.
- [ ] Capture-engine path: no `hex-capture-*.wav` in `/tmp` during/after recording.
- [ ] Fallback path (simulate capture-engine failure): still no persistent temp files.
- [ ] History tab gone; no “Copy last transcript” in menu bar.
- [ ] Word remappings/removals still apply before paste.

### Logging

- Log `wavData.count` and duration at stop/transcribe boundaries.
- Do **not** log transcript text without `privacy: .private` (existing convention).

---

## Implementation order

1. **`WAVEncoder` + `CapturedAudio`** — unit test round-trip (PCM → WAV `Data` → validate header).
2. **`SuperFastCaptureController` in-memory** — highest traffic path.
3. **`RecordingClient.stopRecording` → `CapturedAudio`** — wire through grace-period tuning.
4. **`OpenAITranscriptionClient` + `TranscriptionClient`** — accept `Data`.
5. **`TranscriptionFeature`** — end-to-end without files.
6. **AVAudioRecorder fallback → in-memory** — parity for edge cases.
7. **Remove history/persistence/UI** — large deletion pass.
8. **Pasteboard simplification** — remove restore + `copyToClipboard` setting.
9. **Tests + manual QA checklist.**

---

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Long recordings consume RAM | 16 kHz float32 ≈ 64 KB/s; 5 min ≈ 19 MB — acceptable. Cap max recording duration later if needed. |
| Fallback path still hits disk | Block merge until fallback is verified in-memory; add test that temp directory has no new `.wav` after session. |
| OpenAI rejects in-memory WAV | Reuse exact same PCM format/settings as current `AVAudioFile` writer; add encoder unit test with golden header bytes. |
| Paste failure loses text for users without clipboard manager | Transcript remains on clipboard by design (Q4); acceptable per product decision. |
| Legacy `transcription_history.json` orphaned | Intentional (Q3); document in changelog that history feature was removed. |

---

## Changelog (when shipped)

```bash
bun run changeset:add-ai minor "Transcribe in memory without saving audio; remove transcription history"
```

Suggested summary: *Record and send audio to OpenAI without writing temp files. Remove transcription history, saved audio, and related settings. Simplify clipboard paste behavior.*

---

## Files touched (expected)

**New**

- `HexCore/Sources/HexCore/Audio/WAVEncoder.swift` (or `Hex/Clients/WAVEncoder.swift`)
- `HexCore/Sources/HexCore/Models/CapturedAudio.swift`

**Modified**

- `Hex/Clients/SuperFastCaptureController.swift`
- `Hex/Clients/RecordingClient.swift`
- `Hex/Clients/OpenAITranscriptionClient.swift`
- `Hex/Clients/TranscriptionClient.swift`
- `Hex/Clients/PasteboardClient.swift`
- `Hex/Features/Transcription/TranscriptionFeature.swift`
- `Hex/Features/App/AppFeature.swift`
- `Hex/Features/Settings/SettingsFeature.swift`
- `Hex/Features/Settings/GeneralSectionView.swift`
- `HexCore/Sources/HexCore/Settings/HexSettings.swift`
- `HexTests/RecordingRaceTests.swift`
- `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift`
- `Hex.xcodeproj/project.pbxproj`

**Deleted**

- `Hex/Features/History/HistoryFeature.swift`
- `Hex/Features/Settings/HistorySectionView.swift`
- `Hex/App/MenuBarCopyLastTranscriptButton.swift`
- `HexCore/Sources/HexCore/TranscriptPersistenceClient/TranscriptPersistenceClient.swift`
- `HexCore/Sources/HexCore/Models/TranscriptionHistory.swift`
- `HexTests/HistoryPlaybackTests.swift`
