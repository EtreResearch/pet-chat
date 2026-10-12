# Pet Chat

A native macOS desktop pet for asking questions beside the current work. The approved product behavior and architecture are in [the design specification](docs/superpowers/specs/2026-10-11-macos-pet-chat-design.md).

Chats persist locally across app restarts. Each chat stays bound to its chosen provider and model. The app supports local Ollama and plans direct Sign in with ChatGPT access. Current OpenAI guidance includes personal projects that run locally; app registration, account/workspace access, and real ChatGPT model turns remain unverified. See the [official local-project guide](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt).
