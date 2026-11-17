# Tranq: Clean Voice Dictation for macOS

> **Read this in another language: [Русский](README_RU.md)**

<p align="left">
  <a href="https://github.com/Nuteres/Tranq/releases">
    <img src="https://img.shields.io/github/v/release/Nuteres/Tranq?style=for-the-badge&color=black&logo=apple" alt="Latest Release">
  </a>
  <a href="https://github.com/Nuteres/Tranq/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-black?style=for-the-badge" alt="License">
  </a>
</p>

> [!IMPORTANT]
> **Disclaimer: Early Alpha Stage**
> The application is currently in an active alpha development stage. A comprehensive overhaul is underway to strip out legacy and redundant features from the original fork while introducing truly useful capabilities.
> At this stage, architecture and interfaces are undergoing rapid changes: certain features may be unstable, and parts of the original repository functionality may be removed or completely rewritten in upcoming releases.
> The app is being reshaped for new workflows. Current development efforts are strictly focused on perfecting and polishing the **macOS** version. Once all core features are refined and stable, cross-platform porting to **Windows** and **Linux** will follow.

Voice dictation for macOS. Press a key, speak, and clean, concise text lands in the active field — without filler words, slips, or repeated thoughts. Speech is recognized on-device by Sber GigaAM v3; text cleanup runs on the language model of your choice: local and offline, an external API, or a corporate gateway. No telemetry.

The app targets Russian speech with Latin-script technical terms.

---

## Capabilities

* **Offline recognition.** GigaAM v3 runs on-device; audio never leaves your Mac. Whisper Large-v3 Turbo and Medium are available as English-only alternatives.
* **Speech cleanup.** With a cleanup model set up, local or through an API, it removes filler words, self-corrections, and repeated thoughts while keeping the speaker's own words and facts. Without one, only sounds and stutters are removed. Numbers and Latin terms are guarded by a validator: if the model drops or invents something, the text is inserted without its edits.
* **App and site rules.** Set a tone for an app or for the site in the active browser tab, for example a business tone for work email. Without a rule, every app gets the same clean speech, unless direct mode is on.
* **Prompt mode.** Your hotkey with Shift turns one dictation into a request for an AI assistant. Enabled in Settings.
* **Three processing options:**
  * local models without network access, with a recommendation based on your Mac's memory;
  * an external API: OpenRouter, OpenAI, Anthropic, DeepSeek, Ollama;
  * an OpenAI-compatible corporate gateway. If it is unreachable, for example with VPN off, the text is inserted without cleanup and the overlay shows a notice.
* **Terms.** Built-in dictionaries for IT, business, HR, finance, and more. Latin terms stay in Latin script, Russian abbreviations stay in Cyrillic. The dictionary learns from your note edits.
* **Insertion under the cursor** in any app. Two hotkey modes: toggle and push-to-talk.
* **History.** Notes with the final text, the raw transcript, and the voice recording. Edit text in place.

---

## Technical Specifications

| Component | Specification |
| :--- | :--- |
| **OS** | macOS 13.5+ |
| **Architecture** | Apple Silicon |
| **Languages & Frameworks** | Swift 5.9+, SwiftUI, AppKit |
| **Speech Models** | GigaAM v3 RNN-T, Whisper Large-v3 Turbo, Whisper Medium |
| **Local Cleanup** | llama-server with Gemma 4 and T-lite models |
| **HotKey Subsystem** | Carbon Event Manager for combos, CGEventTap for modifiers and `Fn` |
| **Telemetry** | None |

---

## Installation

1. Download `Tranq.dmg` from the [Releases](https://github.com/Nuteres/Tranq/releases) section.
2. Drag `Tranq.app` to your `/Applications` folder.

### Gatekeeper Quarantine Removal

This build is distributed as open source without a paid Apple Developer certificate. If macOS blocks the initial launch, remove the quarantine attribute:

```bash
xattr -cr /Applications/Tranq.app
```

*(Alternatively: Control + Right-click `Tranq.app` -> Open -> Confirm).*

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
* **Hotkey with Shift:** Runs one dictation in prompt mode, when enabled.
* **Menu Bar Status Icon:** Open the app and settings.

---

## Building from Source

```bash
# 1. Clone the repository
git clone https://github.com/Nuteres/Tranq.git
cd Tranq

# 2. Fetch the GigaAM model and llama-server; versions and SHA-256 checksums are pinned in the script
scripts/fetch-deps.sh

# 3. Open the project in Xcode
open Tranq.xcodeproj
```

Press `⌘ + R` in Xcode to build and run. Xcode downloads the transcribe.cpp engine on its own as a Swift package.

Release DMG, ad-hoc signed with hardened runtime:

```bash
scripts/build-dmg.sh
```

Unit tests also run in GitHub Actions on every push to `main` and on pull requests. They do not need models or binaries.

---

## License

Licensed under the [MIT License](LICENSE).
Original work Copyright (c) 2026 Kozak Developer (Berliner187).
Modifications Copyright (c) 2026 Nuteres.
