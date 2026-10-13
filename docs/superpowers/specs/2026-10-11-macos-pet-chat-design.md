# macOS Pet Chat — Design Specification

Status: written for user review. No product code or implementation plan is approved by this document alone.

## Purpose

Build a personal macOS desktop pet for asking questions while browsing, reading, or working in other applications. A user asks directly beside the pet, sees a concise answer in a message bubble, and can follow up without opening a separate AI app. The first release is for the user's own Mac. Minimize interruption; show immediate UI feedback and stream model output. Measure actual latency on the user's Mac before making speed promises.

## Product behavior

### Desktop presence

- A single slate-blue seated cat, approximately 64 points tall, starts near the bottom-right corner above the Dock. It stays in place until dragged; persist its position.
- The chat uses layout A: one compact panel above the pet, about 340 points wide and up to about 420 points tall. Reposition it to stay on-screen near edges. Scroll older messages; keep the input fixed at the bottom.
- Clicking the pet or pressing the configurable **Control–Option–Space** shortcut opens the chat and focuses its input. Keep the menu-bar item available for Show/Hide, Settings, and Quit. Offer opt-in launch at login during setup.
- Keep a reply visible until dismissed. Escape or Close collapses the panel and preserves the draft. Do not take focus away from the app the user switched to. In full-screen apps, hide the pet until the shortcut summons it. Show one pet on the selected display; relocate it if that display disconnects.
- Capture area temporarily hides the pet and chat. After the user selects a screen region, restore the chat and show an image preview next to their question. Selection does not submit the image; send the request only when they press Send. Escape cancels capture.
- Use occasional idle blinks, a subtle thinking loop, and a brief completion reaction. Start silently. Respect Reduce Motion by disabling nonessential movement.

### Chat and response behavior

- Show a scrollable conversation containing user messages and pet replies, positioned at the newest message when opened. Retain one response at a time per chat. Stream output as it arrives. Display a subtle thinking state and a Stop action.
- Keep answers concise and neutral: usually one to three sentences or a few short bullets. Offer **Tell me more** to continue in the same chat.
- Stop cancels generation when the provider supports it. Preserve partial output with a “Stopped” label; never show interrupted output as complete. Save completed and interrupted chat state as generation progresses. Report local storage errors.
- Messages and replies remain visible until the user closes the panel. Do not send AI requests while idle.

## Providers, account access, and context

