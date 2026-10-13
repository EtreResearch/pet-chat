# Pet Chat

A little cat that lives in the corner of your Mac's screen. Click it, ask a question, and get a short answer without leaving what you're doing.

<p align="center"><img src="docs/images/chat.png" width="380" alt="Pet Chat answering 'Why is the sky blue?' with the cat below the chat panel"></p>

## What you need

- A Mac running macOS 14 or newer, with Xcode installed (to build the app).
- An AI to talk to. Pick one:
  - **Ollama** (free, runs on your Mac, private). Install it from [ollama.com](https://ollama.com) and download a model, for example `ollama pull gemma3`.
  - **ChatGPT** (uses your ChatGPT account; no API key needed). Your account must be eligible; see [OpenAI's guide](https://developers.openai.com/siwc/token-sharing-open-source).

## Install

In Terminal, from this folder:

```sh
xcodebuild build -project PetChat.xcodeproj -scheme PetChat -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/pet-chat-release CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
mkdir -p build && ditto /private/tmp/pet-chat-release/Build/Products/Release/PetChat.app build/PetChat.app
open build/PetChat.app
```

The cat appears in the bottom-right corner, and a cat icon appears in the menu bar. There is no Dock icon.

## Use it

1. **Click the cat** or press **Control + Option + Space** from any app.
2. The first time, choose who answers you, then click **Start chatting**:

   <img src="docs/images/setup.png" width="320" alt="Choosing Ollama and a model">

   - For **Ollama**, choose a model (click **Refresh models** if the list is empty).
   - For **ChatGPT**, click **Connect ChatGPT** and approve the sign-in in your browser.
3. Type your question and press **Send** (or **Command + Return**).
4. Want a longer answer? Click **Tell me more**.
5. Press **Escape** or **Close** to tuck the chat away. Your unsent text stays.

### Handy extras

- **Show the AI something on screen:** click **Capture area** and drag over part of your screen, or copy a picture and click **Paste image**. Nothing is sent until you press **Send**. The first capture asks for Screen Recording permission.
- **Stop** cuts an answer short. **Retry** tries again if something failed.
- **Chat menu:** start a **New Chat**, **Change model**, or **Delete Chat**.
- **Move the cat** by dragging it.
- **Menu-bar cat:** hide or show the pet, open **Settings** (change the shortcut, pick a screen, make the text bigger, sign out of ChatGPT, launch at login), or **Quit**.

## Privacy

- Your chats and images are stored only on your Mac, in `~/Library/Application Support/PetChat`. They are not encrypted.
- With Ollama, nothing leaves your Mac.
- With ChatGPT, your question, recent messages from the same chat, and any attached image go to OpenAI when you press **Send**. Your ChatGPT login is kept in the macOS Keychain.
- **Sign out of ChatGPT** stops requests, attempts to end the remote session, and removes local tokens. The app keeps the account's registration for later sign-in. If remote revocation cannot be confirmed, Settings shows a warning to disconnect the app in ChatGPT Settings.

## For developers

Swift 6, SwiftUI/AppKit and SwiftData. The project has no third-party dependencies. Run the tests (161 unit and UI tests, all passing as of 2026-10-13):

```sh
xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

The built app is ad-hoc signed for your own Mac only. It is not notarized for sharing. The design is in [`docs/superpowers/specs`](docs/superpowers/specs/2026-10-11-macos-pet-chat-design.md). The screenshots are rendered from the app's own views, with a real answer from a local Ollama model.

Not yet checked by hand: live ChatGPT sign-in, VoiceOver, multiple displays and full-screen apps, real screen capture, Login Items approval, and macOS 14.
