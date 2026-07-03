# Hex (local fork)

Personal fork with **OpenAI cloud transcription** (`gpt-4o-mini-transcribe-2025-12-15`). Not upstream Hex — build and install on this machine only.

## Requirements

- macOS 14+, Apple Silicon
- Xcode installed (for `xcodebuild` only — no need to open the app)

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

## Build & install

```bash
./scripts/build.sh          # Release
./scripts/install.sh

# Debug (separate bundle ID, won't clash with official Hex):
./scripts/build.sh Debug
./scripts/install.sh Debug
```

Output: `build/Build/Products/Release/Hex.app`

Launch:

```bash
open build/Build/Products/Release/Hex.app
```

## Setup

1. Settings → Transcription Model → paste **OpenAI API key**
2. Cloud model is selected by default
3. Grant Microphone, Accessibility, and Input Monitoring when prompted

Transcription uses OpenAI cloud only — an API key is required for every recording.

## Troubleshooting

**`Macro must be enabled before it can be used`** — use `./scripts/build.sh` (includes `-skipMacroValidation`).

**Signing errors** — `export DEVELOPMENT_TEAM=YOUR_TEAM_ID` then rebuild, or use the default ad-hoc signing in the script.

## Tests

```bash
cd HexCore && swift test
```