- Support local Ollama models and ChatGPT through the user's ChatGPT account. During initial setup, select a provider and one of its models. Show the active provider and model in the chat header; use the last selected pair for a new chat by default.
- Bind each chat to its selected provider and model. Changing either starts a fresh chat. Never transfer its earlier messages or images to another provider or model.
- Ollama calls its local chat service and lists installed models. Stream replies. Send screenshots only to a model that accepts images; if the selected model cannot accept an image, retain the draft and explain how to select a compatible model. Ollama accepts images through the `images` field for vision-capable models. [Ollama vision documentation](https://docs.ollama.com/capabilities/vision), [Ollama chat API](https://docs.ollama.com/api/chat).
- ChatGPT uses the documented Sign in with ChatGPT flow for personal projects that run locally and open-source apps. Use Pet Chat's actual identity, the browser-based registration and authorization flow, validated OAuth state and PKCE, and local token refresh. Store credentials in macOS Keychain. Show the connection only after identity, granted plan-use scope, and a successful model request are validated. Use the Responses API with streaming and `store: false`. Supply needed context in each request; direct plan-usage Responses do not use HTTP previous-response continuation. Images are supported only for models that accept them. [Sign in with ChatGPT overview](https://developers.openai.com/siwc/token-sharing-open-source), [registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [plan-usage guide](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt).
- The ChatGPT integration must run in the user's local environment and serve this connected application. The implementation does not depend on an installed Codex CLI or reuse another application's credentials. Eligibility, registration for this app, account access, and real model turns are not yet verified.
- Send a user's typed question and only the text or screenshot they explicitly attached and submitted. Preview an image before submission. Never read the screen in the background.
- Persist the full, scrollable history locally across app restarts. For inference, provide the current question, its attached images, and recent exchanges that fit the selected model's context budget. Older messages stay visible in history and show when they are outside the active model context. Do not imply that the model remembers those older messages.
- Provide New Chat and Delete Chat. Deleting removes the chat's local messages and associated screenshot files; the user can manage ChatGPT sign-out separately.

## Architecture

Implement a native Mac application with SwiftUI for the interface and AppKit for floating-window, focus, menu-bar, screen-capture, display, and full-screen integration. The desktop is one application surface composed of the pet, the conversation panel, a screen-region picker, settings, and a menu-bar control.

Keep four responsibilities behind small interfaces: desktop and pet interaction; chat and local history; explicit screen capture and attachment storage; and streaming model providers with cancellation. Implement one Ollama provider and one direct ChatGPT provider. The view displays common message and provider status; it does not make model requests or own OAuth credentials. Store conversation records and screenshot files under app-owned Application Support storage, and store OAuth tokens in Keychain. Use no remote conversation database, provider fallback, browser automation, voice input, or AI-requesting background task in the first release.

Treat model output, user text, and screenshot content as display-only chat data. The pet provides answers only; it does not execute commands or interact with other applications.

## Errors, privacy, and recovery

- Show concise provider errors within the chat. Preserve the user's pending question and images. Offer Retry or Reconnect when appropriate; keep the selected provider and never fail over silently.
- Handle a stopped local Ollama service, missing model, unsupported screenshot, refused ChatGPT sign-in, denied consent, revoked/expired credentials, rate or usage limits, network interruption, and failed local writes with a useful status and a recoverable action.
- Keep OAuth secrets and callback values out of messages, screen content, and logs. Validate OAuth state and PKCE before accepting the callback. Save credentials only for the user and application.
- Request screen-recording permission on the first Capture area action. If denied, explain how to enable access while leaving normal text chat usable. Do not submit an image until Send.
- Persist conversation changes as they occur. Do not claim successful saves after a storage error. Delete corresponding screenshot files when a chat is deleted.
- The idle pet and login-launched app do not issue requests. Every model request requires a user-submitted question.

## Verification

### Automated checks

- Use provider doubles to verify streamed chunks appear in order, Stop marks partial output, and failed or interrupted turns are not marked complete.
- Verify chats retain their provider/model, changing provider/model creates a fresh chat, and requests do not contain earlier chats' data.
- Verify screenshot attachments persist and delete with the correct chat, incompatible image submissions retain the draft, and older visible messages are excluded beyond the active context budget.
- Verify chat restoration and deletion with an isolated local store, including failed-write handling.
- Verify OAuth state, PKCE, issuer/audience/expiry/nonce validation, granted-scope checks, account mismatch rejection, refresh, and secret redaction using test responses. Do not use a real access token in tests.
- Verify only explicit Send actions trigger model requests, and that no startup or idle path triggers a request.

### Checks on the user's Mac

Check opening, shortcut conflict handling and customization, focus ownership, Escape with drafts, floating-window behavior, screen-edge placement, dragging, full-screen apps, capture permission and cancellation, display removal, opt-in login launch, VoiceOver, and Reduce Motion. Validate actual on-screen sizing and all three animation states. Exercise a real local Ollama text exchange and image-capable exchange, then a ChatGPT authorization and streaming exchange if the account is eligible. Measure time from Send to first visible text and completion for selected models; report measurements without promising the same latency across models or networks.

## Scope

First release: macOS, one cat, text questions, explicitly pasted or captured text/images, Ollama, direct ChatGPT account access, concise streaming replies, local persistent chats, model selection, a global shortcut, menu-bar controls, opt-in login launch, and accessible reduced-motion behavior.

Excluded: Windows or Linux, multiple pets or pet import, roaming, voice input/output, automatic screen observation, web search, app control or code execution, cross-device sync, remote history storage, and silent provider switching.

## Known limits and decisions to validate

- Current OpenAI guidance includes personal projects that run locally in ChatGPT plan usage; this app is scoped to that use. Recheck the terms before distributing it, charging for it, or hosting it remotely. This app's registration, the user's account/workspace eligibility, model access, usage limits, and data terms remain unverified until a real sign-in and model turn succeed. If eligibility changes or sign-in is refused, the account flow remains unresolved.
- Image understanding depends on selected model capability at both providers. The direct OpenAI route has preview restrictions; it does not support audio/video input, file upload API, file search, hosted tools, or response-state continuation. This first release uses text and model-supported image input only.
- Native floating-panel focus, ScreenCaptureKit permission and region selection, hotkey behavior, full-screen spaces, startup registration, and multi-display relocation require a working macOS prototype before they can be promised.
- The oldest supported macOS version remains a prototype decision. Choose it after checking the APIs required for login launch, capture, window behavior, and accessibility against the available Mac and SDK.

## Existing working notes

This specification supersedes contradictory untracked `CONTEXT.md` and `docs/adr/0001-chatgpt-via-codex-cli.md` working notes in the current workspace. Review and reconcile those files before treating them as project guidance; they are not included in this design checkpoint.

## Next step

After user review and approval of this specification, create a separate implementation plan and ask the user how they want to execute it. This design approval does not approve code changes.
