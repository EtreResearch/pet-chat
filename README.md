# Pet Chat

A little cat that sits in the corner of your Mac's screen. Click it, ask a question, get a short answer, and keep working.

<p align="center"><img src="docs/images/chat.png" width="400" alt="Pet Chat answering 'Why is the sky blue?', with the cat below the chat"></p>

## What you need

- A Mac with macOS 14 or newer.
- An AI to answer you. Pick one:
  - **Ollama**: free, private, and runs on your Mac. Install it from [ollama.com](https://ollama.com), then download a model, for example `ollama pull gemma3`.
  - **ChatGPT**: uses your ChatGPT account, no API key needed. Your account must be eligible; see [OpenAI's guide](https://developers.openai.com/siwc/token-sharing-open-source).

## Install

1. Download the latest `PetChat-<version>.dmg` from [Releases](https://github.com/EtreResearch/pet-chat/releases/latest).
2. Open it and drag **Pet Chat** into **Applications**.
3. Open **Pet Chat** from Applications.
4. The first time, macOS warns that it can't check the app. Click **Done** (or **OK**). Then go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** and enter your password. You only do this once, because Pet Chat isn't signed by Apple yet.

**To update**, download the new version and replace the old app in Applications. If you use ChatGPT, macOS may ask about the keychain once; click **Always Allow**.

## Use it

1. Click the cat or the Dock icon, or press **Control + Option + Space**.
2. The first time, pick who answers you and click **Start chatting**.

   <img src="docs/images/setup.png" width="320" alt="Choosing Ollama and the gemma4 model">

3. Type a question and press **Return**. Use **Shift + Return** for a new line.

Also:
- **Tell me more** gives a longer answer. **Copy** and **Retry** sit under each answer.
- Drag an image into the message box, or use **Capture area** or **Paste image**, to show Pet a picture. Check its preview, then send.
- The **Chat** menu starts a new chat, changes the model, or deletes the chat.
- **Settings** (Command + , or the menu-bar cat): shortcut, screen, cat color, text size, launch at login, and **Show in Dock**. Cat colors apply immediately and are remembered next time.

## Privacy

- Chats stay on your Mac, in `~/Library/Application Support/PetChat`. They are not encrypted.
- With Ollama, nothing leaves your Mac.
- With ChatGPT, your question, recent messages in that chat, and any image go to OpenAI when you send. Your login is kept in the macOS Keychain, and **Sign out of ChatGPT** in Settings removes it.

## For developers

Swift 6, SwiftUI/AppKit and SwiftData. No third-party dependencies. You need Xcode.

```sh
# Run the tests
xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES

# Build a DMG into dist/
scripts/make-dmg.sh 0.1.0

# Release: the workflow tests, builds the DMG and creates a draft release to publish
git tag v0.1.0 && git push origin v0.1.0
```

The design is in [`docs/superpowers/specs`](docs/superpowers/specs/). Screenshots are rendered from the app's own views with a real answer from a local Ollama model.

Not yet checked by hand: live ChatGPT sign-in, VoiceOver, multiple displays and full-screen apps, real screen capture, Login Items approval, and macOS 14.
