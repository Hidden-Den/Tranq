# Golosok: Local Speech Recognition for macOS

> **Read this in another language: [Русский](README_RU.md)**

<p align="left">
  <a href="https://github.com/Nuteres/Golosok/releases">
    <img src="https://img.shields.io/github/v/release/Nuteres/Golosok?style=for-the-badge&color=black&logo=apple" alt="Latest Release">
  </a>
  <a href="https://github.com/Nuteres/Golosok/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-black?style=for-the-badge" alt="License">
  </a>
</p>

Native voice dictation and offline audio transcription powered by Sber GigaAM v3 and Whisper Large v3. Hardware-accelerated inference for Apple Silicon. Zero telemetry, zero external tracking, 100% offline.

---

## Architecture & Capabilities

* **Complete Autonomy (Zero Cloud):** Local speech-to-text inference runs directly on-device. Audio streams never leave the Mac. Zero telemetry, tracking, or telemetry endpoints.
* **Direct Input:** Press your global hotkey (default `⌥ + Space`, or single key `Fn`) — dictate — text is inserted directly under your active cursor in any application (VS Code, Notion, Telegram, Xcode, Obsidian, Slack, browsers).
* **Hardware Acceleration:** Neural network models run on Apple Silicon (M1–M5) leveraging Core ML, Apple Neural Engine (ANE), and Metal Performance Shaders without CPU overheating.
* **Dual Operation Modes:**
  * **Toggle (Переключение):** Press once to start recording, press again to stop, transcribe, and insert.
  * **Push-to-Talk (Рация):** Hold key down while speaking, release to transcribe and paste immediately.
* **Offline Batch Transcription:** Transcribe audio and video recordings of any length (MP3, WAV, M4A, AAC, FLAC, OGG, OPUS, MP4, MOV, WebM, MKV).
* **Direct AI Post-Processing (Optional):** Clean up punctuation, summarize, or translate transcriptions via direct Bring-Your-Own-Key connections (OpenAI, Groq, DeepSeek) or local Ollama instances, with zero intermediate proxy servers.

---

## Technical Specifications & Stack

| Component | Specification |
| :--- | :--- |
| **OS** | macOS 13.5+ (Ventura, Sonoma, Sequoia) |
| **Architecture** | Apple Silicon (arm64: M1 / M2 / M3 / M4 / M5) |
| **Languages & Frameworks** | Swift 5.9+, SwiftUI, AppKit |
| **Speech Models** | GigaAM v3 RNN-T (GGUF Q8_0) / Whisper Large v3 |
| **Acceleration Engines** | Core ML / Apple Neural Engine (ANE) / MPS |
| **HotKey Subsystem** | Carbon Event Manager (combos) + Quartz CGEventTap (modifiers like `Fn`) |
| **Memory Footprint** | ~70 MB idle / ~100 MB active inference |
| **Telemetry & Analytics** | None (Completely removed) |
| **Distribution Format** | Compressed `.dmg` disk image (~260 MB) |

---

## Installation

1. Download `Golosok.dmg` from the [Releases](https://github.com/Nuteres/Golosok/releases) section.
2. Drag `Golosok.app` to your `/Applications` folder.

### Gatekeeper Quarantine Removal

This build is distributed as open source without a paid Apple Developer certificate. If macOS blocks the initial launch, remove the quarantine attribute:

```bash
xattr -cr /Applications/Golosok.app
```

*(Alternatively: Control + Right-click `Golosok.app` -> Open -> Confirm).*

---

## System Permissions

* **Microphone:** Required for capturing voice input.
* **Accessibility:** Required for simulated keyboard insertion (`⌘ + V`) into active applications and global modifier event taps (`Fn`).

---

## Controls

* **Global Hotkey (Default `⌥ + Space` or `Fn`):**
  * In **Toggle** mode: 1st press starts recording, 2nd press finalizes transcription and pastes text.
  * In **Push-to-Talk** mode: Hold key to record, release to transcribe.
* **`ESC`:** Cancels recording immediately without saving or pasting.
* **Menu Bar Status Icon:** Access recent dictation history, copy snippets, and open settings.

---

## Building from Source

```bash
# 1. Clone the repository
git clone https://github.com/Nuteres/Golosok.git
cd Golosok

# 2. Download GigaAM model weights
curl -L -o Golosok/gigaam.gguf https://huggingface.co/memoravox/gigaam-v3-e2e-rnnt-gguf/resolve/main/gigaam-v3-e2e-rnnt-Q8_0.gguf

# 3. Open project in Xcode
open Golosok.xcodeproj
```

Press `⌘ + R` in Xcode to build and run, or build via command line:

```bash
xcodebuild -scheme Golosok -configuration Release build
```

---

## License

Licensed under the [MIT License](LICENSE).
Original work Copyright (c) 2026 Kozak Developer (Berliner187).
Modifications Copyright (c) 2026 Nuteres.
