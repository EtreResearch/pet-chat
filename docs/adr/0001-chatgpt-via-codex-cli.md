# ChatGPT access decision superseded

The earlier Codex CLI authentication approach is superseded by [the approved design specification](../superpowers/specs/2026-10-11-macos-pet-chat-design.md). The app plans direct Sign in with ChatGPT through its own registered identity and local OAuth flow. It must not depend on an installed Codex CLI or another application's credentials.

Current OpenAI guidance includes personal projects that run locally in ChatGPT plan usage; this app is scoped to local personal use. App registration, account/workspace access, and real model turns remain unverified. Recheck terms before any distribution, paid, or remote-hosted use. See the [official local-project guide](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt).
