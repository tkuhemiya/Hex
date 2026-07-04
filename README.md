# Hex (personal fork)

Personal fork of [kitlangton/Hex](https://github.com/kitlangton/Hex). Not for upstream — use at your own risk.

## What's different

- **OpenAI cloud transcription** — Replaces local Whisper/Parakeet models. Requires an OpenAI API key (`gpt-4o-mini-transcribe`).
- **Realtime streaming** — Streams audio to OpenAI's realtime API for live transcription.
- **Single-press hotkey toggle** — Press to start, press again to stop (Esc cancels).
- **No history** — Removed history persistence; in-memory only.
- **No auto-updates** — Removed Sparkle; updates are manual.

## Requirements

- macOS 14+, Apple Silicon
- Xcode 15+ (`xcode-select` path must point to it)

## Build & install

```bash
./scripts/build.sh               # Release build
./scripts/install.sh              # Copies to /Applications

# Debug (separate bundle ID, won't clash):
./scripts/build.sh Debug
./scripts/install.sh Debug
```

Output: `build/Build/Products/Release/Hex.app`

```bash
open build/Build/Products/Release/Hex.app
```

## Setup

1. Open Hex → Settings → **Transcription Model** → paste your OpenAI API key.
2. Grant Microphone, Accessibility, and Input Monitoring when prompted.
3. Set your hotkey in Settings → Hotkey.

An API key is required — every transcription goes through OpenAI's cloud.

## Troubleshooting

**`Macro must be enabled before it can be used`** — always use `./scripts/build.sh` (it passes `-skipMacroValidation`).

**Signing errors** — set `DEVELOPMENT_TEAM` env var, or the script defaults to ad-hoc signing (fine for local use).

**Stale cache** — `./scripts/build.sh clean Release`

## Tests

```bash
cd HexCore && swift test
```
