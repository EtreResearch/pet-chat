# ChatGPT access decision superseded

The earlier Codex CLI authentication approach is superseded by [the approved design specification](../superpowers/specs/2026-10-11-macos-pet-chat-design.md). The app plans direct Sign in with ChatGPT through its own registered identity and local OAuth flow. It must not depend on an installed Codex CLI or another application's credentials.

Direct Sign in with ChatGPT eligibility, registration for this app, account access, and real model turns remain unverified. If the app does not qualify, the selected account flow remains unresolved.
