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

Voice dictation for macOS. Press a key, speak, and clean, concise text lands in the active field — without filler words, slips, or repeated thoughts. Speech is recognized on-device by Sber GigaAM v3; text cleanup runs on the language model of your choice: local and offline, an external API, or a corporate gateway. Nothing is sent anywhere except to the model you choose; the only statistics are local API token and latency counters, hidden by default.

The app targets Russian speech with Latin-script technical terms.

---

## Capabilities

* **Offline recognition.** GigaAM v3 runs on-device; audio never leaves your Mac. Whisper Large-v3 Turbo and Medium are available as English-only alternatives.
* **Speech cleanup.** With a cleanup model set up, local or through an API, it removes filler words, self-corrections, and repeated thoughts while keeping the speaker's own words and facts. Without one, only sounds and stutters are removed. Numbers and Latin terms are guarded by a validator: if the model drops or invents something, the text is inserted without its edits.
* **App and site rules.** Set a tone for an app or for the site in the active browser tab, for example a business tone for work email. Without a rule, every app gets the same clean speech. Rules have their own item in the sidebar.
* **Three processing options:**
  * local models without network access, with a recommendation based on your Mac's memory;
  * an external API: OpenRouter, OpenAI, Anthropic, DeepSeek, Ollama;
  * an OpenAI-compatible corporate gateway. If it is unreachable, for example with VPN off, the text is inserted without cleanup and the overlay shows a notice.
* **Terms.** Built-in dictionaries for IT, business, HR, finance, and more. Latin terms stay in Latin script, Russian abbreviations stay in Cyrillic. The dictionary learns from your note edits.
* **Agent access.** Off by default. Once turned on in Settings, an AI agent connected over MCP reads the dictionary and adds your words with pronunciation variants, collects themed packs of its own, and, with history access granted separately, reads past dictations to find words the recognizer keeps getting wrong. Everything an agent wrote is marked in the dictionary screen and comes off with one action.
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
| **Agent Access** | Bundled `tranq-mcp` helper in Go 1.27: MCP over stdin and stdout, a Unix socket to the app |
| **Telemetry** | Local only: API tokens and latency, hidden by default |

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

## Sidebar and Settings

The sidebar has four items: Dictionary, Rules, History, Settings. A finished dictation opens History only while the main window is hidden; with the window open, the new note waits with an unread dot.

Settings has six sections, listed in the sidebar:

* **Dictation:** hotkey, hotkey mode, auto-paste, sounds.
* **Recognition:** speech model.
* **Processing:** engine, cleanup model, model instruction, links to the dictionary and rules.
* **Provider:** provider presets, URL, key, connection check, telemetry.
* **App:** language, appearance, launch at login, hide in Dock, open in History, about.
* **Data:** agent access, app logs, history lock, erase history.

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
* **Menu Bar Status Icon:** Choose Toggle or Push-to-Talk, turn sounds on or off, open the app and settings. `⌘ + ,` opens Settings.

---

## Agent Access

Tranq can hand its dictionary to an AI agent. The app ships a helper, `tranq-mcp`, that speaks MCP over stdin and stdout and reaches the app through a Unix socket in its data folder. Nothing listens on the network, and the agent you already use is the only one that sees the data.

**Switches in Settings, section Data, all off until you turn them on:**

* **Access** — read the dictionary, add words, create packs of its own.
* **Full access** — delete any word, your own hand-typed ones included, and disable packs. Confirmed with a warning.
* **History** — read your dictations. Confirmed with a warning: the text goes to the model your agent runs on.

**Connecting a client.** The settings block shows the config with the path to the helper. Clients that read an `mcpServers` config — Claude Code, Cursor, Gemini CLI, Antigravity — take the JSON tab. Codex keeps servers in TOML, so for it the block shows a `codex mcp add` command for the terminal. Copy what is shown; there is nothing else to set up.

**What the agent gets:** `list_dictionary_packs`, `list_user_words`, `list_pack_words`, `set_pack_enabled`, `add_words`, `remove_words`, `create_pack`, `delete_pack`, `revert_agent_words`, `list_dictations`. Words arrive in batches of up to 50; an agent keeps at most 20 packs of its own with up to 500 words in each. Its own words land in your personal list or in its pack, never inside a built-in dictionary, and the dictionary screen has a single action that takes all of them back.

The socket protocol is written down in [mcp/PROTOCOL.md](mcp/PROTOCOL.md).

---

## History Lock

Turn it on in Settings, section Data. Touch ID opens the history, and notes, audio and the dictation journal are encrypted on disk. The key lives on this Mac: with the Secure Enclave it cannot leave the chip, and on a Mac without one it sits in the login keychain, a weaker protection that depends on your login. Either way the history is not meant to be read on another Mac, so export a plain copy with Export before you move. The app log is not encrypted, but with the lock on it records only lengths and ids instead of dictated text, and dictionary words are redacted too. Recognition briefly writes audio to temporary files readable only by your account and deletes them when it finishes; after a crash, startup cleanup removes leftovers older than 24 hours. Erase history removes both the records and the key; with the lock on, new history is encrypted with a new key.

---

## Building from Source

```bash
# 1. Clone the repository
git clone https://github.com/Nuteres/Tranq.git
cd Tranq

# 2. Install Go 1.27 or newer, needed to build the bundled tranq-mcp helper
brew install go

# 3. Fetch the GigaAM model and llama-server; versions and SHA-256 checksums are pinned in the script
scripts/fetch-deps.sh

# 4. Open the project in Xcode
open Tranq.xcodeproj
```

Every Xcode build of the app runs a Go build phase for `tranq-mcp` and fails without Go. It uses the vendored dependencies, so Go needs no network.

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
