# Cloud-Only Migration Plan

Remove all on-device transcription (WhisperKit, Parakeet/FluidAudio) and ship a cloud-only app that transcribes exclusively via the **OpenAI platform** (`/v1/audio/transcriptions`).

**Scope:** OpenAI only for now. No other cloud providers, no local Core ML models, no model downloads.

**Status:** Implemented.

---

## Goals

1. **Delete** every code path, dependency, setting, and UI surface tied to local model download, storage, or inference.
2. **Keep** the existing cloud transcription flow (`OpenAITranscriptionClient`, API key in Keychain, `CloudTranscriptionModel`).
3. **Simplify** readiness: transcription is available when an OpenAI API key is configured (and network is reachable at request time).

## Non-Goals

- Adding Azure, Groq, Deepgram, or other providers.
- Keeping offline / on-device fallback.
- Preserving downloaded Whisper or Parakeet model files on disk (users can delete manually; we stop referencing those paths).
- **Migrate** existing users who have a local model selected in saved settings. (As there are no real users, it's just me using it.)

---

## Current State

The app supports three transcription backends:

| Backend | Package | Example model ID |
|---------|---------|------------------|
| OpenAI cloud | None (URLSession) | `gpt-4o-mini-transcribe-2025-12-15` |
| Whisper (local) | WhisperKit | `openai_whisper-base` |
| Parakeet (local) | FluidAudio | `parakeet-tdt-0.6b-v3-coreml` |

Cloud is already the **default** for new installs (`HexSettings.selectedModel` defaults to `CloudTranscriptionModel.gpt4oMiniTranscribe`). Local infrastructure remains for parity with upstream Hex.

---

## Phase 1 — Remove SPM Dependencies

### Packages to unlink from the Hex target

| Package | Repository | Notes |
|---------|------------|-------|
| **WhisperKit** | `https://github.com/argmaxinc/WhisperKit` | Whisper Core ML download + inference |
| **FluidAudio** | `https://github.com/FluidInference/FluidAudio` | Parakeet Core ML download + inference |

**Steps**

- [ ] In Xcode: Hex target → Frameworks → remove `WhisperKit` and `FluidAudio`.
- [ ] Remove both `XCRemoteSwiftPackageReference` entries from `Hex.xcodeproj/project.pbxproj` if not cleaned automatically.
- [ ] Resolve packages and confirm `Package.resolved` no longer pins `whisperkit`, `fluidaudio`, or Whisper-only transitives (`swift-transformers`, `swift-jinja`).
- [ ] Build (`xcodebuild -scheme Hex -configuration Release`) and fix any remaining `import` errors.

**Expected transitive removals** (pulled in by WhisperKit today):

- `swift-transformers`
- `swift-jinja`

---

## Phase 2 — Delete Local-Model Source Files

### Delete outright

| Path | Reason |
|------|--------|
| `Hex/Clients/ParakeetClient.swift` | Parakeet load/transcribe/delete |
| `Hex/Clients/ParakeetClipPreparer.swift` | Parakeet short-audio padding |
| `HexCore/Sources/HexCore/Models/ParakeetModel.swift` | Parakeet model identifiers |
| `HexCore/Sources/HexCore/Logic/ModelPatternMatcher.swift` | Whisper glob pattern resolution |
| `docs/parakeet-short-audio-plan.md` | Obsolete design doc |

### Delete or replace the Model Download feature

The entire `Hex/Features/Settings/ModelDownload/` directory (~5 files) exists for download progress, curated local model lists, and “Show in Finder”:

| Path | Action |
|------|--------|
| `ModelDownloadFeature.swift` | **Replace** with a slim `CloudModelFeature` (see Phase 4) |
| `ModelDownloadView.swift` | **Replace** with `CloudModelView` |
| `CuratedList.swift` | **Delete** (no “show more” local models) |
| `CuratedRow.swift` | **Replace** with a single cloud model row or inline picker |
| `StarRatingView.swift` | **Keep** only if still used for cloud model metadata display |

### Simplify `models.json`

**Current:** 1 cloud + 5 local entries in `Hex/Resources/Data/models.json`.

**Target:** Cloud-only catalog, e.g.:

```json
[
  {
    "displayName": "GPT-4o Mini Transcribe",
    "internalName": "gpt-4o-mini-transcribe-2025-12-15",
    "provider": "openai",
    "size": "Cloud",
    "accuracyStars": 5,
    "speedStars": 5,
    "storageSize": "—"
  }
]
```

If only one OpenAI model is supported initially, the picker can be removed entirely and `CloudTranscriptionModel` becomes the single source of truth.

---

## Phase 3 — Refactor Transcription Client

### `Hex/Clients/TranscriptionClient.swift`

Today this file is a ~460-line actor managing WhisperKit + Parakeet + a small cloud branch.

**Target API** (keep the `@DependencyClient` name so call sites change minimally):

```swift
@DependencyClient
struct TranscriptionClient {
  var transcribe: @Sendable (URL, TranscriptionOptions, @escaping (Progress) -> Void) async throws -> String
  var isReady: @Sendable () async -> Bool  // API key present
}
```

**Remove entirely**

- `downloadModel`, `deleteModel`, `isModelDownloaded`
- `getRecommendedModels`, `getAvailableModels`
- `WhisperKit` instance, `ParakeetClient`, model folder paths
- All Hugging Face / Core ML download and load logic

**Keep / consolidate**

- Cloud branch → delegate to `OpenAITranscriptionClient`
- `APIKeyClient` for key retrieval

### Replace `DecodingOptions` (WhisperKit type)

`TranscriptionFeature.swift` imports WhisperKit only for `DecodingOptions`.

**Add** in HexCore:

```swift
public struct TranscriptionOptions: Sendable, Equatable {
  public var language: String?
  public init(language: String? = nil)
}
```

Update `TranscriptionFeature` to build `TranscriptionOptions(language: state.hexSettings.outputLanguage)` instead of `DecodingOptions(...)`.

### Logging

- [ ] Remove `HexLog.parakeet` category from `HexCore/Sources/HexCore/Logging.swift` (or leave enum case unused until a major log cleanup).
- [ ] Retain `HexLog.transcription` and `HexLog.models` only if still meaningful; consider renaming `models` → `cloud` or folding into `transcription`.

---

## Phase 4 — Simplify Settings & Readiness UX

### Replace model bootstrap with API-key readiness

Today, `ModelBootstrapState` tracks download progress and “model ready” for local models. Cloud models are treated as always downloaded.

**Target behavior**

| Check | When |
|-------|------|
| API key in Keychain | Required before recording |
| Network | Required at transcription time (existing URLSession errors surface to user) |
| Model on disk | **Removed** |

### Files to update

| File | Changes |
|------|---------|
| `Hex/Models/ModelBootstrapState.swift` | **Delete** or rename to `TranscriptionReadinessState` with only `isAPIKeyConfigured`, `lastError` |
| `Hex/Features/App/AppFeature.swift` | `ensureSelectedModelReadiness()` → check API key, not `isModelDownloaded` |
| `Hex/Features/Transcription/TranscriptionFeature.swift` | Gate on API key readiness; remove `modelBootstrapState.isModelReady` download semantics |
| `Hex/Features/Settings/SettingsFeature.swift` | Remove `ModelDownloadFeature` child; add `CloudModelFeature` or inline cloud model + API key actions |
| `Hex/Features/Settings/ModelSectionView.swift` | API key section + simple model display (no download UI) |
| `Hex/Features/Settings/SettingsView.swift` | **Always** show language picker (remove Parakeet guard) |
| `Hex/Views/AutoDownloadBannerView.swift` | **Delete** or repurpose for “API key missing” / network errors only |

### `HexSettings` cleanup

| Field | Action |
|-------|--------|
| `selectedModel` | **Keep** — still identifies which OpenAI model ID to send |
| `hasCompletedModelBootstrap` | **Remove** — obsolete; add migration to drop from persisted JSON |
| `outputLanguage` | **Keep** — passed to OpenAI `language` parameter |

### New minimal settings child reducer (optional)

`CloudModelFeature` responsibilities:

- Load cloud model metadata from `models.json` (or hardcode `CloudTranscriptionModel.allCases`)
- Reflect `hasOpenAIAPIKey` from `APIKeyClient`
- No download, delete, show-in-finder, or progress actions

---

## Phase 5 — Remove Launch & Storage Local-Model Plumbing

| File | Changes |
|------|---------|
| `Hex/App/HexAppDelegate.swift` | Remove `XDG_CACHE_HOME` setup and FluidAudio cache logging |
| `HexCore/Sources/HexCore/StoragePaths.swift` | Remove `hexModelsDirectory`, `hexParakeetModelsDirectory`; keep only paths still used (e.g. history, app support root) |
| `.gitignore` | Remove `FluidAudio/` entry if no longer relevant |

**On-disk paths we stop referencing** (no automatic deletion required):

- `~/Library/Application Support/com.kitlangton.Hex/models/argmaxinc/whisperkit-coreml/…`
- `~/Library/Containers/…/FluidAudio/Models/…`

---

## Phase 6 — User Settings Migration

Users upgrading from a local-model build may have `selectedModel` set to Whisper or Parakeet IDs.

### Migration rule

On settings load (in `HexSettings` decode or a one-time migration reducer):

```
if !CloudTranscriptionModel.isCloud(selectedModel) {
  selectedModel = CloudTranscriptionModel.gpt4oMiniTranscribe.identifier
}
```

### `hasCompletedModelBootstrap`

- Drop from `HexSettings` Codable schema.
- Ensure `HexSettingsMigrationTests` and `Fixtures/HexSettings/v1.json` are updated.
- Bump settings version if the project uses explicit schema versioning.

### Test fixtures

- [ ] Update `HexCore/Tests/HexCoreTests/Fixtures/HexSettings/v1.json` — use a cloud model ID or verify migration rewrites legacy values.
- [ ] Update `HexSettingsMigrationTests.swift` assertions.

---

## Phase 7 — Tests

| Area | Action |
|------|--------|
| `HexCore` unit tests | Remove Parakeet/Whisper assumptions; add migration test for local → cloud `selectedModel` |
| `HexTests/RecordingRaceTests.swift` | Replace `modelBootstrapState: Shared(.init(isModelReady: true))` with API-key-ready mock |
| `TranscriptionClient` | Add dependency test double that only implements cloud transcribe + `isReady` |
| Integration | Manual: record → transcribe with valid key; record without key → clear error |

No new tests are required for WhisperKit/Parakeet removal beyond fixing existing breakage.

---

## Phase 8 — Documentation & Changelog

| File | Updates |
|------|---------|
| `README.md` | Cloud-only positioning; remove Whisper/Parakeet setup |
| `AGENTS.md` / `CLAUDE.md` | Remove model download, cache paths, WhisperKit/FluidAudio package notes |
| `Hex/Resources/changelog.md` | User-facing note via changeset |
| `.changeset/*.md` | `bun run changeset:add-ai major "Remove local models; cloud-only OpenAI transcription"` |

**User-facing release notes should mention**

- Local models and offline transcription are removed.
- An OpenAI API key is required.
- Users with a local model selected will be moved to the default cloud model.

---

## Phase 9 — Entitlements & Network

Cloud-only makes network **mandatory** for transcription.

- [ ] Confirm `com.apple.security.network.client = true` remains in `Hex.entitlements` (already set for HF downloads).
- [ ] Review error copy when offline: surface `OpenAITranscriptionError` / URLSession errors clearly in the transcription indicator.

No new entitlements required for OpenAI HTTPS.

---

## Implementation Order (Recommended)

Execute in this order to keep the app buildable after each step:

1. **Phase 6 (migration logic)** — safe to land early; prevents broken state for users mid-upgrade.
2. **Phase 3 (TranscriptionClient)** — cloud-only client + `TranscriptionOptions`; fix `TranscriptionFeature` compile errors.
3. **Phase 1 (SPM)** — unlink WhisperKit and FluidAudio once nothing imports them.
4. **Phase 2 (file deletion)** — remove Parakeet files, ModelPatternMatcher, obsolete docs.
5. **Phase 4 (settings UX)** — replace ModelDownload feature, readiness checks, language picker.
6. **Phase 5 (launch/storage)** — HexAppDelegate, StoragePaths cleanup.
7. **Phase 7–9 (tests, docs, changelog)** — finish and ship.

---

## File Checklist (Quick Reference)

### Delete

- [ ] `Hex/Clients/ParakeetClient.swift`
- [ ] `Hex/Clients/ParakeetClipPreparer.swift`
- [ ] `HexCore/Sources/HexCore/Models/ParakeetModel.swift`
- [ ] `HexCore/Sources/HexCore/Logic/ModelPatternMatcher.swift`
- [ ] `Hex/Features/Settings/ModelDownload/` (after replacement)
- [ ] `docs/parakeet-short-audio-plan.md`
- [ ] `Hex/Models/ModelBootstrapState.swift` (if replaced)
- [ ] `Hex/Views/AutoDownloadBannerView.swift` (if unused)

### Heavily edit

- [ ] `Hex/Clients/TranscriptionClient.swift`
- [ ] `Hex/Features/Transcription/TranscriptionFeature.swift`
- [ ] `Hex/Features/App/AppFeature.swift`
- [ ] `Hex/Features/Settings/SettingsFeature.swift`
- [ ] `Hex/Features/Settings/ModelSectionView.swift`
- [ ] `Hex/Features/Settings/SettingsView.swift`
- [ ] `Hex/App/HexAppDelegate.swift`
- [ ] `HexCore/Sources/HexCore/StoragePaths.swift`
- [ ] `HexCore/Sources/HexCore/Settings/HexSettings.swift`
- [ ] `Hex/Resources/Data/models.json`

### Keep as-is (cloud path)

- [ ] `Hex/Clients/OpenAITranscriptionClient.swift`
- [ ] `Hex/Clients/APIKeyClient.swift`
- [ ] `HexCore/Sources/HexCore/Models/CloudTranscriptionModel.swift`

---

## Risk Register

| Risk | Mitigation |
|------|------------|
| Users lose offline transcription | Call out in changelog and settings; set expectations before upgrade |
| Legacy `selectedModel` breaks transcription | Phase 6 migration on load |
| Large diff hard to review | Land in ordered PRs per implementation order above |
| Upstream Hex merge conflicts | This fork diverges intentionally; document cloud-only fork in README |
| API cost / latency | Out of scope for removal work; optional future settings copy about OpenAI billing |

---

## Effort Estimate

| Phase | Estimate |
|-------|----------|
| 1 — SPM removal | 0.5 day |
| 2 — File deletion | 0.5 day |
| 3 — TranscriptionClient | 0.5–1 day |
| 4 — Settings UX | 1–1.5 days |
| 5 — Launch/storage | 0.25 day |
| 6 — Migration | 0.25 day |
| 7–9 — Tests + docs | 0.5–1 day |
| **Total** | **~3–4 days** |

---

## Definition of Done

- [ ] App builds and tests pass with no WhisperKit or FluidAudio dependency.
- [ ] No `import WhisperKit`, `import FluidAudio`, or references to Parakeet/Whisper local model IDs in production code.
- [ ] Transcription requires and uses OpenAI API key only.
- [ ] Settings show API key UI and optional cloud model selection; no download/delete/storage UI.
- [ ] Language picker always available for cloud transcription.
- [ ] Legacy local `selectedModel` values migrate to default cloud model.
- [ ] Changeset and docs updated for release.
