<p align="center">
  <img src="Brand/tq.svg" width="96" alt="Tranq">
</p>

<h1 align="center">Tranq</h1>

<p align="center">
  <b>Clean voice dictation for macOS</b><br>
  Press a key, speak, and clean, concise text lands in the active field.
</p>

<p align="center">
  <a href="https://github.com/Hidden-Den/Tranq/releases/latest"><b>Download</b></a> ·
  <a href="README.md">Русский</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

> Tranq is built for **Russian speech** with Latin-script technical terms. The main documentation is in Russian; this page is a short English overview.

Tranq turns natural speech into text you can send as is. Filler words, slips, self-corrections and repeated thoughts are removed, while your own words, numbers and facts stay intact.

Speech is recognized on-device by Sber's **GigaAM v3**; audio never leaves your Mac. Cleanup runs on the language model of your choice: a local model without network access, an external API, or a corporate gateway.

## Features

- **Offline recognition** with GigaAM v3. Whisper Large-v3 Turbo and Medium are available for English.
- **Speech cleanup** that keeps the speaker's words. If the model drops a number or invents a word, a validator inserts the text without its edits.
- **Long dictations** are cleaned in chunks and inserted as paragraphs.
- **Three processing options:** a local model picked for your Mac's memory; OpenRouter, OpenAI, Anthropic, DeepSeek or Ollama; any OpenAI-compatible corporate gateway.
- **Per-app and per-site tone rules**, for example a business tone for work email.
- **Term dictionary** with built-in packs and your own words. It learns from your edits.
- **Insertion under the cursor** in any app, toggle or push-to-talk.
- **History** with the final text, the raw transcript and the recording, optionally locked with Touch ID and encrypted on disk.
- **MCP access** for Claude Code, Cursor, Codex and other agents to extend your dictionary. Off by default.

## Install

1. Download `Tranq.dmg` from [Releases](https://github.com/Hidden-Den/Tranq/releases/latest) and drag `Tranq.app` to Applications.
2. The build is ad-hoc signed and not notarized, so remove the quarantine flag once:

   ```bash
   xattr -cr /Applications/Tranq.app
   ```

3. Grant **Microphone** and **Accessibility** permissions.
4. Press `⌥ Space`, speak, press it again.

Requires macOS 13.5 or later on Apple Silicon.

## Privacy

Audio stays on your Mac. Text goes only to the cleanup model you choose; with a local model it never leaves the Mac. There is no analytics or telemetry. The app checks GitHub for updates every few hours.

## Building

See [docs/development.md](docs/development.md), in Russian: Xcode 26+, Go 1.27+, then `scripts/fetch-deps.sh` and `open Tranq.xcodeproj`.

## License

[MIT](LICENSE). Original work © 2026 Kozak Developer (Berliner187). Modifications © 2026 Nuteres.
