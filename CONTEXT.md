# Pet Chat

A native macOS desktop pet for asking questions beside the current work. The approved product behavior and architecture are in [the design specification](docs/superpowers/specs/2026-10-11-macos-pet-chat-design.md).

Chats persist locally across app restarts. Each chat stays bound to its chosen provider and model. The app supports local Ollama and plans direct Sign in with ChatGPT access. Current OpenAI guidance includes personal projects that run locally; app registration, account/workspace access, and real ChatGPT model turns remain unverified. See the [official local-project guide](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt).

## Language

**Draft**:
The text and images in the message box that have not been sent yet. Sending empties the Draft; if a send fails before the message appears in the chat, its text and images return to the Draft (unless a new Draft has been started).
_Avoid_: composer text, input, unsent message

**Turn**:
One user message and the Pet reply that answers it. A failed or interrupted Turn stays in the chat and is retried in place.
_Avoid_: exchange, round
