# Pet Chat

A personal native macOS cat that opens a compact streaming chat panel. Chats stay bound to their selected provider and model. Ollama runs on this Mac; direct ChatGPT plan usage requires an eligible account and explicit authorization.

## Build and run

The project targets macOS 14 or later, uses Swift 6, SwiftUI/AppKit and SwiftData, and has no package dependencies. Validation used macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Apple M5 Pro, 48 GiB RAM and 15 logical CPUs. Runtime behavior on macOS 14 has not been checked.

From this directory:

```sh
xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
xcodebuild build -project PetChat.xcodeproj -scheme PetChat -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/pet-chat-release CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
mkdir -p build
ditto /private/tmp/pet-chat-release/Build/Products/Release/PetChat.app build/PetChat.app
codesign --verify --deep --strict --verbose=2 build/PetChat.app
open build/PetChat.app
```

`build/PetChat.app` is the local Release artifact. It is ad-hoc signed for this Mac, without Developer ID signing or notarization; it is not a distribution package. Keep one app instance running. Xcode's macOS UI runner also needs local signing. Automated test launches use DEBUG-only synthetic providers, images, login actions, isolated preferences and temporary history; unit-test host startup does not open personal history or desktop UI.

## First use

Click the cat or press **Control–Option–Space**, select a provider and model, then choose **Start chatting**. Type a question and press **Send** or **Command–Return**. Follow-ups keep the same conversation; **Tell me more** expands the completed answer. **Stop** cancels an answer and retains the draft. On a request error, **Retry** resubmits the retained draft. Answers stream into the panel.

**Close** or **Escape** collapses the panel and keeps the current in-memory draft. Draft text and unsent image selection are not restored after quitting. **Chat → New Chat** starts fresh with the same provider/model; **Change model** selects a provider/model for a new chat. **Delete Chat** removes the selected local conversation and its own attachment directory. Existing chats are not converted between providers. The last saved chat is restored after restart; there is no chat-history browser in this version.

Drag the cat to move it. Its position is saved per display. The menu-bar cat provides Hide/Show Pet, Settings and Quit. Full-screen spaces hide the pet until the global shortcut explicitly summons it. Settings offer the shortcut recorder, pet display, Standard (13 pt) or Larger (17 pt) text, and ChatGPT sign-out. Animations follow macOS Reduce Motion and colors follow the system appearance. A shortcut registration conflict is shown in Settings; record another combination there.

## Providers

For **Ollama**, install and start Ollama yourself and install a model using its documented tools. The app connects only to `http://localhost:11434`; choose **Refresh models** if the server/model was unavailable. It reads the installed model's capabilities and configured context window. Images require a model reporting vision support. It does not install models or execute model tools. Connection, missing-model and interrupted-stream errors leave the draft available for recovery.

For **ChatGPT**, choose ChatGPT, then **Connect ChatGPT** to initiate sign-in in your browser and approve plan usage. This is the direct local/open-source OAuth flow, without an API key. It does not read your ChatGPT conversation history. OpenAI describes this flow for locally hosted/open-source apps; account, workspace, model availability, policies and usage limits can still prevent access. Check the current [official overview](https://developers.openai.com/siwc/token-sharing-open-source) before relying on eligibility. Paid or remotely hosted distribution has a separate approval path.

ChatGPT sends eligible streamed Responses requests with `store:false`; the app supplies its local conversation context. It does not use hosted tools, audio, video or Files APIs. Current requirements and exclusions are listed in [OpenAI's preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations). If sign-in/permission/eligibility fails, use the displayed recovery message rather than repeatedly retrying an ineligible account. On expired or revoked access, reconnect explicitly. Sign out removes this app's active local credential and stops its ChatGPT work; it retains local chats, drafts and Ollama settings. Remote revocation is not performed: disconnect the app in ChatGPT settings if needed. Live ChatGPT sign-in and inference have not been exercised in this validation.

## Images and permissions

**Capture area** starts an explicit region capture and may request macOS Screen Recording permission. It hides the pet and panel while selecting. Escape cancels selection. If permission is denied, use System Settings → Privacy & Security → Screen Recording (the app offers a link) and follow macOS's restart guidance. This validation did not grant screen permission or capture real desktop content.

**Paste image** reads an image from the clipboard only when clicked and does not require Screen Recording. Ordinary text paste works in the message editor. Captured/pasted images first appear as removable previews and are sent only after **Send**. Review the selected provider before submitting sensitive text or images. Stored images remain local until submitted, and the selected provider receives the current image plus the selected local text context. Preview removal deletes an unsent image file; chat deletion cleans that chat's attachments. Starting a new chat discards the in-memory draft; its old draft image files remain associated with the old chat until deletion.

**Launch at login** is off by default. Only the explicit toggle requests SMAppService registration. macOS may require approval in System Settings → General → Login Items. Disable the toggle to unregister. Actual Login Items registration was not enabled during validation; the local ad-hoc bundle's registration behavior still requires a user check.

## Local data and validation limits

History uses `~/Library/Application Support/PetChat/Chats.store` and SwiftData's companion files. Images use `~/Library/Application Support/PetChat/Attachments/<chat UUID>/`. Preferences use the app's macOS defaults domain. ChatGPT access/refresh credentials use this app's Keychain service, `com.etre.pet-chat.chatgpt`; sign-in does not reuse another application's credentials. Local chat/image files are not encrypted by the app. The generic `~/Library/Application Support/default.store` used by earlier development builds is deliberately left untouched and is not imported, because it could belong to another app. Use **Delete Chat** for scoped deletion; do not delete a generic SwiftData store.

On the machine above, the installed Ollama model was `gemma4:e4b` (reported 8.0B, Q4_K_M, approximately 9.6 GB), with image support and a 4096-token effective context. A single benign text turn through the production provider took **6.830 s to first received text / 6.846 s to stream completion**. One synthetic 32×32 PNG turn took **3.636 s / 3.661 s**. Timing used monotonic process uptime around provider-stream iteration, including provider request preparation. These are stream-receipt measurements, not first-visible-text measurements or a benchmark. No model was downloaded, no tools were executed, and no desktop pixels were used for these smokes. Other models, prompt lengths, load and warm-up state can change timing.

The deterministic suite covers provider parsing/authentication, context/history, cancellation, scoped attachment deletion, native desktop lifecycle and isolated UI flows. On 2026-10-12, the complete signed suite passed **136 unit tests and 8 UI tests (144 total), with zero failures**. The Release build succeeded; strict code-signature verification passed for both the built and delivered `build/PetChat.app` bundles (local ad-hoc signature). Window-only synthetic screenshots verified the capture preview, settings and Larger text layout without clipping. Manual VoiceOver, multi-display/full-screen transitions, real screen capture and clipboard image paste, Login Items approval, oldest-supported-OS runtime and live ChatGPT account behavior remain user checks.
